"""
### BanVic - Pipeline Medalhão (Landing → Bronze → Silver → Gold)

Orquestra a ingestão das 7 tabelas do ERP do BanVic (`banvic_data.zip`).

| Etapa | O que faz | Onde executa |
|---|---|---|
| `resolve_ingestion_date` | Define a partição do dia (param > logical_date > run_after) | Airflow |
| `landing.wait_for_landing_file` | Sensor: aguarda o zip do legado no MinIO | Airflow (reschedule) |
| `landing.landing_to_bronze` | Valida contrato, extrai CSVs para `bronze/` e grava manifesto | Airflow |
| `bronze.load_bronze` | Meltano `tap-csv → target-postgres`, 1 pod por tabela | Pod efêmero |
| `bronze.bronze_quality` | Contagem lake × DW + auditoria em `ops.pipeline_audit` | Airflow |
| `silver.dbt_silver` | `dbt build --select tag:silver` (modelos + testes) | Pod efêmero |
| `gold.dbt_gold` | `dbt build --select tag:gold` (modelos + testes) | Pod efêmero |
| `gold.audit_layers` | Contagens finais Silver/Gold em `ops.pipeline_audit` | Airflow |

**Idempotência:** reexecutar o mesmo dia sobrescreve a partição do lake,
faz UPSERT por PK na Bronze, recria Silver/Gold (transações: delete+insert por PK)
e faz UPSERT na auditoria. Nenhuma reexecução duplica dados.

**Reprocessar um dia específico:** *Trigger DAG w/ config* →
`{"ingestion_date": "2026-10-13"}`.
"""

from __future__ import annotations

import json
import logging
import tempfile
from datetime import date, timedelta
from pathlib import Path

import pendulum
from airflow.providers.amazon.aws.hooks.s3 import S3Hook
from airflow.providers.amazon.aws.sensors.s3 import S3KeySensor
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.sdk import Asset, Param, TaskGroup, dag, get_current_context, task
from airflow.sdk.exceptions import AirflowFailException
from kubernetes.client import models as k8s

from banvic import config, quality
from banvic.callbacks import (
    notify_dag_failure,
    notify_dag_success,
    notify_task_failure,
    notify_task_retry,
)
from banvic.contracts import GOLD_TABLES, SILVER_TABLES, TABLES
from banvic.landing import LandingValidationError, extract_and_validate

log = logging.getLogger(__name__)

INGESTION_DATE = "{{ ti.xcom_pull(task_ids='resolve_ingestion_date') }}"

# Assets (linhagem no Airflow 3): permitem que outras DAGs (ex.: refresh de BI)
# sejam disparadas quando a camada for atualizada.
_DW_URI = "postgres://postgres-dw.data:5432/banvic_dw"
BRONZE_ASSET = Asset(name="banvic_bronze_transacoes", uri=f"{_DW_URI}/bronze/transacoes")
SILVER_ASSET = Asset(name="banvic_silver_transacoes", uri=f"{_DW_URI}/silver/transacoes")
GOLD_ASSET = Asset(name="banvic_gold_mart_cliente_mensal", uri=f"{_DW_URI}/gold/mart_cliente_mensal")

DEFAULT_ARGS = {
    "owner": "data-engineering",
    "depends_on_past": False,
    # Resiliência: 3 novas tentativas com backoff exponencial (30s, 60s, 120s...)
    "retries": 3,
    "retry_delay": timedelta(seconds=30),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=10),
    "execution_timeout": timedelta(minutes=30),
    # Monitoramento
    "on_failure_callback": notify_task_failure,
    "on_retry_callback": notify_task_retry,
}


def _pipeline_pod_defaults(db_secret: str) -> dict:
    """Configuração comum aos pods efêmeros do pipeline (Meltano/dbt)."""
    return {
        "namespace": config.JOBS_NAMESPACE,
        "image": config.PIPELINE_IMAGE,
        "image_pull_policy": "IfNotPresent",
        "in_cluster": True,
        "get_logs": True,
        "log_events_on_failure": True,
        "startup_timeout_seconds": 300,
        # Pods com sucesso são removidos; pods com falha ficam para inspeção.
        "on_finish_action": "delete_succeeded_pod",
        # Credenciais montadas a partir de Secrets - nunca passam pelo código.
        "env_from": [
            k8s.V1EnvFromSource(config_map_ref=k8s.V1ConfigMapEnvSource(name=config.PIPELINE_CONFIGMAP)),
            k8s.V1EnvFromSource(secret_ref=k8s.V1SecretEnvSource(name=config.LAKE_SECRET)),
            k8s.V1EnvFromSource(secret_ref=k8s.V1SecretEnvSource(name=db_secret)),
        ],
        "container_resources": k8s.V1ResourceRequirements(
            requests={"cpu": "250m", "memory": "512Mi"},
            limits={"memory": "1Gi"},
        ),
        "container_security_context": k8s.V1SecurityContext(
            run_as_non_root=True,
            allow_privilege_escalation=False,
            capabilities=k8s.V1Capabilities(drop=["ALL"]),
        ),
    }


@dag(
    dag_id="banvic_medallion",
    description="ERP BanVic: landing (MinIO) -> bronze (Meltano) -> silver/gold (dbt) no Postgres",
    schedule="@daily",
    start_date=pendulum.datetime(2026, 10, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    dagrun_timeout=timedelta(hours=2),
    default_args=DEFAULT_ARGS,
    on_failure_callback=notify_dag_failure,
    on_success_callback=notify_dag_success,
    params={
        "ingestion_date": Param(
            None,
            type=["null", "string"],
            format="date",
            description="Opcional (AAAA-MM-DD). Reprocessa uma partição específica.",
        ),
    },
    tags=["banvic", "medallion", "meltano", "dbt"],
    doc_md=__doc__,
)
def banvic_medallion():
    @task(retries=0)
    def resolve_ingestion_date() -> str:
        """Data da partição: param explícito > logical_date > run_after (UTC)."""
        context = get_current_context()
        override = (context.get("params") or {}).get("ingestion_date")
        if override:
            return date.fromisoformat(override).isoformat()
        reference = context.get("logical_date") or context["dag_run"].run_after
        return pendulum.instance(reference).in_timezone("UTC").date().isoformat()

    ingestion_date = resolve_ingestion_date()

    # ------------------------------------------------------------------ LANDING
    with TaskGroup(group_id="landing", tooltip="Arquivo do legado → zona bronze do lake"):
        wait_for_landing_file = S3KeySensor(
            task_id="wait_for_landing_file",
            aws_conn_id=config.LAKE_CONN_ID,
            bucket_name=config.LAKE_BUCKET,
            bucket_key=f"landing/ingestion_date={INGESTION_DATE}/{config.LANDING_FILE_NAME}",
            mode="reschedule",  # libera o slot entre verificações
            poke_interval=60,
            exponential_backoff=True,
            max_wait=timedelta(minutes=10),
            timeout=int(timedelta(hours=6).total_seconds()),
            retries=0,
        )

        @task
        def landing_to_bronze(ingestion_date: str) -> dict:
            """Valida o zip contra o contrato e publica os CSVs em bronze/ (sobrescreve)."""
            hook = S3Hook(aws_conn_id=config.LAKE_CONN_ID)
            with tempfile.TemporaryDirectory() as tmp:
                local_zip = hook.download_file(
                    key=config.landing_key(ingestion_date),
                    bucket_name=config.LAKE_BUCKET,
                    local_path=tmp,
                    preserve_file_name=True,
                )
                try:
                    extracted = extract_and_validate(Path(local_zip), Path(tmp) / "extracted")
                except LandingValidationError as exc:
                    # Arquivo fora do contrato: retry não resolve -> falha imediata.
                    raise AirflowFailException(str(exc)) from exc

                for table, info in extracted.items():
                    hook.load_file(
                        filename=str(info.path),
                        key=config.bronze_key(table, ingestion_date),
                        bucket_name=config.LAKE_BUCKET,
                        replace=True,
                    )
                    log.info("bronze/%s: %s linhas (sha256=%s)", table, info.row_count, info.sha256[:12])

            manifest = {
                "ingestion_date": ingestion_date,
                "source_key": config.landing_key(ingestion_date),
                "row_counts": {t: i.row_count for t, i in extracted.items()},
                "sha256": {t: i.sha256 for t, i in extracted.items()},
                "generated_at": pendulum.now("UTC").isoformat(),
            }
            hook.load_string(
                json.dumps(manifest, indent=2),
                key=config.manifest_key(ingestion_date),
                bucket_name=config.LAKE_BUCKET,
                replace=True,
            )
            return manifest

        manifest = landing_to_bronze(ingestion_date)
        ingestion_date >> wait_for_landing_file >> manifest

    # ------------------------------------------------------------------- BRONZE
    with TaskGroup(group_id="bronze", tooltip="Meltano: lake → bronze.* no Postgres"):

        @task
        def bronze_pod_arguments(manifest: dict) -> list[list[str]]:
            """Um conjunto de argumentos por tabela -> dynamic task mapping."""
            return [["bronze", "--table", table, "--ingestion-date", manifest["ingestion_date"]] for table in TABLES]

        load_bronze = KubernetesPodOperator.partial(
            task_id="load_bronze",
            name="banvic-bronze-load",
            labels={"app": "banvic-pipeline", "layer": "bronze"},
            map_index_template="{{ task.arguments[2] }}",
            max_active_tis_per_dagrun=config.BRONZE_MAX_PARALLEL_PODS,
            outlets=[BRONZE_ASSET],
            **_pipeline_pod_defaults(config.DW_INGESTION_SECRET),
        ).expand(arguments=bronze_pod_arguments(manifest))

        @task
        def bronze_quality(manifest: dict) -> None:
            """Linhas carregadas da partição do dia == linhas do CSV (manifesto)."""
            run_id = get_current_context()["run_id"]
            day = manifest["ingestion_date"]
            hook = PostgresHook(postgres_conn_id=config.DW_CONN_ID)
            pattern = f"%ingestion_date={day}/%"

            rows = [quality.AuditRow("landing", t, n, None, "ok") for t, n in manifest["row_counts"].items()]
            for table, expected in manifest["row_counts"].items():
                loaded = hook.get_first(quality.bronze_partition_count_sql(table), parameters=(pattern,))[0]
                rows.append(quality.compare("bronze", table, loaded, expected))

            for row in rows:
                hook.run(quality.AUDIT_UPSERT_SQL, parameters=row.as_params(run_id, day))

            failed = [r for r in rows if r.status == "fail"]
            for r in rows:
                log.info(
                    "%-7s %-22s %8s (esperado %s) %s", r.layer, r.table_name, r.row_count, r.expected_count, r.status
                )
            if failed:
                raise AirflowFailException(
                    "Divergência lake x DW: "
                    + ", ".join(f"{r.table_name}={r.row_count}/{r.expected_count}" for r in failed)
                )

        quality_bronze = bronze_quality(manifest)
        load_bronze >> quality_bronze

    # ------------------------------------------------------------------- SILVER
    with TaskGroup(group_id="silver", tooltip="dbt: tipagem, padronização e testes"):
        dbt_silver = KubernetesPodOperator(
            task_id="dbt_silver",
            name="banvic-dbt-silver",
            labels={"app": "banvic-pipeline", "layer": "silver"},
            arguments=["dbt", "--select", "tag:silver", "--ingestion-date", INGESTION_DATE],
            outlets=[SILVER_ASSET],
            **_pipeline_pod_defaults(config.DW_TRANSFORM_SECRET),
        )

    # --------------------------------------------------------------------- GOLD
    with TaskGroup(group_id="gold", tooltip="dbt: modelo dimensional e marts"):
        dbt_gold = KubernetesPodOperator(
            task_id="dbt_gold",
            name="banvic-dbt-gold",
            labels={"app": "banvic-pipeline", "layer": "gold"},
            arguments=["dbt", "--select", "tag:gold", "--ingestion-date", INGESTION_DATE],
            outlets=[GOLD_ASSET],
            **_pipeline_pod_defaults(config.DW_TRANSFORM_SECRET),
        )

        @task
        def audit_layers(ingestion_date: str) -> dict:
            """Registra as contagens finais de Silver e Gold para a execução."""
            run_id = get_current_context()["run_id"]
            hook = PostgresHook(postgres_conn_id=config.DW_CONN_ID)
            summary: dict[str, int] = {}
            for layer, tables in (("silver", SILVER_TABLES), ("gold", GOLD_TABLES)):
                for table in tables:
                    n = hook.get_first(quality.count_sql(layer, table))[0]
                    row = quality.AuditRow(layer, table, n, None, "ok")
                    hook.run(quality.AUDIT_UPSERT_SQL, parameters=row.as_params(run_id, ingestion_date))
                    summary[f"{layer}.{table}"] = n
            log.info("Resumo da execução: %s", json.dumps(summary, indent=2))
            return summary

        audit = audit_layers(ingestion_date)

    quality_bronze >> dbt_silver >> dbt_gold >> audit


banvic_medallion()

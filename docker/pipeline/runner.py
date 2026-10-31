"""Entrypoint da imagem banvic/pipeline (executada pelo KubernetesPodOperator).

Subcomandos:
    bronze  Lê o manifesto PUBLICADO da partição, baixa os arquivos que ele lista e roda
            Meltano (tap-csv -> target-postgres) para UMA tabela. Nunca lê arquivos que
            não estejam no manifesto (execuções que falharam no meio ficam invisíveis).
    dbt     Roda `dbt build` para um seletor (tag:silver / tag:gold) e publica os
            artefatos (run_results.json) no lake para auditoria.

Toda configuração vem de variáveis de ambiente (ConfigMap + Secrets do Kubernetes):
    S3_ENDPOINT_URL, LAKE_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
    DW_HOST, DW_PORT, DW_DATABASE
    TARGET_POSTGRES_USER/PASSWORD (bronze)  |  DBT_USER/DBT_PASSWORD (dbt)
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
from datetime import date
from pathlib import Path

import boto3
from botocore.config import Config

TABLES = (
    "agencias",
    "colaboradores",
    "colaborador_agencia",
    "clientes",
    "contas",
    "propostas_credito",
    "transacoes",
)

MELTANO_BIN = os.getenv("MELTANO_BIN", "/opt/venvs/meltano/bin/meltano")
MELTANO_PROJECT = Path(os.getenv("MELTANO_PROJECT_ROOT", "/app/ingestion/meltano"))
DBT_BIN = os.getenv("DBT_BIN", "/opt/venvs/dbt/bin/dbt")
DBT_PROJECT = Path(os.getenv("DBT_PROJECT_DIR", "/app/transform/dbt"))
WORK_DIR = Path(os.getenv("WORK_DIR", "/app/work"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [runner] %(message)s",
)
log = logging.getLogger("runner")


def _require_env(*names: str) -> None:
    missing = [n for n in names if not os.getenv(n)]
    if missing:
        raise SystemExit(f"Variáveis de ambiente obrigatórias ausentes: {', '.join(missing)}")


def _s3_client():
    _require_env("S3_ENDPOINT_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT_URL"],
        region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
        config=Config(retries={"max_attempts": 5, "mode": "standard"}),
    )


def manifest_key(ingestion_date: str) -> str:
    """Manifesto da partição: aponta para a versão vigente (mesmo caminho de dags/banvic/config.py)."""
    return f"bronze/_manifests/ingestion_date={ingestion_date}/manifest.json"


def committed_files(manifest: dict) -> dict[str, str]:
    """Arquivos da versão publicada, um por tabela. Manifesto incompleto = erro (não carrega nada)."""
    files = manifest.get("files") or {}
    missing = [t for t in TABLES if t not in files]
    if missing:
        raise SystemExit(f"Manifesto sem as tabelas {missing}: partição não publicada por inteiro")
    return {t: files[t] for t in TABLES}


def _read_manifest(s3, bucket: str, ingestion_date: str) -> dict:
    key = manifest_key(ingestion_date)
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except s3.exceptions.NoSuchKey as exc:
        raise SystemExit(f"Partição {ingestion_date} não publicada: s3://{bucket}/{key} não existe") from exc
    return json.loads(body)


def _run(cmd: list[str], cwd: Path, extra_env: dict[str, str]) -> int:
    env = {**os.environ, **extra_env}
    log.info("Executando: %s (cwd=%s)", " ".join(cmd), cwd)
    return subprocess.run(cmd, cwd=cwd, env=env, check=False).returncode


def cmd_bronze(table: str, ingestion_date: str) -> int:
    if table not in TABLES:
        raise SystemExit(f"Tabela desconhecida: {table}. Esperado: {TABLES}")
    _require_env("LAKE_BUCKET", "DW_HOST", "DW_DATABASE", "TARGET_POSTGRES_USER", "TARGET_POSTGRES_PASSWORD")

    bucket = os.environ["LAKE_BUCKET"]
    s3 = _s3_client()
    manifest = _read_manifest(s3, bucket, ingestion_date)
    files = committed_files(manifest)

    # O nome da pasta local carrega partição e execução: vira _sdc_source_file na
    # Bronze (linhagem até a versão exata que foi carregada).
    input_dir = WORK_DIR / f"ingestion_date={ingestion_date}" / f"run={manifest['run_token']}"
    input_dir.mkdir(parents=True, exist_ok=True)

    # O tap-csv faz discovery de todos os arquivos declarados no meltano.yml,
    # então baixamos a partição completa (~4 MB) e carregamos só a tabela pedida.
    for name, key in files.items():
        log.info("Baixando s3://%s/%s", bucket, key)
        s3.download_file(bucket, key, str(input_dir / f"{name}.csv"))

    return _run(
        [MELTANO_BIN, "run", "--no-state-update", "tap-csv", "target-postgres"],
        cwd=MELTANO_PROJECT,
        extra_env={
            "BANVIC_INPUT_DIR": str(input_dir),
            "INGESTION_DATE": ingestion_date,
            "TAP_CSV__SELECT_FILTER": json.dumps([table]),
            "MELTANO_ENVIRONMENT": os.getenv("MELTANO_ENVIRONMENT", "prod"),
        },
    )


def _publish_dbt_artifacts(selector: str, ingestion_date: str) -> None:
    """Best-effort: falha no upload não mascara o resultado do dbt."""
    results = DBT_PROJECT / "target" / "run_results.json"
    if not results.exists() or not os.getenv("LAKE_BUCKET"):
        return
    safe_selector = selector.replace(":", "_").replace("/", "_")
    key = f"ops/dbt_artifacts/ingestion_date={ingestion_date}/{safe_selector}/run_results.json"
    try:
        _s3_client().upload_file(str(results), os.environ["LAKE_BUCKET"], key)
        log.info("Artefato dbt publicado em s3://%s/%s", os.environ["LAKE_BUCKET"], key)
    except Exception as exc:  # noqa: BLE001 - observabilidade não deve derrubar o job
        log.warning("Não foi possível publicar run_results.json: %s", exc)


def cmd_dbt(selector: str, ingestion_date: str) -> int:
    _require_env("DW_HOST", "DW_DATABASE", "DBT_USER", "DBT_PASSWORD")
    rc = _run(
        [
            DBT_BIN,
            "build",
            "--select",
            selector,
            "--project-dir",
            str(DBT_PROJECT),
            "--profiles-dir",
            str(DBT_PROJECT),
            "--target",
            os.getenv("DBT_TARGET", "prod"),
            "--vars",
            json.dumps({"ingestion_date": ingestion_date}),
        ],
        cwd=DBT_PROJECT,
        extra_env={},
    )
    _publish_dbt_artifacts(selector, ingestion_date)
    return rc


def _valid_date(value: str) -> str:
    date.fromisoformat(value)  # levanta ValueError se inválida
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Runner do pipeline BanVic")
    sub = parser.add_subparsers(dest="command", required=True)

    p_bronze = sub.add_parser("bronze", help="Carrega uma tabela na camada bronze (Meltano)")
    p_bronze.add_argument("--table", required=True, choices=TABLES)
    p_bronze.add_argument("--ingestion-date", required=True, type=_valid_date)

    p_dbt = sub.add_parser("dbt", help="Executa dbt build para um seletor")
    p_dbt.add_argument("--select", required=True)
    p_dbt.add_argument("--ingestion-date", required=True, type=_valid_date)

    args = parser.parse_args(argv)
    if args.command == "bronze":
        rc = cmd_bronze(args.table, args.ingestion_date)
    else:
        rc = cmd_dbt(args.select, args.ingestion_date)

    log.info("Finalizado com código %s", rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())

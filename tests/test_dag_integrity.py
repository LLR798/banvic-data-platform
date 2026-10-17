"""DAG integrity tests: a DAG importa, tem a estrutura esperada e segue as boas práticas."""

from __future__ import annotations

from datetime import timedelta

import pytest
from airflow.dag_processing.dagbag import DagBag
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator

from conftest import DAGS_DIR

DAG_ID = "banvic_medallion"

EXPECTED_EDGES = {
    ("resolve_ingestion_date", "landing.wait_for_landing_file"),
    ("resolve_ingestion_date", "landing.landing_to_bronze"),
    ("landing.wait_for_landing_file", "landing.landing_to_bronze"),
    ("landing.landing_to_bronze", "bronze.bronze_pod_arguments"),
    ("bronze.bronze_pod_arguments", "bronze.load_bronze"),
    ("bronze.load_bronze", "bronze.bronze_quality"),
    ("landing.landing_to_bronze", "bronze.bronze_quality"),
    ("bronze.bronze_quality", "silver.dbt_silver"),
    ("silver.dbt_silver", "gold.dbt_gold"),
    ("gold.dbt_gold", "gold.audit_layers"),
    ("resolve_ingestion_date", "gold.audit_layers"),
}

# Tasks que, por design, não fazem retry (determinísticas ou com timeout próprio).
NO_RETRY_TASKS = {"resolve_ingestion_date", "landing.wait_for_landing_file"}


@pytest.fixture(scope="session")
def dagbag() -> DagBag:
    return DagBag(dag_folder=str(DAGS_DIR), include_examples=False)


@pytest.fixture(scope="session")
def dag(dagbag):
    return dagbag.dags[DAG_ID]


def test_no_import_errors(dagbag):
    assert dagbag.import_errors == {}, f"Erros de importação: {dagbag.import_errors}"


def test_only_expected_dags(dagbag):
    assert set(dagbag.dag_ids) == {DAG_ID}


def test_dag_settings(dag):
    assert dag.catchup is False
    assert dag.max_active_runs == 1
    assert dag.dagrun_timeout == timedelta(hours=2)
    assert {"banvic", "medallion"} <= set(dag.tags)
    assert dag.doc_md, "A DAG precisa de documentação (doc_md)"
    assert dag.on_failure_callback, "A DAG precisa de callback de falha"
    assert "ingestion_date" in dag.params


def test_dependencies_follow_medallion_order(dag):
    edges = {(up, t.task_id) for t in dag.tasks for up in t.upstream_task_ids}
    assert edges == EXPECTED_EDGES


def test_no_cycles(dag):
    # DagBag rejeita ciclos na importação; a ordenação topológica confirma.
    ordered = [t.task_id for t in dag.topological_sort()]
    assert ordered.index("bronze.load_bronze") < ordered.index("silver.dbt_silver") < ordered.index("gold.dbt_gold")


def test_retries_backoff_and_callbacks(dag):
    for task in dag.tasks:
        assert task.on_failure_callback, f"{task.task_id} sem on_failure_callback"
        if task.task_id in NO_RETRY_TASKS:
            continue
        assert task.retries >= 2, f"{task.task_id} precisa de retries"
        assert task.retry_exponential_backoff, f"{task.task_id} precisa de backoff exponencial"
        assert task.execution_timeout is not None, f"{task.task_id} precisa de execution_timeout"


def test_sensor_releases_worker_slot(dag):
    sensor = dag.get_task("landing.wait_for_landing_file")
    assert sensor.mode == "reschedule"
    assert sensor.timeout <= 6 * 60 * 60


def _pod_tasks(dag):
    for task in dag.tasks:
        op_class = getattr(task, "operator_class", type(task))
        if op_class is KubernetesPodOperator or isinstance(task, KubernetesPodOperator):
            yield task


def test_pod_operators_get_credentials_only_from_secrets(dag):
    pod_tasks = list(_pod_tasks(dag))
    assert {t.task_id for t in pod_tasks} == {"bronze.load_bronze", "silver.dbt_silver", "gold.dbt_gold"}
    for task in pod_tasks:
        kwargs = getattr(task, "partial_kwargs", None) or task.__dict__
        env_vars = kwargs.get("env_vars") or []
        rendered = str(env_vars).lower()
        assert "password" not in rendered and "secret" not in rendered, f"{task.task_id} com credencial inline"
        env_from = kwargs.get("env_from") or []
        secret_refs = {e.secret_ref.name for e in env_from if e.secret_ref}
        assert "lake-credentials" in secret_refs
        assert secret_refs & {"dw-ingestion-credentials", "dw-transform-credentials"}


def test_bronze_load_is_mapped_per_table(dag):
    task = dag.get_task("bronze.load_bronze")
    assert task.partial_kwargs["max_active_tis_per_dagrun"] >= 1
    assert "arguments" in task.expand_input.value

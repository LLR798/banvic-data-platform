"""Configuração da plataforma (Helm values do Airflow + Terraform), validada sem cluster.

Renderiza o mesmo template que o Terraform usa e confere as garantias que o
a operação em produção exige: logs persistentes fora dos pods.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest
import yaml

from conftest import ROOT

LAKE_BUCKET = "banvic-lake"


@pytest.fixture(scope="module")
def values() -> dict:
    rendered = subprocess.run(
        [shutil.which("bash") or "/bin/bash", str(ROOT / "scripts" / "render_airflow_values.sh")],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return yaml.safe_load(rendered)


def test_task_logs_go_to_dedicated_remote_bucket(values):
    logging_cfg = values["config"]["logging"]
    assert logging_cfg["remote_logging"] == "True"
    folder = logging_cfg["remote_base_log_folder"]
    assert folder.startswith("s3://"), "logs remotos precisam de um bucket S3/MinIO"
    bucket = folder.removeprefix("s3://").split("/", 1)[0]
    assert bucket != LAKE_BUCKET, "logs ficam separados do data lake (outro acesso, outra retenção)"


def test_remote_log_connection_comes_from_a_secret(values):
    conn_id = values["config"]["logging"]["remote_log_conn_id"]
    env_names = {s["envName"] for s in values["secret"]}
    assert f"AIRFLOW_CONN_{conn_id.upper()}" in env_names


def test_logs_user_is_scoped_to_logs_bucket():
    module = (ROOT / "infra" / "terraform" / "modules" / "minio" / "main.tf").read_text()
    policy = module.split('"logs-policy.json"', 1)[1].split('"logs-lifecycle.json"', 1)[0]
    assert "var.logs_bucket" in policy
    assert "var.bucket" not in policy.replace("var.logs_bucket", ""), "usuário de logs não pode ler o lake"
    assert "s3:DeleteObject" not in policy, "logs são trilha de auditoria: sem permissão de apagar"

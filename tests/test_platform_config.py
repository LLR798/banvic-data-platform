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


def test_sensitive_values_are_masked_in_ui_and_logs(values):
    core = values["config"]["core"]
    assert core["hide_sensitive_var_conn_fields"] == "True"
    extra = set(core["sensitive_var_conn_names"].split(","))
    assert {"secret_access_key", "aws_secret_access_key", "webhook", "token"} <= extra
    assert values["config"]["api"]["expose_config"] == "False", "a UI não pode exibir o airflow.cfg"


def test_values_template_has_no_literal_secrets():
    lines = (ROOT / "infra" / "helm" / "airflow-values.yaml.tftpl").read_text().lower().splitlines()
    code = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
    for word in ("password:", "secret_key:", "fernetkey:"):
        assert word not in code, f"'{word}' literal no values do Helm"


def test_alert_webhook_url_is_masked(monkeypatch):
    import importlib

    from airflow.sdk._shared.secrets_masker import redact

    url = "https://hooks.example.com/services/T000/B000/abcdefghijklmnop"
    monkeypatch.setenv("BANVIC_ALERT_WEBHOOK_URL", url)
    import banvic.callbacks as callbacks

    importlib.reload(callbacks)
    assert url not in str(redact(f"falha ao chamar {url}"))

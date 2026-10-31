#!/usr/bin/env bash
# Renderiza infra/helm/airflow-values.yaml.tftpl com os valores padrão da stack
# platform (mesmos defaults de infra/terraform/platform/variables.tf).
# Usado no CI para `helm template | kubeconform` e para depuração local:
#   ./scripts/render_airflow_values.sh > /tmp/values.yaml
set -euo pipefail

python3 - "$(dirname "$0")/../infra/helm/airflow-values.yaml.tftpl" <<'PY'
import string
import sys

values = {
    "airflow_version": "3.2.2",
    "airflow_image_repository": "banvic/airflow",
    "airflow_image_tag": "0.2.0",
    "airflow_admin_username": "admin",
    "airflow_ui_node_port": "30080",
    "pipeline_image": "banvic/pipeline:0.2.0",
    "jobs_namespace": "airflow",
    "lake_bucket": "banvic-lake",
    "logs_bucket": "banvic-airflow-logs",
    "metadata_secret": "airflow-metadata",
    "fernet_secret": "airflow-fernet-key",
    "api_secret": "airflow-api-secret-key",
    "jwt_secret": "airflow-jwt-secret",
    "connections_secret": "airflow-connections",
}
with open(sys.argv[1], encoding="utf-8") as fh:
    print(string.Template(fh.read()).substitute(values))
PY

"""Configuração central das DAGs do BanVic.

Valores de ambiente (nomes de bucket, imagem, namespace) vêm de variáveis de
ambiente definidas no Helm values do Airflow pelo Terraform. Credenciais NUNCA
ficam aqui: as conexões `lake_s3` e `dw_postgres` são injetadas como
AIRFLOW_CONN_* a partir de Kubernetes Secrets.
"""

from __future__ import annotations

import os
import re

# Conexões Airflow (definidas via env AIRFLOW_CONN_LAKE_S3 / AIRFLOW_CONN_DW_POSTGRES)
LAKE_CONN_ID = "lake_s3"
DW_CONN_ID = "dw_postgres"

# Data Lake (MinIO)
LAKE_BUCKET = os.getenv("BANVIC_LAKE_BUCKET", "banvic-lake")
LANDING_FILE_NAME = "banvic_data.zip"

# Execução dos jobs (pods efêmeros)
PIPELINE_IMAGE = os.getenv("BANVIC_PIPELINE_IMAGE", "banvic/pipeline:0.2.0")
JOBS_NAMESPACE = os.getenv("BANVIC_JOBS_NAMESPACE", "airflow")
PIPELINE_CONFIGMAP = "pipeline-config"
LAKE_SECRET = "lake-credentials"
DW_INGESTION_SECRET = "dw-ingestion-credentials"
DW_TRANSFORM_SECRET = "dw-transform-credentials"

# Paralelismo máximo de pods de carga Bronze (protege a RAM do cluster local)
BRONZE_MAX_PARALLEL_PODS = int(os.getenv("BANVIC_BRONZE_MAX_PARALLEL", "3"))


def landing_key(ingestion_date: str) -> str:
    """Onde o "sistema legado" deposita o zip do dia."""
    return f"landing/ingestion_date={ingestion_date}/{LANDING_FILE_NAME}"


def run_token(run_id: str) -> str:
    """Identificador da execução seguro para usar em caminhos do lake."""
    return re.sub(r"[^A-Za-z0-9.-]+", "-", run_id).strip("-")


def bronze_key(table: str, ingestion_date: str, token: str) -> str:
    """Arquivo de uma tabela na área da execução (só fica visível quando o manifesto aponta para ele)."""
    return f"bronze/{table}/ingestion_date={ingestion_date}/run={token}/{table}.csv"


def manifest_key(ingestion_date: str) -> str:
    """Manifesto da partição: o "commit" que diz qual execução é a versão vigente do dia."""
    return f"bronze/_manifests/ingestion_date={ingestion_date}/manifest.json"

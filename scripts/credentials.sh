#!/usr/bin/env bash
# Mostra os acessos locais. As senhas foram geradas pelo Terraform.
set -euo pipefail

TF="${TF:-terraform}"
DIR=infra/terraform/platform
out() { "$TF" -chdir="$DIR" output -raw "$1"; }

cat <<TXT
Airflow UI      http://localhost:8080
  usuário       $(out airflow_admin_username)
  senha         $(out airflow_admin_password)

MinIO Console   http://localhost:9001
  usuário       lake-admin
  senha         $(out minio_root_password)

Postgres (Gold, somente leitura) - DBeaver / Power BI / psql
  host:porta    localhost:15432   banco: banvic_dw
  usuário       analyst
  senha         $(out analyst_password)
TXT

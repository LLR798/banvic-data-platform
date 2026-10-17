#!/usr/bin/env bash
# SOMENTE PARA TESTAR A FASE 2 SEM O AIRFLOW.
# Faz manualmente o que a task landing_to_bronze da DAG faz: extrai o zip e
# publica cada CSV em bronze/<tabela>/ingestion_date=<data>/<tabela>.csv
#   ./scripts/stage_bronze_manual.sh [AAAA-MM-DD]
set -euo pipefail

DATE="${1:-$(date -u +%F)}"
ZIP="${ZIP:-data/banvic_data.zip}"
ENDPOINT="${ENDPOINT:-http://localhost:9000}"
BUCKET="${BUCKET:-banvic-lake}"

secret() { kubectl -n airflow get secret lake-credentials -o "jsonpath={.data.$1}" | base64 --decode; }
AWS_ACCESS_KEY_ID="$(secret AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(secret AWS_SECRET_ACCESS_KEY)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=us-east-1
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q -j "$ZIP" '*.csv' -d "$TMP"

for csv in "$TMP"/*.csv; do
  table="$(basename "$csv" .csv)"
  key="bronze/${table}/ingestion_date=${DATE}/${table}.csv"
  aws --endpoint-url "$ENDPOINT" s3 cp "$csv" "s3://${BUCKET}/${key}" --only-show-errors
  echo "  s3://${BUCKET}/${key}"
done

#!/usr/bin/env bash
# SOMENTE PARA TESTAR A INGESTÃO SEM O AIRFLOW.
# Faz manualmente o que a task landing_to_bronze da DAG faz, no mesmo padrão
# write-audit-publish: grava os CSVs na área de uma execução manual e só no fim
# grava o manifesto do dia (o "commit" que o runner do Meltano lê).
#   ./scripts/stage_bronze_manual.sh [AAAA-MM-DD]
set -euo pipefail

DATE="${1:-$(date -u +%F)}"
ZIP="${ZIP:-data/banvic_data.zip}"
ENDPOINT="${ENDPOINT:-http://localhost:9000}"
BUCKET="${BUCKET:-banvic-lake}"
TOKEN="manual-$(date -u +%Y%m%dT%H%M%S)"

secret() { kubectl -n airflow get secret lake-credentials -o "jsonpath={.data.$1}" | base64 --decode; }
AWS_ACCESS_KEY_ID="$(secret AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(secret AWS_SECRET_ACCESS_KEY)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=us-east-1
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q -j "$ZIP" '*.csv' -d "$TMP"

# 1. write: área exclusiva desta execução (ninguém lê enquanto não houver manifesto)
files='{}'
for csv in "$TMP"/*.csv; do
  table="$(basename "$csv" .csv)"
  key="bronze/${table}/ingestion_date=${DATE}/run=${TOKEN}/${table}.csv"
  aws --endpoint-url "$ENDPOINT" s3 cp "$csv" "s3://${BUCKET}/${key}" --only-show-errors
  files="$(jq -c --arg t "$table" --arg k "$key" '. + {($t): $k}' <<<"$files")"
  echo "  s3://${BUCKET}/${key}"
done

# 2. publish: o manifesto é gravado por último, num único PUT
jq -n --arg d "$DATE" --arg t "$TOKEN" --argjson f "$files" \
  '{schema_version: 2, ingestion_date: $d, run_id: $t, run_token: $t, files: $f,
    committed_at: (now | todate)}' > "$TMP/manifest.json"
aws --endpoint-url "$ENDPOINT" s3 cp "$TMP/manifest.json" \
  "s3://${BUCKET}/bronze/_manifests/ingestion_date=${DATE}/manifest.json" --only-show-errors
echo "Partição ${DATE} publicada (run=${TOKEN})"

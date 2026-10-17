#!/usr/bin/env bash
# Simula o sistema legado depositando o arquivo do dia na landing zone do MinIO.
#   ./scripts/seed_landing.sh [AAAA-MM-DD]
# Usa as credenciais do usuário de serviço (lidas do Secret, nunca do código).
set -euo pipefail

DATE="${1:-$(date -u +%F)}"
ZIP="${ZIP:-data/banvic_data.zip}"
BUCKET="${BUCKET:-banvic-lake}"
ENDPOINT="${ENDPOINT:-http://localhost:9000}"

[ -f "$ZIP" ] || { echo "Arquivo $ZIP não encontrado." >&2; exit 1; }

secret() {
  kubectl -n airflow get secret lake-credentials -o "jsonpath={.data.$1}" | base64 --decode
}

AWS_ACCESS_KEY_ID="$(secret AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(secret AWS_SECRET_ACCESS_KEY)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=us-east-1
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

KEY="landing/ingestion_date=${DATE}/banvic_data.zip"
echo "Enviando $ZIP -> s3://${BUCKET}/${KEY}"
aws --endpoint-url "$ENDPOINT" s3 cp "$ZIP" "s3://${BUCKET}/${KEY}" --only-show-errors
aws --endpoint-url "$ENDPOINT" s3 ls "s3://${BUCKET}/landing/" --recursive --human-readable

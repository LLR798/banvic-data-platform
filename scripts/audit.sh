#!/usr/bin/env bash
# Auditoria da plataforma (rodar depois de pelo menos uma execução da DAG):
#   1. configuração do Airflow: logs remotos ligados, mascaramento ligado, config fora da UI
#   2. logs persistentes: os logs das tarefas estão no bucket dedicado
#   3. menor privilégio: o usuário de logs não lê o lake, e o do pipeline não lê os logs
#   4. vazamento: NENHUM valor de segredo aparece nos logs das tarefas nem dos componentes
# Nenhum segredo é exibido: os valores ficam num arquivo temporário (0600) apagado no fim.
#   ./scripts/audit.sh
set -euo pipefail

ENDPOINT="${ENDPOINT:-http://localhost:9000}"
LAKE_BUCKET="${LAKE_BUCKET:-banvic-lake}"
LOGS_BUCKET="${LOGS_BUCKET:-banvic-airflow-logs}"
DAG_ID="${DAG_ID:-banvic_medallion}"
SCHED="airflow-scheduler-0"

FAILED=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; FAILED=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

k8s_secret() { kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 --decode; }
af_cfg() { kubectl -n airflow exec "$SCHED" -c scheduler -- airflow config get-value "$1" "$2" 2>/dev/null | tail -1; }

as_user() {  # as_user <access_key> <secret_key> <comando aws ...>
  local ak="$1" sk="$2"; shift 2
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_DEFAULT_REGION=us-east-1 \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws --endpoint-url "$ENDPOINT" "$@"
}

echo "1. Configuração do Airflow"
[ "$(af_cfg logging remote_logging)" = "True" ] && ok "remote_logging = True" || fail "remote_logging desligado"
[ "$(af_cfg core hide_sensitive_var_conn_fields)" = "True" ] && ok "hide_sensitive_var_conn_fields = True" \
  || fail "mascaramento de campos sensíveis desligado"
[ "$(af_cfg api expose_config)" = "False" ] && ok "expose_config = False (configuração fora da UI)" \
  || fail "a UI expõe a configuração"

echo "2. Logs persistentes em s3://${LOGS_BUCKET}"
logs_conn="$(k8s_secret airflow airflow-connections AIRFLOW_CONN_LOGS_S3)"
LOGS_AK="$(jq -r .login <<<"$logs_conn")"
LOGS_SK="$(jq -r .password <<<"$logs_conn")"
count=0
for _ in 1 2 3 4 5 6; do  # o upload acontece ao fim de cada tentativa: dá alguns segundos
  count="$(as_user "$LOGS_AK" "$LOGS_SK" s3 ls "s3://${LOGS_BUCKET}/airflow/dag_id=${DAG_ID}/" --recursive \
    | grep -c '\.log$' || true)"
  [ "$count" -gt 0 ] && break
  sleep 5
done
[ "$count" -gt 0 ] && ok "${count} arquivos de log de tarefas no bucket" || fail "nenhum log de tarefa no bucket"

echo "3. Menor privilégio entre lake e logs"
PIPE_AK="$(k8s_secret airflow lake-credentials AWS_ACCESS_KEY_ID)"
PIPE_SK="$(k8s_secret airflow lake-credentials AWS_SECRET_ACCESS_KEY)"
if as_user "$LOGS_AK" "$LOGS_SK" s3 ls "s3://${LAKE_BUCKET}/" >/dev/null 2>&1; then
  fail "o usuário de logs consegue ler o lake"
else ok "usuário de logs NÃO lê o lake"; fi
if as_user "$PIPE_AK" "$PIPE_SK" s3 ls "s3://${LOGS_BUCKET}/" >/dev/null 2>&1; then
  fail "o usuário do pipeline consegue ler os logs"
else ok "usuário do pipeline NÃO lê os logs"; fi

echo "4. Nenhum segredo nos logs"
umask 077
PATTERNS="$TMP/patterns"
{
  for k in POSTGRES_PASSWORD SVC_INGESTION_PASSWORD SVC_TRANSFORM_PASSWORD SVC_ORCHESTRATOR_PASSWORD ANALYST_PASSWORD; do
    k8s_secret data postgres-dw-credentials "$k"; echo
  done
  for k in MINIO_ROOT_PASSWORD PIPELINE_SECRET_KEY LOGS_SECRET_KEY; do k8s_secret data minio-credentials "$k"; echo; done
  k8s_secret airflow postgres-airflow-credentials POSTGRES_PASSWORD; echo
  k8s_secret airflow airflow-fernet-key fernet-key; echo
  k8s_secret airflow airflow-api-secret-key api-secret-key; echo
  k8s_secret airflow airflow-jwt-secret jwt-secret; echo
} | { grep -v '^$' || true; } > "$PATTERNS"
n_secrets="$(wc -l < "$PATTERNS" | tr -d ' ')"
[ "$n_secrets" -ge 12 ] || fail "esperava 12 segredos para procurar, li ${n_secrets} (Secret ausente?)"

mkdir -p "$TMP/logs"
as_user "$LOGS_AK" "$LOGS_SK" s3 cp "s3://${LOGS_BUCKET}/airflow/" "$TMP/logs/tasks/" --recursive --only-show-errors
for c in scheduler:airflow-scheduler-0 api-server:deploy/airflow-api-server dag-processor:deploy/airflow-dag-processor; do
  kubectl -n airflow logs "${c#*:}" -c "${c%%:*}" --tail=-1 > "$TMP/logs/${c%%:*}.log" 2>/dev/null || true
done
n_files="$(find "$TMP/logs" -type f | wc -l | tr -d ' ')"
# grep sai com código 1 quando NÃO encontra nada (o resultado esperado); com pipefail
# isso encerraria o script. O "|| true" trata "nenhuma ocorrência" como sucesso.
leaks="$( (grep -rlF -f "$PATTERNS" "$TMP/logs" 2>/dev/null || true) | wc -l | tr -d ' ')"
if [ "$leaks" -eq 0 ]; then
  ok "0 ocorrências de ${n_secrets} segredos em ${n_files} arquivos de log (tarefas + componentes)"
else
  fail "${leaks} arquivo(s) de log contêm valores de segredos (os nomes dos arquivos não são exibidos por segurança)"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "Auditoria concluída com sucesso."; else echo "Auditoria encontrou problemas." >&2; exit 1; fi

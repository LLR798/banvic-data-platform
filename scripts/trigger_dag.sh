#!/usr/bin/env bash
# Despausa e dispara a DAG para uma data e acompanha até o fim.
#   ./scripts/trigger_dag.sh [AAAA-MM-DD]
set -euo pipefail

DATE="${1:-$(date -u +%F)}"
DAG_ID="${DAG_ID:-banvic_medallion}"
TIMEOUT="${TIMEOUT:-1800}"
NS=airflow

SCHED="$(kubectl -n "$NS" get pod -l component=scheduler -o jsonpath='{.items[0].metadata.name}')"
af() { kubectl -n "$NS" exec "$SCHED" -c scheduler -- airflow "$@" 2>/dev/null; }
# A CLI do Airflow 3 mistura logs no stdout; o JSON é a linha que começa com "[".
af_json() { af "$@" -o json | grep -E '^\[' | tail -1 || true; }

echo "Aguardando o DAG Processor registrar ${DAG_ID}..."
for _ in $(seq 1 40); do
  if af_json dags list | jq -e --arg d "$DAG_ID" 'any(.[]; .dag_id == $d)' >/dev/null; then
    break
  fi
  sleep 5
done

af dags unpause "$DAG_ID" >/dev/null
RUN_ID="manual__${DATE}__$(date -u +%Y%m%dT%H%M%S)"
echo "Disparando ${DAG_ID} (run_id=${RUN_ID}, ingestion_date=${DATE})"
af dags trigger "$DAG_ID" -r "$RUN_ID" -c "{\"ingestion_date\": \"${DATE}\"}" >/dev/null

start=$(date +%s)
state="queued"
while :; do
  state="$(af_json dags list-runs "$DAG_ID" \
    | jq -r --arg r "$RUN_ID" 'map(select(.run_id == $r)) | .[0].state // "queued"')"
  state="${state:-queued}"
  printf '\r  estado: %-10s (%ss)' "$state" "$(( $(date +%s) - start ))"
  case "$state" in
    success) echo; echo "DAG concluída com sucesso."; exit 0 ;;
    failed)  echo; echo "DAG falhou. Veja os logs na UI (http://localhost:8080)." >&2; exit 1 ;;
  esac
  if [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ]; then
    echo; echo "Timeout aguardando a DAG." >&2; exit 1
  fi
  sleep 10
done

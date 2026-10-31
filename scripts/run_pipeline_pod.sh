#!/usr/bin/env bash
# Executa a imagem banvic/pipeline como Pod avulso no cluster - exatamente como
# o KubernetesPodOperator faz - para testar Meltano/dbt SEM o Airflow (Fase 2)
# ou depurar uma etapa isolada.
#
#   ./scripts/run_pipeline_pod.sh bronze --table agencias --ingestion-date 2026-10-13
#   ./scripts/run_pipeline_pod.sh dbt --select tag:silver --ingestion-date 2026-10-13
set -euo pipefail

[ $# -ge 1 ] || { sed -n 2,9p "$0"; exit 1; }

IMAGE="${PIPELINE_IMAGE:-banvic/pipeline:0.2.0}"
NS=airflow
case "$1" in
  bronze) DB_SECRET=dw-ingestion-credentials ;;
  dbt)    DB_SECRET=dw-transform-credentials ;;
  *) echo "Primeiro argumento deve ser 'bronze' ou 'dbt'." >&2; exit 1 ;;
esac

NAME="pipeline-manual-$1-$(date +%s)"
ARGS_JSON="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"

kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${NAME}
  labels: {app: banvic-pipeline, trigger: manual}
spec:
  restartPolicy: Never
  containers:
    - name: base
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      args: ${ARGS_JSON}
      envFrom:
        - configMapRef: {name: pipeline-config}
        - secretRef: {name: lake-credentials}
        - secretRef: {name: ${DB_SECRET}}
      resources:
        requests: {cpu: 250m, memory: 512Mi}
        limits: {memory: 1Gi}
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
YAML

echo "Aguardando o pod ${NAME}..."
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/${NAME}" --timeout=180s >/dev/null 2>&1 || true
kubectl -n "$NS" logs -f "${NAME}" || true

for _ in $(seq 1 30); do
  phase="$(kubectl -n "$NS" get pod "${NAME}" -o jsonpath='{.status.phase}')"
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 2
done
kubectl -n "$NS" delete pod "${NAME}" --wait=false >/dev/null
echo "Resultado: ${phase}"
[ "$phase" = "Succeeded" ]

#!/usr/bin/env bash
# Executa as queries de validação dentro do pod do DW (sem expor senha).
set -euo pipefail

POD="$(kubectl -n data get pod -l app.kubernetes.io/name=postgres-dw -o jsonpath='{.items[0].metadata.name}')"
kubectl -n data exec -i "$POD" -- \
  psql -X -U dw_admin -d banvic_dw -v ON_ERROR_STOP=1 < sql/validation/validate.sql

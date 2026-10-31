#!/usr/bin/env bash
# Mostra os acessos locais. As senhas foram geradas pelo Terraform e ficam
# MASCARADAS por padrão (seguro para gravar a tela ou compartilhar o terminal).
#   make credentials                 -> senhas mascaradas
#   make credentials SHOW=1          -> senhas visíveis
#   make credentials COPY=airflow    -> copia a senha para a área de transferência
#                                       (airflow | minio | analyst), sem exibi-la
set -euo pipefail

TF="${TF:-terraform}"
DIR=infra/terraform/platform
out() { "$TF" -chdir="$DIR" output -raw "$1"; }

# (sem arrays associativos: o bash do macOS é a versão 3.2)
if [ -n "${COPY:-}" ]; then
  case "$COPY" in
    airflow) name=airflow_admin_password ;;
    minio)   name=minio_root_password ;;
    analyst) name=analyst_password ;;
    *) echo "COPY deve ser: airflow, minio ou analyst" >&2; exit 1 ;;
  esac
  if command -v pbcopy >/dev/null; then out "$name" | pbcopy
  elif command -v clip.exe >/dev/null; then out "$name" | clip.exe
  elif command -v xclip >/dev/null; then out "$name" | xclip -selection clipboard
  else echo "Nenhum utilitário de área de transferência encontrado (pbcopy/clip.exe/xclip)." >&2; exit 1
  fi
  echo "Senha de '$COPY' copiada para a área de transferência."
  exit 0
fi

secret() {
  if [ "${SHOW:-0}" = "1" ]; then out "$1"; else
    local v; v="$(out "$1")"; printf '%s••••••••  (oculta: SHOW=1 exibe, COPY=%s copia)' "${v:0:2}" "$2"
  fi
}

cat <<TXT
Airflow UI      http://localhost:8080
  usuário       $(out airflow_admin_username)
  senha         $(secret airflow_admin_password airflow)

MinIO Console   http://localhost:9001
  usuário       lake-admin
  senha         $(secret minio_root_password minio)

Postgres (Gold, somente leitura) - DBeaver / Power BI / psql
  host:porta    localhost:15432   banco: banvic_dw
  usuário       analyst
  senha         $(secret analyst_password analyst)
TXT

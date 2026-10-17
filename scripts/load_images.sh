#!/usr/bin/env bash
# Deixa as imagens de terceiros disponíveis DENTRO do nó do Kind antes do deploy.
#
# - Docker Hub (Postgres): pull no host (usa o seu `docker login`, evitando o limite
#   de downloads anônimos) + `kind load`.
# - Imagens fixadas por DIGEST (MinIO/Chainguard): o próprio nó faz o pull com
#   `crictl`. O `kind load` não preserva o digest, então o kubelet baixaria de novo.
#   A fonte da verdade dos digests é infra/terraform/modules/minio/variables.tf.
set -euo pipefail

CLUSTER="${CLUSTER:-banvic}"
NODE="${CLUSTER}-control-plane"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOST_IMAGES=(
  "postgres:17-alpine"
)

for image in "${HOST_IMAGES[@]}"; do
  echo "==> [host -> kind] $image"
  docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
  kind load docker-image "$image" --name "$CLUSTER"
done

# Lê os digests direto do Terraform (sem duplicar valores aqui).
NODE_IMAGES=$(grep -oE 'cgr\.dev/[^"]+' "$ROOT/infra/terraform/modules/minio/variables.tf")

for image in $NODE_IMAGES; do
  echo "==> [pull no nó] $image"
  docker exec "$NODE" crictl pull "$image" >/dev/null
done

echo "Imagens de terceiros disponíveis no nó $NODE."

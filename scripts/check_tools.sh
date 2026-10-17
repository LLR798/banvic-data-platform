#!/usr/bin/env bash
# Verifica se as ferramentas necessárias estão instaladas e o Docker está rodando.
# Funciona no macOS e no Linux/WSL2 (Windows); as dicas de instalação seguem o sistema.
set -euo pipefail

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; MISSING=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

MISSING=0
OS="$(uname -s)"
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

if [ "$OS" = "Darwin" ]; then
  GUIDE="docs/setup/macos.md"
elif [ "$IS_WSL" -eq 1 ]; then
  GUIDE="docs/setup/windows-wsl2.md"
else
  GUIDE="docs/setup/windows-wsl2.md#linux-nativo"
fi

hint() {
  if [ "$OS" = "Darwin" ]; then
    case "$1" in
      terraform) echo "brew tap hashicorp/tap && brew install hashicorp/tap/terraform" ;;
      aws)       echo "brew install awscli" ;;
      docker)    echo "brew install --cask docker-desktop" ;;
      *)         echo "brew install $1" ;;
    esac
  else
    echo "veja $GUIDE"
  fi
}

case "$OS" in
  Darwin) echo "Sistema: macOS ($(uname -m))" ;;
  *)      if [ "$IS_WSL" -eq 1 ]; then echo "Sistema: Windows / WSL2 ($(uname -m))"; else echo "Sistema: Linux ($(uname -m))"; fi ;;
esac

if [ "$IS_WSL" -eq 1 ]; then
  case "$PWD" in
    /mnt/*) warn "repositório em $PWD (disco do Windows): lento e sujeito a CRLF; clone em ~/ (veja $GUIDE)" ;;
  esac
fi

echo "Ferramentas obrigatórias:"
for bin in docker kind kubectl terraform aws jq unzip; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else fail "$bin  ->  $(hint "$bin")"; fi
done

echo "Ferramentas opcionais:"
for bin in psql k9s helm uv gh; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else warn "$bin (opcional)"; fi
done

echo "Docker:"
if docker info >/dev/null 2>&1; then
  ok "daemon ativo ($(docker info --format '{{.OperatingSystem}} / {{.Architecture}}'))"
  mem_bytes=$(docker info --format '{{.MemTotal}}')
  mem_gb=$((mem_bytes / 1024 / 1024 / 1024))
  if [ "$mem_gb" -lt 8 ]; then
    warn "Docker com ${mem_gb} GiB de RAM; recomendado >= 8 GiB (ideal 10 GiB) - veja $GUIDE"
  else
    ok "memória disponível para containers: ${mem_gb} GiB"
  fi
  # O 'containerd image store' do Docker Desktop quebra o `kind load docker-image`.
  if docker info --format '{{.Driver}} {{json .DriverStatus}}' 2>/dev/null \
      | grep -qE 'overlayfs|containerd\.snapshotter'; then
    warn "containerd image store ativo: desmarque 'Use containerd for pulling and storing images' no Docker Desktop"
  fi
else
  fail "Docker não está rodando (abra o Docker Desktop ou inicie o serviço docker)"
fi

if [ "$MISSING" -ne 0 ]; then
  echo "Instale o que falta e rode novamente." >&2
  exit 1
fi
echo "Tudo pronto."

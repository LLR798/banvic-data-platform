# Preparar o ambiente — Windows 10/11 (WSL2) e Linux

No Windows, o projeto roda dentro do **WSL2 com Ubuntu**, um Linux de verdade integrado ao Windows.
O Makefile e os scripts são Bash, então funcionam no WSL2 sem nenhuma adaptação. O Docker Desktop
roda os containers e publica as portas no `localhost` do Windows: as UIs abrem no navegador do Windows
normalmente.

> **Por que não PowerShell nativo?** Seria preciso manter uma segunda versão de cada script (e do
> Makefile) só para o Windows. O WSL2 é o caminho recomendado pela própria documentação do Docker e do
> Kind, e é o mesmo Ubuntu usado no CI: o workflow **E2E (Kind)** sobe a stack inteira do zero em um
> runner Ubuntu a cada PR.

Ao final você terá tudo instalado **dentro do Ubuntu** e o `make check` terminando com
**"Tudo pronto."**.

> Linux nativo (Ubuntu/Debian)? Pule para [Linux nativo](#linux-nativo).

**Requisitos:** Windows 10 22H2 ou Windows 11, virtualização ativa na BIOS (normalmente já vem ativa) e
**16 GB de RAM** no computador (o ambiente usa ~8–10 GB).

---

## 1. WSL2 + Ubuntu

No **PowerShell como Administrador**:

```powershell
wsl --install -d Ubuntu-24.04
```

Reinicie o computador quando pedir. Na primeira abertura do **Ubuntu** (menu Iniciar), crie seu usuário e
senha do Linux.

Limite a memória e as CPUs do WSL2 criando o arquivo `%UserProfile%\.wslconfig` (ex.:
`C:\Users\<voce>\.wslconfig`) no Bloco de Notas:

```ini
[wsl2]
memory=10GB
processors=6
```

Aplique com, no PowerShell:

```powershell
wsl --shutdown
```

> Com o backend WSL2, é **esse arquivo** que define a RAM disponível para o Docker. Os controles de memória
> do Docker Desktop ficam desabilitados.

## 2. Docker Desktop

Instale o [Docker Desktop para Windows](https://www.docker.com/products/docker-desktop/) e ajuste:

| Onde | Configuração |
|---|---|
| *Settings → General* | **Marcar** *"Use the WSL 2 based engine"* |
| *Settings → General* | **Desmarcar** *"Use containerd for pulling and storing images"* (o `kind load` falha com ele) |
| *Settings → Resources → WSL integration* | **Ativar** a integração com `Ubuntu-24.04` |

Clique em *Apply & restart*. A partir daqui, **todos os comandos são no terminal do Ubuntu**, não no
PowerShell.

```bash
docker info --format '{{.OperatingSystem}} | {{.Architecture}}'   # Docker Desktop | x86_64
docker login                                                      # conta gratuita do Docker Hub
```

## 3. Ferramentas do projeto (terminal do Ubuntu)

Os comandos detectam a arquitetura (`amd64` ou `arm64`) sozinhos.

```bash
ARCH="$(dpkg --print-architecture)"

# Utilitários base (make, git, unzip, jq, cliente psql)
sudo apt update
sudo apt install -y make git unzip curl jq ca-certificates gnupg postgresql-client

# Terraform (repositório oficial da HashiCorp)
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# kind (mesma versão usada pelo provider Terraform do projeto)
curl -fsSLo kind "https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-${ARCH}"
sudo install -m 0755 kind /usr/local/bin/kind && rm kind

# kubectl (versão estável mais recente)
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# AWS CLI v2 (fala com o MinIO via API S3)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip

# uv (lint e testes Python num .venv isolado)
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"
```

Opcionais: [k9s](https://k9scat.com/), [Helm](https://helm.sh/docs/intro/install/) e o
[GitHub CLI](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) (`gh`).

## 4. Clonar **dentro** do Linux

```bash
cd ~                                   # /home/<voce>, o disco do Linux
git clone https://github.com/LLR798/banvic-data-platform.git
cd banvic-data-platform
make check
```

> **Não clone em `/mnt/c/...`** (o disco do Windows). Por ali o acesso a arquivos é várias vezes mais
> lento, as permissões de execução dos scripts se perdem e o Git pode converter as quebras de linha para
> CRLF, o que quebra os scripts Bash. O `make check` avisa se detectar esse caso.
>
> Para editar no Windows, use o VS Code com a extensão **WSL**: rode `code .` no terminal do Ubuntu.

**✅ Esperado:** todas as ferramentas obrigatórias com ✔, Docker ativo com ≥ 8 GiB e a mensagem
**"Tudo pronto."**. Siga para o [Quickstart do README](../../README.md#3-quickstart). As UIs
(`http://localhost:8080`, `http://localhost:9001`) abrem no navegador do Windows.

## Problemas comuns

| Sintoma | Causa | Solução |
|---|---|---|
| `docker: command not found` no Ubuntu | Integração WSL desligada | Docker Desktop → *Resources → WSL integration* → ativar o Ubuntu |
| `/bin/bash^M: bad interpreter` | Arquivos com CRLF (clonados pelo Windows) | Clone de novo **dentro** do Ubuntu (passo 4); o `.gitattributes` do repo força LF |
| `make: command not found` | Pacote ausente | `sudo apt install -y make` |
| Tudo muito lento | Repositório em `/mnt/c/...` | Clone em `~/` (passo 4) |
| `make check` acusa menos de 8 GiB | Limite do WSL2 | Ajuste o `.wslconfig` (passo 1) e rode `wsl --shutdown` |
| `localhost:8080` não abre no navegador | Docker Desktop parado ou porta ocupada no Windows | Confira `make status`; libere a porta (`netstat -ano \| findstr 8080` no PowerShell) |

---

## Linux nativo

Em Ubuntu/Debian sem Windows, o caminho é o mesmo a partir do **passo 3**, com duas diferenças:

1. Em vez do Docker Desktop, instale o **Docker Engine** pelo
   [guia oficial](https://docs.docker.com/engine/install/ubuntu/) e adicione seu usuário ao grupo
   `docker`: `sudo usermod -aG docker "$USER"` (faça logout/login em seguida).
2. Não existe `.wslconfig`: o Docker usa a RAM da própria máquina (recomendado ≥ 16 GB no total).

Depois, clone o repositório e rode `make check` (passo 4).

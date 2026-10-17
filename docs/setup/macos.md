# Preparar o ambiente — macOS

Testado em **macOS 26 (Tahoe), MacBook Apple Silicon (M4)**. Em Macs Intel os comandos são os mesmos.

Ao final você terá Docker, Terraform, Kind, kubectl, AWS CLI, jq e uv instalados, e o `make check`
terminando com **"Tudo pronto."**.

> Outro sistema? Veja [windows-wsl2.md](windows-wsl2.md) (Windows 10/11 e Linux).

---

## 1. Command Line Tools da Apple

Trazem `git`, `make` e os compiladores que o Homebrew usa.

```bash
xcode-select --install
pkgutil --pkg-info=com.apple.pkg.CLTools_Executables | grep version   # confere a versão instalada
```

> **Atenção:** se o `softwareupdate --list` oferecer um *upgrade* do macOS junto com as Command Line Tools,
> instale **só** o item `Command Line Tools for Xcode`. Atualizar o sistema no meio do projeto pode quebrar
> o Docker e as ferramentas.

## 2. Homebrew

```bash
brew --version || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 3. Docker Desktop

```bash
brew install --cask docker-desktop     # ou baixe em https://www.docker.com/products/docker-desktop/
```

Abra o Docker Desktop e ajuste:

| Onde | Configuração | Por quê |
|---|---|---|
| *Settings → Resources* | **Memory 10 GB** (mínimo 8 GB), **CPUs 6** | Airflow + Postgres ×2 + MinIO + pods do pipeline no mesmo nó |
| *Settings → General* | **Desmarcar** *"Use containerd for pulling and storing images"* | Com o *containerd image store* o `kind load docker-image` falha |

Depois faça login no Docker Hub (conta gratuita) para não esbarrar no limite de downloads anônimos:

```bash
docker login
```

> Alternativas leves ao Docker Desktop (OrbStack, Colima) também funcionam, porque o Kind só precisa de um
> daemon Docker. O projeto foi validado com o Docker Desktop.

## 4. Ferramentas do projeto

```bash
# Terraform vem do tap oficial da HashiCorp (não está mais no Homebrew core)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Kubernetes local, AWS CLI (fala com o MinIO via API S3), jq e uv (Python)
brew install kind kubectl awscli jq uv

# Opcionais, mas úteis
brew install k9s helm gh libpq             # painel do cluster, Helm CLI, GitHub CLI, psql
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
brew install --cask dbeaver-community      # cliente SQL visual
```

| Ferramenta | Para que serve no projeto |
|---|---|
| Docker Desktop | Roda os containers. O cluster Kind é um container dele |
| Terraform | Cria o cluster e tudo dentro dele de forma declarativa (IaC) |
| kind | Carrega as imagens locais no cluster (`kind load`) |
| kubectl | Conversa com o Kubernetes (pods, logs, secrets) |
| awscli | Envia o zip para o MinIO (simula o sistema legado) |
| jq | Lê JSON nos scripts |
| uv | Roda lint e testes Python num `.venv` isolado, sem poluir o sistema |

## 5. Ajuste do zsh (recomendado)

Permite colar blocos de comandos que têm comentários `#` no fim da linha:

```bash
echo 'setopt interactive_comments' >> ~/.zshrc && source ~/.zshrc
```

## 6. Teste

```bash
git clone https://github.com/LLR798/banvic-data-platform.git
cd banvic-data-platform
make check
```

**✅ Esperado:** todas as ferramentas obrigatórias com ✔, Docker ativo com ≥ 8 GiB e a mensagem
**"Tudo pronto."**. Siga para o [Quickstart do README](../../README.md#3-quickstart).

## Problemas comuns

| Sintoma | Causa | Solução |
|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop fechado | Abra o app e aguarde "Engine running" |
| `brew install terraform` diz que não existe | Terraform saiu do Homebrew core | Use `hashicorp/tap/terraform` (passo 4) |
| Erro de Command Line Tools ao instalar com o brew | CLT ausente ou desatualizada | Passo 1; depois `brew doctor` |
| `zsh: parse error` ao colar comandos | Comentários `#` inline | Passo 5 |
| `kind load` falha com *"content digest not found"* | *containerd image store* ativo | Desmarque a opção (passo 3) e rode `make images` |

# Guia passo a passo — da instalação à entrega

Este guia leva você do computador "zerado" até a POC rodando, **uma fase por vez**, com um teste ao final
de cada etapa. Siga na ordem: cada fase depende da anterior.

| Fase | O que você terá no final | Tempo estimado |
|---|---|---|
| [0. Preparar o computador](#fase-0--preparar-o-computador-e-o-repositório) | Ferramentas instaladas, repositório no GitHub | 30–45 min |
| [1. Infraestrutura](#fase-1--infraestrutura-como-código-terraform--kind) | Cluster Kind + MinIO + Postgres + Airflow no ar | 1–2 h |
| [2. Ingestão](#fase-2--ingestão-meltano--bronze-dbt--silvergold) | Bronze, Silver e Gold carregadas **sem** o Airflow | 1–2 h |
| [3. Orquestração](#fase-3--orquestração-no-airflow) | DAG rodando de ponta a ponta + testes de falha | 1–2 h |
| [4. CI/CD](#fase-4--cicd-com-github-actions) | Pipelines verdes no GitHub Actions | 1 h |
| [5. Entrega](#fase-5--documentação-vídeo-e-entrega) | README revisado, vídeo gravado, link enviado | 2–3 h |

Convenções:

- `$` indica um comando para colar no **Terminal** (sempre na raiz do projeto, salvo indicação).
- **✅ Teste** = como confirmar que a etapa funcionou.
- **🔧 Se der errado** = causas mais comuns.
- Toda data `INGESTION_DATE` padrão é **hoje em UTC** (após as 21h no Brasil, já é "amanhã" em UTC).
  Isso não é problema desde que você use a mesma data no `seed` e no `trigger` — o `make` cuida disso.

---

## Fase 0 — Preparar o computador e o repositório

### 0.1 Ferramentas e Docker

A instalação depende do sistema operacional. Siga o guia do seu e volte aqui com o `make check` verde:

| Sistema | Guia |
|---|---|
| macOS (Apple Silicon ou Intel) | [setup/macos.md](setup/macos.md) |
| Windows 10/11 (WSL2 + Ubuntu) | [setup/windows-wsl2.md](setup/windows-wsl2.md) |
| Linux (Ubuntu/Debian) | [setup/windows-wsl2.md#linux-nativo](setup/windows-wsl2.md#linux-nativo) |

### 0.2 Projeto e GitHub

```bash
$ mkdir -p ~/Projetos && cd ~/Projetos
$ unzip ~/Downloads/banvic-data-platform.zip     # ou copie a pasta que você recebeu
$ cd banvic-data-platform
$ make check                                     # confere ferramentas e memória do Docker
```

Crie o repositório (público, porque o link vai na entrega) e faça o primeiro commit:

```bash
$ git init -b main            # se a pasta ainda não for um repositório
$ git add . && git commit -m "chore: estrutura inicial da POC BanVic"
$ gh auth login               # uma vez só
$ gh repo create banvic-data-platform --public --source=. --push
```

Se você criou o repositório a partir de um fork ou com outro usuário, troque `LLR798` pelo seu usuário no
`README.md` (badges e `git clone`).

**✅ Teste**: `make check` termina com **"Tudo pronto."** e o repositório aparece no GitHub.

---

## Fase 1 — Infraestrutura como código (Terraform + Kind)

### Arquivos desta fase

| Arquivo | O que faz |
|---|---|
| `infra/terraform/cluster/*.tf` | **Stack 1**: cria o cluster Kind de 1 nó (imagem fixada por digest) e expõe as portas 8080, 9000, 9001 e 15432 **só em 127.0.0.1** |
| `infra/terraform/platform/namespaces.tf` | Namespaces `data` (armazenamento) e `airflow` (orquestração + pods do pipeline) |
| `infra/terraform/platform/secrets.tf` | **Gera todas as senhas** (`random_password`) e cria os Kubernetes Secrets. Nada de credencial no Git |
| `infra/terraform/platform/storage.tf` | Instancia os módulos: MinIO, Postgres DW e Postgres de metadados do Airflow |
| `infra/terraform/modules/postgres/` | Módulo reutilizável: StatefulSet + PVC + Service (+ NodePort opcional) + scripts de init |
| `infra/terraform/modules/minio/` | StatefulSet do MinIO + **Job** que cria o bucket versionado e o usuário de serviço com política restrita |
| `sql/bootstrap/init_dw.sh` | Roda no 1º boot do DW: schemas `bronze/silver/gold/ops`, 4 roles de menor privilégio, auditoria |
| `infra/terraform/platform/airflow.tf` + `infra/helm/airflow-values.yaml.tftpl` | Instala o **chart oficial do Airflow 3.2.2** (LocalExecutor, banco externo, UI em NodePort) |
| `docker/airflow/Dockerfile` | Imagem do Airflow com providers fixados e DAGs embutidas |
| `docker/pipeline/Dockerfile` | Imagem dos jobs: Meltano + dbt + `runner.py` |
| `Makefile` / `scripts/` | Atalhos: `make cluster`, `make images`, `make platform`, `make up` |

> **Por que duas stacks Terraform?** O provider do Kubernetes precisa que o cluster **já exista** no
> momento do `plan`. Separar `cluster` e `platform` resolve isso de forma limpa (sem `-target`), e é o
> mesmo padrão usado em produção (cluster EKS de um lado, workloads do outro).

### 1.1 Criar o cluster

```bash
$ make cluster
```

O Terraform mostra o plano e cria o cluster (~1–2 min). O contexto `kind-banvic` é gravado no seu
`~/.kube/config`.

**✅ Teste**

```bash
$ kubectl config current-context        # kind-banvic
$ kubectl get nodes                     # banvic-control-plane   Ready
$ docker ps --format '{{.Names}}  {{.Ports}}'
# banvic-control-plane  127.0.0.1:8080->30080/tcp, 127.0.0.1:9000->30900/tcp, ...
$ kubectl get storageclass              # standard (rancher.io/local-path)
```

**🔧 Se der errado**: `port is already allocated` → algo usa 8080/9000/9001/15432. Pare o serviço ou
mude `port_mappings` em `infra/terraform/cluster/variables.tf` **e** `node_ports` em
`infra/terraform/platform/variables.tf`.

### 1.2 Construir e carregar as imagens

```bash
$ make images
```

Faz três coisas: baixa e carrega no Kind as imagens de terceiros (Postgres, MinIO), constrói
`banvic/airflow:0.2.0` e `banvic/pipeline:0.2.0` **nativas arm64** e as carrega no nó do Kind.
Primeira vez: **10–20 min** (depois o cache do Docker deixa rápido).

**✅ Teste**

```bash
$ docker images | grep banvic
$ docker run --rm banvic/pipeline:0.2.0 --help                        # ajuda do runner (bronze | dbt)
$ docker run --rm --entrypoint /opt/venvs/dbt/bin/dbt banvic/pipeline:0.2.0 --version
$ docker run --rm banvic/airflow:0.2.0 airflow version                # 3.2.2
$ docker exec banvic-control-plane crictl images | grep -E 'banvic|minio|postgres'
```

**🔧 Se der errado**:
`failed to solve ... pip install` → rede instável; rode de novo.
`ctr: content digest not found` no `kind load` → Docker Desktop com containerd store (ver [setup/macos.md](setup/macos.md), passo 3).

### 1.3 Provisionar a plataforma

```bash
$ make platform
```

O Terraform cria ~30 recursos: namespaces, Secrets, MinIO (+ Job de setup), 2 Postgres e o Airflow
via Helm. Leva **5–10 min** (o Airflow só fica pronto depois da migração do banco de metadados).

**✅ Teste 1 — tudo rodando**

```bash
$ make status
```

Esperado (os sufixos mudam):

```
NAMESPACE data:     minio-0 (Running) · postgres-dw-0 (Running) · minio-setup-xxxxx (Completed)
NAMESPACE airflow:  postgres-airflow-0 · airflow-scheduler-0 · airflow-api-server-xxx ·
                    airflow-dag-processor-xxx (Running) · airflow-run-airflow-migrations-xxx ·
                    airflow-create-user-xxx (Completed)
```

> Dica: `k9s` mostra isso ao vivo (`:pods`, Enter para logs, `q` para sair).

**✅ Teste 2 — segredos fora do código**

```bash
$ kubectl -n airflow get secrets       # só NOMES: airflow-connections, lake-credentials, dw-*-credentials...
$ git grep -niE 'password\s*[:=]\s*["'\''][^$"{]' -- . ':!docs' ':!README.md' || echo "nenhuma senha no código"
$ make credentials                     # URLs + senhas geradas (lidas do estado do Terraform)
```

> Secrets do Kubernetes são **base64, não criptografia**. Por isso o acesso a eles é controlado por
> RBAC e, em produção, a fonte da verdade seria o AWS Secrets Manager (ver README, seção 10).

**✅ Teste 3 — interfaces**

- http://localhost:8080 → login `admin` + senha do `make credentials` → a DAG **banvic_medallion**
  aparece (pausada).
- http://localhost:9001 → login `lake-admin` → bucket **banvic-lake** existe (vazio).

**✅ Teste 4 — o DW nasceu com o medalhão e com as permissões certas**

```bash
# Como administrador, de dentro do pod (sem precisar de senha):
$ kubectl -n data exec -it postgres-dw-0 -- psql -U dw_admin -d banvic_dw -c '\dn+' -c '\du'
# schemas: bronze (svc_ingestion), silver/gold (svc_transform), ops (svc_orchestrator)
# roles:   svc_ingestion, svc_transform, svc_orchestrator, analyst

# Como analista, pela porta exposta (o mesmo acesso que o Power BI teria):
$ make psql
banvic_dw=> \dn                       -- vê os schemas
banvic_dw=> SELECT 1 FROM silver.clientes;   -- ERROR: permission denied for schema silver ✔
banvic_dw=> \q
```

**✅ Teste 5 — idempotência da infraestrutura**

```bash
$ make platform      # não deve recriar nada: "No changes" (ou, no máximo, ajustes cosméticos in-place)
```

### 1.4 Checkpoint da Fase 1

```bash
$ make lock          # grava hashes dos providers p/ macOS e Linux (necessário para o CI)
$ git add infra/terraform/*/.terraform.lock.hcl
$ git commit -m "feat(infra): cluster Kind, MinIO, Postgres e Airflow via Terraform"
$ git push
```

> **Atalho para o dia a dia:** `make up` = `check` + `cluster` + `images` + `platform`.
> **Recomeçar do zero:** `make down && make up`.

---

## Fase 2 — Ingestão (Meltano → Bronze, dbt → Silver/Gold)

Nesta fase você roda o pipeline **sem o Airflow**, executando a mesma imagem que a DAG vai usar, em
pods avulsos. Assim, quando chegar na Fase 3, você já sabe que a ingestão funciona e o Airflow só
precisa orquestrar.

### Arquivos desta fase

| Arquivo | O que faz |
|---|---|
| `ingestion/meltano/meltano.yml` | Extractor `tap-csv` (7 entidades + PKs) e loader `target-postgres` (schema `bronze`, UPSERT, metadados). Plugins definidos inline → build sem depender do Meltano Hub |
| `docker/pipeline/runner.py` | Entrypoint da imagem: `bronze` (baixa a partição do MinIO e roda o Meltano para 1 tabela) e `dbt` (roda `dbt build` e publica `run_results.json` no lake) |
| `transform/dbt/models/silver/*.sql` | 1 modelo por tabela: tipagem, padronização (CPF, CEP, UF), deduplicação; `transacoes` incremental |
| `transform/dbt/models/silver/_silver__models.yml` | Testes da Silver (PK, FKs, valores aceitos). Cliente 528 = **warn** |
| `transform/dbt/models/gold/*.sql` | `dim_*`, `fct_*` e `mart_cliente_mensal` (transações e churn por cliente/mês), sem PII |
| `transform/dbt/tests/assert_bronze_silver_reconciliam.sql` | Nenhuma chave da Bronze pode "sumir" na Silver |
| `transform/dbt/macros/cleaning.sql` | Funções de limpeza reutilizáveis (timestamp, dinheiro, CPF/CEP, UF) |
| `scripts/stage_bronze_manual.sh` | **Só para esta fase**: faz à mão o que a task `landing_to_bronze` fará |
| `scripts/run_pipeline_pod.sh` | Roda a imagem do pipeline como Pod, com os mesmos Secrets do KubernetesPodOperator |

Defina a data do teste (use a mesma em todos os comandos):

```bash
$ export D=2026-10-13
```

### 2.1 Publicar os CSVs na zona bronze do lake

```bash
$ ./scripts/stage_bronze_manual.sh $D
#   s3://banvic-lake/bronze/agencias/ingestion_date=2026-10-13/run=manual-.../agencias.csv  (x7)
#   Partição 2026-10-13 publicada (run=manual-...)   ← o manifesto é gravado por último
```

**✅ Teste**: no MinIO Console (http://localhost:9001) → `banvic-lake/bronze/` tem 7 pastas.

### 2.2 Carregar UMA tabela na Bronze

```bash
$ ./scripts/run_pipeline_pod.sh bronze --table agencias --ingestion-date $D
# ... [runner] Baixando s3://banvic-lake/bronze/... (7 arquivos)
# ... tap-csv / target-postgres ...
# Resultado: Succeeded
```

**✅ Teste**

```bash
$ alias dw='kubectl -n data exec -it postgres-dw-0 -- psql -U dw_admin -d banvic_dw'
$ dw -c '\d bronze.agencias'
#  colunas de negócio em text + _sdc_source_file, _sdc_batched_at, ... e "agencias_pkey" PRIMARY KEY
$ dw -c 'select cod_agencia, nome, _sdc_source_file from bronze.agencias limit 3'
#  _sdc_source_file = /app/work/ingestion_date=2026-10-13/run=manual-.../agencias.csv  ← partição e execução
```

### 2.3 Carregar as 7 tabelas

```bash
$ for t in agencias colaboradores colaborador_agencia clientes contas propostas_credito transacoes; do
    ./scripts/run_pipeline_pod.sh bronze --table $t --ingestion-date $D || break
  done
```

**✅ Teste — contagens batem com os CSVs**

```bash
$ dw -c "
select 'agencias' t, count(*) from bronze.agencias union all
select 'colaboradores', count(*) from bronze.colaboradores union all
select 'colaborador_agencia', count(*) from bronze.colaborador_agencia union all
select 'clientes', count(*) from bronze.clientes union all
select 'contas', count(*) from bronze.contas union all
select 'propostas_credito', count(*) from bronze.propostas_credito union all
select 'transacoes', count(*) from bronze.transacoes"
# 10 · 100 · 100 · 998 · 999 · 2000 · 71999
```

### 2.4 Provar a idempotência da Bronze

```bash
$ ./scripts/run_pipeline_pod.sh bronze --table transacoes --ingestion-date $D
$ dw -c 'select count(*) from bronze.transacoes'      # continua 71999 (UPSERT por cod_transacao)
```

### 2.5 Silver (dbt)

```bash
$ ./scripts/run_pipeline_pod.sh dbt --select tag:silver --ingestion-date $D
# ... Done. PASS=45 WARN=2 ERROR=0 SKIP=0 TOTAL=47
```

Os **2 WARN são esperados** e são um achado de qualidade da origem: o `cod_cliente = 528` tem 1 conta
e 4 propostas de crédito, mas não existe na tabela `clientes`. O teste registra o problema sem
bloquear o pipeline (ótimo ponto para o vídeo).

**✅ Teste**

```bash
$ dw -c 'select data_inclusao, cep, uf_endereco from silver.clientes limit 3'   # timestamptz, CEP 8 dígitos, UF
$ dw -c 'select pg_typeof(valor_transacao), sum(valor_transacao) from silver.transacoes group by 1'  # numeric
```

### 2.6 Gold (dbt)

```bash
$ ./scripts/run_pipeline_pod.sh dbt --select tag:gold --ingestion-date $D
# ... Done. PASS=30 WARN=0 ERROR=0 SKIP=0 TOTAL=30
```

**✅ Teste final da fase**

```bash
$ make validate
# == 1. Contagem por camada ... OK em todas
# == 7. Segurança: OK: analyst bloqueado na silver (PII protegida)
# Validação concluída com sucesso.
```

(A seção 6, auditoria, fica vazia por enquanto — quem escreve nela é o Airflow, na Fase 3.)

**🔧 Se der errado**:
`NoSuchKey` no runner → rode o 2.1 com a **mesma** data.
`permission denied for schema` → o pod pegou o Secret errado (bronze usa `dw-ingestion-credentials`,
dbt usa `dw-transform-credentials`).
Falha de teste dbt com `ERROR` → leia o SQL compilado indicado no log; ele mostra as linhas problemáticas.

### 2.7 Checkpoint da Fase 2

```bash
$ git commit -am "feat(ingestion): bronze com Meltano e silver/gold com dbt" && git push
```

---

## Fase 3 — Orquestração no Airflow

### Arquivos desta fase

| Arquivo | O que faz |
|---|---|
| `dags/banvic_medallion.py` | A DAG: sensor → validação do zip → 7 pods Bronze (mapping) → qualidade → dbt Silver → dbt Gold → auditoria |
| `dags/banvic/contracts.py` | Contrato das 7 tabelas (colunas e PK), na ordem das dependências |
| `dags/banvic/landing.py` | Validação do zip: tabelas presentes, cabeçalhos, linhas, sha256, proteções zip-slip/zip-bomb |
| `dags/banvic/quality.py` | SQL de contagem com *allowlist* e UPSERT na auditoria |
| `dags/banvic/callbacks.py` | Alertas de falha/retry/sucesso (log estruturado + webhook opcional) |
| `dags/banvic/config.py` | Nomes de conexões, bucket, imagem e Secrets (sem valores sensíveis) |
| `scripts/seed_landing.sh` | Simula o legado: envia o zip para `landing/ingestion_date=D/` |
| `scripts/trigger_dag.sh` | Despausa, dispara com `{"ingestion_date": D}` e acompanha até o fim |

### 3.1 Conhecer a DAG na UI

Em http://localhost:8080 → **Dags → banvic_medallion**:

- **Graph**: os grupos `landing → bronze → silver → gold` (expanda cada um).
- **Code**: o código da DAG (veio dentro da imagem).
- **Details**: `max_active_runs=1`, `catchup=False`, agenda `@daily`, parâmetro `ingestion_date`.

> Toda alteração em `dags/` exige reconstruir a imagem: `make images && make platform`
> (o Terraform detecta e o Helm faz o rollout).

### 3.2 Rodar o pipeline completo

```bash
$ make seed        # envia o zip para landing/ingestion_date=<hoje UTC>/
$ make trigger     # despausa, dispara e acompanha
#   estado: running   (95s)
#   DAG concluída com sucesso.
```

Enquanto roda, observe:

- na UI (**Grid**), `load_bronze` com **7 instâncias nomeadas pela tabela** (máx. 3 em paralelo);
- no terminal, os pods sendo criados e removidos:

```bash
$ kubectl -n airflow get pods -l app=banvic-pipeline -w
```

> Ao despausar, o Airflow pode criar também a execução **agendada** mais recente (`@daily`). Ela
> processa a partição do dia dela e, por ser idempotente, não duplica nada. Isso é esperado.

**✅ Teste**

```bash
$ make validate
# agora a seção 6 mostra a auditoria: landing, bronze, silver e gold com status ok
```

E no MinIO: `bronze/_manifests/ingestion_date=.../manifest.json` (contagens + sha256) e
`ops/dbt_artifacts/.../run_results.json` (resultado dos testes dbt).

### 3.3 Idempotência da DAG

```bash
$ make trigger && make validate      # mesma data → mesmas contagens; auditoria com 2 run_ids
```

### 3.4 Testes de resiliência (ótimos para o vídeo)

**a) Sensor esperando o arquivo**

```bash
# Terminal A: dispara para um dia que ainda não tem arquivo
$ make trigger INGESTION_DATE=2030-01-01
```

Na UI, `wait_for_landing_file` fica em **up_for_reschedule** (sem ocupar slot). Então:

```bash
# Terminal B: o "legado" entrega o arquivo
$ make seed INGESTION_DATE=2030-01-01
```

Na próxima verificação (1–2 min) o sensor passa e o pipeline segue até o fim.

**b) Retry com backoff exponencial (banco indisponível)**

```bash
# Derruba o DW de propósito (o Airflow continua de pé: o banco de metadados é outro)
$ kubectl -n data scale statefulset postgres-dw --replicas=0
$ make trigger INGESTION_DATE=2030-01-01      # Terminal A
```

Na UI, as tasks `load_bronze` falham e ficam **up_for_retry** (laranja). Em ~1 min:

```bash
$ kubectl -n data scale statefulset postgres-dw --replicas=1     # Terminal B
```

Na próxima tentativa (backoff: ≈30 s, 60 s, 120 s) as tasks se recuperam e a DAG termina com sucesso.
Nos logs da task aparece a linha `RETRY {...}` emitida pelo callback.

**c) Arquivo fora do contrato (falha imediata, sem retry)**

```bash
$ cp data/banvic_data.zip /tmp/banvic_quebrado.zip
$ zip -d /tmp/banvic_quebrado.zip 'banvic_data/transacoes.csv'
$ ZIP=/tmp/banvic_quebrado.zip make seed INGESTION_DATE=2030-02-01
$ make trigger INGESTION_DATE=2030-02-01
#   DAG falhou.
```

O log de `landing_to_bronze` mostra `Arquivos ausentes no zip: ['transacoes']`, a task falha **sem
retry** (`AirflowFailException`) e o callback registra `ALERTA {"event": "TASK_FAILED", ...}`.
Nada foi escrito na Bronze — o contrato protegeu o DW.

### 3.5 Checkpoint da Fase 3

```bash
$ git commit -am "feat(orchestration): DAG medalhão com sensor, mapping, retries e auditoria" && git push
```

---

## Fase 4 — CI/CD com GitHub Actions

### Arquivos desta fase

| Arquivo | O que faz |
|---|---|
| `.github/workflows/ci.yml` | Lint · testes de DAG · pipeline de dados contra Postgres real · Terraform · manifestos K8s · Trivy |
| `.github/workflows/build-images.yml` | Build multi-arch das 2 imagens; publica no GHCR em `main` |
| `.github/workflows/e2e-kind.yml` | Sobe tudo do zero num Kind dentro do runner, roda a DAG 2× e destrói |
| `tests/` | `test_dag_integrity.py`, `test_landing.py`, `test_consistency.py` |
| `pyproject.toml`, `.yamllint`, `.tflint.hcl`, `.pre-commit-config.yaml` | Configuração de lint/format/testes |

### 4.1 Rodar localmente o que o CI roda

```bash
$ make lint      # ruff, yamllint, terraform fmt
$ make test      # 1ª vez instala o Airflow num .venv (~2–3 min); depois: 21 testes em segundos
```

Opcional: `uvx pre-commit install` para rodar o lint a cada commit.

### 4.2 Ver os workflows no GitHub

```bash
$ git push
$ gh run list --limit 5          # ou a aba "Actions" no navegador
$ gh run watch                   # acompanha o run mais recente
```

- **CI** roda em todo push/PR (~5 min).
- **Build images** roda quando mudam Dockerfiles, DAGs, Meltano ou dbt (~10–15 min por causa do arm64).
- **E2E (Kind)** roda em PR para `main` ou manualmente:

```bash
$ gh workflow run e2e-kind.yml && gh run watch       # ~25–35 min
```

### 4.3 Provar que o CI barra erros (opcional, bom para o vídeo)

```bash
$ git checkout -b teste/ci-quebrado
# Edite dags/banvic_medallion.py: troque  "retries": 3  por  "retries": 0
$ git commit -am "test: deve falhar no CI" && git push -u origin teste/ci-quebrado
$ gh pr create --fill
# O job dag-tests falha em test_retries_backoff_and_callbacks → o PR fica bloqueado.
$ gh pr close --delete-branch && git checkout main
```

> Para tornar isso obrigatório: *Settings → Branches → Add rule* em `main` exigindo os checks do CI.

**🔧 Se der errado**: falha no `terraform init` do CI com *"doesn't match any of the checksums"* →
rode `make lock` (Fase 1.4) e commite os `.terraform.lock.hcl`.

---

## Fase 5 — Documentação, vídeo e entrega

### 5.1 Revisar o README

- [ ] Badges e `git clone` do README apontam para o seu repositório (e os badges aparecem verdes).
- [ ] Confira se os diagramas Mermaid renderizam na página do GitHub.
- [ ] Rode o Quickstart do README "do zero" uma última vez (`make down && make up && make demo`).

### 5.2 Gravar o vídeo

O vídeo (3 a 5 min) precisa mostrar três coisas: **(a)** o deploy do ambiente (`make up`), **(b)** a DAG
executando com sucesso na UI do Airflow e **(c)** os dados chegando ao destino (`make validate` e consultas
na Gold).

### 5.3 Checklist contra os critérios de avaliação

| Critério | Onde está a evidência |
|---|---|
| **a) Infraestrutura** (Docker, Terraform, Kubernetes, reprodutibilidade) | `infra/terraform/*`, `docker/*`, `make up`, workflow E2E |
| **b) Ingestão** (fontes, destinos, Taps/Targets, integridade) | `meltano.yml` (PKs, UPSERT, metadados), contrato do zip, `bronze_quality`, testes dbt |
| **c) Airflow** (DAG organizada, operadores, dependências, agendamento) | TaskGroups por camada, sensor, KubernetesPodOperator com mapping, `@daily` sem catchup, `test_dag_integrity.py` |
| **d) Qualidade e resiliência** (código limpo, modular, erros) | ruff/testes no CI, retries com backoff, falhas não-retentáveis, callbacks, idempotência provada 2× |
| **e) Segurança e segredos** | senhas geradas pelo Terraform, Secrets, roles de menor privilégio, Trivy, portas só em 127.0.0.1 |
| **f) Apresentação** | README + vídeo |

### 5.4 Entregar

```bash
$ git tag v1.0.0 && git push --tags         # dispara o build/publicação das imagens
$ git archive -o ~/Desktop/banvic-data-platform.zip HEAD   # se preferir enviar em zip
```

Envie o **link do repositório** (ou o zip) e o **vídeo**.

---

## Apêndice — Comandos úteis

```bash
make help                    # todos os atalhos
make status                  # pods
make logs                    # scheduler do Airflow
make credentials             # URLs e senhas
make psql                    # psql como analista (Gold)
k9s                          # painel interativo do cluster
kubectl -n airflow get pods -l app=banvic-pipeline        # pods do pipeline (falhos ficam para inspeção)
kubectl -n airflow logs <pod>                             # log de um pod do pipeline
./scripts/run_pipeline_pod.sh dbt --select tag:gold --ingestion-date 2026-10-13   # roda uma etapa isolada
make down                    # destrói tudo (cluster + estado local)
```

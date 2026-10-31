# =============================================================================
# BanVic Data Platform - atalhos de operação
#   make help      lista os comandos
#   make up        sobe tudo do zero (cluster + imagens + plataforma)
#   make demo      envia o arquivo, roda a DAG e valida os dados
#   make down      destrói o ambiente
# Compatível com o GNU Make 3.81 que vem no macOS.
# =============================================================================
SHELL := /bin/bash

CLUSTER        ?= banvic
CONTEXT        := kind-$(CLUSTER)
TF             ?= terraform
TF_CLUSTER     := infra/terraform/cluster
TF_PLATFORM    := infra/terraform/platform
VERSION        ?= 0.1.0
AIRFLOW_IMAGE  ?= banvic/airflow:$(VERSION)
PIPELINE_IMAGE ?= banvic/pipeline:$(VERSION)
INGESTION_DATE ?= $(shell date -u +%F)

.DEFAULT_GOAL := help
.PHONY: help check up cluster images preload platform seed trigger validate demo \
        credentials psql status logs down lint test fmt lock

help: ## Lista os comandos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## Verifica ferramentas e Docker
	@./scripts/check_tools.sh

# ----------------------------------------------------------------- infra
up: check cluster images platform ## Sobe o ambiente completo do zero
	@echo
	@echo "Ambiente pronto."
	@echo "  Acessos e senhas geradas: make credentials"
	@echo "  Rodar o pipeline:         make demo"

cluster: ## [Fase 1] Cria o cluster Kind via Terraform
	$(TF) -chdir=$(TF_CLUSTER) init -input=false
	$(TF) -chdir=$(TF_CLUSTER) apply -input=false -auto-approve
	kubectl config use-context $(CONTEXT)
	kubectl get nodes -o wide

images: preload ## Builda as imagens Airflow/pipeline e carrega no Kind
	docker build -f docker/airflow/Dockerfile -t $(AIRFLOW_IMAGE) .
	docker build -f docker/pipeline/Dockerfile -t $(PIPELINE_IMAGE) .
	kind load docker-image $(AIRFLOW_IMAGE) $(PIPELINE_IMAGE) --name $(CLUSTER)

preload: ## Carrega imagens de terceiros (Postgres, MinIO) no Kind
	CLUSTER=$(CLUSTER) ./scripts/load_images.sh

platform: ## [Fase 1] Provisiona MinIO, Postgres, Secrets e Airflow via Terraform
	$(TF) -chdir=$(TF_PLATFORM) init -input=false
	$(TF) -chdir=$(TF_PLATFORM) apply -input=false -auto-approve \
		-var="kube_context=$(CONTEXT)" \
		-var="airflow_image_tag=$(VERSION)" \
		-var="pipeline_image=$(PIPELINE_IMAGE)"

# ----------------------------------------------------------------- pipeline
seed: ## [Fase 3] Simula o legado: envia o zip para a landing (INGESTION_DATE=AAAA-MM-DD)
	./scripts/seed_landing.sh $(INGESTION_DATE)

trigger: ## [Fase 3] Dispara a DAG e acompanha até o fim
	./scripts/trigger_dag.sh $(INGESTION_DATE)

validate: ## [Fase 3] Valida contagens, integridade e permissões no DW
	./scripts/validate.sh

demo: seed trigger validate ## seed + trigger + validate

# ----------------------------------------------------------------- operação
credentials: ## Mostra URLs e senhas geradas
	@TF=$(TF) ./scripts/credentials.sh

psql: ## Abre o psql como analista (somente Gold)
	PGPASSWORD="$$($(TF) -chdir=$(TF_PLATFORM) output -raw analyst_password)" \
		psql -h localhost -p 15432 -U analyst -d banvic_dw

status: ## Pods de todos os namespaces do projeto
	kubectl get pods -n data -o wide
	kubectl get pods -n airflow -o wide

logs: ## Logs do scheduler do Airflow
	kubectl -n airflow logs -l component=scheduler -c scheduler --tail=200

down: ## Destrói o cluster (e todo o estado local da plataforma)
	-$(TF) -chdir=$(TF_CLUSTER) destroy -input=false -auto-approve
	rm -f $(TF_PLATFORM)/terraform.tfstate $(TF_PLATFORM)/terraform.tfstate.backup

lock: ## Registra hashes dos providers p/ macOS e Linux (rode antes de commitar os .lock.hcl)
	$(TF) -chdir=$(TF_CLUSTER) init -input=false
	$(TF) -chdir=$(TF_CLUSTER) providers lock -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64
	$(TF) -chdir=$(TF_PLATFORM) init -input=false
	$(TF) -chdir=$(TF_PLATFORM) providers lock -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64

# ----------------------------------------------------------------- qualidade
lint: ## Lint de Python, YAML e Terraform (mesmo do CI)
	uvx ruff@0.17.0 check .
	uvx ruff@0.17.0 format --check .
	uvx yamllint@1.38.0 -s .
	$(TF) fmt -check -recursive infra/terraform

AIRFLOW_CONSTRAINTS := https://raw.githubusercontent.com/apache/airflow/constraints-3.2.2/constraints-3.12.txt

test: ## Testes (integridade da DAG, contratos, landing)
	uv venv --allow-existing -q -p 3.12 .venv
	uv pip install -q -p .venv -r requirements-dev.txt -c $(AIRFLOW_CONSTRAINTS)
	.venv/bin/pytest -q

fmt: ## Formata Python e Terraform
	uvx ruff@0.17.0 format .
	uvx ruff@0.17.0 check --fix .
	$(TF) fmt -recursive infra/terraform

#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Bootstrap do Data Warehouse BanVic (arquitetura medalhão).
#
# Executado UMA vez pelo entrypoint oficial do Postgres
# (/docker-entrypoint-initdb.d) quando o volume de dados está vazio.
# Montado via ConfigMap pelo Terraform (módulo postgres).
#
# Cria:
#   - schemas: bronze, silver, gold, ops
#   - roles de serviço com privilégio mínimo (senhas vêm de K8s Secrets)
#   - default privileges para que tabelas criadas no futuro já nasçam
#     com as permissões corretas
#   - tabela de auditoria ops.pipeline_audit
#
# Nenhuma senha está neste arquivo: são lidas de variáveis de ambiente
# injetadas pelo Secret "postgres-dw-credentials".
# -----------------------------------------------------------------------------
set -euo pipefail

: "${SVC_INGESTION_PASSWORD:?variavel obrigatoria}"
: "${SVC_TRANSFORM_PASSWORD:?variavel obrigatoria}"
: "${SVC_ORCHESTRATOR_PASSWORD:?variavel obrigatoria}"
: "${ANALYST_PASSWORD:?variavel obrigatoria}"

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  -v dbname="$POSTGRES_DB" \
  -v ingestion_pwd="$SVC_INGESTION_PASSWORD" \
  -v transform_pwd="$SVC_TRANSFORM_PASSWORD" \
  -v orchestrator_pwd="$SVC_ORCHESTRATOR_PASSWORD" \
  -v analyst_pwd="$ANALYST_PASSWORD" <<'EOSQL'

-- ---------------------------------------------------------------------------
-- 1. Roles (uma por responsabilidade -> princípio do menor privilégio)
-- ---------------------------------------------------------------------------
CREATE ROLE svc_ingestion    LOGIN PASSWORD :'ingestion_pwd';    -- Meltano: escreve Bronze
CREATE ROLE svc_transform    LOGIN PASSWORD :'transform_pwd';    -- dbt: lê Bronze, escreve Silver/Gold
CREATE ROLE svc_orchestrator LOGIN PASSWORD :'orchestrator_pwd'; -- Airflow: qualidade e auditoria
CREATE ROLE analyst          LOGIN PASSWORD :'analyst_pwd';      -- BI/analistas: só lê Gold

-- Ninguém conecta "por padrão": acesso é concedido explicitamente.
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"dbname" TO svc_ingestion, svc_transform, svc_orchestrator, analyst;
-- target-postgres e dbt usam tabelas temporárias durante a carga.
GRANT TEMPORARY ON DATABASE :"dbname" TO svc_ingestion, svc_transform;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 2. Schemas do medalhão (o dono é quem escreve na camada)
-- ---------------------------------------------------------------------------
CREATE SCHEMA bronze AUTHORIZATION svc_ingestion;
CREATE SCHEMA silver AUTHORIZATION svc_transform;
CREATE SCHEMA gold   AUTHORIZATION svc_transform;
CREATE SCHEMA ops    AUTHORIZATION svc_orchestrator;

COMMENT ON SCHEMA bronze IS 'Cópia fiel da origem (texto) + metadados de ingestão. Escrita: Meltano.';
COMMENT ON SCHEMA silver IS 'Dados tipados, padronizados, deduplicados e testados. Escrita: dbt.';
COMMENT ON SCHEMA gold   IS 'Modelo dimensional e marts de negócio para BI. Escrita: dbt.';
COMMENT ON SCHEMA ops    IS 'Auditoria e metadados operacionais do pipeline. Escrita: Airflow.';

-- ---------------------------------------------------------------------------
-- 3. Permissões de leitura entre camadas
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA bronze TO svc_transform, svc_orchestrator;
GRANT USAGE ON SCHEMA silver TO svc_orchestrator;
GRANT USAGE ON SCHEMA gold   TO svc_orchestrator, analyst;

-- Tabelas que forem criadas no futuro já nascem com o GRANT certo.
ALTER DEFAULT PRIVILEGES FOR ROLE svc_ingestion IN SCHEMA bronze
  GRANT SELECT ON TABLES TO svc_transform, svc_orchestrator;
ALTER DEFAULT PRIVILEGES FOR ROLE svc_transform IN SCHEMA silver
  GRANT SELECT ON TABLES TO svc_orchestrator;
ALTER DEFAULT PRIVILEGES FOR ROLE svc_transform IN SCHEMA gold
  GRANT SELECT ON TABLES TO svc_orchestrator, analyst;

-- Analistas não enxergam bronze/silver/ops (dados brutos e PII).
REVOKE ALL ON SCHEMA bronze, silver, ops FROM analyst;

-- ---------------------------------------------------------------------------
-- 4. Auditoria do pipeline (idempotente por run_id + camada + tabela)
-- ---------------------------------------------------------------------------
SET ROLE svc_orchestrator;
CREATE TABLE ops.pipeline_audit (
    run_id          text        NOT NULL,
    ingestion_date  date        NOT NULL,
    layer           text        NOT NULL CHECK (layer IN ('landing', 'bronze', 'silver', 'gold')),
    table_name      text        NOT NULL,
    row_count       bigint      NOT NULL,
    expected_count  bigint,
    status          text        NOT NULL CHECK (status IN ('ok', 'warn', 'fail')),
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, layer, table_name)
);
COMMENT ON TABLE ops.pipeline_audit IS 'Contagem de linhas por camada/tabela em cada execução da DAG.';
RESET ROLE;
EOSQL

echo "Bootstrap do DW concluído: schemas bronze/silver/gold/ops e roles criados."

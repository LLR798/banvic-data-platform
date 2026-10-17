-- =============================================================================
-- Validação ponta a ponta do DW BanVic (rodar após a DAG).
--   make validate
-- Falha (exit != 0) se alguma contagem divergir do esperado ou se a role
-- "analyst" conseguir ler dados fora da Gold.
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\echo '== 1. Contagem por camada (esperado = linhas dos CSVs do banvic_data.zip)'

WITH expected(tabela, esperado) AS (
    VALUES ('agencias', 10), ('colaboradores', 100), ('colaborador_agencia', 100),
           ('clientes', 998), ('contas', 999), ('propostas_credito', 2000),
           ('transacoes', 71999)
),
counts AS (
    SELECT 'agencias' AS tabela,
           (SELECT count(*) FROM bronze.agencias) AS bronze,
           (SELECT count(*) FROM silver.agencias) AS silver
    UNION ALL SELECT 'colaboradores', (SELECT count(*) FROM bronze.colaboradores), (SELECT count(*) FROM silver.colaboradores)
    UNION ALL SELECT 'colaborador_agencia', (SELECT count(*) FROM bronze.colaborador_agencia), (SELECT count(*) FROM silver.colaborador_agencia)
    UNION ALL SELECT 'clientes', (SELECT count(*) FROM bronze.clientes), (SELECT count(*) FROM silver.clientes)
    UNION ALL SELECT 'contas', (SELECT count(*) FROM bronze.contas), (SELECT count(*) FROM silver.contas)
    UNION ALL SELECT 'propostas_credito', (SELECT count(*) FROM bronze.propostas_credito), (SELECT count(*) FROM silver.propostas_credito)
    UNION ALL SELECT 'transacoes', (SELECT count(*) FROM bronze.transacoes), (SELECT count(*) FROM silver.transacoes)
)
SELECT c.tabela, e.esperado, c.bronze, c.silver,
       CASE WHEN c.bronze = e.esperado AND c.silver = e.esperado THEN 'OK' ELSE 'DIVERGENTE' END AS status
FROM counts c JOIN expected e USING (tabela)
ORDER BY e.esperado;

DO $$
DECLARE
    divergentes int;
BEGIN
    SELECT count(*) INTO divergentes FROM (
        VALUES ('bronze.agencias', (SELECT count(*) FROM bronze.agencias), 10),
               ('silver.agencias', (SELECT count(*) FROM silver.agencias), 10),
               ('bronze.colaboradores', (SELECT count(*) FROM bronze.colaboradores), 100),
               ('silver.colaboradores', (SELECT count(*) FROM silver.colaboradores), 100),
               ('bronze.colaborador_agencia', (SELECT count(*) FROM bronze.colaborador_agencia), 100),
               ('silver.colaborador_agencia', (SELECT count(*) FROM silver.colaborador_agencia), 100),
               ('bronze.clientes', (SELECT count(*) FROM bronze.clientes), 998),
               ('silver.clientes', (SELECT count(*) FROM silver.clientes), 998),
               ('bronze.contas', (SELECT count(*) FROM bronze.contas), 999),
               ('silver.contas', (SELECT count(*) FROM silver.contas), 999),
               ('bronze.propostas_credito', (SELECT count(*) FROM bronze.propostas_credito), 2000),
               ('silver.propostas_credito', (SELECT count(*) FROM silver.propostas_credito), 2000),
               ('bronze.transacoes', (SELECT count(*) FROM bronze.transacoes), 71999),
               ('silver.transacoes', (SELECT count(*) FROM silver.transacoes), 71999)
    ) AS t(tabela, atual, esperado)
    WHERE atual <> esperado;

    IF divergentes > 0 THEN
        RAISE EXCEPTION 'Validação falhou: % tabela(s) com contagem divergente', divergentes;
    END IF;
    RAISE NOTICE 'OK: contagens de Bronze e Silver batem com a origem.';
END $$;

\echo
\echo '== 2. Unicidade das chaves na Silver (0 = sem duplicatas)'
SELECT 'transacoes' AS tabela, count(*) - count(DISTINCT cod_transacao) AS duplicatas FROM silver.transacoes
UNION ALL SELECT 'clientes', count(*) - count(DISTINCT cod_cliente) FROM silver.clientes
UNION ALL SELECT 'contas', count(*) - count(DISTINCT num_conta) FROM silver.contas
UNION ALL SELECT 'propostas_credito', count(*) - count(DISTINCT cod_proposta) FROM silver.propostas_credito;

\echo
\echo '== 3. Integridade referencial: problema conhecido da origem (cliente 528)'
SELECT 'contas sem cliente' AS checagem, count(*) AS linhas
FROM silver.contas c LEFT JOIN silver.clientes cl USING (cod_cliente) WHERE cl.cod_cliente IS NULL
UNION ALL
SELECT 'propostas sem cliente', count(*)
FROM silver.propostas_credito p LEFT JOIN silver.clientes cl USING (cod_cliente) WHERE cl.cod_cliente IS NULL
UNION ALL
SELECT 'fatos Gold sem dimensão (deve ser 0)', count(*)
FROM gold.fct_transacoes f LEFT JOIN gold.dim_cliente d USING (cod_cliente) WHERE d.cod_cliente IS NULL;

\echo
\echo '== 4. Gold: tabelas publicadas'
SELECT 'dim_agencia' AS tabela, count(*) AS linhas FROM gold.dim_agencia
UNION ALL SELECT 'dim_colaborador', count(*) FROM gold.dim_colaborador
UNION ALL SELECT 'dim_cliente', count(*) FROM gold.dim_cliente
UNION ALL SELECT 'fct_transacoes', count(*) FROM gold.fct_transacoes
UNION ALL SELECT 'fct_propostas_credito', count(*) FROM gold.fct_propostas_credito
UNION ALL SELECT 'mart_cliente_mensal', count(*) FROM gold.mart_cliente_mensal;

\echo
\echo '== 5. Gold: média de transações por cliente ativo, por ano'
SELECT extract(year FROM mes)::int AS ano,
       round(sum(qtd_transacoes)::numeric / nullif(count(DISTINCT cod_cliente) FILTER (WHERE qtd_transacoes > 0), 0), 1)
           AS transacoes_por_cliente_ativo,
       count(DISTINCT cod_cliente) FILTER (WHERE status_cliente = 'risco_churn' AND mes = date_trunc('year', mes) + interval '11 months')
           AS clientes_em_risco_dezembro
FROM gold.mart_cliente_mensal
GROUP BY 1 ORDER BY 1;

\echo
\echo '== 6. Auditoria das últimas execuções (ops.pipeline_audit)'
SELECT run_id, layer, count(*) AS tabelas, sum(row_count) AS linhas,
       string_agg(DISTINCT status, ',') AS status, max(recorded_at) AS registrado_em
FROM ops.pipeline_audit
GROUP BY run_id, layer
ORDER BY max(recorded_at) DESC, layer
LIMIT 8;

\echo
\echo '== 7. Segurança: a role analyst só enxerga a Gold'
DO $$
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE analyst';
        PERFORM 1 FROM gold.dim_cliente LIMIT 1;
        RAISE NOTICE 'OK: analyst lê gold.dim_cliente';
        PERFORM 1 FROM silver.clientes LIMIT 1;
        RAISE EXCEPTION 'FALHA DE SEGURANÇA: analyst conseguiu ler silver.clientes (PII)';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK: analyst bloqueado na silver (PII protegida)';
    END;
END $$;

\echo
\echo 'Validação concluída com sucesso.'

-- Teste singular de reconciliação: toda chave da Bronze precisa existir na Silver.
-- Falha (ERROR) se a tipagem/deduplicação "perder" linhas no caminho.
{{ config(tags=['silver']) }}

with checks as (
    select 'agencias' as tabela, (select count(distinct cod_agencia) from {{ source('bronze', 'agencias') }}) as bronze, (select count(*) from {{ ref('agencias') }}) as silver
    union all
    select 'colaboradores', (select count(distinct cod_colaborador) from {{ source('bronze', 'colaboradores') }}), (select count(*) from {{ ref('colaboradores') }})
    union all
    select 'colaborador_agencia', (select count(*) from (select distinct cod_colaborador, cod_agencia from {{ source('bronze', 'colaborador_agencia') }}) as d), (select count(*) from {{ ref('colaborador_agencia') }})
    union all
    select 'clientes', (select count(distinct cod_cliente) from {{ source('bronze', 'clientes') }}), (select count(*) from {{ ref('clientes') }})
    union all
    select 'contas', (select count(distinct num_conta) from {{ source('bronze', 'contas') }}), (select count(*) from {{ ref('contas') }})
    union all
    select 'propostas_credito', (select count(distinct cod_proposta) from {{ source('bronze', 'propostas_credito') }}), (select count(*) from {{ ref('propostas_credito') }})
    union all
    select 'transacoes', (select count(distinct cod_transacao) from {{ source('bronze', 'transacoes') }}), (select count(*) from {{ ref('transacoes') }})
)

select * from checks where bronze <> silver

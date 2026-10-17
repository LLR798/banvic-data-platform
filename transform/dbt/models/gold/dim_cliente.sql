{#
  Dimensão de clientes SEM PII (LGPD): CPF, e-mail e endereço ficam na Silver,
  acessível apenas às roles de engenharia.

  Membro "não identificado": clientes referenciados em contas/propostas mas
  ausentes no cadastro (ex.: cod_cliente 528) entram com cliente_cadastrado = false,
  para que nenhum fato se perca nos joins do BI.
#}
with clientes as (
    select * from {{ ref('clientes') }}
),

contas as (
    select * from {{ ref('contas') }}
),

data_ref as (
    -- Os dados terminam em 2023; idade/tempo de casa são calculados contra
    -- a última data da base, não contra a data de hoje.
    select max(data_transacao)::date as data_referencia from {{ ref('transacoes') }}
),

cadastrados as (
    select
        cl.cod_cliente,
        cl.nome_completo,
        cl.tipo_cliente,
        cl.uf_endereco,
        cl.data_inclusao,
        cl.data_nascimento,
        true as cliente_cadastrado
    from clientes as cl
),

nao_identificados as (
    select distinct
        ref_cli.cod_cliente,
        'CLIENTE NÃO IDENTIFICADO'::text as nome_completo,
        null::text as tipo_cliente,
        null::text as uf_endereco,
        null::timestamptz as data_inclusao,
        null::date as data_nascimento,
        false as cliente_cadastrado
    from (
        select cod_cliente from contas
        union
        select cod_cliente from {{ ref('propostas_credito') }}
    ) as ref_cli
    where not exists (select 1 from clientes as cl where cl.cod_cliente = ref_cli.cod_cliente)
),

todos as (
    select * from cadastrados
    union all
    select * from nao_identificados
)

select
    t.cod_cliente,
    t.nome_completo,
    t.tipo_cliente,
    t.uf_endereco,
    t.data_inclusao,
    co.num_conta,
    co.cod_agencia,
    co.data_abertura                                          as data_abertura_conta,
    date_part('year', age(r.data_referencia, t.data_nascimento))::integer as idade,
    case
        when t.data_nascimento is null then 'Não informado'
        when age(r.data_referencia, t.data_nascimento) < interval '25 years' then 'Até 24'
        when age(r.data_referencia, t.data_nascimento) < interval '35 years' then '25-34'
        when age(r.data_referencia, t.data_nascimento) < interval '45 years' then '35-44'
        when age(r.data_referencia, t.data_nascimento) < interval '60 years' then '45-59'
        else '60+'
    end                                                       as faixa_etaria,
    t.cliente_cadastrado
from todos as t
cross join data_ref as r
left join contas as co on co.cod_cliente = t.cod_cliente

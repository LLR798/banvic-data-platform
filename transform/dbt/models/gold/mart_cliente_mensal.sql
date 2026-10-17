{#
  Mart da Diretoria Comercial: 1 linha por cliente x mês.
  Responde: "quantas transações por cliente?" e "quem está em risco de churn?".

  - Meses sem transação aparecem com zero (calendário completo por cliente).
  - dias_sem_transacao é medido no fim de cada mês (ou na data de referência
    da base, no último mês).
#}
with fatos as (
    select * from {{ ref('fct_transacoes') }}
),

limites as (
    select
        date_trunc('month', min(data_transacao))::date as primeiro_mes,
        date_trunc('month', max(data_transacao))::date as ultimo_mes,
        max(data_transacao)::date                      as data_referencia
    from fatos
),

meses as (
    select generate_series(primeiro_mes, ultimo_mes, interval '1 month')::date as mes
    from limites
),

inicio_cliente as (
    -- Primeiro mês de relacionamento: inclusão no cadastro ou 1ª transação.
    select
        d.cod_cliente,
        least(
            date_trunc('month', d.data_inclusao)::date,
            date_trunc('month', min(f.data_transacao))::date
        ) as mes_inicio
    from {{ ref('dim_cliente') }} as d
    left join fatos as f on f.cod_cliente = d.cod_cliente
    group by d.cod_cliente, d.data_inclusao
),

calendario as (
    select ic.cod_cliente, m.mes
    from inicio_cliente as ic
    inner join meses as m on m.mes >= ic.mes_inicio
),

agregado as (
    select
        cod_cliente,
        mes,
        count(*)                                                   as qtd_transacoes,
        sum(valor_absoluto)                                        as valor_movimentado,
        sum(valor_transacao) filter (where sentido = 'credito')    as valor_entradas,
        -sum(valor_transacao) filter (where sentido = 'debito')    as valor_saidas,
        count(distinct categoria)                                  as qtd_categorias_usadas,
        max(data_transacao)::date                                  as ultima_transacao_no_mes
    from fatos
    group by cod_cliente, mes
),

base as (
    select
        c.cod_cliente,
        c.mes,
        coalesce(a.qtd_transacoes, 0)          as qtd_transacoes,
        coalesce(a.valor_movimentado, 0)       as valor_movimentado,
        coalesce(a.valor_entradas, 0)          as valor_entradas,
        coalesce(a.valor_saidas, 0)            as valor_saidas,
        coalesce(a.qtd_categorias_usadas, 0)   as qtd_categorias_usadas,
        max(a.ultima_transacao_no_mes) over (
            partition by c.cod_cliente order by c.mes
            rows between unbounded preceding and current row
        )                                      as ultima_transacao_ate_mes,
        sum(coalesce(a.qtd_transacoes, 0)) over (
            partition by c.cod_cliente order by c.mes
            rows between 2 preceding and current row
        )                                      as qtd_transacoes_3m
    from calendario as c
    left join agregado as a
        on a.cod_cliente = c.cod_cliente
       and a.mes = c.mes
),

final as (
    select
        b.*,
        least((b.mes + interval '1 month' - interval '1 day')::date, l.data_referencia)
            - b.ultima_transacao_ate_mes       as dias_sem_transacao
    from base as b
    cross join limites as l
)

select
    cod_cliente || '-' || to_char(mes, 'YYYY-MM') as sk_cliente_mes,
    cod_cliente,
    mes,
    qtd_transacoes,
    qtd_transacoes_3m,
    valor_movimentado,
    valor_entradas,
    valor_saidas,
    qtd_categorias_usadas,
    ultima_transacao_ate_mes,
    dias_sem_transacao,
    case
        when ultima_transacao_ate_mes is null then 'sem_historico'
        when dias_sem_transacao > {{ var('churn_dias_sem_transacao') }} then 'risco_churn'
        when qtd_transacoes = 0 then 'inativo_no_mes'
        else 'ativo'
    end as status_cliente
from final

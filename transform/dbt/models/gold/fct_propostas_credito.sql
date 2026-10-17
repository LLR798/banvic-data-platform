select
    p.cod_proposta,
    p.cod_cliente,
    p.cod_colaborador,
    ca.cod_agencia,
    p.data_entrada_proposta,
    date_trunc('month', p.data_entrada_proposta)::date as mes,
    p.status_proposta,
    (p.status_proposta = 'Aprovada')                     as flag_aprovada,
    p.taxa_juros_mensal,
    p.valor_proposta,
    p.valor_financiamento,
    p.valor_entrada,
    p.valor_prestacao,
    p.quantidade_parcelas,
    p.carencia
from {{ ref('propostas_credito') }} as p
left join {{ ref('colaborador_agencia') }} as ca on ca.cod_colaborador = p.cod_colaborador

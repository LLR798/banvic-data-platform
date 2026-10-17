with src as (
    {{ latest_from_bronze('propostas_credito', ['cod_proposta']) }}
)

select
    cod_proposta::integer                          as cod_proposta,
    cod_cliente::integer                           as cod_cliente,
    cod_colaborador::integer                       as cod_colaborador,
    {{ to_timestamptz('data_entrada_proposta') }}  as data_entrada_proposta,
    round(taxa_juros_mensal::numeric, 4)::numeric(8, 4) as taxa_juros_mensal,
    {{ to_money('valor_proposta') }}               as valor_proposta,
    {{ to_money('valor_financiamento') }}          as valor_financiamento,
    {{ to_money('valor_entrada') }}                as valor_entrada,
    {{ to_money('valor_prestacao') }}              as valor_prestacao,
    quantidade_parcelas::integer                   as quantidade_parcelas,
    carencia::integer                              as carencia,
    trim(status_proposta)                          as status_proposta,
    _sdc_source_file                               as _source_file,
    _sdc_batched_at                                as _loaded_at
from src

with src as (
    {{ latest_from_bronze('contas', ['num_conta']) }}
)

select
    num_conta::integer                              as num_conta,
    cod_cliente::integer                            as cod_cliente,
    cod_agencia::integer                            as cod_agencia,
    cod_colaborador::integer                        as cod_colaborador,
    upper(trim(tipo_conta))                         as tipo_conta,
    {{ to_timestamptz('data_abertura') }}           as data_abertura,
    {{ to_money('saldo_total') }}                   as saldo_total,
    {{ to_money('saldo_disponivel') }}              as saldo_disponivel,
    {{ to_timestamptz('data_ultimo_lancamento') }}  as data_ultimo_lancamento,
    _sdc_source_file                                as _source_file,
    _sdc_batched_at                                 as _loaded_at
from src

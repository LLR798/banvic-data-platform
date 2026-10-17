with src as (
    {{ latest_from_bronze('agencias', ['cod_agencia']) }}
)

select
    cod_agencia::integer             as cod_agencia,
    trim(nome)                       as nome_agencia,
    trim(endereco)                   as endereco,
    trim(cidade)                     as cidade,
    upper(trim(uf))                  as uf,
    nullif(trim(data_abertura), '')::date as data_abertura,
    trim(tipo_agencia)               as tipo_agencia,
    _sdc_source_file                 as _source_file,
    _sdc_batched_at                  as _loaded_at
from src

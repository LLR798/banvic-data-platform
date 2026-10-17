with src as (
    {{ latest_from_bronze('clientes', ['cod_cliente']) }}
)

select
    cod_cliente::integer                           as cod_cliente,
    trim(primeiro_nome)                            as primeiro_nome,
    trim(ultimo_nome)                              as ultimo_nome,
    trim(primeiro_nome) || ' ' || trim(ultimo_nome) as nome_completo,
    lower(trim(email))                             as email,
    upper(trim(tipo_cliente))                      as tipo_cliente,
    {{ to_timestamptz('data_inclusao') }}          as data_inclusao,
    {{ only_digits('cpfcnpj') }}                   as cpf_cnpj,
    nullif(trim(data_nascimento), '')::date        as data_nascimento,
    trim(endereco)                                 as endereco,
    {{ uf_from_address('endereco') }}              as uf_endereco,
    {{ to_cep('cep') }}                            as cep,
    _sdc_source_file                               as _source_file,
    _sdc_batched_at                                as _loaded_at
from src

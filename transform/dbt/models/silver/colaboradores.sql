with src as (
    {{ latest_from_bronze('colaboradores', ['cod_colaborador']) }}
)

select
    cod_colaborador::integer                       as cod_colaborador,
    trim(primeiro_nome)                            as primeiro_nome,
    trim(ultimo_nome)                              as ultimo_nome,
    trim(primeiro_nome) || ' ' || trim(ultimo_nome) as nome_completo,
    lower(trim(email))                             as email,
    {{ only_digits('cpf') }}                       as cpf,
    nullif(trim(data_nascimento), '')::date        as data_nascimento,
    trim(endereco)                                 as endereco,
    {{ to_cep('cep') }}                            as cep,
    _sdc_source_file                               as _source_file,
    _sdc_batched_at                                as _loaded_at
from src

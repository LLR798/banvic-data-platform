with src as (
    {{ latest_from_bronze('colaborador_agencia', ['cod_colaborador', 'cod_agencia']) }}
)

select
    cod_colaborador::integer as cod_colaborador,
    cod_agencia::integer     as cod_agencia,
    _sdc_source_file         as _source_file,
    _sdc_batched_at          as _loaded_at
from src

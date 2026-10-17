{#
  Única tabela incremental do projeto (72 mil linhas e crescendo).
  - delete+insert por cod_transacao: reexecutar não duplica (idempotente).
  - Janela de lookback reprocessa os últimos N dias para capturar ajustes.
#}
{{
    config(
        materialized='incremental',
        unique_key='cod_transacao',
        incremental_strategy='delete+insert',
        on_schema_change='append_new_columns'
    )
}}

with src as (
    {{ latest_from_bronze('transacoes', ['cod_transacao']) }}
),

typed as (
    select
        cod_transacao::bigint                    as cod_transacao,
        num_conta::integer                       as num_conta,
        {{ to_timestamptz('data_transacao') }}   as data_transacao,
        trim(nome_transacao)                     as nome_transacao,
        {{ to_money('valor_transacao') }}        as valor_transacao,
        _sdc_source_file                         as _source_file,
        _sdc_batched_at                          as _loaded_at
    from src
)

select
    *,
    case when valor_transacao >= 0 then 'credito' else 'debito' end as sentido
from typed
{% if is_incremental() %}
where data_transacao >= (
    select coalesce(max(data_transacao), '1900-01-01'::timestamptz)
           - interval '{{ var("transacoes_lookback_days") }} days'
    from {{ this }}
)
{% endif %}

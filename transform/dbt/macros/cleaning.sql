{#
  Macros de padronização reutilizadas pela camada Silver.
  A Bronze guarda tudo como texto; aqui definimos os tipos de verdade.
#}

{# Seleciona a versão mais recente de cada chave na Bronze (deduplicação defensiva). #}
{% macro latest_from_bronze(table_name, key_columns) -%}
    select *
    from (
        select
            src.*,
            row_number() over (
                partition by {{ key_columns | join(', ') }}
                order by src._sdc_batched_at desc nulls last, src._sdc_source_lineno desc
            ) as _row_rank
        from {{ source('bronze', table_name) }} as src
    ) as ranked
    where _row_rank = 1
{%- endmacro %}

{# Timestamps da origem vêm como "2021-06-29 11:52:38[.ffffff] UTC". #}
{% macro to_timestamptz(column) -%}
    nullif(trim({{ column }}), '')::timestamptz
{%- endmacro %}

{# Valores monetários: texto com ruído de ponto flutuante -> numeric(18,2). #}
{% macro to_money(column) -%}
    round(nullif(trim({{ column }}), '')::numeric, 2)::numeric(18, 2)
{%- endmacro %}

{# Mantém apenas dígitos (CPF, CEP). #}
{% macro only_digits(column) -%}
    nullif(regexp_replace({{ column }}, '[^0-9]', '', 'g'), '')
{%- endmacro %}

{# CEP com 8 dígitos (a origem mistura "99999-999" e "99999999"). #}
{% macro to_cep(column) -%}
    lpad({{ only_digits(column) }}, 8, '0')
{%- endmacro %}

{# UF ao final do endereço livre: "... Cidade / SP" -> "SP". #}
{% macro uf_from_address(column) -%}
    nullif(upper(substring(trim({{ column }}) from '/\s*([A-Za-z]{2})$')), '')
{%- endmacro %}

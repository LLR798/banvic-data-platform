{#
  Usa o schema configurado (+schema: silver/gold) exatamente como está,
  em vez do padrão do dbt "<target_schema>_<custom_schema>".
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}

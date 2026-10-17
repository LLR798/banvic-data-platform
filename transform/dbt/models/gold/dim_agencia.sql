with agencias as (
    select * from {{ ref('agencias') }}
),

lotacao as (
    select cod_agencia, count(*) as qtd_colaboradores
    from {{ ref('colaborador_agencia') }}
    group by cod_agencia
)

select
    a.cod_agencia,
    a.nome_agencia,
    a.tipo_agencia,
    a.cidade,
    a.uf,
    a.data_abertura,
    coalesce(l.qtd_colaboradores, 0) as qtd_colaboradores
from agencias as a
left join lotacao as l on l.cod_agencia = a.cod_agencia

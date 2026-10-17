-- Sem PII (CPF, e-mail, endereço): a Gold é a camada aberta aos analistas.
select
    c.cod_colaborador,
    c.nome_completo,
    ca.cod_agencia,
    a.nome_agencia
from {{ ref('colaboradores') }} as c
left join {{ ref('colaborador_agencia') }} as ca on ca.cod_colaborador = c.cod_colaborador
left join {{ ref('agencias') }} as a on a.cod_agencia = ca.cod_agencia

select
    t.cod_transacao,
    t.num_conta,
    c.cod_cliente,
    c.cod_agencia,
    t.data_transacao,
    t.data_transacao::date                          as data,
    date_trunc('month', t.data_transacao)::date     as mes,
    t.nome_transacao,
    case
        when t.nome_transacao ilike 'pix%'               then 'Pix'
        when t.nome_transacao ilike 'compra%'            then 'Cartão'
        when t.nome_transacao ilike 'ted%'
          or t.nome_transacao ilike 'doc%'
          or t.nome_transacao ilike 'transfer%'          then 'Transferência'
        when t.nome_transacao ilike 'saque%'
          or t.nome_transacao ilike 'depósito%'          then 'Numerário'
        when t.nome_transacao ilike 'pagamento%'         then 'Pagamento'
        when t.nome_transacao ilike 'estorno%'           then 'Estorno'
        else 'Outros'
    end                                             as categoria,
    t.sentido,
    t.valor_transacao,
    abs(t.valor_transacao)                          as valor_absoluto
from {{ ref('transacoes') }} as t
inner join {{ ref('contas') }} as c on c.num_conta = t.num_conta

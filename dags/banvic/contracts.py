"""Contrato de dados das 7 tabelas do ERP (banvic_data.zip).

É a "fonte da verdade" usada para validar o arquivo antes de qualquer carga:
se o legado mudar uma coluna, a DAG falha na landing - e não no meio do DW.
A ordem do dicionário respeita as dependências relacionais (dimensões -> fatos).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TableContract:
    name: str
    primary_key: tuple[str, ...]
    columns: tuple[str, ...]


CONTRACTS: dict[str, TableContract] = {
    c.name: c
    for c in (
        TableContract(
            "agencias",
            ("cod_agencia",),
            ("cod_agencia", "nome", "endereco", "cidade", "uf", "data_abertura", "tipo_agencia"),
        ),
        TableContract(
            "colaboradores",
            ("cod_colaborador",),
            (
                "cod_colaborador",
                "primeiro_nome",
                "ultimo_nome",
                "email",
                "cpf",
                "data_nascimento",
                "endereco",
                "cep",
            ),
        ),
        TableContract(
            "colaborador_agencia",
            ("cod_colaborador", "cod_agencia"),
            ("cod_colaborador", "cod_agencia"),
        ),
        TableContract(
            "clientes",
            ("cod_cliente",),
            (
                "cod_cliente",
                "primeiro_nome",
                "ultimo_nome",
                "email",
                "tipo_cliente",
                "data_inclusao",
                "cpfcnpj",
                "data_nascimento",
                "endereco",
                "cep",
            ),
        ),
        TableContract(
            "contas",
            ("num_conta",),
            (
                "num_conta",
                "cod_cliente",
                "cod_agencia",
                "cod_colaborador",
                "tipo_conta",
                "data_abertura",
                "saldo_total",
                "saldo_disponivel",
                "data_ultimo_lancamento",
            ),
        ),
        TableContract(
            "propostas_credito",
            ("cod_proposta",),
            (
                "cod_proposta",
                "cod_cliente",
                "cod_colaborador",
                "data_entrada_proposta",
                "taxa_juros_mensal",
                "valor_proposta",
                "valor_financiamento",
                "valor_entrada",
                "valor_prestacao",
                "quantidade_parcelas",
                "carencia",
                "status_proposta",
            ),
        ),
        TableContract(
            "transacoes",
            ("cod_transacao",),
            ("cod_transacao", "num_conta", "data_transacao", "nome_transacao", "valor_transacao"),
        ),
    )
}

TABLES: tuple[str, ...] = tuple(CONTRACTS)

# Tabelas geradas pelo dbt, auditadas ao final da DAG.
SILVER_TABLES: tuple[str, ...] = TABLES
GOLD_TABLES: tuple[str, ...] = (
    "dim_agencia",
    "dim_colaborador",
    "dim_cliente",
    "fct_transacoes",
    "fct_propostas_credito",
    "mart_cliente_mensal",
)

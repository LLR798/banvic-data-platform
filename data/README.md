# Dados de origem

`banvic_data.zip` contém as 7 cópias de tabelas do ERP do BanVic fornecidas no desafio
(dados fictícios). Ele simula o arquivo que o sistema legado deposita diariamente na landing zone:

```bash
make seed                              # envia para s3://banvic-lake/landing/ingestion_date=<hoje UTC>/
make seed INGESTION_DATE=2026-10-13    # ou para uma data específica
```

| Arquivo | Linhas | Chave primária |
|---|---:|---|
| agencias.csv | 10 | cod_agencia |
| colaboradores.csv | 100 | cod_colaborador |
| colaborador_agencia.csv | 100 | (cod_colaborador, cod_agencia) |
| clientes.csv | 998 | cod_cliente |
| contas.csv | 999 | num_conta |
| propostas_credito.csv | 2.000 | cod_proposta |
| transacoes.csv | 71.999 | cod_transacao |

Achados de perfilamento (tratados no pipeline):

- `cod_cliente = 528` aparece em 1 conta e 4 propostas, mas não existe em `clientes` (FK órfã).
- Timestamps no formato `AAAA-MM-DD HH:MM:SS[.ffffff] UTC`, com 0 a 6 casas decimais.
- Valores monetários com ruído de ponto flutuante (ex.: `2984.7614999999996`).
- CEP em dois formatos (`99999-999` e `99999999`); CPF com pontuação.

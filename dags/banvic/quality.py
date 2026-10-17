"""Checagens de qualidade e auditoria no DW (executadas pelo Airflow).

Usa a role svc_orchestrator (lê todas as camadas, escreve só em `ops`).
Os nomes de tabela vêm de listas fixas (contracts.py), nunca de input externo.
"""

from __future__ import annotations

from dataclasses import dataclass

from banvic.contracts import GOLD_TABLES, SILVER_TABLES, TABLES

_ALLOWED = {
    "bronze": set(TABLES),
    "silver": set(SILVER_TABLES),
    "gold": set(GOLD_TABLES),
}

AUDIT_UPSERT_SQL = """
INSERT INTO ops.pipeline_audit
    (run_id, ingestion_date, layer, table_name, row_count, expected_count, status, recorded_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (run_id, layer, table_name) DO UPDATE SET
    row_count      = EXCLUDED.row_count,
    expected_count = EXCLUDED.expected_count,
    status         = EXCLUDED.status,
    recorded_at    = now()
"""


@dataclass(frozen=True)
class AuditRow:
    layer: str
    table_name: str
    row_count: int
    expected_count: int | None
    status: str

    def as_params(self, run_id: str, ingestion_date: str) -> tuple:
        return (
            run_id,
            ingestion_date,
            self.layer,
            self.table_name,
            self.row_count,
            self.expected_count,
            self.status,
        )


def qualified(layer: str, table: str) -> str:
    """Retorna schema.tabela somente se estiver na allowlist (evita SQL injection)."""
    if table not in _ALLOWED.get(layer, set()):
        raise ValueError(f"Tabela não permitida: {layer}.{table}")
    return f"{layer}.{table}"


def count_sql(layer: str, table: str) -> str:
    return f"SELECT count(*) FROM {qualified(layer, table)}"  # noqa: S608 - allowlist


def bronze_partition_count_sql(table: str) -> str:
    """Linhas da Bronze cuja última carga veio da partição do dia."""
    return (
        f"SELECT count(*) FROM {qualified('bronze', table)} "  # noqa: S608 - allowlist
        "WHERE _sdc_source_file LIKE %s"
    )


def compare(layer: str, table: str, actual: int, expected: int | None) -> AuditRow:
    status = "ok" if expected is None or actual == expected else "fail"
    return AuditRow(layer, table, actual, expected, status)

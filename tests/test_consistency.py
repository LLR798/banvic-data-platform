"""Garante que contrato (Airflow), Meltano, runner e dbt descrevem as MESMAS tabelas."""

from __future__ import annotations

import importlib.util
import re

import yaml

from banvic.contracts import CONTRACTS, GOLD_TABLES, TABLES
from banvic.quality import count_sql, qualified
from conftest import ROOT

MELTANO_YML = ROOT / "ingestion" / "meltano" / "meltano.yml"
DBT_DIR = ROOT / "transform" / "dbt"


def _load_runner():
    spec = importlib.util.spec_from_file_location("runner", ROOT / "docker" / "pipeline" / "runner.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _meltano_files() -> list[dict]:
    project = yaml.safe_load(MELTANO_YML.read_text())
    tap = next(p for p in project["plugins"]["extractors"] if p["name"] == "tap-csv")
    return tap["config"]["files"]


def test_meltano_declares_every_table_with_contract_pk():
    files = {f["entity"]: f for f in _meltano_files()}
    assert set(files) == set(TABLES)
    for table, contract in CONTRACTS.items():
        assert tuple(files[table]["keys"]) == contract.primary_key
        assert files[table]["path"].endswith(f"/{table}.csv")


def test_meltano_has_no_inline_credentials():
    text = MELTANO_YML.read_text().lower()
    assert "password:" not in text
    assert not re.search(r"user:\s*\S", text)


def test_runner_tables_match_contract():
    runner = _load_runner()
    assert tuple(runner.TABLES) == TABLES
    assert runner.bronze_key("contas", "2026-10-13") == "bronze/contas/ingestion_date=2026-10-13/contas.csv"


def test_dbt_has_silver_model_for_each_table_and_gold_models():
    silver = {p.stem for p in (DBT_DIR / "models" / "silver").glob("*.sql")}
    gold = {p.stem for p in (DBT_DIR / "models" / "gold").glob("*.sql")}
    assert silver == set(TABLES)
    assert gold == set(GOLD_TABLES)


def test_dbt_profile_reads_credentials_from_env():
    profile = (DBT_DIR / "profiles.yml").read_text()
    assert "env_var('DBT_PASSWORD')" in profile
    assert "env_var('DBT_USER')" in profile


def test_quality_sql_uses_allowlist():
    assert count_sql("gold", "dim_cliente") == "SELECT count(*) FROM gold.dim_cliente"
    assert qualified("bronze", "transacoes") == "bronze.transacoes"
    try:
        qualified("bronze", "transacoes; DROP TABLE x")
    except ValueError:
        pass
    else:  # pragma: no cover
        raise AssertionError("allowlist não bloqueou nome inválido")

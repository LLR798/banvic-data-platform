"""Validação do arquivo da landing zone (contrato, contagem e proteções)."""

from __future__ import annotations

import io
import zipfile
from pathlib import Path

import pytest

from banvic.contracts import CONTRACTS, TABLES
from banvic.landing import LandingValidationError, extract_and_validate
from conftest import ROOT

ZIP_PATH = ROOT / "data" / "banvic_data.zip"

EXPECTED_ROWS = {
    "agencias": 10,
    "colaboradores": 100,
    "colaborador_agencia": 100,
    "clientes": 998,
    "contas": 999,
    "propostas_credito": 2000,
    "transacoes": 71999,
}


def _members() -> dict[str, bytes]:
    with zipfile.ZipFile(ZIP_PATH) as zf:
        return {Path(i.filename).name: zf.read(i) for i in zf.infolist() if not i.is_dir()}


def _make_zip(tmp_path: Path, members: dict[str, bytes]) -> Path:
    path = tmp_path / "banvic_data.zip"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        for name, content in members.items():
            zf.writestr(name, content)
    path.write_bytes(buffer.getvalue())
    return path


def test_real_file_matches_contract(tmp_path):
    result = extract_and_validate(ZIP_PATH, tmp_path / "out")
    assert list(result) == list(TABLES)
    assert {t: r.row_count for t, r in result.items()} == EXPECTED_ROWS
    for info in result.values():
        assert info.path.exists()
        assert len(info.sha256) == 64


def test_missing_table_fails(tmp_path):
    members = _members()
    members.pop("transacoes.csv")
    with pytest.raises(LandingValidationError, match="ausentes"):
        extract_and_validate(_make_zip(tmp_path, members), tmp_path / "out")


def test_changed_header_fails(tmp_path):
    members = _members()
    members["agencias.csv"] = b"cod_agencia,nome_agencia\n1,Matriz\n"
    with pytest.raises(LandingValidationError, match="Contrato violado em agencias"):
        extract_and_validate(_make_zip(tmp_path, members), tmp_path / "out")


def test_empty_table_fails(tmp_path):
    members = _members()
    header = ",".join(CONTRACTS["agencias"].columns).encode() + b"\n"
    members["agencias.csv"] = header
    with pytest.raises(LandingValidationError, match="não possui linhas"):
        extract_and_validate(_make_zip(tmp_path, members), tmp_path / "out")


def test_zip_slip_paths_are_neutralized(tmp_path):
    members = {f"../../../tmp/evil/{name}": content for name, content in _members().items()}
    out = tmp_path / "out"
    result = extract_and_validate(_make_zip(tmp_path, members), out)
    assert all(info.path.parent == out for info in result.values())


def test_not_a_zip_fails(tmp_path):
    fake = tmp_path / "banvic_data.zip"
    fake.write_text("isto não é um zip")
    with pytest.raises(LandingValidationError, match="não é um arquivo zip"):
        extract_and_validate(fake, tmp_path / "out")

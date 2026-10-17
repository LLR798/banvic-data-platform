"""Validação e extração do arquivo da landing zone (banvic_data.zip).

Funções puras (sem Airflow) para serem testadas com pytest.
Proteções: zip-slip (nomes de arquivo são ignorados, só o basename é usado),
zip-bomb (limite de tamanho por membro), contrato de colunas e contagem de linhas.
"""

from __future__ import annotations

import csv
import hashlib
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from banvic.contracts import CONTRACTS

MAX_MEMBER_BYTES = 500 * 1024 * 1024  # 500 MB por CSV


class LandingValidationError(ValueError):
    """O arquivo recebido não respeita o contrato. Não adianta fazer retry."""


@dataclass(frozen=True)
class ExtractedTable:
    table: str
    path: Path
    row_count: int
    sha256: str
    size_bytes: int


def _count_rows_and_header(path: Path) -> tuple[list[str], int]:
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        header = next(reader, [])
        rows = sum(1 for row in reader if row)
    return [h.strip() for h in header], rows


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_and_validate(zip_path: Path, output_dir: Path) -> dict[str, ExtractedTable]:
    """Extrai os 7 CSVs esperados e valida contrato, retornando metadados por tabela."""
    output_dir.mkdir(parents=True, exist_ok=True)
    if not zipfile.is_zipfile(zip_path):
        raise LandingValidationError(f"{zip_path.name} não é um arquivo zip válido")

    found: dict[str, zipfile.ZipInfo] = {}
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = PurePosixPath(info.filename).name  # descarta diretórios (anti zip-slip)
            if name.startswith(".") or not name.lower().endswith(".csv"):
                continue
            table = name[:-4].lower()
            if table not in CONTRACTS:
                continue
            if table in found:
                raise LandingValidationError(f"Tabela duplicada no zip: {table}")
            if info.file_size > MAX_MEMBER_BYTES:
                raise LandingValidationError(f"{name} excede o limite de {MAX_MEMBER_BYTES} bytes")
            found[table] = info

        missing = sorted(set(CONTRACTS) - set(found))
        if missing:
            raise LandingValidationError(f"Arquivos ausentes no zip: {missing}")

        results: dict[str, ExtractedTable] = {}
        for table, info in found.items():
            target = output_dir / f"{table}.csv"
            with zf.open(info) as src, target.open("wb") as dst:
                dst.write(src.read())

            header, rows = _count_rows_and_header(target)
            expected = list(CONTRACTS[table].columns)
            if header != expected:
                raise LandingValidationError(f"Contrato violado em {table}: esperado {expected}, recebido {header}")
            if rows == 0:
                raise LandingValidationError(f"{table}.csv não possui linhas")

            results[table] = ExtractedTable(
                table=table,
                path=target,
                row_count=rows,
                sha256=_sha256(target),
                size_bytes=target.stat().st_size,
            )
    # Ordem do contrato (dimensões antes de fatos)
    return {t: results[t] for t in CONTRACTS}

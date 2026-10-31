"""Publicação atômica da partição Bronze no lake (padrão write-audit-publish).

Object storage (S3/MinIO) não tem "rename" atômico de vários arquivos: mover N objetos
é copiar e apagar um por um. A atomicidade vem de outro lugar: gravar UM objeto
(PUT) é atômico. Por isso:

1. **write**   os CSVs vão para uma área exclusiva da execução
               (``bronze/<tabela>/ingestion_date=D/run=<token>/``), que ninguém lê;
2. **audit**   cada objeto gravado é conferido (existe e tem o tamanho esperado);
3. **publish** o manifesto do dia é gravado por último, num único PUT. Ele é o
               ponteiro para a versão vigente: os leitores (runner Meltano) só
               leem os arquivos que o manifesto lista.

Se a execução falhar em qualquer ponto antes do passo 3, o manifesto anterior
continua valendo e os arquivos parciais ficam isolados na pasta daquela execução,
sem nunca serem lidos. Funções puras: o acesso ao storage é injetado (testável).
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from banvic import config
from banvic.landing import ExtractedTable

MANIFEST_SCHEMA_VERSION = 2


class PublishError(RuntimeError):
    """A partição não pôde ser publicada; o manifesto vigente não foi alterado."""


class ObjectStore(Protocol):
    def upload_file(self, path: Path, key: str) -> None: ...

    def object_size(self, key: str) -> int | None: ...

    def put_text(self, key: str, text: str) -> None: ...


def build_manifest(
    ingestion_date: str,
    run_id: str,
    source_key: str,
    files: Mapping[str, str],
    extracted: Mapping[str, ExtractedTable],
) -> dict:
    return {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "ingestion_date": ingestion_date,
        "run_id": run_id,
        "run_token": config.run_token(run_id),
        "source_key": source_key,
        "files": dict(files),
        "row_counts": {t: e.row_count for t, e in extracted.items()},
        "sha256": {t: e.sha256 for t, e in extracted.items()},
        "size_bytes": {t: e.size_bytes for t, e in extracted.items()},
        "committed_at": datetime.now(UTC).isoformat(),
    }


def publish_partition(
    store: ObjectStore,
    ingestion_date: str,
    run_id: str,
    source_key: str,
    extracted: Mapping[str, ExtractedTable],
) -> dict:
    """Grava, confere e só então publica a partição. Retorna o manifesto publicado."""
    token = config.run_token(run_id)

    # 1. write: área exclusiva da execução (invisível para os leitores)
    files: dict[str, str] = {}
    for table, info in extracted.items():
        key = config.bronze_key(table, ingestion_date, token)
        store.upload_file(info.path, key)
        files[table] = key

    # 2. audit: tudo que vai ser publicado precisa estar lá, inteiro
    for table, key in files.items():
        size = store.object_size(key)
        if size != extracted[table].size_bytes:
            raise PublishError(
                f"{key}: tamanho {size} difere do esperado {extracted[table].size_bytes}; partição não publicada"
            )

    # 3. publish: um único PUT troca a versão vigente da partição (atomic swap)
    manifest = build_manifest(ingestion_date, run_id, source_key, files, extracted)
    store.put_text(config.manifest_key(ingestion_date), json.dumps(manifest, indent=2))
    return manifest

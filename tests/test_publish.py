"""Publicação atômica da Bronze: o manifesto só aparece quando tudo foi gravado e conferido."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

from banvic import config
from banvic.contracts import TABLES
from banvic.landing import ExtractedTable
from banvic.publish import PublishError, publish_partition
from conftest import ROOT

DAY = "2026-10-13"
RUN_ID = "manual__2026-10-13T10:00:00+00:00"
MANIFEST = config.manifest_key(DAY)


class FakeStore:
    """Object store em memória, com falha programável no N-ésimo upload."""

    def __init__(self, fail_on_upload: int | None = None, truncate: str | None = None):
        self.objects: dict[str, bytes] = {}
        self.fail_on_upload = fail_on_upload
        self.truncate = truncate
        self.uploads = 0

    def upload_file(self, path: Path, key: str) -> None:
        self.uploads += 1
        if self.uploads == self.fail_on_upload:
            raise ConnectionError("rede caiu no meio da publicação")
        data = path.read_bytes()
        self.objects[key] = data[:-1] if self.truncate and key.endswith(f"/{self.truncate}.csv") else data

    def object_size(self, key: str) -> int | None:
        return len(self.objects[key]) if key in self.objects else None

    def put_text(self, key: str, text: str) -> None:
        self.objects[key] = text.encode()


@pytest.fixture
def extracted(tmp_path) -> dict[str, ExtractedTable]:
    result = {}
    for table in TABLES:
        path = tmp_path / f"{table}.csv"
        path.write_text(f"id\n1\n2\n# {table}\n")
        result[table] = ExtractedTable(table, path, 2, f"sha-{table}", path.stat().st_size)
    return result


def _publish(store, extracted):
    return publish_partition(store, DAY, RUN_ID, config.landing_key(DAY), extracted)


def test_successful_publish_writes_manifest_last_pointing_to_run_area(extracted):
    store = FakeStore()
    manifest = _publish(store, extracted)

    assert list(store.objects)[-1] == MANIFEST, "o manifesto precisa ser o ÚLTIMO objeto gravado"
    committed = json.loads(store.objects[MANIFEST])
    assert committed == manifest
    assert set(committed["files"]) == set(TABLES)
    token = config.run_token(RUN_ID)
    for table, key in committed["files"].items():
        assert key == f"bronze/{table}/ingestion_date={DAY}/run={token}/{table}.csv"
        assert key in store.objects


def test_failure_mid_publish_never_exposes_partial_partition(extracted):
    store = FakeStore(fail_on_upload=4)
    with pytest.raises(ConnectionError):
        _publish(store, extracted)
    assert MANIFEST not in store.objects, "falha no meio não pode publicar manifesto"


def test_failure_keeps_previous_version_as_current(extracted):
    store = FakeStore()
    previous = _publish(store, extracted)

    store.fail_on_upload, store.uploads = 2, 0
    with pytest.raises(ConnectionError):
        publish_partition(store, DAY, "manual__retry", config.landing_key(DAY), extracted)

    assert json.loads(store.objects[MANIFEST])["run_token"] == previous["run_token"]


def test_audit_rejects_truncated_object(extracted):
    store = FakeStore(truncate="transacoes")
    with pytest.raises(PublishError, match="transacoes"):
        _publish(store, extracted)
    assert MANIFEST not in store.objects


def test_run_token_is_path_safe():
    token = config.run_token("scheduled__2026-10-18T00:00:00+00:00")
    assert token == "scheduled-2026-10-18T00-00-00-00-00"
    assert "_" not in token, "underscore é curinga no LIKE da checagem de qualidade"


def _load_runner():
    spec = importlib.util.spec_from_file_location("runner", ROOT / "docker" / "pipeline" / "runner.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_runner_reads_only_committed_files(extracted):
    runner = _load_runner()
    manifest = _publish(FakeStore(), extracted)
    assert runner.manifest_key(DAY) == MANIFEST
    assert runner.committed_files(manifest) == manifest["files"]

    incomplete = {**manifest, "files": {k: v for k, v in manifest["files"].items() if k != "contas"}}
    with pytest.raises(SystemExit, match="contas"):
        runner.committed_files(incomplete)

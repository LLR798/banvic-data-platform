"""Configuração comum dos testes: Airflow isolado e pasta de DAGs no sys.path."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DAGS_DIR = ROOT / "dags"

# Airflow "descartável" para os testes (não toca no ~/airflow do desenvolvedor).
os.environ.setdefault("AIRFLOW_HOME", tempfile.mkdtemp(prefix="airflow-test-"))
os.environ.setdefault("AIRFLOW__CORE__LOAD_EXAMPLES", "False")
os.environ.setdefault("AIRFLOW__CORE__DAGS_FOLDER", str(DAGS_DIR))

# Mesmo efeito do PYTHONPATH=/opt/airflow/dags da imagem.
sys.path.insert(0, str(DAGS_DIR))

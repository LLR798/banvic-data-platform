# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Imagem "banvic/pipeline": Meltano (Bronze) + dbt (Silver/Gold) + runner.
# Executada como pod efêmero pelo KubernetesPodOperator do Airflow.
#
# Build (na raiz do repositório):
#   docker build -f docker/pipeline/Dockerfile -t banvic/pipeline:0.2.0 .
# -----------------------------------------------------------------------------
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MELTANO_SEND_ANONYMOUS_USAGE_STATS=false \
    DBT_SEND_ANONYMOUS_USAGE_STATS=false \
    WORK_DIR=/app/work

# git: necessário para instalar o tap-csv (pip_url git+https).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 app \
 && useradd --create-home --uid 10001 --gid 10001 --shell /usr/sbin/nologin app

# Três ambientes isolados: runner (sistema), Meltano e dbt.
COPY docker/pipeline/requirements-*.txt /tmp/requirements/
RUN pip install -r /tmp/requirements/requirements-runner.txt \
 && python -m venv /opt/venvs/meltano \
 && /opt/venvs/meltano/bin/pip install -r /tmp/requirements/requirements-meltano.txt \
 && python -m venv /opt/venvs/dbt \
 && /opt/venvs/dbt/bin/pip install -r /tmp/requirements/requirements-dbt.txt

WORKDIR /app
RUN mkdir -p /app/ingestion/meltano /app/transform \
 && chown -R app:app /app
# UID numérico: permite ao Kubernetes validar runAsNonRoot.
USER 10001:10001

# Plugins do Meltano instalados no build -> nenhum download em tempo de execução.
COPY --chown=app:app ingestion/meltano/meltano.yml /app/ingestion/meltano/meltano.yml
RUN cd /app/ingestion/meltano && /opt/venvs/meltano/bin/meltano install

# Projeto dbt validado no build (dbt parse não conecta no banco).
COPY --chown=app:app transform/dbt /app/transform/dbt
RUN cd /app/transform/dbt \
 && DW_HOST=build DW_DATABASE=build DBT_USER=build DBT_PASSWORD=build \
    /opt/venvs/dbt/bin/dbt parse --profiles-dir . --project-dir . \
 && rm -rf logs

COPY --chown=app:app docker/pipeline/runner.py /app/runner.py

ENTRYPOINT ["python", "/app/runner.py"]
CMD ["--help"]

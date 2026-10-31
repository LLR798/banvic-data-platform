# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Imagem "banvic/airflow": Airflow oficial + providers fixados + DAGs embutidas.
#
# Build (na raiz do repositório):
#   docker build -f docker/airflow/Dockerfile -t banvic/airflow:0.2.0 .
# -----------------------------------------------------------------------------
ARG AIRFLOW_VERSION=3.2.2
ARG PYTHON_VERSION=3.12
FROM apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION}

ARG AIRFLOW_VERSION
ARG PYTHON_VERSION

COPY docker/airflow/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir \
      "apache-airflow==${AIRFLOW_VERSION}" \
      -r /tmp/requirements.txt \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

# DAGs versionadas junto com a imagem (deploy imutável, igual no CI e no laptop).
COPY --chown=airflow:root dags/ /opt/airflow/dags/

# Permite `from banvic import ...` dentro das DAGs e das tasks.
ENV PYTHONPATH=/opt/airflow/dags

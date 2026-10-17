# -----------------------------------------------------------------------------
# Segredos
#
# Todas as senhas são GERADAS pelo Terraform (random_*) e entregues aos pods
# exclusivamente via Kubernetes Secrets. Nenhuma credencial existe no Git.
# O estado (terraform.tfstate) contém esses valores: fica local e no .gitignore
# (em produção: backend remoto criptografado, ex. S3 + KMS, e um gerenciador
# de segredos como AWS Secrets Manager/Vault via External Secrets Operator).
# -----------------------------------------------------------------------------
locals {
  passwords = toset([
    "dw_admin",
    "svc_ingestion",
    "svc_transform",
    "svc_orchestrator",
    "analyst",
    "airflow_metadata",
    "airflow_admin",
    "minio_root",
    "minio_pipeline",
  ])

  dw_host      = "postgres-dw.${kubernetes_namespace_v1.data.metadata[0].name}.svc.cluster.local"
  minio_access = "svc-pipeline"
}

resource "random_password" "this" {
  for_each = local.passwords

  length  = 32
  special = false # evita problemas de escaping em URIs de conexão
}

resource "random_password" "airflow_api_secret" {
  length  = 48
  special = false
}

resource "random_password" "airflow_jwt_secret" {
  length  = 48
  special = false
}

# Fernet key do Airflow: 32 bytes em base64 url-safe.
resource "random_bytes" "airflow_fernet" {
  length = 32
}

# ------------------------------------------------------------- namespace data
resource "kubernetes_secret_v1" "postgres_dw" {
  metadata {
    name      = "postgres-dw-credentials"
    namespace = kubernetes_namespace_v1.data.metadata[0].name
  }

  data = {
    POSTGRES_PASSWORD         = random_password.this["dw_admin"].result
    SVC_INGESTION_PASSWORD    = random_password.this["svc_ingestion"].result
    SVC_TRANSFORM_PASSWORD    = random_password.this["svc_transform"].result
    SVC_ORCHESTRATOR_PASSWORD = random_password.this["svc_orchestrator"].result
    ANALYST_PASSWORD          = random_password.this["analyst"].result
  }
}

resource "kubernetes_secret_v1" "minio" {
  metadata {
    name      = "minio-credentials"
    namespace = kubernetes_namespace_v1.data.metadata[0].name
  }

  data = {
    MINIO_ROOT_USER     = "lake-admin"
    MINIO_ROOT_PASSWORD = random_password.this["minio_root"].result
    PIPELINE_ACCESS_KEY = local.minio_access
    PIPELINE_SECRET_KEY = random_password.this["minio_pipeline"].result
  }
}

# ---------------------------------------------------------- namespace airflow
resource "kubernetes_secret_v1" "postgres_airflow" {
  metadata {
    name      = "postgres-airflow-credentials"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    POSTGRES_PASSWORD = random_password.this["airflow_metadata"].result
  }
}

resource "kubernetes_secret_v1" "airflow_metadata" {
  metadata {
    name      = "airflow-metadata"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    connection = "postgresql://airflow:${random_password.this["airflow_metadata"].result}@postgres-airflow.airflow.svc.cluster.local:5432/airflow?sslmode=disable"
  }
}

resource "kubernetes_secret_v1" "airflow_fernet" {
  metadata {
    name      = "airflow-fernet-key"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    fernet-key = replace(replace(random_bytes.airflow_fernet.base64, "+", "-"), "/", "_")
  }
}

resource "kubernetes_secret_v1" "airflow_api_secret" {
  metadata {
    name      = "airflow-api-secret-key"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    api-secret-key = random_password.airflow_api_secret.result
  }
}

resource "kubernetes_secret_v1" "airflow_jwt_secret" {
  metadata {
    name      = "airflow-jwt-secret"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    jwt-secret = random_password.airflow_jwt_secret.result
  }
}

# Conexões do Airflow como variáveis AIRFLOW_CONN_* (nunca no banco/UI/código).
resource "kubernetes_secret_v1" "airflow_connections" {
  metadata {
    name      = "airflow-connections"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    AIRFLOW_CONN_LAKE_S3 = jsonencode({
      conn_type = "aws"
      login     = local.minio_access
      password  = random_password.this["minio_pipeline"].result
      extra = {
        endpoint_url = module.minio.endpoint
        region_name  = "us-east-1"
      }
    })
    AIRFLOW_CONN_DW_POSTGRES = jsonencode({
      conn_type = "postgres"
      host      = local.dw_host
      port      = 5432
      schema    = var.dw_database
      login     = "svc_orchestrator"
      password  = random_password.this["svc_orchestrator"].result
    })
  }
}

# Credenciais dos pods efêmeros: cada job recebe SÓ o que precisa.
resource "kubernetes_secret_v1" "lake_credentials" {
  metadata {
    name      = "lake-credentials"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = local.minio_access
    AWS_SECRET_ACCESS_KEY = random_password.this["minio_pipeline"].result
  }
}

resource "kubernetes_secret_v1" "dw_ingestion" {
  metadata {
    name      = "dw-ingestion-credentials"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    TARGET_POSTGRES_USER     = "svc_ingestion"
    TARGET_POSTGRES_PASSWORD = random_password.this["svc_ingestion"].result
  }
}

resource "kubernetes_secret_v1" "dw_transform" {
  metadata {
    name      = "dw-transform-credentials"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    DBT_USER     = "svc_transform"
    DBT_PASSWORD = random_password.this["svc_transform"].result
  }
}

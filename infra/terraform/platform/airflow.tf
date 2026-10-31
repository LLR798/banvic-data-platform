# Configuração não sensível dos pods do pipeline (Meltano/dbt).
resource "kubernetes_config_map_v1" "pipeline_config" {
  metadata {
    name      = "pipeline-config"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  data = {
    DW_HOST            = module.postgres_dw.host
    DW_PORT            = tostring(module.postgres_dw.port)
    DW_DATABASE        = module.postgres_dw.database
    S3_ENDPOINT_URL    = module.minio.endpoint
    LAKE_BUCKET        = module.minio.bucket
    AWS_DEFAULT_REGION = "us-east-1"
    # SDKs AWS recentes calculam checksums extras por padrão; com storages
    # S3-compatíveis é mais seguro usar só quando a operação exige.
    AWS_REQUEST_CHECKSUM_CALCULATION = "when_required"
    AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required"
    MELTANO_ENVIRONMENT              = "prod"
    DBT_TARGET                       = "prod"
  }
}

resource "helm_release" "airflow" {
  name       = "airflow"
  namespace  = kubernetes_namespace_v1.airflow.metadata[0].name
  repository = "https://airflow.apache.org"
  chart      = "airflow"
  version    = var.airflow_chart_version

  values = [
    templatefile("${path.module}/../../helm/airflow-values.yaml.tftpl", {
      airflow_version          = var.airflow_version
      airflow_image_repository = var.airflow_image_repository
      airflow_image_tag        = var.airflow_image_tag
      airflow_admin_username   = var.airflow_admin_username
      airflow_ui_node_port     = var.node_ports.airflow_ui
      pipeline_image           = var.pipeline_image
      jobs_namespace           = kubernetes_namespace_v1.airflow.metadata[0].name
      lake_bucket              = var.lake_bucket
      logs_bucket              = module.minio.logs_bucket
      metadata_secret          = kubernetes_secret_v1.airflow_metadata.metadata[0].name
      fernet_secret            = kubernetes_secret_v1.airflow_fernet.metadata[0].name
      api_secret               = kubernetes_secret_v1.airflow_api_secret.metadata[0].name
      jwt_secret               = kubernetes_secret_v1.airflow_jwt_secret.metadata[0].name
      connections_secret       = kubernetes_secret_v1.airflow_connections.metadata[0].name
    })
  ]

  # Senha do admin da UI: gerada, nunca escrita em arquivo.
  set_sensitive = [
    {
      name  = "createUserJob.defaultUser.password"
      value = random_password.this["airflow_admin"].result
    }
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 900

  depends_on = [
    module.postgres_airflow,
    module.postgres_dw,
    module.minio,
    kubernetes_config_map_v1.pipeline_config,
    kubernetes_secret_v1.lake_credentials,
    kubernetes_secret_v1.dw_ingestion,
    kubernetes_secret_v1.dw_transform,
  ]
}

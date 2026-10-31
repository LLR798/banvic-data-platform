# ------------------------------------------------------------ Data Lake
module "minio" {
  source = "../modules/minio"

  namespace               = kubernetes_namespace_v1.data.metadata[0].name
  credentials_secret_name = kubernetes_secret_v1.minio.metadata[0].name
  bucket                  = var.lake_bucket
  logs_bucket             = var.logs_bucket
  api_node_port           = var.node_ports.minio_api
  console_node_port       = var.node_ports.minio_console
}

# ------------------------------------------------------------ Data Warehouse
module "postgres_dw" {
  source = "../modules/postgres"

  name                    = "postgres-dw"
  namespace               = kubernetes_namespace_v1.data.metadata[0].name
  image                   = var.postgres_image
  database                = var.dw_database
  admin_user              = "dw_admin"
  credentials_secret_name = kubernetes_secret_v1.postgres_dw.metadata[0].name
  storage_size            = "5Gi"
  node_port               = var.node_ports.postgres_dw

  # Schemas do medalhão + roles de menor privilégio (executa só no 1º boot).
  init_scripts = {
    "01-init-dw.sh" = file("${path.module}/../../../sql/bootstrap/init_dw.sh")
  }
}

# ------------------------------------------------------------ Metadados Airflow
module "postgres_airflow" {
  source = "../modules/postgres"

  name                    = "postgres-airflow"
  namespace               = kubernetes_namespace_v1.airflow.metadata[0].name
  image                   = var.postgres_image
  database                = "airflow"
  admin_user              = "airflow"
  credentials_secret_name = kubernetes_secret_v1.postgres_airflow.metadata[0].name
  storage_size            = "2Gi"
}

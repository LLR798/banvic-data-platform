# data    -> camada de armazenamento (MinIO + Postgres DW)
# airflow -> orquestração (Airflow + metadados) e pods efêmeros do pipeline
resource "kubernetes_namespace_v1" "data" {
  metadata {
    name   = "data"
    labels = { "app.kubernetes.io/part-of" = "banvic-data-platform" }
  }
}

resource "kubernetes_namespace_v1" "airflow" {
  metadata {
    name   = "airflow"
    labels = { "app.kubernetes.io/part-of" = "banvic-data-platform" }
  }
}

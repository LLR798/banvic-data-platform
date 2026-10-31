variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

variable "kube_context" {
  description = "Contexto criado pela stack cluster (kind-<cluster_name>)."
  type        = string
  default     = "kind-banvic"
}

# ------------------------------------------------------------------ imagens
variable "airflow_image_repository" {
  description = "Imagem customizada do Airflow (DAGs embutidas), carregada no Kind com `kind load`."
  type        = string
  default     = "banvic/airflow"
}

variable "airflow_image_tag" {
  type    = string
  default = "0.1.0"
}

variable "airflow_version" {
  description = "Versão do Airflow dentro da imagem (o chart usa para decidir componentes)."
  type        = string
  default     = "3.2.2"
}

variable "airflow_chart_version" {
  type    = string
  default = "1.22.0"
}

variable "pipeline_image" {
  description = "Imagem Meltano + dbt executada pelos KubernetesPodOperator."
  type        = string
  default     = "banvic/pipeline:0.1.0"
}

variable "postgres_image" {
  type    = string
  default = "postgres:17-alpine"
}

# ------------------------------------------------------------------ dados
variable "lake_bucket" {
  type    = string
  default = "banvic-lake"
}

variable "logs_bucket" {
  description = "Bucket dos logs de tarefas do Airflow (separado do lake: outro dono, outra retenção)."
  type        = string
  default     = "banvic-airflow-logs"
}

variable "dw_database" {
  type    = string
  default = "banvic_dw"
}

variable "airflow_admin_username" {
  type    = string
  default = "admin"
}

# ------------------------------------------------------------------ portas
variable "node_ports" {
  description = "Precisam bater com o port_mappings da stack cluster."
  type = object({
    airflow_ui    = number
    minio_api     = number
    minio_console = number
    postgres_dw   = number
  })
  default = {
    airflow_ui    = 30080
    minio_api     = 30900
    minio_console = 30901
    postgres_dw   = 30432
  }
}

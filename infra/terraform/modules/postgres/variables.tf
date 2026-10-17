variable "name" {
  description = "Nome do StatefulSet/Service (vira o hostname <name>.<namespace>.svc)."
  type        = string
}

variable "namespace" {
  type = string
}

variable "image" {
  type    = string
  default = "postgres:17-alpine"
}

variable "database" {
  description = "Banco criado na inicialização (POSTGRES_DB)."
  type        = string
}

variable "admin_user" {
  description = "Superusuário criado na inicialização (POSTGRES_USER)."
  type        = string
}

variable "credentials_secret_name" {
  description = "Secret com POSTGRES_PASSWORD (+ variáveis extras consumidas pelos init scripts)."
  type        = string
}

variable "init_scripts" {
  description = "Scripts executados no 1º boot (/docker-entrypoint-initdb.d). nome => conteúdo."
  type        = map(string)
  default     = {}
}

variable "storage_size" {
  type    = string
  default = "2Gi"
}

variable "storage_class" {
  description = "StorageClass do PVC (Kind já traz o local-path 'standard')."
  type        = string
  default     = "standard"
}

variable "node_port" {
  description = "Se definido, cria um Service NodePort para acesso do host (ex.: psql/BI)."
  type        = number
  default     = null
}

variable "resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { memory = "1Gi" }
  }
}

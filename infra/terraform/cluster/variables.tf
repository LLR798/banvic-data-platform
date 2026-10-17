variable "cluster_name" {
  description = "Nome do cluster Kind (o contexto kubectl será kind-<nome>)."
  type        = string
  default     = "banvic"
}

variable "node_image" {
  description = "Imagem do nó Kind (versão do Kubernetes). Fixada por digest para reprodutibilidade."
  type        = string
  # Imagem padrão do Kind v0.31 (mesma versão embarcada no provider tehcyx/kind 0.11).
  default = "kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f"
}

variable "kubeconfig_path" {
  description = "Kubeconfig onde o contexto do cluster será gravado."
  type        = string
  default     = "~/.kube/config"
}

variable "listen_address" {
  description = "Endereço do host para as portas expostas. 127.0.0.1 = acessível só pela sua máquina."
  type        = string
  default     = "127.0.0.1"
}

variable "port_mappings" {
  description = "NodePorts do cluster expostos no host (container_port = NodePort do Service)."
  type = map(object({
    container_port = number
    host_port      = number
  }))
  default = {
    airflow_ui    = { container_port = 30080, host_port = 8080 }
    minio_api     = { container_port = 30900, host_port = 9000 }
    minio_console = { container_port = 30901, host_port = 9001 }
    postgres_dw   = { container_port = 30432, host_port = 15432 }
  }
}

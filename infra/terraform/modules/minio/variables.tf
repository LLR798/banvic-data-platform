variable "namespace" {
  type = string
}

variable "name" {
  type    = string
  default = "minio"
}

variable "image" {
  description = <<-EOT
    Imagem do servidor MinIO. A MinIO removeu minio/minio do Docker Hub (set/2026) e o
    quay.io passou a exigir login; usamos a build mantida da Chainguard (patches de
    segurança, multi-arch, não-root). O plano gratuito só publica a tag "latest",
    por isso fixamos pelo DIGEST: reprodutível e imune a mudanças da tag.
  EOT
  type        = string
  default     = "cgr.dev/chainguard/minio:latest@sha256:c93745c56fccdaf0e5dcb88999a96a65a136428beb045ef5d546255a80d747a7"
}

variable "mc_image" {
  description = <<-EOT
    Cliente mc (Chainguard) para o Job de setup. Variante "-dev" porque o Job executa
    um script shell; as imagens Chainguard padrão são distroless (sem shell).
  EOT
  type        = string
  default     = "cgr.dev/chainguard/minio-client:latest-dev@sha256:8d736271bb105639f2348d04186e748bbed63c5392e4ce86641453c11b53f3c8"
}

variable "run_as_uid" {
  description = "UID não-root das imagens Chainguard."
  type        = number
  default     = 65532
}

variable "credentials_secret_name" {
  description = "Secret com MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, PIPELINE_ACCESS_KEY e PIPELINE_SECRET_KEY."
  type        = string
}

variable "bucket" {
  description = "Bucket do data lake (prefixos landing/, bronze/, ops/)."
  type        = string
}

variable "storage_size" {
  type    = string
  default = "5Gi"
}

variable "storage_class" {
  type    = string
  default = "standard"
}

variable "api_node_port" {
  type    = number
  default = null
}

variable "console_node_port" {
  type    = number
  default = null
}

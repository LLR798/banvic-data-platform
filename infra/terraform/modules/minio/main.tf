# -----------------------------------------------------------------------------
# Módulo: MinIO (Data Lake S3-compatível) + Job de configuração.
#
# O Job cria dois buckets, cada um com um usuário de serviço próprio:
#   - <bucket>       data lake (versionado)        -> usuário do pipeline
#   - <logs_bucket>  logs de tarefas do Airflow    -> usuário só de logs
# Cada política dá acesso a UM bucket. As aplicações NUNCA usam a credencial root.
# -----------------------------------------------------------------------------
locals {
  labels = {
    "app.kubernetes.io/name"       = var.name
    "app.kubernetes.io/component"  = "object-storage"
    "app.kubernetes.io/part-of"    = "banvic-data-platform"
    "app.kubernetes.io/managed-by" = "terraform"
  }
  endpoint = "http://${var.name}.${var.namespace}.svc.cluster.local:9000"
}

resource "kubernetes_stateful_set_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    service_name = var.name
    replicas     = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = var.name }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Imagem Chainguard roda como UID 65532 (não-root).
        security_context {
          run_as_non_root = true
          run_as_user     = var.run_as_uid
          run_as_group    = var.run_as_uid
          fs_group        = var.run_as_uid
        }

        container {
          name  = "minio"
          image = var.image
          args  = ["server", "/data", "--console-address", ":9001"]

          port {
            name           = "api"
            container_port = 9000
          }
          port {
            name           = "console"
            container_port = 9001
          }

          env_from {
            secret_ref {
              name = var.credentials_secret_name
            }
          }

          readiness_probe {
            http_get {
              path = "/minio/health/ready"
              port = "api"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/minio/health/live"
              port = "api"
            }
            initial_delay_seconds = 20
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "1Gi" }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name   = "data"
        labels = local.labels
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class
        resources {
          requests = { storage = var.storage_size }
        }
      }
    }
  }

  wait_for_rollout = true

  timeouts {
    create = "10m"
    update = "10m"
  }
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = { "app.kubernetes.io/name" = var.name }
    port {
      name        = "api"
      port        = 9000
      target_port = "api"
    }
    port {
      name        = "console"
      port        = 9001
      target_port = "console"
    }
  }
}

resource "kubernetes_service_v1" "external" {
  count = var.api_node_port == null ? 0 : 1

  metadata {
    name      = "${var.name}-external"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type     = "NodePort"
    selector = { "app.kubernetes.io/name" = var.name }
    port {
      name        = "api"
      port        = 9000
      target_port = "api"
      node_port   = var.api_node_port
    }
    port {
      name        = "console"
      port        = 9001
      target_port = "console"
      node_port   = var.console_node_port
    }
  }
}

# ---------------------------------------------------------------- setup job
resource "kubernetes_config_map_v1" "setup" {
  metadata {
    name      = "${var.name}-setup"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "pipeline-policy.json" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketVersions"]
          Resource = ["arn:aws:s3:::${var.bucket}"]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = ["arn:aws:s3:::${var.bucket}/*"]
        },
      ]
    })

    # Logs: lê e grava, mas não apaga (trilha de auditoria). Sem acesso ao lake.
    "logs-policy.json" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = ["arn:aws:s3:::${var.logs_bucket}"]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = ["arn:aws:s3:::${var.logs_bucket}/*"]
        },
      ]
    })

    # Retenção dos logs: expiram após N dias (import substitui a regra: idempotente).
    "logs-lifecycle.json" = jsonencode({
      Rules = [{
        ID         = "expira-logs-airflow"
        Status     = "Enabled"
        Filter     = { Prefix = "" }
        Expiration = { Days = var.logs_retention_days }
      }]
    })

    "setup.sh" = <<-EOT
      #!/bin/sh
      # Idempotente: pode rodar quantas vezes for preciso.
      set -eu
      until mc alias set lake "${local.endpoint}" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
        echo "Aguardando MinIO..."; sleep 3
      done
      mc mb --ignore-existing "lake/${var.bucket}"
      mc version enable "lake/${var.bucket}"
      mc anonymous set none "lake/${var.bucket}"
      mc admin policy create lake banvic-pipeline /setup/pipeline-policy.json
      mc admin user add lake "$PIPELINE_ACCESS_KEY" "$PIPELINE_SECRET_KEY"
      mc admin policy attach lake banvic-pipeline --user "$PIPELINE_ACCESS_KEY" 2>&1 \
        | grep -v -i "already" || true
      echo "Bucket ${var.bucket} pronto (versionado, privado) e usuário de serviço configurado."

      # Logs persistentes do Airflow (remote logging).
      mc mb --ignore-existing "lake/${var.logs_bucket}"
      mc anonymous set none "lake/${var.logs_bucket}"
      mc ilm import "lake/${var.logs_bucket}" < /setup/logs-lifecycle.json
      mc admin policy create lake banvic-airflow-logs /setup/logs-policy.json
      mc admin user add lake "$LOGS_ACCESS_KEY" "$LOGS_SECRET_KEY"
      mc admin policy attach lake banvic-airflow-logs --user "$LOGS_ACCESS_KEY" 2>&1 \
        | grep -v -i "already" || true
      echo "Bucket ${var.logs_bucket} pronto (privado, retenção de ${var.logs_retention_days} dias)."
    EOT
  }
}

resource "kubernetes_job_v1" "setup" {
  metadata {
    name      = "${var.name}-setup"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = local.labels
        annotations = {
          "checksum/setup" = sha256(jsonencode(kubernetes_config_map_v1.setup.data))
        }
      }

      spec {
        restart_policy = "OnFailure"

        security_context {
          run_as_non_root = true
          run_as_user     = var.run_as_uid
          run_as_group    = var.run_as_uid
        }

        container {
          name    = "mc"
          image   = var.mc_image
          command = ["/bin/sh", "/setup/setup.sh"]

          env {
            name  = "MC_CONFIG_DIR"
            value = "/tmp/.mc"
          }

          env_from {
            secret_ref {
              name = var.credentials_secret_name
            }
          }

          volume_mount {
            name       = "setup"
            mount_path = "/setup"
            read_only  = true
          }
        }

        volume {
          name = "setup"
          config_map {
            name = kubernetes_config_map_v1.setup.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_stateful_set_v1.this]
}

# -----------------------------------------------------------------------------
# Módulo reutilizável: PostgreSQL single-instance em StatefulSet + PVC.
# Usado 2x: DW (namespace data) e metadados do Airflow (namespace airflow).
# -----------------------------------------------------------------------------
locals {
  labels = {
    "app.kubernetes.io/name"       = var.name
    "app.kubernetes.io/component"  = "database"
    "app.kubernetes.io/part-of"    = "banvic-data-platform"
    "app.kubernetes.io/managed-by" = "terraform"
  }
  has_init_scripts = length(var.init_scripts) > 0
}

resource "kubernetes_config_map_v1" "init" {
  count = local.has_init_scripts ? 1 : 0

  metadata {
    name      = "${var.name}-init"
    namespace = var.namespace
    labels    = local.labels
  }

  data = var.init_scripts
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
        annotations = {
          # Muda o hash -> recria o pod se os scripts mudarem (só têm efeito em volume vazio).
          "checksum/init" = sha256(jsonencode(var.init_scripts))
        }
      }

      spec {
        container {
          name  = "postgres"
          image = var.image

          port {
            name           = "postgres"
            container_port = 5432
          }

          env {
            name  = "POSTGRES_USER"
            value = var.admin_user
          }
          env {
            name  = "POSTGRES_DB"
            value = var.database
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          # Senhas: somente via Secret (POSTGRES_PASSWORD e as das roles de serviço).
          env_from {
            secret_ref {
              name = var.credentials_secret_name
            }
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -h 127.0.0.1"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -h 127.0.0.1"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 6
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }

          dynamic "volume_mount" {
            for_each = local.has_init_scripts ? [1] : []
            content {
              name       = "init"
              mount_path = "/docker-entrypoint-initdb.d"
              read_only  = true
            }
          }
        }

        dynamic "volume" {
          for_each = local.has_init_scripts ? [1] : []
          content {
            name = "init"
            config_map {
              name = kubernetes_config_map_v1.init[0].metadata[0].name
              # Executável: o entrypoint roda o script em processo separado
              # (em vez de fazer "source"), isolando o set -euo pipefail.
              default_mode = "0755"
            }
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
      name        = "postgres"
      port        = 5432
      target_port = "postgres"
    }
  }
}

resource "kubernetes_service_v1" "external" {
  count = var.node_port == null ? 0 : 1

  metadata {
    name      = "${var.name}-external"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type     = "NodePort"
    selector = { "app.kubernetes.io/name" = var.name }
    port {
      name        = "postgres"
      port        = 5432
      target_port = "postgres"
      node_port   = var.node_port
    }
  }
}

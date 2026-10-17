output "host" {
  description = "DNS interno do serviço."
  value       = "${kubernetes_service_v1.this.metadata[0].name}.${var.namespace}.svc.cluster.local"
}

output "port" {
  value = 5432
}

output "database" {
  value = var.database
}

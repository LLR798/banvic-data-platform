output "cluster_name" {
  value = kind_cluster.this.name
}

output "kube_context" {
  description = "Contexto do kubectl para este cluster."
  value       = "kind-${kind_cluster.this.name}"
}

output "endpoint" {
  value = kind_cluster.this.endpoint
}

output "exposed_ports" {
  description = "Portas do host -> serviços do cluster."
  value       = { for k, v in var.port_mappings : k => "${var.listen_address}:${v.host_port}" }
}

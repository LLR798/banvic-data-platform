# -----------------------------------------------------------------------------
# Stack 1/2 - Cluster Kubernetes local (Kind)
#
# Separado da stack "platform" de propósito: o provider kubernetes/helm precisa
# de um cluster existente no momento do plan. Duas stacks = apply sem -target.
# -----------------------------------------------------------------------------
resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = var.node_image
  kubeconfig_path = pathexpand(var.kubeconfig_path)
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # Nó único (control-plane também agenda workloads): mais leve para um laptop.
    node {
      role = "control-plane"

      dynamic "extra_port_mappings" {
        for_each = var.port_mappings
        content {
          container_port = extra_port_mappings.value.container_port
          host_port      = extra_port_mappings.value.host_port
          listen_address = var.listen_address
          protocol       = "TCP"
        }
      }
    }
  }
}

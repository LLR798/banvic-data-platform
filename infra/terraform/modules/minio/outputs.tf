output "endpoint" {
  description = "Endpoint S3 interno do cluster."
  value       = local.endpoint
}

output "bucket" {
  value = var.bucket
}

output "logs_bucket" {
  value = var.logs_bucket
}

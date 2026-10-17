output "urls" {
  description = "Endereços expostos no host."
  value = {
    airflow_ui    = "http://localhost:8080"
    minio_console = "http://localhost:9001"
    minio_api     = "http://localhost:9000"
    postgres_dw   = "postgresql://localhost:15432/${var.dw_database}"
  }
}

output "airflow_admin_username" {
  value = var.airflow_admin_username
}

output "airflow_admin_password" {
  description = "terraform output -raw airflow_admin_password"
  value       = random_password.this["airflow_admin"].result
  sensitive   = true
}

output "analyst_password" {
  description = "Senha da role somente-leitura da Gold (terraform output -raw analyst_password)."
  value       = random_password.this["analyst"].result
  sensitive   = true
}

output "minio_root_password" {
  description = "Console do MinIO, usuário lake-admin (terraform output -raw minio_root_password)."
  value       = random_password.this["minio_root"].result
  sensitive   = true
}

output "bucket_name" {
  value = google_storage_bucket.terraform_state.name
}

output "backend_configuration" {
  value = <<-EOT
    terraform {
      backend "gcs" {
        bucket = "${google_storage_bucket.terraform_state.name}"
        prefix = "replace-environment/openclaw"
      }
    }
  EOT
}

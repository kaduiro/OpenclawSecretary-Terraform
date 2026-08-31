resource "google_project_iam_audit_config" "sensitive_services" {
  for_each = toset([
    "iamcredentials.googleapis.com",
    "secretmanager.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}

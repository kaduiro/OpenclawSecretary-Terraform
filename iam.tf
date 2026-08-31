data "google_project" "current" {
  project_id = var.project_id
}

resource "google_service_account" "principal" {
  for_each = local.service_accounts

  account_id   = each.value
  display_name = "OpenClaw ${each.key} (${var.environment})"
  description  = "Dedicated ${each.key} identity for OpenClaw; managed by Terraform."
}

resource "google_project_iam_member" "runtime_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/cloudtasks.enqueuer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/aiplatform.user",
    "roles/dlp.user",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.principal["runtime"].email}"
}

resource "google_project_iam_member" "migration_cloudsql_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.principal["migration"].email}"
}

resource "google_project_iam_custom_role" "secret_creator" {
  role_id     = replace("${local.prefix}_secret_creator", "-", "_")
  title       = "OpenClaw refresh secret creator"
  description = "Creates per-user OAuth refresh-token secret resources."
  permissions = ["secretmanager.secrets.create"]
}

resource "google_project_iam_member" "runtime_secret_creator" {
  project = var.project_id
  role    = google_project_iam_custom_role.secret_creator.id
  member  = "serviceAccount:${google_service_account.principal["runtime"].email}"
}

resource "google_project_iam_member" "runtime_refresh_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.principal["runtime"].email}"

  condition {
    title       = "refresh_token_secrets_only"
    description = "Restrict access to dynamically created refresh-token secrets."
    expression  = "resource.name.startsWith('projects/${data.google_project.current.number}/secrets/openclaw-refresh-')"
  }
}

resource "google_project_iam_member" "runtime_refresh_adder" {
  project = var.project_id
  role    = "roles/secretmanager.secretVersionAdder"
  member  = "serviceAccount:${google_service_account.principal["runtime"].email}"

  condition {
    title       = "refresh_token_secrets_only"
    description = "Restrict version creation to dynamically created refresh-token secrets."
    expression  = "resource.name.startsWith('projects/${data.google_project.current.number}/secrets/openclaw-refresh-')"
  }
}

resource "google_kms_crypto_key_iam_member" "runtime_crypto" {
  crypto_key_id = google_kms_crypto_key.data.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.principal["runtime"].email}"
}

resource "google_secret_manager_secret" "oauth_client_secret" {
  secret_id = "${local.prefix}-oauth-client-secret"

  replication {
    auto {}
  }

  labels     = local.labels
  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "runtime_oauth_client_secret" {
  secret_id = google_secret_manager_secret.oauth_client_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.principal["runtime"].email}"
}

resource "google_kms_key_ring" "app" {
  name     = "${local.prefix}-keyring"
  location = var.region

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "data" {
  name            = "application-data"
  key_ring        = google_kms_key_ring.app.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}

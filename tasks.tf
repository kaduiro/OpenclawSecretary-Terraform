resource "google_cloud_tasks_queue" "calendar" {
  name     = "${local.prefix}-calendar-ops"
  location = var.region

  rate_limits {
    max_dispatches_per_second = 1
    max_concurrent_dispatches = 1
  }

  retry_config {
    max_attempts       = 1
    max_retry_duration = "0s"
    min_backoff        = "1s"
    max_backoff        = "1s"
    max_doublings      = 0
  }

  depends_on = [google_project_service.required]
}

resource "google_service_account_iam_member" "runtime_can_use_tasks_identity" {
  service_account_id = google_service_account.principal["tasks"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.principal["runtime"].email}"
}

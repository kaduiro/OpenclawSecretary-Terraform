resource "google_cloud_scheduler_job" "internal" {
  for_each = var.deploy_services ? local.scheduler_jobs : {}

  name             = "${local.prefix}-${each.key}"
  description      = "OpenClaw internal ${each.key} trigger"
  schedule         = each.value.schedule
  time_zone        = var.scheduler_time_zone
  attempt_deadline = "180s"
  region           = var.region

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
    max_doublings        = 0
  }

  http_target {
    uri         = "${google_cloud_run_v2_service.api[0].uri}${each.value.path}"
    http_method = "POST"
    body        = base64encode("{}")

    headers = { "Content-Type" = "application/json" }

    oidc_token {
      service_account_email = google_service_account.principal["scheduler"].email
      audience              = google_cloud_run_v2_service.api[0].uri
    }
  }

  depends_on = [google_cloud_run_v2_service_iam_member.api_invoker]
}

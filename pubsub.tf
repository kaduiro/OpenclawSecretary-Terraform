resource "google_pubsub_topic" "gmail" {
  name   = "${local.prefix}-gmail"
  labels = local.labels

  depends_on = [google_project_service.required]
}

resource "google_pubsub_topic_iam_member" "gmail_api_publisher" {
  topic  = google_pubsub_topic.gmail.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:gmail-api-push@system.gserviceaccount.com"
}

resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.principal["pubsub"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription" "gmail_push" {
  count = var.deploy_services ? 1 : 0

  name  = "${local.prefix}-gmail-push"
  topic = google_pubsub_topic.gmail.id

  ack_deadline_seconds       = 60
  message_retention_duration = "86400s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.api[0].uri}/internal/gmail/notifications"

    oidc_token {
      service_account_email = google_service_account.principal["pubsub"].email
      audience              = google_cloud_run_v2_service.api[0].uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.api_invoker,
    google_service_account_iam_member.pubsub_token_creator,
  ]
}

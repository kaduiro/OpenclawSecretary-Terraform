resource "google_logging_metric" "internal_auth_failure" {
  name        = "${local.prefix}-internal-auth-failure"
  description = "401/403 responses on Back internal endpoints."
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${local.api_service_name}"
    (httpRequest.status=401 OR httpRequest.status=403)
    httpRequest.requestUrl=~"/internal/"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "internal_auth_failure" {
  count = var.deploy_services ? 1 : 0

  display_name = "${local.prefix}: internal caller authentication failure"
  combiner     = "OR"

  conditions {
    display_name = "Internal endpoint returned 401/403"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.internal_auth_failure.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
  enabled               = true
}

resource "google_monitoring_alert_policy" "api_5xx" {
  count = var.deploy_services ? 1 : 0

  display_name = "${local.prefix}: API 5xx responses"
  combiner     = "OR"

  conditions {
    display_name = "API 5xx count exceeds zero"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"cloud_run_revision\"",
        "resource.label.service_name=\"${local.api_service_name}\"",
        "metric.type=\"run.googleapis.com/request_count\"",
        "metric.label.response_code_class=\"5xx\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
  enabled               = true
}

resource "google_logging_metric" "auth_bootstrap_denied" {
  name        = "${local.prefix}-auth-bootstrap-denied"
  description = "Rejected or rate-limited requests at the narrowly public auth-bootstrap boundary."
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${local.bootstrap_service_name}"
    (httpRequest.status=403 OR httpRequest.status=429)
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "auth_bootstrap_abuse" {
  count = var.deploy_services ? 1 : 0

  display_name = "${local.prefix}: auth-bootstrap rejected requests"
  combiner     = "OR"

  conditions {
    display_name = "Auth bootstrap 403/429 count exceeds five per minute"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.auth_bootstrap_denied.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
  enabled               = true
}

resource "google_monitoring_alert_policy" "cloud_sql_cpu" {
  display_name = "${local.prefix}: Cloud SQL sustained CPU"
  combiner     = "OR"

  conditions {
    display_name = "Cloud SQL CPU exceeds 80 percent for five minutes"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"cloudsql_database\"",
        "resource.label.database_id=\"${var.project_id}:${google_sql_database_instance.main.name}\"",
        "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channels
  enabled               = true
}

resource "google_monitoring_alert_policy" "calendar_queue_depth" {
  display_name = "${local.prefix}: Calendar task queue backlog"
  combiner     = "OR"

  conditions {
    display_name = "Calendar queue depth remains above ten"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"cloud_tasks_queue\"",
        "resource.label.queue_id=\"${google_cloud_tasks_queue.calendar.name}\"",
        "resource.label.location=\"${var.region}\"",
        "metric.type=\"cloudtasks.googleapis.com/queue/depth\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = var.notification_channels
  enabled               = true
}

resource "google_logging_metric" "background_execution_failure" {
  name        = "${local.prefix}-background-execution-failure"
  description = "Cloud Scheduler or migration job errors requiring operator attention."
  filter      = <<-EOT
    severity>=ERROR AND (
      resource.type="cloud_scheduler_job" OR
      (resource.type="cloud_run_job" AND resource.labels.job_name="${local.prefix}-migration")
    )
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "background_execution_failure" {
  display_name = "${local.prefix}: background execution failure"
  combiner     = "OR"

  conditions {
    display_name = "Scheduler or migration job emitted an error"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.background_execution_failure.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
  enabled               = true
}

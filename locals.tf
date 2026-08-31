locals {
  prefix                 = "oc-${var.organization_slug}-${var.environment}"
  api_service_name       = "oc-${var.organization_slug}-${var.environment}-api"
  api_expected_uri       = "https://oc-${var.organization_slug}-${var.environment}-api-${data.google_project.current.number}.${var.region}.run.app"
  gateway_service_name   = "${local.prefix}-gateway"
  bootstrap_service_name = "${local.prefix}-auth-bootstrap"
  gateway_iap_audience   = "/projects/${data.google_project.current.number}/locations/${var.region}/services/${local.gateway_service_name}"

  service_accounts = {
    runtime   = "${local.prefix}-runtime"
    gateway   = "${local.prefix}-gateway"
    bootstrap = "${local.prefix}-bootstrap"
    migration = "${local.prefix}-migration"
    scheduler = "${local.prefix}-scheduler"
    tasks     = "${local.prefix}-tasks"
    pubsub    = "${local.prefix}-pubsub"
    admin     = "${local.prefix}-admin"
  }

  api_services = toset([
    "artifactregistry.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudtasks.googleapis.com",
    "billingbudgets.googleapis.com",
    "aiplatform.googleapis.com",
    "dlp.googleapis.com",
    "gmail.googleapis.com",
    "pubsub.googleapis.com",
    "compute.googleapis.com",
  ])

  scheduler_jobs = {
    poll-gmail = {
      schedule = var.environment == "pilot" ? "0 * * * *" : "*/5 * * * *"
      path     = "/internal/poll-gmail"
    }
    gmail-watch-renew = {
      schedule = "15 2 * * *"
      path     = "/internal/gmail/watch/renew"
    }
    outbox-dispatch = {
      schedule = var.environment == "pilot" ? "*/5 * * * *" : "* * * * *"
      path     = "/internal/outbox/dispatch"
    }
    mail-send-reconcile = {
      schedule = var.environment == "pilot" ? "*/15 * * * *" : "*/5 * * * *"
      path     = "/internal/mail-send/reconcile"
    }
    oauth-compensate = {
      schedule = var.environment == "pilot" ? "*/30 * * * *" : "*/10 * * * *"
      path     = "/internal/auth/compensate"
    }
    pii-retention = {
      schedule = "0 3 * * *"
      path     = "/internal/retention/pii-mask"
    }
  }

  labels = {
    application  = "openclaw-secretary"
    environment  = var.environment
    organization = var.organization_slug
    managed-by   = "terraform"
  }
}

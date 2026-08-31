resource "google_cloud_run_v2_service" "api" {
  count = var.deploy_services ? 1 : 0

  name                = local.api_service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.environment == "prod"

  template {
    service_account                  = google_service_account.principal["runtime"].email
    timeout                          = "120s"
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      network_interfaces {
        network    = google_compute_network.main.id
        subnetwork = google_compute_subnetwork.serverless.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.backend_image

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLIENT_ID"
        value = var.google_client_id
      }
      env {
        name  = "GOOGLE_OAUTH_REDIRECT_URI"
        value = var.google_oauth_redirect_uri
      }
      env {
        name  = "GOOGLE_OAUTH_CLIENT_SECRET_RESOURCE"
        value = google_secret_manager_secret.oauth_client_secret.id
      }
      env {
        name  = "ALLOWED_DOMAIN"
        value = var.allowed_domain
      }
      env {
        name  = "CLOUD_RUN_AUDIENCE"
        value = local.api_expected_uri
      }
      env {
        name  = "GATEWAY_SA_EMAIL"
        value = google_service_account.principal["gateway"].email
      }
      env {
        name  = "BOOTSTRAP_SA_EMAIL"
        value = google_service_account.principal["bootstrap"].email
      }
      env {
        name  = "SCHEDULER_SA_EMAIL"
        value = google_service_account.principal["scheduler"].email
      }
      env {
        name  = "TASKS_SA_EMAIL"
        value = google_service_account.principal["tasks"].email
      }
      env {
        name  = "ADMIN_SA_EMAIL"
        value = google_service_account.principal["admin"].email
      }
      env {
        name  = "RUNTIME_SA_EMAIL"
        value = google_service_account.principal["runtime"].email
      }
      env {
        name  = "PUBSUB_SA_EMAIL"
        value = google_service_account.principal["pubsub"].email
      }
      env {
        name  = "GMAIL_PUBSUB_TOPIC"
        value = google_pubsub_topic.gmail.id
      }
      env {
        name  = "AI_ANALYSIS_ENABLED"
        value = tostring(var.enable_ai_analysis)
      }
      env {
        name  = "GEMINI_FLASH_LITE_MODEL"
        value = "gemini-2.5-flash-lite"
      }
      env {
        name  = "GEMINI_FLASH_MODEL"
        value = "gemini-2.5-flash"
      }
      env {
        name  = "GEMINI_DAILY_REQUEST_LIMIT"
        value = tostring(var.gemini_daily_request_limit)
      }
      env {
        name  = "GEMINI_MAX_OUTPUT_TOKENS"
        value = "800"
      }
      env {
        name  = "KMS_KEY_NAME"
        value = google_kms_crypto_key.data.id
      }
      env {
        name  = "CLOUD_TASKS_LOCATION"
        value = var.region
      }
      env {
        name  = "CLOUD_TASKS_QUEUE"
        value = google_cloud_tasks_queue.calendar.name
      }
      env {
        name  = "CLOUD_TASKS_TARGET_URL"
        value = local.api_expected_uri
      }

      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = google_sql_database_instance.main.connection_name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.app.name
      }
      env {
        name  = "DB_USER"
        value = trimsuffix(google_service_account.principal["runtime"].email, ".gserviceaccount.com")
      }
      env {
        name  = "DB_IP_TYPE"
        value = "PRIVATE"
      }

      startup_probe {
        initial_delay_seconds = 2
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 12
        tcp_socket { port = 8080 }
      }

      liveness_probe {
        timeout_seconds   = 3
        period_seconds    = 10
        failure_threshold = 3
        http_get {
          path = "/livez"
          port = 8080
        }
      }
    }

    labels = local.labels
  }

  depends_on = [
    google_project_service.required,
    google_secret_manager_secret_iam_member.runtime_oauth_client_secret,
    google_kms_crypto_key_iam_member.runtime_crypto,
    google_sql_user.iam_service_account,
  ]

  lifecycle {
    postcondition {
      condition     = self.uri == local.api_expected_uri
      error_message = "The Cloud Run URI no longer matches the deterministic audience supplied to Back. Configure a stable audience before applying."
    }
  }
}

resource "google_cloud_run_v2_service" "gateway" {
  count = var.deploy_services ? 1 : 0

  name                = local.gateway_service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  iap_enabled         = true
  deletion_protection = var.environment == "prod"

  template {
    service_account = google_service_account.principal["gateway"].email
    timeout         = "60s"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.gateway_image

      ports { container_port = 8080 }
      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.api[0].uri
      }
      env {
        name  = "BACKEND_AUDIENCE"
        value = google_cloud_run_v2_service.api[0].uri
      }
      env {
        name  = "GOOGLE_CLIENT_ID"
        value = var.google_client_id
      }
      env {
        name  = "AUTH_BOOTSTRAP_URL"
        value = google_cloud_run_v2_service.auth_bootstrap[0].uri
      }
      env {
        name  = "IAP_AUDIENCE"
        value = local.gateway_iap_audience
      }

      resources {
        limits   = { cpu = "1", memory = "512Mi" }
        cpu_idle = true
      }

      startup_probe {
        tcp_socket { port = 8080 }
      }
      liveness_probe {
        http_get {
          path = "/livez"
          port = 8080
        }
      }
    }

    labels = local.labels
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_service" "auth_bootstrap" {
  count = var.deploy_services ? 1 : 0

  name                = local.bootstrap_service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.environment == "prod"

  template {
    service_account = google_service_account.principal["bootstrap"].email
    timeout         = "30s"

    scaling {
      min_instance_count = var.auth_bootstrap_min_instances
      max_instance_count = min(var.max_instances, 2)
    }

    containers {
      image = var.auth_bootstrap_image
      ports { container_port = 8080 }
      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.api[0].uri
      }
      env {
        name  = "BACKEND_AUDIENCE"
        value = google_cloud_run_v2_service.api[0].uri
      }
      resources {
        limits   = { cpu = "1", memory = "256Mi" }
        cpu_idle = true
      }
      startup_probe {
        tcp_socket { port = 8080 }
      }
      liveness_probe {
        http_get {
          path = "/livez"
          port = 8080
        }
      }
    }

    labels = local.labels
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker" {
  for_each = var.deploy_services ? toset(["gateway", "bootstrap", "scheduler", "tasks", "admin", "pubsub"]) : toset([])

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.principal[each.value].email}"
}

resource "google_cloud_run_v2_service_iam_member" "auth_bootstrap_public" {
  count = var.deploy_services ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.auth_bootstrap[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "iap_gateway_invoker" {
  count = var.deploy_services ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.gateway[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-iap.iam.gserviceaccount.com"
}

resource "google_iap_web_cloud_run_service_iam_binding" "gateway_access" {
  count = var.deploy_services ? 1 : 0

  project                = var.project_id
  location               = var.region
  cloud_run_service_name = google_cloud_run_v2_service.gateway[0].name
  role                   = "roles/iap.httpsResourceAccessor"
  members                = var.iap_access_members
}

resource "google_iap_settings" "programmatic_access" {
  count = var.deploy_services ? 1 : 0

  name            = "projects/${data.google_project.current.number}/iap_web"
  deletion_policy = "PREVENT"

  access_settings {
    oauth_settings {
      programmatic_clients = [var.google_client_id]
    }
  }

  depends_on = [google_cloud_run_v2_service.gateway]
}

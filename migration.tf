resource "google_cloud_run_v2_job" "migration" {
  count = var.deploy_migration_job ? 1 : 0

  name                = "${local.prefix}-migration"
  location            = var.region
  deletion_protection = var.environment == "prod"

  template {
    template {
      service_account = google_service_account.principal["migration"].email
      timeout         = "900s"
      max_retries     = 0

      vpc_access {
        network_interfaces {
          network    = google_compute_network.main.id
          subnetwork = google_compute_subnetwork.serverless.id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image = var.migration_image

        env {
          name  = "NODE_ENV"
          value = "production"
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
          value = trimsuffix(google_service_account.principal["migration"].email, ".gserviceaccount.com")
        }
        env {
          name  = "DB_IP_TYPE"
          value = "PRIVATE"
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.migration_cloudsql_roles,
    google_sql_user.iam_service_account,
  ]
}

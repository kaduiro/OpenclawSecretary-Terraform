resource "terraform_data" "production_guards" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = var.environment != "prod" || length(var.notification_channels) > 0
      error_message = "Production requires at least one Cloud Monitoring notification channel."
    }
    precondition {
      condition = var.environment != "prod" || alltrue([
        for image in [var.backend_image, var.gateway_image, var.auth_bootstrap_image, var.migration_image] :
        can(regex("@sha256:[0-9a-f]{64}$", image))
      ])
      error_message = "Production container images must be immutable sha256 digest references."
    }
    precondition {
      condition = var.environment != "prod" || alltrue([
        for image in [var.backend_image, var.gateway_image, var.auth_bootstrap_image, var.migration_image] :
        startswith(image, "${var.region}-docker.pkg.dev/${var.project_id}/")
      ])
      error_message = "Production images must come from Artifact Registry in the deployment project and region."
    }
    precondition {
      condition     = var.max_instances >= var.min_instances
      error_message = "max_instances must be greater than or equal to min_instances."
    }
    precondition {
      condition     = var.environment != "prod" || var.min_instances >= 1
      error_message = "Production requires at least one warm Cloud Run instance."
    }
    precondition {
      condition     = var.environment != "prod" || var.auth_bootstrap_min_instances >= 1
      error_message = "Production requires at least one warm auth-bootstrap instance."
    }
    precondition {
      condition     = var.environment != "prod" || var.database_availability_type == "REGIONAL"
      error_message = "Production Cloud SQL must use REGIONAL availability."
    }
    precondition {
      condition = var.environment != "pilot" || (
        var.database_tier == "db-g1-small" &&
        var.database_availability_type == "ZONAL" &&
        var.min_instances == 0 &&
        var.auth_bootstrap_min_instances == 0 &&
        var.max_instances <= 2 &&
        var.billing_account_id != null
      )
      error_message = "Pilot must use db-g1-small, ZONAL, zero minimum instances, at most two maximum instances, and a billing budget."
    }
  }
}

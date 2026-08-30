mock_provider "google" {}

variables {
  project_id                   = "openclaw-prod"
  region                       = "asia-northeast1"
  environment                  = "prod"
  organization_slug            = "example"
  backend_image                = "asia-northeast1-docker.pkg.dev/openclaw-prod/openclaw/backend@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  gateway_image                = "asia-northeast1-docker.pkg.dev/openclaw-prod/openclaw/gateway@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  auth_bootstrap_image         = "asia-northeast1-docker.pkg.dev/openclaw-prod/openclaw/bootstrap@sha256:3333333333333333333333333333333333333333333333333333333333333333"
  migration_image              = "asia-northeast1-docker.pkg.dev/openclaw-prod/openclaw/migration@sha256:4444444444444444444444444444444444444444444444444444444444444444"
  allowed_domain               = "example.com"
  google_client_id             = "client.apps.googleusercontent.com"
  google_oauth_redirect_uri    = "https://gateway.example.com/v1/auth/callback"
  iap_access_members           = ["group:openclaw@example.com"]
  notification_channels        = ["projects/openclaw-prod/notificationChannels/1"]
  deploy_services              = false
  deploy_migration_job         = false
  auth_bootstrap_min_instances = 1
}

run "valid_production_guards" {
  command = plan
}

run "reject_public_iap_principal" {
  command = plan
  variables {
    iap_access_members = ["allUsers"]
  }
  expect_failures = [var.iap_access_members]
}

run "reject_zonal_production_database" {
  command = plan
  variables {
    database_availability_type = "ZONAL"
  }
  expect_failures = [terraform_data.production_guards]
}

run "reject_foreign_production_registry" {
  command = plan
  variables {
    backend_image = "registry.example.com/openclaw/backend@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  }
  expect_failures = [terraform_data.production_guards]
}

run "reject_zero_production_instances" {
  command = plan
  variables {
    min_instances = 0
  }
  expect_failures = [terraform_data.production_guards]
}

run "reject_zero_production_auth_bootstrap_instances" {
  command = plan
  variables {
    auth_bootstrap_min_instances = 0
  }
  expect_failures = [terraform_data.production_guards]
}

run "accept_low_cost_pilot_profile" {
  command = plan
  variables {
    environment                  = "pilot"
    database_tier                = "db-g1-small"
    database_availability_type   = "ZONAL"
    min_instances                = 0
    auth_bootstrap_min_instances = 0
    max_instances                = 2
    notification_channels        = []
    billing_account_id           = "000000-000000-000000"
  }
}

run "reject_oversized_pilot_profile" {
  command = plan
  variables {
    environment                  = "pilot"
    database_tier                = "db-custom-1-3840"
    database_availability_type   = "ZONAL"
    min_instances                = 0
    auth_bootstrap_min_instances = 0
    max_instances                = 2
    notification_channels        = []
    billing_account_id           = "000000-000000-000000"
  }
  expect_failures = [terraform_data.production_guards]
}

variable "project_id" {
  description = "GCP project hosting one OpenClaw organization environment."
  type        = string
}

variable "region" {
  description = "Region shared by Cloud Run, Cloud SQL, Scheduler and Tasks."
  type        = string
  default     = "asia-northeast1"
}

variable "environment" {
  description = "Deployment environment suffix."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "pilot", "staging", "prod"], var.environment)
    error_message = "environment must be dev, pilot, staging, or prod."
  }
}

variable "organization_slug" {
  description = "Short organization identifier used in resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.organization_slug))
    error_message = "organization_slug must be 3-16 lowercase alphanumeric/hyphen characters."
  }
}

variable "backend_image" {
  description = "Immutable backend container image reference, preferably pinned by digest."
  type        = string
}

variable "gateway_image" {
  description = "Immutable gateway container image reference, preferably pinned by digest."
  type        = string
}

variable "auth_bootstrap_image" {
  description = "Immutable auth-bootstrap container image reference, preferably pinned by digest."
  type        = string
}

variable "migration_image" {
  description = "Backend migrate-target image reference, preferably pinned by digest."
  type        = string
}

variable "allowed_domain" {
  description = "Google Workspace hosted domain accepted by the backend."
  type        = string
}

variable "google_client_id" {
  description = "OAuth client ID used as the user ID-token audience. Not a secret."
  type        = string
}

variable "google_oauth_redirect_uri" {
  description = "Gateway OAuth redirect URI registered with Google."
  type        = string
}

variable "iap_access_members" {
  description = "Users or groups allowed through IAP, for example group:openclaw@example.com."
  type        = set(string)
  default     = []

  validation {
    condition = length(var.iap_access_members) > 0 && alltrue([
      for member in var.iap_access_members :
      !contains(["allUsers", "allAuthenticatedUsers"], member) &&
      can(regex("^(user|group|domain|serviceAccount):[^[:space:]]+$", member))
    ])
    error_message = "IAP members must be explicit user, group, domain, or serviceAccount principals; public principals are forbidden."
  }
}

variable "database_name" {
  type    = string
  default = "openclaw"
}

variable "database_tier" {
  type    = string
  default = "db-custom-1-3840"
}

variable "database_availability_type" {
  description = "Use REGIONAL in production and ZONAL in lower environments when cost is preferred."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.database_availability_type)
    error_message = "database_availability_type must be ZONAL or REGIONAL."
  }
}

variable "min_instances" {
  type    = number
  default = 1

  validation {
    condition     = var.min_instances >= 0 && floor(var.min_instances) == var.min_instances
    error_message = "min_instances must be a non-negative integer."
  }
}

variable "auth_bootstrap_min_instances" {
  description = "Minimum auth-bootstrap instances. Pilot environments scale to zero; production requires at least one."
  type        = number
  default     = 0

  validation {
    condition     = var.auth_bootstrap_min_instances >= 0 && floor(var.auth_bootstrap_min_instances) == var.auth_bootstrap_min_instances
    error_message = "auth_bootstrap_min_instances must be a non-negative integer."
  }
}

variable "max_instances" {
  type    = number
  default = 3

  validation {
    condition     = var.max_instances >= 1 && floor(var.max_instances) == var.max_instances
    error_message = "max_instances must be a positive integer."
  }
}

variable "scheduler_time_zone" {
  type    = string
  default = "Asia/Tokyo"
}

variable "notification_channels" {
  description = "Existing Cloud Monitoring notification channel resource names."
  type        = list(string)
  default     = []
}

variable "billing_account_id" {
  description = "Optional billing account ID used to create the pilot cost budget."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.billing_account_id == null || can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id must use the 000000-000000-000000 format."
  }
}

variable "monthly_budget_jpy" {
  description = "Monthly cost target. Alerts do not stop resources, so application quotas remain required."
  type        = number
  default     = 7000

  validation {
    condition     = var.monthly_budget_jpy >= 1000 && floor(var.monthly_budget_jpy) == var.monthly_budget_jpy
    error_message = "monthly_budget_jpy must be an integer of at least 1000 JPY."
  }
}

variable "enable_ai_analysis" {
  description = "Enable DLP-deidentified Gemini mail analysis."
  type        = bool
  default     = false
}

variable "gemini_daily_request_limit" {
  description = "Hard application-side daily limit across Flash-Lite and Flash calls."
  type        = number
  default     = 100

  validation {
    condition     = var.gemini_daily_request_limit >= 1 && floor(var.gemini_daily_request_limit) == var.gemini_daily_request_limit
    error_message = "gemini_daily_request_limit must be a positive integer."
  }
}

variable "deploy_services" {
  description = "Set false for the bootstrap apply that creates secrets. Populate secret versions, then set true."
  type        = bool
  default     = false
}

variable "deploy_migration_job" {
  description = "Enable after secret versions exist. Execute this job before enabling deploy_services."
  type        = bool
  default     = false
}

output "api_service_uri" {
  description = "Private API URI. Do not distribute this URL to HUD users."
  value       = var.deploy_services ? google_cloud_run_v2_service.api[0].uri : null
}

output "gateway_service_uri" {
  description = "IAP-protected URL configured in the Front application."
  value       = var.deploy_services ? google_cloud_run_v2_service.gateway[0].uri : null
}

output "auth_bootstrap_service_uri" {
  description = "Narrowly public redeem URL configured alongside the Gateway and verified against the loopback handoff."
  value       = var.deploy_services ? google_cloud_run_v2_service.auth_bootstrap[0].uri : null
}

output "database_private_ip" {
  description = "Private IP for approved database bootstrap and connectivity diagnostics. Application runtime uses the Cloud SQL Connector."
  value       = google_sql_database_instance.main.private_ip_address
}

output "oauth_client_secret" {
  value = google_secret_manager_secret.oauth_client_secret.id
}

output "service_accounts" {
  value = { for key, account in google_service_account.principal : key => account.email }
}

output "calendar_queue" {
  value = google_cloud_tasks_queue.calendar.id
}

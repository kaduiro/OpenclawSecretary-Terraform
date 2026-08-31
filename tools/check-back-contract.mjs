import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

const repo = path.resolve(import.meta.dirname, "..");
const back = path.resolve(process.argv[2] || process.env.BACK_REPOSITORY || path.join(repo, "..", "OpenclawSecretary-Back"));
const contractLock = JSON.parse(fs.readFileSync(path.join(repo, "contracts", "back-contract.lock.json"), "utf8"));
for (const entry of [contractLock.openapi, contractLock.config, contractLock.package]) {
  const digest = createHash("sha256").update(fs.readFileSync(path.join(back, entry.path))).digest("hex");
  if (digest !== entry.sha256) throw new Error(`Back contract digest changed for ${entry.path}: expected ${entry.sha256}, received ${digest}`);
}
const config = fs.readFileSync(path.join(back, "src", "config.js"), "utf8");
const openapi = fs.readFileSync(path.join(back, "docs", "api", "openapi.yaml"), "utf8");
const cloudRun = fs.readFileSync(path.join(repo, "cloud_run.tf"), "utf8");
const scheduler = fs.readFileSync(path.join(repo, "locals.tf"), "utf8");
const tasks = fs.readFileSync(path.join(repo, "tasks.tf"), "utf8");
const backPackage = fs.readFileSync(path.join(back, "package.json"), "utf8");
const allTerraform = fs.readdirSync(repo)
  .filter((name) => name.endsWith(".tf"))
  .map((name) => fs.readFileSync(path.join(repo, name), "utf8"))
  .join("\n");

const requiredEnvironment = [
  "INSTANCE_CONNECTION_NAME",
  "DB_NAME",
  "DB_USER",
  "GOOGLE_CLIENT_ID",
  "GOOGLE_OAUTH_REDIRECT_URI",
  "GOOGLE_OAUTH_CLIENT_SECRET_RESOURCE",
  "ALLOWED_DOMAIN",
  "CLOUD_RUN_AUDIENCE",
  "GATEWAY_SA_EMAIL",
  "BOOTSTRAP_SA_EMAIL",
  "SCHEDULER_SA_EMAIL",
  "TASKS_SA_EMAIL",
  "ADMIN_SA_EMAIL",
  "RUNTIME_SA_EMAIL",
  "PUBSUB_SA_EMAIL",
  "GMAIL_PUBSUB_TOPIC",
  "KMS_KEY_NAME",
  "GOOGLE_CLOUD_PROJECT",
];

const schedulerPaths = [
  "/internal/outbox/dispatch",
  "/internal/mail-send/reconcile",
  "/internal/auth/compensate",
  "/internal/poll-gmail",
  "/internal/gmail/watch/renew",
  "/internal/retention/pii-mask",
];

const errors = [];
for (const name of requiredEnvironment) {
  if (!config.includes(`"${name}"`)) errors.push(`Back no longer requires expected env ${name}`);
  if (!new RegExp(`name\\s*=\\s*"${name}"`).test(cloudRun)) errors.push(`cloud_run.tf does not supply ${name}`);
}
for (const endpoint of schedulerPaths) {
  if (!openapi.includes(`  ${endpoint}:`)) errors.push(`Back OpenAPI no longer defines ${endpoint}`);
  if (!scheduler.includes(`path     = "${endpoint}"`)) errors.push(`Terraform does not schedule ${endpoint}`);
}
if (!openapi.includes("  /internal/calendar/operations/{operationId}/execute:")) errors.push("Back Calendar task endpoint is missing");
if (!openapi.includes("  /internal/gmail/notifications:")) errors.push("Back Gmail Pub/Sub endpoint is missing");
if (!/resource\s+"google_pubsub_subscription"\s+"gmail_push"/.test(allTerraform)) errors.push("Gmail Pub/Sub push subscription is missing");
if (!/max_attempts\s*=\s*1/.test(tasks)) errors.push("Calendar queue max_attempts must remain 1");
const publicPrincipals = allTerraform.match(/member\s*=\s*"(?:allUsers|allAuthenticatedUsers)"/g) || [];
if (publicPrincipals.length !== 1 || !allTerraform.includes('resource "google_cloud_run_v2_service_iam_member" "auth_bootstrap_public"')) {
  errors.push("Only the explicit auth-bootstrap allUsers invoker exception is allowed");
}
if (/secret_data\s*=/.test(allTerraform)) errors.push("Secret value found in Terraform state input");
if (!/liveness_probe[\s\S]*?path\s*=\s*"\/livez"/.test(cloudRun) || /liveness_probe[\s\S]*?path\s*=\s*"\/v1\/health"/.test(cloudRun)) {
  errors.push("Back liveness probe must use anonymous /livez");
}
if (!backPackage.includes('"@google-cloud/cloud-sql-connector"')) errors.push("Back Cloud SQL Connector dependency is missing");
if (/name\s*=\s*"DATABASE_URL"/.test(cloudRun)) errors.push("Production Cloud Run must not receive DATABASE_URL");
if (!/resource\s+"google_iap_settings"\s+"programmatic_access"/.test(cloudRun) || !/programmatic_clients\s*=\s*\[var\.google_client_id\]/.test(cloudRun)) {
  errors.push("Terraform must manage the Front OAuth client as an IAP programmatic client");
}
if (!/deletion_protection_enabled\s*=\s*var\.environment\s*==\s*"prod"/.test(allTerraform)) errors.push("Production Cloud SQL API deletion protection is missing");
if (!/database_availability_type\s*==\s*"REGIONAL"/.test(allTerraform)) errors.push("Production Cloud SQL REGIONAL guard is missing");
if (!/docker\.pkg\.dev\/\$\{var\.project_id\}/.test(allTerraform)) errors.push("Production Artifact Registry project guard is missing");
if (!/auth_bootstrap_denied/.test(allTerraform) || !/calendar_queue_depth/.test(allTerraform) || !/cloud_sql_cpu/.test(allTerraform)) {
  errors.push("Required auth-bootstrap, Cloud Tasks, or Cloud SQL monitoring is missing");
}

if (errors.length) {
  console.error(errors.map((error) => `- ${error}`).join("\n"));
  process.exit(1);
}

console.log(`Back contract locked and verified: ${requiredEnvironment.length} env vars, ${schedulerPaths.length} scheduler jobs, Calendar queue maxAttempts=1`);

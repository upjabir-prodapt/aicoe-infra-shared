# gclt-aicoe-dev-auditlogs
#
# WHY THIS IS FIDDLY
# A sink's writer identity does not exist until the sink does, so granting
# it on the destination cannot happen in the same resource. Two stages,
# with an explicit dependency. Getting this wrong produces a sink that
# silently drops everything.

# API enablement. This project has no project-baseline module (it needs no
# service accounts), so the APIs it does need are enabled directly here.
# cloudkms must exist before the key ring below; logging/pubsub/bigquery
# serve the bucket, the sink, and the linked dataset.
resource "google_project_service" "gclt_aicoe_dev_auditlogs_apis" {
  for_each = toset([
    "cloudkms.googleapis.com",
    "logging.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
  ])
  project            = var.gclt_aicoe_dev_auditlogs_project_id
  service            = each.value
  disable_on_destroy = false
}

module "gclt_aicoe_dev_auditlogs_agents" {
  source     = "../modules/service-agents"
  project_id = var.gclt_aicoe_dev_auditlogs_project_id
  services   = ["logging.googleapis.com"]
}

# Cloud Logging's CMEK service account. Reading the project settings
# provisions it if it does not exist yet; the log-bucket key grant goes to
# this account, which is what actually encrypts the bucket.
data "google_logging_project_settings" "gclt_aicoe_dev_auditlogs" {
  project = var.gclt_aicoe_dev_auditlogs_project_id
}

module "gclt_aicoe_dev_auditlogs_kms" {
  source     = "../modules/kms-ring"
  project_id = var.gclt_aicoe_dev_auditlogs_project_id
  location   = var.region
  ring_name  = "logs"
  keys       = { "log-bucket" = {} }
  key_grants = { "log-bucket" = [data.google_logging_project_settings.gclt_aicoe_dev_auditlogs.kms_service_account_id] }

  depends_on = [google_project_service.gclt_aicoe_dev_auditlogs_apis]
}

resource "google_logging_project_bucket_config" "gclt_aicoe_dev_auditlogs_main" {
  project        = var.gclt_aicoe_dev_auditlogs_project_id
  location       = var.region
  bucket_id      = "aicoe-dev-logs-400d"
  retention_days = 400
  cmek_settings { kms_key_name = module.gclt_aicoe_dev_auditlogs_kms.key_ids["log-bucket"] }

  # Log Analytics gives SQL over the logs without a second stored copy.
  enable_analytics = true

  # NOT locked. Locking is irreversible and prevents deletion until every
  # entry has aged out — a 400-day commitment in a dev environment.
  locked = false

  depends_on = [module.gclt_aicoe_dev_auditlogs_kms]
}

# The linked BigQuery dataset is the half that makes Log Analytics queryable.
# enable_analytics on the bucket alone stores the data; without this there is
# no dataset to run SQL against — "SQL over logs, no second cost" per the
# logging architecture.
resource "google_logging_linked_dataset" "gclt_aicoe_dev_auditlogs_main" {
  parent      = "projects/${var.gclt_aicoe_dev_auditlogs_project_id}"
  location    = var.region
  bucket      = google_logging_project_bucket_config.gclt_aicoe_dev_auditlogs_main.bucket_id
  link_id     = "aicoe_dev_logs"
  description = "SQL over the 400-day central log bucket"
  depends_on  = [google_logging_project_bucket_config.gclt_aicoe_dev_auditlogs_main]
}

# ── sink 1 · everything, to the 400-day bucket ──────────────────────────
resource "google_logging_folder_sink" "gclt_aicoe_dev_auditlogs_aicoe_400d" {
  name             = "aicoe-400d"
  folder           = var.folder_id
  include_children = true # without this you capture nothing
  destination      = "logging.googleapis.com/${google_logging_project_bucket_config.gclt_aicoe_dev_auditlogs_main.id}"

  exclusions {
    name   = "exclude-flow-logs"
    filter = "logName:\"compute.googleapis.com%2Fvpc_flows\""
  }
  exclusions {
    name   = "exclude-lb-health"
    filter = "resource.type=\"http_load_balancer\" AND httpRequest.userAgent:\"GoogleHC\""
  }
}

# Stage two. writer_identity only exists once the sink above is created.
resource "google_project_iam_member" "gclt_aicoe_dev_auditlogs_sink_400d_writer" {
  project = var.gclt_aicoe_dev_auditlogs_project_id
  role    = "roles/logging.bucketWriter"
  member  = google_logging_folder_sink.gclt_aicoe_dev_auditlogs_aicoe_400d.writer_identity

  depends_on = [google_logging_folder_sink.gclt_aicoe_dev_auditlogs_aicoe_400d]
}

# ── sinks 2 and 3 REMOVED (decision 2026-08-12) ─────────────────────────
# Sink 2 (aicoe-to-org, copy to the enterprise logging project) and sink 3
# (aicoe-siem, security subset to Pub/Sub for Sentinel) are not required:
# logs go only to the 400-day bucket above. The Pub/Sub topic, its writer
# binding, and the org_log_project variable went with them.

# ── Data Access audit logs ──────────────────────────────────────────────
# Off by default for most services. Without these there is no IAP DATA_READ,
# no GCS object reads and no BigQuery data reads — exactly the records the
# business-unit attribution depends on.
resource "google_folder_iam_audit_config" "gclt_aicoe_dev_auditlogs_data_access" {
  for_each = toset([
    "iap.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "aiplatform.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "run.googleapis.com",
  ])
  folder  = var.folder_id
  service = each.value

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content { log_type = audit_log_config.value }
  }
}

output "gclt_aicoe_dev_auditlogs_log_bucket_id" { value = google_logging_project_bucket_config.gclt_aicoe_dev_auditlogs_main.id }

# gclt-aicoe-dev-auditlogs
#
# WHY THIS IS FIDDLY
# A sink's writer identity does not exist until the sink does, so granting
# it on the destination cannot happen in the same resource. Two stages,
# with an explicit dependency. Getting this wrong produces a sink that
# silently drops everything.

module "gclt_aicoe_dev_auditlogs_agents" {
  source     = "../modules/service-agents"
  project_id = var.gclt_aicoe_dev_auditlogs_project_id
  services   = ["logging.googleapis.com", "pubsub.googleapis.com"]
}

module "gclt_aicoe_dev_auditlogs_kms" {
  source     = "../modules/kms-ring"
  project_id = var.gclt_aicoe_dev_auditlogs_project_id
  location   = var.region
  ring_name  = "logs"
  keys       = { "log-bucket" = {} }
  key_grants = { "log-bucket" = [module.gclt_aicoe_dev_auditlogs_agents.emails["logging.googleapis.com"]] }
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

# ── sink 1 · everything, to the 400-day bucket ──────────────────────────
resource "google_logging_folder_sink" "gclt_aicoe_dev_auditlogs_aicoe_400d" {
  name             = "aicoe-400d"
  folder           = var.folder_id
  include_children = true                 # without this you capture nothing
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

  depends_on = [google_logging_folder_sink.aicoe_400d]
}

# ── sink 2 · to the enterprise logging project ──────────────────────────
# A separate sink, not a shared one. Each is a copy with its own filter, so
# your retention requirement and their platform standard stay decoupled.
resource "google_logging_folder_sink" "gclt_aicoe_dev_auditlogs_to_org" {
  name             = "aicoe-to-org"
  folder           = var.folder_id
  include_children = true
  destination      = "logging.googleapis.com/projects/${var.org_log_project}/locations/${var.region}/buckets/_Default"
}

# ── sink 3 · security subset to Pub/Sub for the SIEM ────────────────────
resource "google_pubsub_topic" "gclt_aicoe_dev_auditlogs_siem" {
  project = var.gclt_aicoe_dev_auditlogs_project_id
  name    = "aicoe-security-logs"
}

resource "google_logging_folder_sink" "gclt_aicoe_dev_auditlogs_siem" {
  name             = "aicoe-siem"
  folder           = var.folder_id
  include_children = true
  destination      = "pubsub.googleapis.com/${google_pubsub_topic.gclt_aicoe_dev_auditlogs_siem.id}"

  # SIEMs charge by volume ingested. Security-relevant only.
  filter = <<-EOT
    logName:"cloudaudit.googleapis.com" OR
    logName:"iap.googleapis.com" OR
    protoPayload.serviceName="apigee.googleapis.com"
  EOT
}

resource "google_pubsub_topic_iam_member" "gclt_aicoe_dev_auditlogs_siem_writer" {
  project = var.gclt_aicoe_dev_auditlogs_project_id
  topic   = google_pubsub_topic.gclt_aicoe_dev_auditlogs_siem.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_folder_sink.gclt_aicoe_dev_auditlogs_siem.writer_identity

  depends_on = [google_logging_folder_sink.siem]
}

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
    "firestore.googleapis.com",
  ])
  folder  = var.folder_id
  service = each.value

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content { log_type = audit_log_config.value }
  }
}

output "gclt_aicoe_dev_auditlogs_log_bucket_id" { value = google_logging_project_bucket_config.gclt_aicoe_dev_auditlogs_main.id }

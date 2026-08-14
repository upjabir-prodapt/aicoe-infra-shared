# gclt-aicoe-dev-aihub-ui

module "gclt_aicoe_dev_aihub_ui_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_aihub_ui_project_id
  services = [
    "run.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    "binaryauthorization.googleapis.com",
    "firestore.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "iap.googleapis.com",
  ]
  agent_services = [
    "artifactregistry.googleapis.com",
    "firestore.googleapis.com",
    "iap.googleapis.com",
    "secretmanager.googleapis.com",
  ]
  service_accounts = {
    "aihub-bff-sa" = { display_name = "AI Hub Backend-for-Frontend" }
  }
}

module "gclt_aicoe_dev_aihub_ui_kms" {
  source     = "../modules/kms-ring"
  project_id = var.gclt_aicoe_dev_aihub_ui_project_id
  location   = var.region
  ring_name  = "aihub"
  keys = {
    "artifacts" = {}
    "firestore" = {}
    "session"   = {} # wraps the cached data encryption key — see doc 13 section 5
  }
  key_grants = {
    "artifacts" = [module.gclt_aicoe_dev_aihub_ui_baseline.agent_emails["artifactregistry.googleapis.com"]]
    "firestore" = [module.gclt_aicoe_dev_aihub_ui_baseline.agent_emails["firestore.googleapis.com"]]
    "session"   = [module.gclt_aicoe_dev_aihub_ui_baseline.agent_emails["secretmanager.googleapis.com"]]
  }
}

resource "google_artifact_registry_repository" "gclt_aicoe_dev_aihub_ui_containers" {
  project       = var.gclt_aicoe_dev_aihub_ui_project_id
  location      = var.region
  repository_id = "containers"
  format        = "DOCKER"
  kms_key_name  = module.gclt_aicoe_dev_aihub_ui_kms.key_ids["artifacts"]

  docker_config { immutable_tags = true }

  depends_on = [module.gclt_aicoe_dev_aihub_ui_kms]
}

# Session store. CMEK, regional, Native mode.
# Session store. Regional, Native mode.
# CMEK REMOVED 2026-08-14: Firestore CMEK requires a Google allowlist that is
# not yet approved for this project (429 quota error). Using Google-managed
# encryption until the allowlist is granted. NOTE: CMEK cannot be added to an
# existing database - enabling it later means deleting and recreating the DB.
resource "google_firestore_database" "gclt_aicoe_dev_aihub_ui_sessions" {
  project                 = var.gclt_aicoe_dev_aihub_ui_project_id
  name                    = "(default)"
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
}

# TTL is housekeeping, not enforcement — deletion lags by up to 24 hours,
# so the BFF checks expiry on every read. See doc 13 section 4.
resource "google_firestore_field" "gclt_aicoe_dev_aihub_ui_session_ttl" {
  project    = var.gclt_aicoe_dev_aihub_ui_project_id
  database   = google_firestore_database.gclt_aicoe_dev_aihub_ui_sessions.name
  collection = "sessions"
  field      = "absolute_expires_at"

  ttl_config {}
}

resource "google_binary_authorization_policy" "gclt_aicoe_dev_aihub_ui_policy" {
  project = var.gclt_aicoe_dev_aihub_ui_project_id

  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = [google_binary_authorization_attestor.gclt_aicoe_dev_ingress_build.id]
  }
}

resource "google_secret_manager_secret" "gclt_aicoe_dev_aihub_ui_bff" {
  for_each  = toset(["entra-bff-client-secret", "apigee-bff-client-key"])
  project   = var.gclt_aicoe_dev_aihub_ui_project_id
  secret_id = each.value

  replication {
    user_managed {
      replicas {
        location = var.region # manual replication keeps it in the EU
        customer_managed_encryption { kms_key_name = module.gclt_aicoe_dev_aihub_ui_kms.key_ids["session"] }
      }
    }
  }
}

output "gclt_aicoe_dev_aihub_ui_service_accounts" { value = module.gclt_aicoe_dev_aihub_ui_baseline.service_accounts }
output "gclt_aicoe_dev_aihub_ui_kms_key_ids" { value = module.gclt_aicoe_dev_aihub_ui_kms.key_ids }

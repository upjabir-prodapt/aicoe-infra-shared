# gclt-aicoe-dev-st

module "gclt_aicoe_dev_st_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_st_project_id
  services = [
    "run.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudtasks.googleapis.com",
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "aiplatform.googleapis.com",
    "dlp.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "firestore.googleapis.com",
  ]
  agent_services = [
    "artifactregistry.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
  ]

  # One identity per service. A shared account means a compromise anywhere
  # is a compromise everywhere.
  service_accounts = {
    "translation-api-sa"    = { display_name = "Translation API" }
    "translation-worker-sa" = { display_name = "Translation worker" }
    "salesagent-sa"         = { display_name = "Sales research agent" }
    "mcp-sa"                = { display_name = "MCP server (future)" }
    "worker-invoker-sa"     = { display_name = "Cloud Tasks, invokes the worker" }
    "tf-deployer"           = { display_name = "Terraform deployer, st" }
  }
}

module "gclt_aicoe_dev_st_kms" {
  source     = "../modules/kms-ring"
  project_id = var.gclt_aicoe_dev_st_project_id
  location   = var.region
  ring_name  = "st"
  keys = {
    "app-gcs"    = {}
    "bq"         = {}
    "vxai-index" = {}
    "secrets"    = {}
    "artifacts"  = {}
  }
  key_grants = {
    "artifacts"  = [module.gclt_aicoe_dev_st_baseline.agent_emails["artifactregistry.googleapis.com"]]
    "app-gcs"    = [module.gclt_aicoe_dev_st_baseline.agent_emails["storage.googleapis.com"]]
    "bq"         = [module.gclt_aicoe_dev_st_baseline.agent_emails["bigquery.googleapis.com"]]
    "vxai-index" = [module.gclt_aicoe_dev_st_baseline.agent_emails["aiplatform.googleapis.com"]]
  }
}

resource "google_artifact_registry_repository" "gclt_aicoe_dev_st_containers" {
  project       = var.gclt_aicoe_dev_st_project_id
  location      = var.region
  repository_id = "containers"
  format        = "DOCKER"
  kms_key_name  = module.gclt_aicoe_dev_st_kms.key_ids["artifacts"]
  docker_config { immutable_tags = true }
  depends_on    = [module.gclt_aicoe_dev_st_kms]
}

resource "google_binary_authorization_policy" "gclt_aicoe_dev_st_policy" {
  project = var.gclt_aicoe_dev_st_project_id
  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = [var.attestor_name]
  }
}

# ── THE step that makes the AI gateway a control rather than a convention ─
# No workload service account holds aiplatform.user. Only the Apigee LLM
# runtime does, and that grant lives in static/llm. This check exists to make
# the absence deliberate and reviewable rather than accidental.
#
# See the LLD's decision log, D-30. Until this holds, every gateway control
# is advisory.

output "gclt_aicoe_dev_st_workload_service_accounts" {
  description = "None of these may hold roles/aiplatform.user anywhere."
  value       = module.gclt_aicoe_dev_st_baseline.service_accounts
}
output "gclt_aicoe_dev_st_kms_key_ids" { value = module.gclt_aicoe_dev_st_kms.key_ids }

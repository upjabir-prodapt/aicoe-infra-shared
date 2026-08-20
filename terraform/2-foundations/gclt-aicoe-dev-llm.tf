# gclt-aicoe-dev-llm
#
# Its whole purpose is to be the project every Vertex AI call is billed and
# quota-counted against, and to hold the safety configuration.

module "gclt_aicoe_dev_llm_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_llm_project_id
  services = [
    "aiplatform.googleapis.com",
    "modelarmor.googleapis.com",
    "cloudkms.googleapis.com",
    "dlp.googleapis.com",
  ]
  agent_services = ["aiplatform.googleapis.com"]
  service_accounts = {
    "llm-breakglass" = {
      display_name = "Break-glass direct Vertex AI access"
      description  = "Granted via PAM with approval. Every use is alerted on."
    }
  }
}

# ── the grant that makes the gateway mandatory ──────────────────────────
# Only the Apigee LLM runtime may call a model. No workload service account
# holds this anywhere. See the LLD's decision log, D-30.

resource "google_project_iam_member" "gclt_aicoe_dev_llm_apigee_vertex" {
  project = var.gclt_aicoe_dev_llm_project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${module.gclt_aicoe_dev_apigee_baseline.service_accounts["apigee-llm-runtime"]}"
}

resource "google_project_iam_member" "gclt_aicoe_dev_llm_apigee_modelarmor" {
  project = var.gclt_aicoe_dev_llm_project_id
  role    = "roles/modelarmor.user"
  member  = "serviceAccount:${module.gclt_aicoe_dev_apigee_baseline.service_accounts["apigee-llm-runtime"]}"
}

# Break-glass. An emergency route nobody notices being used is not a control,
# so the security logging design alerts on any authentication as this account.
resource "google_project_iam_member" "gclt_aicoe_dev_llm_breakglass_vertex" {
  project = var.gclt_aicoe_dev_llm_project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${module.gclt_aicoe_dev_llm_baseline.service_accounts["llm-breakglass"]}"
}

# Model Armor templates moved to Stage 7 (Apigee Runtime) where they can reach the regional PSC endpoint
output "gclt_aicoe_dev_llm_breakglass_sa" { value = module.gclt_aicoe_dev_llm_baseline.service_accounts["llm-breakglass"] }

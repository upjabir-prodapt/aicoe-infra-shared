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

    # This project runs no VMs and needs no Compute resources of its own, but
    # it IS a Shared VPC service project of gclt-aicoe-dev-network. The
    # provider reads google_compute_shared_vpc_service_project through the
    # Compute API scoped to the *service* project; with the API disabled that
    # read returns SERVICE_DISABLED and Terraform concludes the attachment was
    # deleted. Stage 3 then plans to recreate an attachment that already
    # exists — permanent false drift on every plan. Enabling the API here is
    # what makes the attachment readable.
    "compute.googleapis.com",
    # Already enabled here by hand (unlike 5 of the other 7 dev projects);
    # codified for consistency, not because it was missing. See
    # gclt-aicoe-dev-aihub-ui.tf — codified platform-wide 2026-09-02.
    "cloudresourcemanager.googleapis.com",
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

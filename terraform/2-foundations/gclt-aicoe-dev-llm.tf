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

# ── Model Armor templates · europe-west1, contrary to earlier belief ────
resource "google_model_armor_template" "gclt_aicoe_dev_llm_default" {
  provider    = google-beta
  project     = var.gclt_aicoe_dev_llm_project_id
  location    = var.region
  template_id = "aicoe-default"

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }
    malicious_uri_filter_settings { filter_enforcement = "ENABLED" }
    sdp_settings {
      basic_config { filter_enforcement = "ENABLED" }
    }
  }
}

resource "google_model_armor_template" "gclt_aicoe_dev_llm_strict" {
  provider    = google-beta
  project     = var.gclt_aicoe_dev_llm_project_id
  location    = var.region
  template_id = "aicoe-strict"

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "LOW_AND_ABOVE"
    }
    malicious_uri_filter_settings { filter_enforcement = "ENABLED" }
    sdp_settings {
      basic_config { filter_enforcement = "ENABLED" }
    }
  }
}

output "gclt_aicoe_dev_llm_template_ids" {
  value = {
    default = google_model_armor_template.gclt_aicoe_dev_llm_default.template_id
    strict  = google_model_armor_template.gclt_aicoe_dev_llm_strict.template_id
  }
}
output "gclt_aicoe_dev_llm_breakglass_sa" { value = module.gclt_aicoe_dev_llm_baseline.service_accounts["llm-breakglass"] }

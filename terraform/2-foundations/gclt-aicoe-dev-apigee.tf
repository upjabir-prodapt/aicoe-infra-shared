# gclt-aicoe-dev-apigee
#
# WHY THIS FILE EXISTS
# Stage 4 creates the Apigee organisation, instance and environments. It
# calls modules/service-agents and modules/kms-ring directly, but never
# modules/project-baseline — so nothing was enabling the APIs on this
# project. On a green-field build that fails twice over: the Apigee service
# agent cannot be forced into existence before apigee.googleapis.com is on,
# and google_apigee_organization cannot be created at all.
#
# The KMS ring stays in stage 4 rather than moving here, because the two keys
# it holds are consumed by immutable settings on the organisation and the
# instance, and keeping them beside the resources that consume them is what
# makes that dependency legible.

module "gclt_aicoe_dev_apigee_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_apigee_project_id
  services = [
    "apigee.googleapis.com",
    "compute.googleapis.com",  # the PSC endpoint attachment in stage 7
    "cloudkms.googleapis.com", # runtime-db and instance-disk keys
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",        # the Apigee client key, per the BFF design
    "cloudresourcemanager.googleapis.com", # see gclt-aicoe-dev-aihub-ui.tf — codified platform-wide 2026-09-02
  ]

  # Forced ahead of stage 4's KMS grants. Creating the agent lazily is what
  # produces "service account does not exist" against the key rather than
  # against the account.
  agent_services = ["apigee.googleapis.com"]

  # One identity per role. apigee-int-runtime invokes the usecase Cloud Run
  # services; apigee-llm-runtime is the ONLY identity anywhere holding
  # roles/aiplatform.user, which is the grant that makes the AI gateway
  # mandatory rather than advisory — see the LLD's decision log, D-30.
  service_accounts = {
    "apigee-int-runtime" = {
      display_name = "Apigee int environment runtime"
      description  = "Calls the usecase Cloud Run services through the Backend ILB. Holds run.invoker, never aiplatform.user."
    }
    "apigee-llm-runtime" = {
      display_name = "Apigee llm environment runtime"
      description  = "The only identity granted roles/aiplatform.user. Screens, meters and forwards every Vertex AI call."
    }
  }
}

# ── Apigee Service Agent -> runtime SA token minting ───────────────────
# Half of Apigee's backend authentication lived here unwritten until
# 2026-09-11. A proxy whose TargetEndpoint carries <Authentication>
# <GoogleIDToken> does not sign that token itself: the Apigee Service Agent
# mints it *as* the environment's runtime service account, which requires
# roles/iam.serviceAccountTokenCreator on that account. Stage 6b grants the
# other half (run.invoker on the usecase Cloud Run services) — but with this
# binding absent, no token is ever minted, so run.invoker is never even
# exercised. Every request died in the proxy with
# "Google token generation has failed" (GoogleTokenGenerationFailure),
# surfacing to the caller as a bare HTTP 500.
#
# Kept in 2-foundations rather than 4-apigee or 7-apigee-runtime because
# this is a binding *on the service account*, and both the account and the
# service agent are created here — stage 4 would have to reach back for both.
#
# apigee-llm-runtime is included although the llm environment has no proxies
# deployed yet: the gap is identical, and the AI gateway would otherwise hit
# this same wall on its first deploy. See docs/BUILD-LOG.md #37.
resource "google_service_account_iam_member" "apigee_runtime_token_creator" {
  for_each           = toset(["apigee-int-runtime", "apigee-llm-runtime"])
  service_account_id = "projects/${var.gclt_aicoe_dev_apigee_project_id}/serviceAccounts/${module.gclt_aicoe_dev_apigee_baseline.service_accounts[each.key]}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${module.gclt_aicoe_dev_apigee_baseline.agent_emails["apigee.googleapis.com"]}"
}

output "gclt_aicoe_dev_apigee_service_accounts" {
  description = "apigee-llm-runtime is consumed by gclt-aicoe-dev-llm as apigee_llm_runtime_sa; apigee-int-runtime by stage 6b as apigee_runtime_sa."
  value       = module.gclt_aicoe_dev_apigee_baseline.service_accounts
}

output "gclt_aicoe_dev_apigee_apis_ready" {
  description = "Consumed as an ordering handle by stage 4, which cannot create the organisation until apigee.googleapis.com is enabled."
  value       = module.gclt_aicoe_dev_apigee_baseline.apis_ready
}

# ── scalar outputs, named for the consuming stage's variables ───────────
# The artifact handoff turns output names into variable names verbatim, so
# these are published under the exact names the consumers declare. Typing
# them into terraform.tfvars by hand is how a misspelled principal silently
# leaves the AI gateway unenforced — Google accepts a binding to a principal
# that does not exist, and the failure surfaces at request time.
# ── Cloud Logging for the LLM gateway's attribution record ──────────────
# llm-gateway-v1's ML-Attribution policy is a MessageLogging/CloudLogging step
# writing one metadata-only entry per LLM call (product, app, department, scan
# verdicts) to projects/gclt-aicoe-dev-apigee/logs/llm-gateway-attribution.
# That IS the authoritative usage meter -- StatisticsCollector is not a
# supported policy in this org, so Apigee analytics custom dimensions are not
# available to us at all (docs/BUILD-LOG.md #39).
#
# MessageLogging writes as the ENVIRONMENT'S RUNTIME SERVICE ACCOUNT, so
# apigee-llm-runtime needs logging.logWriter on this project. Without it the
# policy fails silently: calls succeed, nothing is written, and the log simply
# does not appear -- there is no error anywhere to notice. Confirmed live
# 2026-09-15: the first successful end-to-end call through the gateway produced
# a 200 and an empty attribution log, and this SA held no bindings at all here.
resource "google_project_iam_member" "gclt_aicoe_dev_apigee_llm_runtime_log_writer" {
  project = var.gclt_aicoe_dev_apigee_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${module.gclt_aicoe_dev_apigee_baseline.service_accounts["apigee-llm-runtime"]}"
}

output "apigee_llm_runtime_sa" {
  description = "Consumed by 2-foundations' own llm file (roles/aiplatform.user, D-30) and published for any later stage that needs the gateway identity."
  value       = module.gclt_aicoe_dev_apigee_baseline.service_accounts["apigee-llm-runtime"]
}
output "apigee_runtime_sa" {
  description = "Consumed by 6b-gclt-aicoe-dev-st as the run.invoker principal on the usecase services."
  value       = module.gclt_aicoe_dev_apigee_baseline.service_accounts["apigee-int-runtime"]
}

# gclt-aicoe-dev-aihub-ui

locals {
  # The BFF's runtime identity. Every grant below is workload-specific, so
  # none of it belongs in modules/project-baseline — that module is shared by
  # eight projects and would hand these roles to all of them.
  aihub_bff_sa = module.gclt_aicoe_dev_aihub_ui_baseline.service_accounts["aihub-bff-sa"]

  # The CI identity — created by 0-bootstrap in a different project
  # (aicoe-sharedwif) and stage, so there is no resource reference for it
  # here, only the deterministic email (account_id is always literally
  # "tf-deployer", see 0-bootstrap/main.tf). This is what the app repo's own
  # .gitlab-ci.yml impersonates via WIF for build-and-push/deploy-cloud-run —
  # a separate identity from aihub_bff_sa, which is what the *deployed
  # container* runs as, never what CI runs as.
  aihub_ui_tf_deployer = "tf-deployer@${var.gclt_aicoe_dev_aihub_ui_project_id}.iam.gserviceaccount.com"
}

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
    # Was disabled here (unlike aicoe-sharedwif and llm, where it happened to
    # already be on) and caused a `gcloud config set project` WARNING in
    # deploy-cloud-run — harmless there, but checked and found missing on 5 of
    # the 8 dev projects. Codified everywhere on 2026-09-02 per the "APIs
    # through Terraform only" decision (section 8).
    "cloudresourcemanager.googleapis.com",
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
  ring_name  = "aihub-ew3"
  keys = {
    "artifacts" = {}
    "firestore" = {}
    "session"   = {} # wraps the cached data encryption key — see doc 13 section 5
  }
  # APPEND ONLY — never prepend or reorder these lists.
  # modules/kms-ring/main.tf:65 keys its for_each on "${key}:${i}" where i
  # indexes the *flattened* list across every key, and the map iterates
  # lexicographically (artifacts=0, firestore=1, session=2). Inserting a
  # member ahead of an existing one renumbers it, and Terraform then destroys
  # and recreates the secretmanager service agent's binding on a CMEK key that
  # is actively protecting both BFF secrets.
  key_grants = {
    "artifacts" = [module.gclt_aicoe_dev_aihub_ui_baseline.agent_emails["artifactregistry.googleapis.com"]]
    "firestore" = [module.gclt_aicoe_dev_aihub_ui_baseline.agent_emails["firestore.googleapis.com"]]
    # Bare emails — modules/kms-ring adds the "serviceAccount:" prefix itself.
    "session" = [
      module.gclt_aicoe_dev_aihub_ui_baseline.agent_emails["secretmanager.googleapis.com"], # session:2
      local.aihub_bff_sa,                                                                   # session:3 — appended
    ]
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

# CI's `build-and-push` job (.gitlab-ci.yml in the app repo) authenticates as
# this project's own tf-deployer and pushes here directly with `docker push`
# — 0-bootstrap only grants that SA access to its Terraform state prefix, not
# to anything workload-specific, so without this the WIF token exchange
# succeeds but `docker push` then 403s. Scoped to this one repository rather
# than project-wide.
resource "google_artifact_registry_repository_iam_member" "gclt_aicoe_dev_aihub_ui_containers_ci_writer" {
  project    = var.gclt_aicoe_dev_aihub_ui_project_id
  location   = google_artifact_registry_repository.gclt_aicoe_dev_aihub_ui_containers.location
  repository = google_artifact_registry_repository.gclt_aicoe_dev_aihub_ui_containers.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.aihub_ui_tf_deployer}"
}

# ── tf-deployer CI IAM (deploy-cloud-run) ────────────────────────────────
# .gitlab-ci.yml's deploy-cloud-run job runs `gcloud run deploy` as this same
# tf-deployer. Two grants, same shape as the writer above: without them the
# WIF token exchange still succeeds, and only the gcloud call itself 403s.

# 1 · Deploy/update the Cloud Run service. Project-scoped, not resource-
#     scoped: a per-service binding cannot exist before the service does, and
#     this SA is also what creates it the first time.
resource "google_project_iam_member" "gclt_aicoe_dev_aihub_ui_ci_run_admin" {
  project = var.gclt_aicoe_dev_aihub_ui_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${local.aihub_ui_tf_deployer}"
}

# 2 · actAs on the runtime identity. `gcloud run deploy` sets
#     --service-account=aihub-bff-sa, and setting a resource's runtime
#     identity to a *different* SA than the caller always needs
#     serviceAccountUser on that specific target SA — run.admin alone is not
#     enough and the deploy fails with "iam.serviceaccounts.actAs" denied.
#     Scoped to aihub_bff_sa only, not project-wide: tf-deployer must not be
#     able to run as arbitrary other service accounts in this project.
resource "google_service_account_iam_member" "gclt_aicoe_dev_aihub_ui_ci_run_as_bff" {
  service_account_id = "projects/${var.gclt_aicoe_dev_aihub_ui_project_id}/serviceAccounts/${local.aihub_bff_sa}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.aihub_ui_tf_deployer}"
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

# ── aihub-bff-sa runtime IAM ────────────────────────────────────────────
# Without these the container never becomes ready: the BFF reads both secrets
# during startup and a 403 there surfaces as a 503 on /readyz with
# "secrets: Failed to access secret".

# 1 · The two secrets the BFF loads at startup. This grant alone unblocks
#     container startup.
resource "google_secret_manager_secret_iam_member" "gclt_aicoe_dev_aihub_ui_bff_accessor" {
  for_each  = google_secret_manager_secret.gclt_aicoe_dev_aihub_ui_bff
  project   = var.gclt_aicoe_dev_aihub_ui_project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.aihub_bff_sa}"
}

# 2 · Session store. Firestore has no per-database IAM, so this is
#     project-scoped by necessity.
resource "google_project_iam_member" "gclt_aicoe_dev_aihub_ui_bff_firestore" {
  project = var.gclt_aicoe_dev_aihub_ui_project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${local.aihub_bff_sa}"
}

# 3 · Self-impersonation, for V4 signed URLs. Cloud Run's metadata credentials
#     carry no private key, so the SDK signs through the IAM signBlob API and
#     the SA must be able to impersonate itself. Missing this fails at request
#     time, not at startup — the container looks healthy and uploads break.
resource "google_service_account_iam_member" "gclt_aicoe_dev_aihub_ui_bff_self_signer" {
  service_account_id = "projects/${var.gclt_aicoe_dev_aihub_ui_project_id}/serviceAccounts/${local.aihub_bff_sa}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.aihub_bff_sa}"
}

# 4 · The session CMEK key is granted through the kms-ring module's key_grants
#     above (see the append-only note), not as a raw resource here.

output "gclt_aicoe_dev_aihub_ui_service_accounts" { value = module.gclt_aicoe_dev_aihub_ui_baseline.service_accounts }
output "gclt_aicoe_dev_aihub_ui_kms_key_ids" { value = module.gclt_aicoe_dev_aihub_ui_kms.key_ids }

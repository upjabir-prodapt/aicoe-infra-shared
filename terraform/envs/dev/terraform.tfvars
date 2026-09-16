environment      = "dev"
region           = "europe-west3"
analytics_region = "europe-west2" # need to change in europe west3 in prod

# Pinned to the already-live, cosmetically wrong name (GAP-REGISTER R-01) --
# do not "fix" this to aicoe-dev-ew3, that would try to destroy and rebuild
# the live, prevent_destroy-protected Apigee instance for a label.
apigee_instance_name = "aicoe-dev-ew1"

# ── 0-bootstrap ──────────────────────────────────────────────────────────
# aicoe-sharedwif IS the seed project. Already exists in GCP — see the LLD's
# Organisation, folder and project structure section for the folder tree. Not created by this Terraform; hosts the state
# bucket and the GitLab WIF pool/provider, per 0-bootstrap.
seed_project_id = "aicoe-sharedwif"

# One tf-deployer service account is created per entry here, including the
# seed project itself (it needs one too, to run the 1-org stage).
target_projects = [
  "aicoe-sharedwif",
  "gclt-aicoe-dev-network",
  "gclt-aicoe-dev-ingress",
  "gclt-aicoe-dev-apigee",
  "gclt-aicoe-dev-aihub-ui",
  "gclt-aicoe-dev-st",
  "gclt-aicoe-dev-llm",
  "gclt-aicoe-dev-auditlogs",
]

# ── 1-org ────────────────────────────────────────────────────────────────
# Read-only reference to the estate that already exists in GCP. Not created
# by this Terraform — see 1-org/main.tf's header comment.
existing_projects = {
  network   = "gclt-aicoe-dev-network"
  ingress   = "gclt-aicoe-dev-ingress"
  apigee    = "gclt-aicoe-dev-apigee"
  aihub-ui  = "gclt-aicoe-dev-aihub-ui"
  st        = "gclt-aicoe-dev-st"
  llm       = "gclt-aicoe-dev-llm"
  auditlogs = "gclt-aicoe-dev-auditlogs"
}

gitlab_issuer   = "https://amsgit01"
gitlab_audience = "https://iam.googleapis.com"
# Real clone paths confirmed 2026-08-12: all repos live under the
# code-scanning-toolset group. The Terraform repo plus every use-case app
# repo that deploys through this pool.
# shared-aihub-ui added 2026-09-02: the AI Hub BFF's build-and-push/
# deploy-cloud-run jobs (.gitlab-ci.yml's .gcp_wif) impersonate tf-deployer
# via this same pool, and the condition rejects anything not listed here —
# omitting it fails CI with "unauthorized_client: ... rejected by the
# attribute condition", not a Terraform error, so it is easy to miss.
allowed_repositories = [
  "code-scanning-toolset/aicoe-terraform",
  # Corrected 2026-09-06: "translation" and "sales-agent" (no "shared-"
  # prefix) never matched any real GitLab project_path -- confirmed live via
  # a real CI failure ("unauthorized_client: ... rejected by the attribute
  # condition") whose checkout path was .../code-scanning-toolset/
  # shared-salesagent/.git, not .../sales-agent/.git. Every app repo in this
  # GitLab group actually uses the shared-* prefix, matching shared-aihub-ui
  # below, which was already correct.
  "code-scanning-toolset/shared-translation",
  "code-scanning-toolset/shared-salesagent",
  "code-scanning-toolset/shared-aihub-ui",
]

# The pool that actually federates Entra for this platform. Two decoys exist
# in the org (colt-aiappsui-auth, colt-dev-aiappsui-auth); pointing at either
# builds a valid principalSet:// against a pool containing none of our users,
# and IAP then denies everyone with no diagnostic.
workforce_pool = "colt-aicoe-aihubui-auth"

# Entra object ID of App-AICoE-UI-Users — an object ID, not a display name or
# sAMAccountName. Sole entry in the groups[] claim of a live workforce-pool
# ID token; consumed by 6a's principalSet://.../group/<id> IAP binding.
ui_user_group = "874d0e37-2dd6-4b85-acd3-fcc2a9cc6e79"

# ── 2-foundations ────────────────────────────────────────────────────────
# The AI COE folder. Every folder-level sink and audit-log config in
# 2-foundations attaches here. Numeric id, no "folders/" prefix.
# Verified against the live estate on 2026-08-12: folders/846301442455.
folder_id = "846301442455"

# org_log_project REMOVED — decision 2026-08-12: logs go only to the
# 400-day bucket in gclt-aicoe-dev-auditlogs. No enterprise-logging copy
# (sink 2) and no SIEM Pub/Sub copy (sink 3); both removed from
# 2-foundations/gclt-aicoe-dev-auditlogs.tf.

# apigee_llm_runtime_sa, apigee_runtime_sa and worker_invoker_sa are NO
# LONGER set here. They are created by 2-foundations and published as scalar
# outputs named exactly for the consuming stages' variables, arriving through
# the .auto.tfvars.json artifact handoff. A hand-typed value here is how a
# misspelled principal silently leaves the AI gateway unenforced.

# The Certificate Manager certs in 2-foundations are gated behind this flag so
# that stage could first apply and create the empty PEM/key secret containers.
# Those secrets are now populated and both certs exist, so the flag must stay
# true: it defaults to false, and any plan of 2-foundations without it DESTROYS
# cert-aihub and cert-backend and blanks the two certificate_id outputs that
# 6c consumes. It was previously passed only as an ad-hoc
# -var="certs_enabled=true" on the command line, which made the destroy the
# default behaviour of a plain plan.
certs_enabled = true

# ── 6c · gclt-aicoe-dev-ingress ──────────────────────────────────────────
# aihub_certificate_id and backend_certificate_id are NOT set here. They are
# created by 2-foundations (Certificate Manager) and arrive through
# vars-handoff/2-foundations.auto.tfvars.json.
#
# They must not be re-declared in this file: CI copies the handoff files into
# the stage directory and then passes -var-file=envs/dev/terraform.tfvars on
# the command line (terraform/ci/job-templates.yml:46,53). A CLI -var-file
# outranks an *.auto.tfvars.json, so a placeholder here silently overrides the
# real certificate ids.

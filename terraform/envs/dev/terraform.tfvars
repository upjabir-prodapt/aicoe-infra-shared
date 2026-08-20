environment      = "dev"
region           = "europe-west3"
analytics_region = "europe-west2" # need to change in europe west3 in prod

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
# Real clone paths confirmed 2026-08-12: all three repos live under the
# code-scanning-toolset group. The Terraform repo plus the two use-case app
# repos that deploy through this pool.
allowed_repositories = [
  "code-scanning-toolset/aicoe-terraform",
  "code-scanning-toolset/translation",
  "code-scanning-toolset/sales-agent",
]

workforce_pool = "colt-aiappsui-auth"
ui_user_group  = "REPLACE_ME"

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

# ── 6c · gclt-aicoe-dev-ingress ──────────────────────────────────────────
# Certificate Manager certificate ids for the two load balancer frontends.
# These become outputs of the 2-certificates stage once it exists; until
# then they remain placeholders gated on P4 (DNS-01 automation).
aihub_certificate_id   = "REPLACE_ME"
backend_certificate_id = "REPLACE_ME"

environment      = "dev"
region           = "europe-west1"
analytics_region = "europe-west2"     # EU, per the residency policy

# ── 0-bootstrap ──────────────────────────────────────────────────────────
# aicoe-sharedwif IS the seed project. Already exists in GCP — see the LLD's
# Organisation, folder and project structure section for the folder tree. Not created by this Terraform; hosts the state
# bucket and the GitLab WIF pool/provider, per 0-bootstrap.
seed_project_id  = "aicoe-sharedwif"

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

gitlab_issuer      = "https://amsgit01.colt.net"
gitlab_audience    = "https://gitlab.example.colt.net"
allowed_repository = "aicoe/terraform"

workforce_pool = "colt-aiappsui-auth"
ui_user_group  = "REPLACE_ME"

# ── 2-foundations ────────────────────────────────────────────────────────
# The AI COE folder. Every folder-level sink and audit-log config in
# 2-foundations attaches here. Numeric id, no "folders/" prefix.
folder_id = "REPLACE_ME"

# The enterprise logging project that sink 2 copies into.
org_log_project = "REPLACE_ME"

# The Apigee llm runtime service account, in name@project.iam.gserviceaccount.com
# form. This is the single identity granted roles/aiplatform.user, which is
# what makes the AI gateway mandatory rather than advisory — see the LLD's
# decision log, D-30. No workload service account may hold that role.
apigee_llm_runtime_sa = "REPLACE_ME"

# ── 6b · gclt-aicoe-dev-st ───────────────────────────────────────────────
# The Apigee int runtime service account, granted run.invoker on the two
# usecase services, and the Cloud Tasks identity that invokes the worker.
# Both are created in 2-foundations; recorded here until that handoff is
# wired through as an artifact output.
apigee_runtime_sa = "REPLACE_ME"
worker_invoker_sa = "REPLACE_ME"

# ── 6c · gclt-aicoe-dev-ingress ──────────────────────────────────────────
# Certificate Manager certificate ids for the two load balancer frontends.
# Nothing in this repository creates them: per the LLD, certificates are
# publicly issued for privately resolved names with DNS-01 validation, which
# is pre-requisite gate P4. Fill these in once that gate clears.
aihub_certificate_id   = "REPLACE_ME"
backend_certificate_id = "REPLACE_ME"

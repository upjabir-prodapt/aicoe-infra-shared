# Production. Same code, different values — that is the point of the split.
# NOT YET IN USE — see the LLD's Production Promotion Model. Production does
# not exist yet; these values are placeholders to be filled in when it does.
environment      = "prod"
region           = "europe-west1"
analytics_region = "europe-west2" # EU, per the residency policy

# ── 0-bootstrap ──────────────────────────────────────────────────────────
# Whether production shares aicoe-sharedwif or gets its own bootstrap
# project is an open decision — see the LLD's Production Promotion Model. Placeholder assumes shared.
seed_project_id = "aicoe-sharedwif"

target_projects = [
  "aicoe-sharedwif",
  "REPLACE_ME-prod-network",
  "REPLACE_ME-prod-ingress",
  "REPLACE_ME-prod-apigee",
  "REPLACE_ME-prod-aihub-ui",
  "REPLACE_ME-prod-st",
  "REPLACE_ME-prod-llm",
  "REPLACE_ME-prod-auditlogs",
]

# ── 1-org ────────────────────────────────────────────────────────────────
# Read-only reference to the estate that already exists in GCP. Fill in once
# the production projects are provisioned by the platform team — this
# Terraform does not create them, in production any more than it does in dev.
existing_projects = {
  network   = "REPLACE_ME-prod-network"
  ingress   = "REPLACE_ME-prod-ingress"
  apigee    = "REPLACE_ME-prod-apigee"
  aihub-ui  = "REPLACE_ME-prod-aihub-ui"
  st        = "REPLACE_ME-prod-st"
  llm       = "REPLACE_ME-prod-llm"
  auditlogs = "REPLACE_ME-prod-auditlogs"
}

gitlab_issuer      = "https://amsgit01.colt.net"
gitlab_audience    = "https://gitlab.example.colt.net"
allowed_repository = "aicoe/terraform"

workforce_pool = "colt-aiappsui-auth"
ui_user_group  = "REPLACE_ME"

# Production. Same code, different values — that is the point of the split.
# NOT YET IN USE — see the LLD's Production Promotion Model. Production does
# not exist yet; these values are placeholders to be filled in when it does.
environment = "prod"
region      = "europe-west1" # STALE placeholder, predates the platform's europe-west3
# standardization (see dev's own region value and GAP-REGISTER
# R-05) -- not corrected here because region also drives other
# stages' resources this pass didn't audit; revisit before prod
# is actually provisioned, don't copy this value blindly.
analytics_region = "europe-west2" # EU, per the residency policy

# Correct from day one -- do NOT repeat GAP-REGISTER R-01's mistake. The
# Apigee instance's own location is hardcoded to europe-west3 in
# terraform/4-apigee/main.tf regardless of var.region above, so "ew3" here
# is right even though var.region (still a stale placeholder) says west1.
apigee_instance_name = "aicoe-prod-ew3"

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

# Prod must NOT reuse the Dev workforce pool (docs/18 §1). Create a separate
# prod pool + Entra app registration, then put its Pool ID here.
# Dev uses colt-aicoe-aihubui-auth; colt-aiappsui-auth and colt-dev-aiappsui-auth
# are earlier-naming pools that still exist in the org and must not be used.
workforce_pool = "REPLACE_ME"
ui_user_group  = "REPLACE_ME"

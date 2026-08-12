# 1-org — reference to the existing project estate.
#
# CHANGED. Earlier revisions of this stage were a YAML-driven project
# factory: it created every project, set folder-level organisation policy,
# and drove Shared VPC service-project attachment from the same YAML. That
# is no longer the case.
#
# The platform team confirmed the estate is already provisioned in the
# console, under this folder structure:
#
#   Colt Organisation
#   └── AI COE                              org policy + hierarchical
#       │                                   firewall policy attach HERE
#       ├── shared
#       │   ├── aicoe-sharedwif             THE SEED PROJECT (0-bootstrap's
#       │   │                               seed_project_id). GitLab WIF
#       │   │                               pool + providers
#       │   ├── gclt-aicoe-dev-auditlogs
#       │   ├── network/gclt-aicoe-dev-network
#       │   ├── ingress/gclt-aicoe-dev-ingress
#       │   ├── apigee/gclt-aicoe-dev-apigee
#       │   ├── aihub/gclt-aicoe-dev-aihub-ui
#       │   └── llm/gclt-aicoe-dev-llm
#       └── Dev
#           └── usecases/gclt-aicoe-dev-st
#
# Both the projects and the organisation policy (including the folder's
# hierarchical firewall policy) are owned and maintained by the platform /
# cloud team directly — NOT by this Terraform. This stage therefore:
#
#   - does NOT create projects (no google_project resource)
#   - does NOT create folders
#   - does NOT set organisation policy (no google_folder_organization_policy)
#   - does NOT drive Shared VPC attachment (that is 3-network's job alone —
#     removing it here also removes a resource overlap the two stages used
#     to have over the same association)
#
# It only reads back the projects that already exist, so downstream stages
# have project numbers to work with, and this file remains the one place
# that records the estate's role → project ID mapping.
#
# If your organisation DOES want project creation and org policy back under
# Terraform, that is a deliberate re-adoption of the project-factory pattern
# described in docs/14-terraform-structure-decision.md and terraform/README.md
# — do not silently reintroduce `google_project` or
# `google_folder_organization_policy` resources here without updating those
# documents and the LLD's decision log, or this file will start fighting
# whoever manages the console side by hand.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "environment" {
  type        = string
  description = "Kept for parity with other stages. Not used to select or create anything here."
}

# ── the estate, as it already exists in GCP ─────────────────────────────
# role => project ID. Update this map by hand when a project is added or
# removed in the console — there is deliberately no automated "destroy on
# file deletion" guard rail here any more, because there is no longer a
# file per project to delete. Supplied per environment in envs/<env>/terraform.tfvars.
variable "existing_projects" {
  type        = map(string)
  description = "role => project ID, for every project already provisioned in GCP (network, ingress, apigee, aihub-ui, st, llm, auditlogs)."
}

data "google_project" "p" {
  for_each   = var.existing_projects
  project_id = each.value
}

output "project_ids" {
  value = { for k, v in data.google_project.p : k => v.project_id }
}
output "project_numbers" {
  value = { for k, v in data.google_project.p : k => v.number }
}

# ── what used to live here ──────────────────────────────────────────────
# Removed in this revision:
#   - google_project "p"                         — project creation
#   - check "project_count" / "required_labels"  — guard rails for the YAML
#                                                   factory, meaningless once
#                                                   there is no factory
#   - google_project_service "svc"               — API enablement now
#                                                   assumed handled wherever
#                                                   the platform team manages
#                                                   the project, or belongs
#                                                   in 2-foundations
#   - google_compute_shared_vpc_service_project "attach"
#                                                 — Shared VPC attachment;
#                                                   3-network is now the only
#                                                   stage that touches it
#   - google_folder_organization_policy (boolean, resource_locations,
#     run_ingress, drs)                          — organisation policy; owned
#                                                   by the platform team at
#                                                   the AI COE folder
#
# Cost-attribution labelling (usecase / cost-centre / owner) is therefore no
# longer enforced by a Terraform check or by ci/policy-check.sh. It is an
# open item for whoever provisions projects in the console — see the LLD's
# risk register (new risk on org-policy/labelling drift being invisible to
# this codebase).

# ── individually-named outputs, for the stage-2 handoff ─────────────────
# Stages exchange values as `terraform output -json | jq map_values(.value)`
# written to a .auto.tfvars.json artifact, so an output name here must match
# the consuming stage's VARIABLE name exactly. The `project_ids` map above
# cannot satisfy 2-foundations' per-project variables, so each is republished
# under the name that stage declares.
output "gclt_aicoe_dev_network_project_id"   { value = data.google_project.p["network"].project_id }
output "gclt_aicoe_dev_ingress_project_id"   { value = data.google_project.p["ingress"].project_id }
output "gclt_aicoe_dev_apigee_project_id"    { value = data.google_project.p["apigee"].project_id }
output "gclt_aicoe_dev_aihub_ui_project_id"  { value = data.google_project.p["aihub-ui"].project_id }
output "gclt_aicoe_dev_st_project_id"        { value = data.google_project.p["st"].project_id }
output "gclt_aicoe_dev_llm_project_id"       { value = data.google_project.p["llm"].project_id }
output "gclt_aicoe_dev_auditlogs_project_id" { value = data.google_project.p["auditlogs"].project_id }

# Consumed by 4-apigee and 6c-ingress, which reference the network and Apigee
# projects by these names.
output "network_project_id" { value = data.google_project.p["network"].project_id }
output "apigee_project_id"  { value = data.google_project.p["apigee"].project_id }

# Consumed by 3-network for Shared VPC service-project attachment.
output "service_projects" {
  value = [for k, v in data.google_project.p : v.project_id if k != "network"]
}

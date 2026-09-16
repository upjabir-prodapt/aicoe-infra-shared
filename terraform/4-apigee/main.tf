# static/apigee — the organisation and instance.
#
# Slow: 30 to 60 minutes. Immutable: five settings below cannot be changed
# afterwards. Gated behind a manual job in the pipeline for that reason.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {} # bucket and prefix from -backend-config
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
  }
}

# Regional control-plane endpoint. Must be a multi-region host (eu-, us-, asia-),
# never a specific-region host like "europe-west1-apigee..." — that host doesn't
# exist and 404s. "eu" is what satisfies gcp.resourceLocations here, since the
# effective policy on this project allows all EU regions.
provider "google" {
  apigee_custom_endpoint = "https://de-apigee.googleapis.com/v1/"
}
provider "google-beta" {
  apigee_custom_endpoint = "https://de-apigee.googleapis.com/v1/"
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "analytics_region" { type = string }
variable "billing_type" {
  type    = string
  default = "PAYG"
}

# The Apigee instance's own name -- deliberately NOT derived from
# var.region or var.environment (unlike almost everything else in this
# stage). It must be set explicitly per environment in envs/<env>/terraform.tfvars:
# see GAP-REGISTER R-01. dev is pinned to its already-live, cosmetically
# wrong "aicoe-dev-ew1" (name is ForceNew + prevent_destroy -- renaming
# means destroying and rebuilding the whole instance, judged not worth it
# for a label). prod must be set correctly ("aicoe-prod-ew3") from the
# moment it's first created, so this mistake is not repeated.
variable "apigee_instance_name" { type = string }

# ── step 1 · force the service agent, before any KMS binding ────────────
module "agents" {
  source     = "../modules/service-agents"
  project_id = var.project_id
  services   = ["apigee.googleapis.com"]
}

# ── step 2 · keys, with the agent granted before anything consumes them ──
module "kms_db" {
  source     = "../modules/kms-ring"
  project_id = var.project_id
  location   = "europe-west3" # Matches control plane location DE
  ring_name  = "apigee-db"
  keys = {
    "runtime-db" = {}
  }
  key_grants = {
    "runtime-db" = [module.agents.emails["apigee.googleapis.com"]]
  }
}

module "kms_disk" {
  source     = "../modules/kms-ring"
  project_id = var.project_id
  location   = "europe-west3" # Matches control plane and instance location
  ring_name  = "apigee-disk"
  keys = {
    "instance-disk" = {}
  }
  key_grants = {
    "instance-disk" = [module.agents.emails["apigee.googleapis.com"]]
  }
}

# ── step 3 · the organisation ────────────────────────────────────────────
resource "google_apigee_organization" "org" {
  project_id   = var.project_id
  billing_type = var.billing_type

  # Regional API-consumer-data residency. Independent of the control-plane
  # location set by the provider endpoint above — both must stay inside the
  # allowed EU set, and europe-west1 does.
  api_consumer_data_location = "europe-west3"

  # IMMUTABLE. Peering is non-transitive, so it would prevent other usecase
  # VPCs ever consuming this gateway. Do not set authorized_network.
  disable_vpc_peering = true

  # IMMUTABLE. Cannot be added to an existing organisation.
  runtime_database_encryption_key_name = module.kms_db.key_ids["runtime-db"]

  # Waits for the IAM binding, not merely for the key to exist.
  depends_on = [module.kms_db, module.kms_disk]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_apigee_instance" "instance" {
  name                     = var.apigee_instance_name
  location                 = "europe-west3" # Aligned with Germany control plane
  org_id                   = google_apigee_organization.org.id
  disk_encryption_key_name = module.kms_disk.key_ids["instance-disk"]

  # Only these projects may create a Private Service Connect endpoint to
  # this instance. An unpinned list is an unlocked side door.
  # Found live 2026-09-05 (during the int-environment-type fix): the actual
  # instance also has var.project_id (this Apigee project itself) in its
  # accept list, added outside Terraform at some point -- plausibly needed
  # for Apigee's own control plane to reach its own instance. Reconciled
  # here rather than silently dropped, since removing a live PSC consumer
  # entry without understanding why it's there risks breaking connectivity
  # that's currently working.
  #
  # gclt_aicoe_dev_ingress_project_id added 2026-09-11: the R-06 northbound
  # LB's PSC NEG (apigee-psc-neg, 5-network-psc/main.tf) lives in the
  # gclt-aicoe-dev-ingress project (moved there from network the same day,
  # to satisfy Certificate Manager's same-project constraint on the target
  # HTTPS proxy). Without this entry the NEG's PSC connection to this
  # instance sits stuck in `PENDING` forever -- confirmed live: the LB's
  # client-facing TLS always worked (Certificate Manager terminates that at
  # the edge, unrelated to backend reachability), but every real HTTP
  # request through it failed fast with 503, and an Apigee debug session
  # captured zero transactions, proving requests never reached Apigee's
  # proxy engine at all. See docs/BUILD-LOG.md entry #36.
  consumer_accept_list = [var.network_project_id, var.project_id, var.gclt_aicoe_dev_ingress_project_id]

  lifecycle { prevent_destroy = true }
}

variable "network_project_id" { type = string }
variable "gclt_aicoe_dev_ingress_project_id" { type = string } # from 1-org, see consumer_accept_list comment above

# ── step 4 · environments ────────────────────────────────────────────────
# CORRECTED 2026-09-05, was wrong: this comment used to say "int is Base:
# every policy in the user API proxy is Standard" -- true, but irrelevant.
# Base environments cannot host API Products at all (confirmed live: creating
# one against `int` failed with "Base environments do not support configuring
# API Products"), regardless of whether any policy is Extensible. docs/20's
# entire `int` proxy design requires an API Product (VerifyAPIKey resolves the
# calling developer app via one) -- Base was never viable for this proxy.
# Google's own comparison table confirms "API Products and Developer Portals"
# is N/A on Base, Available from Intermediate up
# (docs.cloud.google.com/apigee/docs/api-platform/reference/pay-as-you-go-environment-types).
# llm is Intermediate for the reason the old comment gave (both LLM token
# policies are Extensible, and Extensible policies deploy only to
# Intermediate/Comprehensive) -- that reasoning was correct and unaffected by
# this fix.
resource "google_apigee_environment" "int" {
  org_id = google_apigee_organization.org.id
  name   = "int"
  type   = "INTERMEDIATE"
}

resource "google_apigee_environment" "llm" {
  org_id = google_apigee_organization.org.id
  name   = "llm"
  type   = "INTERMEDIATE"
}

resource "google_apigee_instance_attachment" "int" {
  instance_id = google_apigee_instance.instance.id
  environment = google_apigee_environment.int.name
}

resource "google_apigee_instance_attachment" "llm" {
  instance_id = google_apigee_instance.instance.id
  environment = google_apigee_environment.llm.name
}

resource "google_apigee_envgroup" "aihub" {
  org_id = google_apigee_organization.org.id
  name   = "aihub-int"
  # Must match the private zone published by 3-network (aicoedev-int.colt.net)
  # and the A-record in 5-network-psc. Apigee routes by Host header, so a
  # spelling mismatch means live callers match no env group at all.
  hostnames = ["aihub-api.aicoedev-int.colt.net"]
}

resource "google_apigee_envgroup" "llm" {
  org_id    = google_apigee_organization.org.id
  name      = "llm-int"
  hostnames = ["llm.aicoedev-int.colt.net"]
}

resource "google_apigee_envgroup_attachment" "aihub" {
  envgroup_id = google_apigee_envgroup.aihub.id
  environment = google_apigee_environment.int.name
}

resource "google_apigee_envgroup_attachment" "llm" {
  envgroup_id = google_apigee_envgroup.llm.id
  environment = google_apigee_environment.llm.name
}

# ── outputs consumed by network/psc and infra/apigee ────────────────────
output "org_id" { value = google_apigee_organization.org.id }
output "instance_service_attachment" {
  description = "Consumed by network/psc to create the endpoint at 192.168.6.146."
  value       = google_apigee_instance.instance.service_attachment
}
# Consumed by infra/ingress's sa-backends service attachment consumer_accept_lists.
# The PSC connection Apigee actually opens comes from ITS OWN internal tenant
# project (this value), not from the org's own project id (gclt-aicoe-dev-apigee)
# -- confirmed live 2026-09-07: a service attachment whose accept list only
# names the org's project id leaves every real connection attempt stuck at
# connectionState PENDING (visible bug: state ACTIVE, connectionState PENDING,
# never auto-accepting), because the connecting consumerNetwork's project is
# this tenant project, not the org's.
output "apigee_tenant_project_id" {
  description = "Apigee's own internal tenant project -- the real PSC consumer identity, distinct from the org's project id (gclt-aicoe-dev-apigee). Deliberately a different output name from 1-org's apigee_project_id to avoid a silent same-name handoff collision between the two artifacts."
  value       = google_apigee_organization.org.apigee_project_id
}
output "environments" {
  value = { int = google_apigee_environment.int.name, llm = google_apigee_environment.llm.name }
}
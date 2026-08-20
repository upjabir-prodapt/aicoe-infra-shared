# static/apigee — the organisation and instance.
#
# Slow: 30 to 60 minutes. Immutable: five settings below cannot be changed
# afterwards. Gated behind a manual job in the pipeline for that reason.
 
terraform {
  required_version = ">= 1.9"
  backend "gcs" {}                       # bucket and prefix from -backend-config
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 6.0" }
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

variable "project_id"       { type = string }
variable "region"           { type = string }
variable "analytics_region" { type = string }
variable "billing_type" {
  type    = string
  default = "PAYG"
}
 
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
    "runtime-db"    = {}
  }
  key_grants = {
    "runtime-db"    = [module.agents.emails["apigee.googleapis.com"]]
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
  project_id       = var.project_id
  analytics_region = var.analytics_region
  billing_type     = var.billing_type
 
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
  name                     = "aicoe-dev-ew1"
  location                 = "europe-west3" # Aligned with Germany control plane
  org_id                   = google_apigee_organization.org.id
  disk_encryption_key_name = module.kms_disk.key_ids["instance-disk"]
 
  # Only these projects may create a Private Service Connect endpoint to
  # this instance. An unpinned list is an unlocked side door.
  consumer_accept_list = [var.network_project_id]
 
  lifecycle { prevent_destroy = true }
}
 
variable "network_project_id" { type = string }
 
# ── step 4 · environments ────────────────────────────────────────────────
# int is Base: every policy in the user API proxy is Standard.
# llm is Intermediate: both LLM token policies are Extensible, and
# extensible policies deploy only to intermediate or comprehensive.
 
resource "google_apigee_environment" "int" {
  org_id = google_apigee_organization.org.id
  name   = "int"
  type   = "BASE"
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
  org_id    = google_apigee_organization.org.id
  name      = "aihub-int"
  hostnames = ["aihub-api.aicoe-dev-int.colt.net"]
}
 
resource "google_apigee_envgroup" "llm" {
  org_id    = google_apigee_organization.org.id
  name      = "llm-int"
  hostnames = ["llm.aicoe-dev-int.colt.net"]
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
output "environments" {
  value = { int = google_apigee_environment.int.name, llm = google_apigee_environment.llm.name }
}
# infra/apigee — the southbound endpoint attachment and runtime config.
# Last in the order: it consumes the service attachment published by
# infra/ingress.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

# This org has Data Residency enabled (apiConsumerDataLocation: europe-west3)
# and is only reachable through the regional control-plane host, never the
# global apigee.googleapis.com default -- confirmed live 2026-09-07: every
# google_apigee_* resource here failed with a misleading "resource
# organizations/gclt-aicoe-dev-apigee not found" (404) without this override,
# even though the org demonstrably exists (reachable directly at this same
# host via curl). Matches the identical override already required, and
# already present, in terraform/4-apigee/main.tf -- that stage's own comment
# explains why: must be a multi-region host (eu-/us-/asia-), never a
# specific-region host like "europe-west1-apigee...", which doesn't exist.
provider "google" {
  apigee_custom_endpoint = "https://de-apigee.googleapis.com/v1/"
}

variable "project_id" { type = string }
variable "region" { type = string }
# ── inputs from upstream stages ─────────────────────────────────────────
variable "org_id" {
  type        = string
  description = "From stage 4."
}
variable "backend_service_attachment_id" {
  type        = string
  description = "From stage 6c. Published by the Backend load balancer."
}

resource "google_apigee_endpoint_attachment" "backends" {
  org_id                 = var.org_id
  endpoint_attachment_id = "backends-attachment"
  location               = var.region
  service_attachment     = var.backend_service_attachment_id
}

# Key value maps. Values are managed by the proxy pipeline, not here —
# Terraform creates the container, apigeecli populates it.
resource "google_apigee_environment_keyvaluemaps" "int_backend_audiences" {
  env_id = "${var.org_id}/environments/int"
  name   = "backend-audiences"
}

resource "google_apigee_environment_keyvaluemaps" "llm_models" {
  env_id = "${var.org_id}/environments/llm"
  name   = "allowed-models"
}

output "endpoint_attachment_host" {
  description = "Used as the target server host in the int environment."
  value       = google_apigee_endpoint_attachment.backends.host
}

# The Target Server the aihub-api-v1 proxy's single TargetEndpoint routes
# through (docs/09 §22.3's design). Managed here, not by the proxy pipeline,
# for the same reason the KVM containers above are: it's environment
# plumbing that must exist before the proxy bundle can reference it, not
# proxy-owned config -- and its host value only exists as this stage's own
# endpoint_attachment output, so it cannot be a static value hand-typed into
# a JSON file the way KVM entries are.
resource "google_apigee_target_server" "backends" {
  name       = "backends"
  env_id     = "${var.org_id}/environments/int"
  host       = google_apigee_endpoint_attachment.backends.host
  port       = 443
  is_enabled = true

  # A public Google-trusted certificate is NOT what's presented here: the
  # backend load balancer (6c) uses the private CA-backed Certificate
  # Manager certs (cert-backend), not a publicly trusted one, since nothing
  # public ever reaches this internal ILB. ignore_validation_errors=true is
  # deliberate, not a shortcut: the actual security boundary is PSC network
  # isolation (only gclt-aicoe-dev-apigee's tenant project can reach this
  # endpoint attachment at all, per 6c's consumer_accept_lists) plus the
  # GoogleIDToken the proxy still sends and Cloud Run's own run.invoker
  # check still enforces -- identical trust model to every other internal
  # hop in this platform.
  s_sl_info {
    enabled                  = true
    ignore_validation_errors = true
  }
}

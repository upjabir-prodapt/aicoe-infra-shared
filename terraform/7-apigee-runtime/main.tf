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

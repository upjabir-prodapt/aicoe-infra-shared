# Force Google service agents into existence.
#
# WHY THIS MODULE EXISTS
# Service agents are created lazily — often only the first time the service
# actually does something. So a KMS IAM binding that references one fails on
# a fresh project with "service account does not exist", and the error names
# the key rather than the missing account.
#
# The usual workaround is "run terraform apply twice". That is not a
# workaround, it is a latent failure that reappears in every new environment.
# This module creates the agents deliberately, first.

variable "project_id" { type = string }
variable "services" {
  type        = list(string)
  description = "API service names, for example apigee.googleapis.com"
}

resource "google_project_service_identity" "agent" {
  provider = google-beta
  for_each = toset(var.services)
  project  = var.project_id
  service  = each.value
}

data "google_project" "this" {
  project_id = var.project_id
}

# Deterministic per-service agent email patterns (Google-documented). The
# google_project_service_identity resource does not reliably populate `email`
# for every service (bigquery and storage return null even after the agent
# exists), so build the address from the project number instead.
locals {
  agent_email_patterns = {
    "bigquery.googleapis.com"         = "bq-${data.google_project.this.number}@bigquery-encryption.iam.gserviceaccount.com"
    "storage.googleapis.com"          = "service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com"
    "aiplatform.googleapis.com"       = "service-${data.google_project.this.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
    "artifactregistry.googleapis.com" = "service-${data.google_project.this.number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
    "firestore.googleapis.com"        = "service-${data.google_project.this.number}@gcp-sa-firestore.iam.gserviceaccount.com"
    "iap.googleapis.com"              = "service-${data.google_project.this.number}@gcp-sa-iap.iam.gserviceaccount.com"
    "logging.googleapis.com"          = "service-${data.google_project.this.number}@gcp-sa-logging.iam.gserviceaccount.com"
    "pubsub.googleapis.com"           = "service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
    "apigee.googleapis.com"           = "service-${data.google_project.this.number}@gcp-sa-apigee.iam.gserviceaccount.com"
    "secretmanager.googleapis.com"      = "service-${data.google_project.this.number}@gcp-sa-secretmanager.iam.gserviceaccount.com"
  }
}

output "emails" {
  description = "Map of service name to service agent email, for KMS and other bindings."
  # Prefer the resource's email when populated; fall back to the documented
  # pattern for services where the resource returns null.
  value = { for k, v in google_project_service_identity.agent : k => coalesce(v.email, lookup(local.agent_email_patterns, k, null)) }
}

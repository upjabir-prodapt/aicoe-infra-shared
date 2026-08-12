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

output "emails" {
  description = "Map of service name to service agent email, for KMS and other bindings."
  value       = { for k, v in google_project_service_identity.agent : k => v.email }
}

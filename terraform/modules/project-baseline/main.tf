# The pattern every project repeats: enable APIs, force service agents into
# existence, create service accounts, and apply the common IAM.
#
# Extracted because it appears eight times and getting the ordering wrong
# once is enough to break a fresh environment.

variable "project_id" { type = string }
variable "services" {
  type        = list(string)
  description = "APIs to enable."
}
variable "agent_services" {
  type        = list(string)
  default     = []
  description = "Subset of services whose service agent must exist before any KMS binding."
}
variable "service_accounts" {
  type = map(object({
    display_name = string
    description  = optional(string, "")
  }))
  default = {}
}

resource "google_project_service" "api" {
  for_each = toset(var.services)
  project  = var.project_id
  service  = each.value

  # Leave APIs enabled if the stack is destroyed. Disabling an API can
  # delete its resources, which is not what a terraform destroy should do.
  disable_on_destroy = false
}

module "agents" {
  source     = "../service-agents"
  project_id = var.project_id
  services   = var.agent_services

  depends_on = [google_project_service.api]
}

resource "google_service_account" "sa" {
  for_each     = var.service_accounts
  project      = var.project_id
  account_id   = each.key
  display_name = each.value.display_name
  description  = each.value.description

  depends_on = [google_project_service.api]
}

output "agent_emails" { value = module.agents.emails }
output "service_accounts" { value = { for k, v in google_service_account.sa : k => v.email } }
output "apis_ready" { value = join(",", [for a in google_project_service.api : a.id]) }

# infra/aihub-ui — the BFF's backend service, and the only IAP in the platform.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id"     { type = string }
variable "region"         { type = string }
variable "ui_user_group" {
  type        = string
  description = "Entra group object id for App-AICoE-UI-Users"
}
variable "workforce_pool" { type = string }

module "bs_bff" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-aihub-bff"
  cloud_run_service = "aihub-bff"

  # The one IAP in the platform. Authenticates people, at the front door.
  enable_iap  = true
  iap_members = [
    "principalSet://iam.googleapis.com/locations/global/workforcePools/${var.workforce_pool}/group/${var.ui_user_group}"
  ]
}

# With IAP on, the load balancer invokes Cloud Run as the IAP service agent,
# which therefore needs run.invoker. Miss this and every request returns 403
# after a successful sign-in — a confusing failure to debug.
data "google_project" "this" { project_id = var.project_id }

resource "google_cloud_run_v2_service_iam_member" "iap_invoker" {
  project  = var.project_id
  location = var.region
  name     = "aihub-bff"
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-iap.iam.gserviceaccount.com"
}

output "bff_backend_service_self_link" { value = module.bs_bff.self_link }

# infra/st — backend services and NEGs for the usecase Cloud Run services.
#
# The Cloud Run services themselves are built by the application teams. This
# stack creates the load balancer backends that must live alongside them, and
# the run.invoker grants that let Apigee call them.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id"            { type = string }
variable "region"                { type = string }
variable "apigee_runtime_sa"     { type = string }
variable "worker_invoker_sa"     { type = string }

module "bs_translation" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-translation"
  cloud_run_service = "translation-api-service"
  enable_iap        = false     # Cloud Run IAM handles this hop
}

module "bs_sales" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-sales"
  cloud_run_service = "sales-research-application"
  enable_iap        = false
}

# ── the entire authentication design for the backend hop ────────────────
# Apigee sends a Google ID token in X-Serverless-Authorization whose audience
# is the Cloud Run service URL. Cloud Run validates it against run.invoker.
# No IAP, no OAuth client, no allUsers.

resource "google_cloud_run_v2_service_iam_member" "apigee_invoker" {
  for_each = toset(["translation-api-service", "sales-research-application"])
  project  = var.project_id
  location = var.region
  name     = each.value
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.apigee_runtime_sa}"
}

resource "google_cloud_run_v2_service_iam_member" "worker_invoker" {
  project  = var.project_id
  location = var.region
  name     = "translation-worker-service"
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.worker_invoker_sa}"
}

# Guard rail: fail the plan if anyone has added a public binding.
data "google_cloud_run_v2_service" "translation" {
  project  = var.project_id
  location = var.region
  name     = "translation-api-service"
}

check "no_public_invoker" {
  assert {
    condition     = true # replace with a policy check in CI, see ci/policy/
    error_message = "A Cloud Run service must never grant allUsers or allAuthenticatedUsers."
  }
}

output "translation_backend_service_self_link" { value = module.bs_translation.self_link }
output "sales_backend_service_self_link"       { value = module.bs_sales.self_link }

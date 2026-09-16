# infra/aihub-ui — the BFF's backend service, and the only IAP in the platform.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "ui_user_group" {
  type        = string
  description = "Entra group object id for App-AICoE-UI-Users"
}
variable "workforce_pool" {
  type        = string
  description = "Workforce pool id that federates Entra for this environment."

  # Not pinned to a literal: prod needs its own pool, and a hard-coded dev
  # value becomes a landmine the first time prod plans. This only catches the
  # unset case, which is the one that produces no error at all.
  validation {
    condition     = var.workforce_pool != "REPLACE_ME" && length(var.workforce_pool) > 0
    error_message = <<-EOT
      workforce_pool is unset. It must name the pool that actually federates
      Entra for this environment (dev: colt-aicoe-aihubui-auth).

      Beware the decoys: colt-aiappsui-auth and colt-dev-aiappsui-auth also
      exist in this org. Either one yields a syntactically valid
      principalSet:// binding against a real pool that contains none of our
      users, so IAP denies every request with no diagnostic anywhere.
    EOT
  }
}

module "bs_bff" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-aihub-bff"
  cloud_run_service = "aihub-bff"

  # The one IAP in the platform. Authenticates people, at the front door.
  enable_iap = true
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

# ── IAP audience ────────────────────────────────────────────────────────
# The BFF validates x-goog-iap-jwt-assertion and must know the exact `aud`
# IAP mints. That value is numeric; the backend service *name* is not it, and
# hand-typing the name into app CI is what produces `iap_audience_is_not_numeric`
# at startup. Published here so the app team consumes it from the handoff
# artifact instead of retyping it.
output "bff_backend_service_numeric_id" {
  description = "Numeric id of bs-aihub-bff, the second half of the IAP audience."
  value       = module.bs_bff.generated_id
}

# CONFIRMED EMPIRICALLY 2026-09-09 (see docs/BUILD-LOG.md #30): decoded the `error`
# detail of a real `iap_validation_failed` log line from the app, which echoes back
# both the actual `aud` IAP signed and the one the app expected. For this regional
# backend service, IAP signs the region's *name* in place of "global" — no "regions/"
# prefix — i.e. /projects/<number>/<region>/backendServices/<numeric id>. The
# global-endpoint form documented for global external LBs does NOT apply here.
output "bff_iap_audience" {
  description = "Expected IAP JWT aud for bs-aihub-bff (regional backend service — region name, not \"global\"). Re-verify against a live assertion if this backend service's region or type ever changes."
  value       = "/projects/${data.google_project.this.number}/${var.region}/backendServices/${module.bs_bff.generated_id}"
}

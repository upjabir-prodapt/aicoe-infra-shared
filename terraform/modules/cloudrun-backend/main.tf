# A Cloud Run service's load balancer backend, created in the SAME project
# as the service.
#
# WHY THIS MODULE EXISTS
# A serverless network endpoint group must be created in the project that
# owns the Cloud Run service. Cross-project service referencing splits a load
# balancer at the frontend/backend line: address, forwarding rule, target
# proxy and URL map in one project, backend service and NEG in another.
#
# So this module lives with the workload, and the ingress stack consumes its
# self_link output across the project boundary.

variable "project_id" { type = string }
variable "region" { type = string }
variable "name" { type = string }
variable "cloud_run_service" { type = string }
variable "enable_iap" {
  type    = bool
  default = false
}
variable "iap_members" {
  type        = list(string)
  default     = []
  description = "Principals granted roles/iap.httpsResourceAccessor."
}

resource "google_compute_region_network_endpoint_group" "neg" {
  project               = var.project_id
  name                  = "neg-${var.name}"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run { service = var.cloud_run_service }
}

resource "google_compute_region_backend_service" "bs" {
  project               = var.project_id
  name                  = var.name
  region                = var.region
  protocol              = "HTTPS"
  load_balancing_scheme = "INTERNAL_MANAGED"

  # timeout_sec is deliberately omitted, not just left at a default: the API
  # rejects it outright on a backend service pointing at a Serverless NEG
  # ("Timeout sec is not supported for a backend service with Serverless
  # network endpoint groups"), confirmed live 2026-09-07. It is not a no-op
  # field for this backend type -- setting it to anything, including the
  # provider's own default, fails the apply. The request timeout for a
  # Serverless NEG backend is the Cloud Run service's own timeout setting.

  backend {
    group = google_compute_region_network_endpoint_group.neg.id
    # Not a no-op default: for a NEG-backed regional backend service, the API
    # does NOT default an omitted capacity_scaler to 1.0 the way it does for
    # instance-group backends -- it silently ends up 0.0 (0% of traffic ever
    # routed), a full outage with no plan-time warning since Terraform never
    # flagged the omission as a change. Confirmed live 2026-09-10: bs-aihub-
    # bff, bs-translation and bs-sales (all using this same omission pattern,
    # some via this module, some not) were all found at capacityScaler: 0.0.
    # See docs/BUILD-LOG.md entries #33/#35 and GAP-REGISTER.
    capacity_scaler = 1.0
  }

  dynamic "iap" {
    for_each = var.enable_iap ? [1] : []
    content {
      enabled = true
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# NOTE: this must be the *region* variant of this resource, not
# google_iap_web_backend_service_iam_member -- that one targets the global
# IAP webbackendservice endpoint, which does not exist for a
# google_compute_region_backend_service. Using it produces a convincing but
# wrong-cause 404 ("Requested entity was not found") on apply, because
# Terraform queries the global endpoint for a resource that only exists at
# the regional one -- confirmed live 2026-09-07, `gcloud iap web
# get-iam-policy` only succeeds once `--region` is passed explicitly.
resource "google_iap_web_region_backend_service_iam_member" "accessor" {
  for_each                   = var.enable_iap ? toset(var.iap_members) : toset([])
  project                    = var.project_id
  region                     = var.region
  web_region_backend_service = google_compute_region_backend_service.bs.name
  role                       = "roles/iap.httpsResourceAccessor"
  member                     = each.value
}

output "self_link" {
  description = "Consumed by the ingress stack's URL map, across projects."
  value       = google_compute_region_backend_service.bs.self_link
}
output "id" { value = google_compute_region_backend_service.bs.id }

# The numeric id. Neither self_link nor id is what IAP puts in the JWT `aud`
# claim — that is built from the project number and this value, so callers
# validating x-goog-iap-jwt-assertion need it and cannot derive it from a name.
output "generated_id" {
  description = "Numeric backend service id, for constructing the IAP JWT audience."
  value       = google_compute_region_backend_service.bs.generated_id
}

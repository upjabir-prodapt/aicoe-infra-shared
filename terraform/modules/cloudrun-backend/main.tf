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

variable "project_id"       { type = string }
variable "region"           { type = string }
variable "name"             { type = string }
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
variable "timeout_sec" {
  type    = number
  default = 300
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

  # NOTE: timeout_sec does not apply to serverless NEG backends. The binding
  # value is the Cloud Run request timeout. Set here only for completeness.
  timeout_sec = var.timeout_sec

  backend {
    group = google_compute_region_network_endpoint_group.neg.id
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

resource "google_iap_web_backend_service_iam_member" "accessor" {
  for_each            = var.enable_iap ? toset(var.iap_members) : toset([])
  project             = var.project_id
  web_backend_service = google_compute_region_backend_service.bs.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
}

output "self_link" {
  description = "Consumed by the ingress stack's URL map, across projects."
  value       = google_compute_region_backend_service.bs.self_link
}
output "id" { value = google_compute_region_backend_service.bs.id }

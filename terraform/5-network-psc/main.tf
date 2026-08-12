# network/psc — the endpoints that cannot exist until other things do.
#
# WHY THE NETWORK LAYER IS SPLIT
# The endpoint to Apigee targets a service attachment that only exists once
# the Apigee instance is provisioned. Rather than applying the network layer
# twice and documenting it as a quirk, the dependency is made explicit here
# and enforced by the pipeline's needs:.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id"   { type = string }
variable "region"       { type = string }
# ── inputs from upstream stages ─────────────────────────────────────────
variable "vpc_self_link"             { type = string }
variable "internal_subnet_self_link" { type = string }
variable "private_zone_name"         { type = string }
variable "instance_service_attachment" {
  type        = string
  description = "From stage 4. This is why the network layer is split."
}

# ── PSC to all Google APIs · a GLOBAL address, outside every subnet ─────
resource "google_compute_global_address" "google_apis" {
  project      = var.project_id
  name         = "psc-google-apis-ip"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  address      = "192.168.6.164"
  network      = var.vpc_self_link
}

resource "google_compute_global_forwarding_rule" "google_apis" {
  project               = var.project_id
  name                  = "psc-google-apis"
  target                = "vpc-sc"          # not all-apis: only perimeter-supported APIs
  network               = var.vpc_self_link
  ip_address            = google_compute_global_address.google_apis.id
  load_balancing_scheme = ""
}

# ── PSC to Apigee · consumed by the BFF and the backend services ────────
resource "google_compute_address" "apigee_endpoint" {
  project      = var.project_id
  name         = "psc-apigee-ip"
  region       = var.region
  subnetwork   = var.internal_subnet_self_link
  address_type = "INTERNAL"
  address      = "192.168.6.146"
}

resource "google_compute_forwarding_rule" "apigee_endpoint" {
  project               = var.project_id
  name                  = "psc-apigee"
  region                = var.region
  network               = var.vpc_self_link
  subnetwork            = var.internal_subnet_self_link
  ip_address            = google_compute_address.apigee_endpoint.id
  load_balancing_scheme = ""
  target                = var.instance_service_attachment
}

# ── private DNS · so callers use hostnames and TLS verification stays on ─
resource "google_dns_record_set" "aihub_api" {
  project      = var.project_id
  managed_zone = var.private_zone_name
  name         = "aihub-api.aicoe-dev-int.colt.net."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.apigee_endpoint.address]
}

resource "google_dns_record_set" "llm" {
  project      = var.project_id
  managed_zone = var.private_zone_name
  name         = "llm.aicoe-dev-int.colt.net."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.apigee_endpoint.address]
}

# Both hostnames resolve to the same endpoint. Apigee selects the
# environment from the Host header, so the hostname is functional.

output "apigee_endpoint_ip" { value = google_compute_address.apigee_endpoint.address }
output "google_apis_ip"     { value = google_compute_global_address.google_apis.address }

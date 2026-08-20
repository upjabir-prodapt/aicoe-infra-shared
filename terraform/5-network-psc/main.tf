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

variable "project_id" { type = string }
variable "region" { type = string }
# ── inputs from upstream stages ─────────────────────────────────────────
variable "vpc_self_link" { type = string }
variable "internal_subnet_self_link" { type = string }
variable "subnet_ew3_self_link" { type = string }
variable "private_zone_name" { type = string }
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
  name                  = "pscgoogleapis"
  target                = "vpc-sc" # not all-apis: only perimeter-supported APIs
  network               = var.vpc_self_link
  ip_address            = google_compute_global_address.google_apis.id
  load_balancing_scheme = ""
}

# ── PSC to Apigee · consumed by the BFF and the backend services ────────
resource "google_compute_address" "apigee_endpoint" {
  project      = var.project_id
  name         = "psc-apigee-ip"
  region       = var.region
  subnetwork   = var.subnet_ew3_self_link
  address_type = "INTERNAL"
  address      = "10.110.73.10"
}

resource "google_compute_forwarding_rule" "apigee_endpoint" {
  project               = var.project_id
  name                  = "psc-apigee"
  region                = var.region
  network               = var.vpc_self_link
  subnetwork            = var.subnet_ew3_self_link
  ip_address            = google_compute_address.apigee_endpoint.id
  load_balancing_scheme = ""
  target                = var.instance_service_attachment
}

# ── private DNS · so callers use hostnames and TLS verification stays on ─
resource "google_dns_record_set" "aihub_api" {
  project      = var.project_id
  managed_zone = var.private_zone_name
  name         = "aihub-api.aicoedev-int.colt.net."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.apigee_endpoint.address]
}

resource "google_dns_record_set" "llm" {
  project      = var.project_id
  managed_zone = var.private_zone_name
  name         = "llm.aicoedev-int.colt.net."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.apigee_endpoint.address]
}

# Both hostnames resolve to the same endpoint. Apigee selects the
# environment from the Host header, so the hostname is functional.

output "apigee_endpoint_ip" { value = google_compute_address.apigee_endpoint.address }
output "google_apis_ip" { value = google_compute_global_address.google_apis.address }

# ── Vector Search · automatic service connection policy ─────────────────
# The LLD records Private Service Connect in AUTOMATIC mode for Vector
# Search in both environments. Without a service connection policy, every
# index deployment needs a manually created endpoint — the exact outcome
# automatic mode was chosen to avoid. The policy names a subnet from which
# endpoint addresses are allocated, so it lives in the network layer.
#
# service_class "gcp-memorystore-redis" is NOT this; Vector Search publishes
# under its own producer service class. The class below is the Vertex AI
# Vector Search producer. Confirm against the live service class before
# apply — a wrong class silently creates a policy that matches nothing.
#
# Note: Commented out because the Vertex AI Vector Search service class is not
# globally available or registered for Service Connection Policies in all regions/projects yet.
#
# resource "google_network_connectivity_service_connection_policy" "vector_search" {
#   project       = var.project_id
#   location      = var.region
#   name          = "vector-search-auto"
#   service_class = "gcp-aiplatform-vector-search"
#   network       = var.vpc_self_link
#
#   psc_config {
#     subnetworks = [var.internal_subnet_self_link]
#   }
# }
#
# output "vector_search_policy_id" { value = google_network_connectivity_service_connection_policy.vector_search.id }

# ── PSC to Model Armor (Regional Endpoint) ──────────────────────────────
resource "google_network_connectivity_regional_endpoint" "model_armor" {
  project           = var.project_id
  name              = "model-armor-ew3"
  location          = var.region
  target_google_api = "modelarmor.europe-west3.rep.googleapis.com"
  network           = "projects/${var.project_id}/global/networks/gclt-aicoe-dev-vpc"
  subnetwork        = "projects/${var.project_id}/regions/${var.region}/subnetworks/gclt-aicoe-dev-internal-ew3"
  address           = "192.168.6.148"
  access_type       = "REGIONAL"
}

resource "google_dns_managed_zone" "modelarmor" {
  project     = var.project_id
  name        = "modelarmor-private"
  dns_name    = "modelarmor.europe-west3.rep.googleapis.com."
  visibility  = "private"
  description = "Private zone for regional Model Armor endpoint"

  private_visibility_config {
    networks { network_url = var.vpc_self_link }
  }
}

resource "google_dns_record_set" "modelarmor" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.modelarmor.name
  name         = "modelarmor.europe-west3.rep.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_network_connectivity_regional_endpoint.model_armor.address]
}

output "model_armor_ip" { value = google_network_connectivity_regional_endpoint.model_armor.address }

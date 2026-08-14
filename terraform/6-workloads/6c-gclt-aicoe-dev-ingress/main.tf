# infra/ingress — the frontend halves of both load balancers.
#
# THIS IS THE CROSS-PROJECT JOIN.
# Backend services live in the workload projects because a serverless NEG
# must sit with its Cloud Run service. This stack reads their self_links
# from remote state and references them in URL maps. The pipeline enforces
# the ordering with needs:; this file enforces it in Terraform.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id" { type = string }
variable "network_project_id" { type = string }
variable "region" { type = string }

# ── inputs from upstream stages ─────────────────────────────────────────
# Supplied as .auto.tfvars.json artifacts by stages 3 and 6a/6b. No stage
# reads another stage's state file, so each service account needs access to
# its own state and nothing else.

variable "bff_backend_service_self_link" { type = string }
variable "translation_backend_service_self_link" { type = string }
variable "sales_backend_service_self_link" { type = string }
variable "vpc_self_link" { type = string }
variable "subnet_ew1_self_link" { type = string }
variable "internal_subnet_self_link" { type = string }
variable "pscnat_subnet_self_link" { type = string }

locals {
  bff         = var.bff_backend_service_self_link
  translation = var.translation_backend_service_self_link
  sales       = var.sales_backend_service_self_link
  subnet      = var.subnet_ew1_self_link
}

# ── AI Hub load balancer · the only Colt-reachable address ──────────────
resource "google_compute_address" "aihub_vip" {
  project      = var.network_project_id
  name         = "aihub-ilb-vip"
  region       = var.region
  subnetwork   = local.subnet
  address_type = "INTERNAL"
  address      = "10.110.73.20"
  purpose      = "SHARED_LOADBALANCER_VIP"

  # CSOC opens the firewall for this exact address. If it moves, users lose
  # access and a new request is needed, with its own lead time.
  lifecycle { prevent_destroy = true }
}

resource "google_compute_region_url_map" "aihub" {
  project = var.project_id
  name    = "aihub-urlmap"
  region  = var.region

  # One rule. The BFF serves the interface, /auth/* and /api/* from a single
  # origin, which is what lets the session cookie work with no CORS.
  default_service = local.bff
}

resource "google_compute_region_target_https_proxy" "aihub" {
  project                          = var.project_id
  name                             = "aihub-proxy"
  region                           = var.region
  url_map                          = google_compute_region_url_map.aihub.id
  certificate_manager_certificates = [var.aihub_certificate_id]
}

variable "aihub_certificate_id" { type = string }

resource "google_compute_forwarding_rule" "aihub" {
  project               = var.project_id
  name                  = "aihub-fr"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = var.vpc_self_link
  subnetwork            = local.subnet
  ip_address            = google_compute_address.aihub_vip.id
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.aihub.id
}

# ── Backend load balancer · machine-only, pure transport ────────────────
# No IAP anywhere on it. Apigee authenticates with a Google ID token in
# X-Serverless-Authorization and Cloud Run validates it against run.invoker.

resource "google_compute_address" "backend_vip" {
  project      = var.network_project_id
  name         = "backend-ilb-vip"
  region       = var.region
  subnetwork   = var.internal_subnet_self_link
  address_type = "INTERNAL"
  address      = "192.168.6.145"
  purpose      = "SHARED_LOADBALANCER_VIP"
}

resource "google_compute_region_url_map" "backend" {
  project         = var.project_id
  name            = "backend-urlmap"
  region          = var.region
  default_service = local.translation

  host_rule {
    hosts        = ["*"]
    path_matcher = "svc"
  }

  path_matcher {
    name            = "svc"
    default_service = local.translation
    path_rule {
      paths   = ["/translation/*"]
      service = local.translation
    }
    path_rule {
      paths   = ["/sales/*"]
      service = local.sales
    }
  }
}

resource "google_compute_region_target_https_proxy" "backend" {
  project                          = var.project_id
  name                             = "backend-proxy"
  region                           = var.region
  url_map                          = google_compute_region_url_map.backend.id
  certificate_manager_certificates = [var.backend_certificate_id]
}

variable "backend_certificate_id" { type = string }

resource "google_compute_forwarding_rule" "backend" {
  project               = var.project_id
  name                  = "backend-fr"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = var.vpc_self_link
  subnetwork            = var.internal_subnet_self_link
  ip_address            = google_compute_address.backend_vip.id
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.backend.id
}

# ── publish it so Apigee can reach it ───────────────────────────────────
resource "google_compute_service_attachment" "backends" {
  project     = var.project_id
  name        = "sa-backends"
  region      = var.region
  description = "Southbound path from Apigee to the backend services"

  enable_proxy_protocol = false
  connection_preference = "ACCEPT_MANUAL"
  nat_subnets           = [var.pscnat_subnet_self_link]
  target_service        = google_compute_forwarding_rule.backend.id

  # Only the Apigee project. An open list lets any project in the
  # organisation reach the backends directly.
  consumer_accept_lists {
    project_id_or_num = var.apigee_project_id
    connection_limit  = 10
  }
}

variable "apigee_project_id" { type = string }

output "backend_service_attachment_id" {
  description = "Consumed by infra/apigee to create the endpoint attachment."
  value       = google_compute_service_attachment.backends.id
}

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
variable "subnet_ew3_self_link" { type = string }
variable "internal_v2_subnet_self_link" { type = string }
variable "pscnat_v2_subnet_self_link" { type = string }

locals {
  bff         = var.bff_backend_service_self_link
  translation = var.translation_backend_service_self_link
  sales       = var.sales_backend_service_self_link
  subnet      = var.subnet_ew3_self_link
}

# ── AI Hub load balancer · the only Colt-reachable address ──────────────
# project = var.project_id (the SERVICE project), NOT network_project_id (the
# Shared VPC host project) -- confirmed live 2026-09-07 and in Google's own
# Shared VPC docs: "The internal IP address object must be created in the
# same service project as the resource that uses it, even though its value
# comes from the range of available IP addresses in the selected shared
# subnet." Reserving it in the host project instead produces a convincing
# but wrong-cause error on the forwarding rule that actually consumes it --
# "IP address ... is reserved by another project" -- because the forwarding
# rule (in the service project) and the address object (in the host
# project) are, correctly, two different projects; Shared VPC requires the
# opposite pairing from what was here.
resource "google_compute_address" "aihub_vip" {
  project      = var.project_id
  name         = "aihub-ilb-vip"
  region       = var.region
  subnetwork   = local.subnet
  address_type = "INTERNAL"
  address      = "10.110.73.20"
  purpose      = "SHARED_LOADBALANCER_VIP"

  # CSOC opens the firewall for this exact address. If it moves, users lose
  # access and a new request is needed, with its own lead time. Moving which
  # PROJECT holds the reservation object does not change this literal IP
  # value, so it does not require a new CSOC request by itself.
  #
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

  # REQUIRED for the corporate front door -- not an optimisation.
  # Corporate/Zscaler traffic enters the shared transit VPC over PARTNER
  # Interconnect attachments in europe-west1, -west2 AND -west3, and
  # 10.110.73.0/24 is advertised by BOTH the europe-west1 and europe-west3
  # Cloud Routers (gclt-shr-interconnect-europe-west{1,3}-router{1,2}).
  # Which attachment a session lands on is BGP's choice and re-converges
  # whenever anything in the estate changes.
  #
  # Without global access, a regional INTERNAL_MANAGED forwarding rule drops
  # any packet that did not enter in its own region. Confirmed 2026-09-11 by
  # Network Intelligence Center from source 10.100.209.2 (Zscaler connector
  # range) -> 10.110.73.20:443, which returned AMBIGUOUS across six traces:
  # the two europe-west3 paths DELIVER, while the two europe-west1 paths DROP
  # with "sent to forwarding rule without global access enabled, but its
  # region does not match forwarding rule region". That coin flip is the
  # intermittent ERR_CONNECTION_CLOSED chased in BUILD-LOG #28/#33/#34 -- it
  # presents as "DNS needs time after an infra change", but DNS never
  # changes here; the BGP path does.
  #
  # This does NOT make the load balancer global: scheme, region, VIP, proxies
  # and backends all stay regional in europe-west3. It only stops the rule
  # rejecting clients that arrived in another region.
  allow_global_access = true
}




# ── Backend load balancer · machine-only, pure transport ────────────────
# No IAP anywhere on it. Apigee authenticates with a Google ID token in
# X-Serverless-Authorization and Cloud Run validates it against run.invoker.

resource "google_compute_address" "backend_vip" {
  # Same fix, same reason as aihub_vip above: the address object belongs in
  # the service project, not the Shared VPC host project.
  project      = var.project_id
  name         = "backend-ilb-vip"
  region       = var.region
  subnetwork   = var.internal_v2_subnet_self_link
  address_type = "INTERNAL"

  # Migrated from 192.168.6.144/28 to 192.168.7.80/28 -- GAP-REGISTER B-04.
  # .81 is the GCP-reserved default gateway and can never be allocated.
  # .82 is the Apigee PSC endpoint, .84 is Model Armor (Vector Search not
  # yet deployed), so the ILB VIP takes .85.
  address = "192.168.7.85"
  purpose = "SHARED_LOADBALANCER_VIP"
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

  # The /api prefix is NOT decoration: Apigee's TargetEndpoint prepends it
  # (apigee/proxies/aihub-api-v1/apiproxy/targets/backends.xml, <Path>/api</Path>)
  # because Apigee does not forward its own BasePath, while both backends mount
  # their routes under API_PREFIX = /api/translation/v1 and /api/sales/v1.
  #
  # These rules and that <Path> element must change together. Revert one alone
  # and NEITHER rule matches, so every request — Sales-Agent included — falls
  # through to default_service below and is answered by the Translation
  # service. That failure is silent: a 200 from the wrong backend, not an
  # error. Codified 2026-09-11, see docs/BUILD-LOG.md #38.
  path_matcher {
    name            = "svc"
    default_service = local.translation
    path_rule {
      paths   = ["/api/translation/*"]
      service = local.translation
    }
    path_rule {
      paths   = ["/api/sales/*"]
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
  subnetwork            = var.internal_v2_subnet_self_link
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
  nat_subnets           = [var.pscnat_v2_subnet_self_link]
  target_service        = google_compute_forwarding_rule.backend.id

  # Only Apigee's own internal TENANT project, not the org's outward-facing
  # project id (gclt-aicoe-dev-apigee) -- confirmed live 2026-09-07: the
  # actual PSC connection Apigee opens comes from its own tenant project
  # (google_apigee_organization.apigee_project_id in stage 4, published here
  # as apigee_tenant_project_id, deliberately a different name from 1-org's
  # apigee_project_id to avoid a silent handoff collision). Using the org's
  # project id here left every real connection attempt stuck at
  # connectionState PENDING forever -- visible as state ACTIVE,
  # connectionState PENDING, never auto-accepting, because the accept list
  # never actually matched the connecting consumer's project.
  consumer_accept_lists {
    project_id_or_num = var.apigee_tenant_project_id
    connection_limit  = 10
  }
}

variable "apigee_tenant_project_id" { type = string }

output "backend_service_attachment_id" {
  description = "Consumed by infra/apigee to create the endpoint attachment."
  value       = google_compute_service_attachment.backends.id
}

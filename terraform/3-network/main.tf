# network/base — the VPC, every subnet, the firewall and private DNS.
#
# Split from network/psc because the PSC endpoint to Apigee cannot exist
# until the Apigee instance is provisioned. This half has no such dependency
# and everything else waits on it.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id" { type = string }
variable "region"     { type = string }
variable "service_projects" {
  type        = list(string)
  description = "Projects attached to the Shared VPC."
}

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "gclt-aicoe-dev-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  # No Cloud NAT and no internet egress. Confirmed: the sales agent needs
  # no outbound internet access.
  delete_default_routes_on_create = false
}

# ── the Colt-reachable range · user-facing load balancer VIPs only ──────
resource "google_compute_subnetwork" "subnet_ew1" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-subnet-ew1"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.110.73.0/24"

  # Forced off so every Google API call goes through the PSC endpoint,
  # giving one chokepoint that can be logged and restricted.
  private_ip_google_access = false

  log_config {
    aggregation_interval = "INTERVAL_15_MIN"
    flow_sampling        = 0.1      # full-rate flow logs cost more than the workload
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── everything below has NO route from the Colt network ─────────────────
resource "google_compute_subnetwork" "cloudrun" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-cloudrun-ew1"
  region        = var.region
  network       = google_compute_network.vpc.id
  # 508 usable → 127 instance ceiling, at ~2 addresses per instance and a 4x
  # rollout peak. Cannot be grown in place: widening a subnet preserves its
  # network address, so the only /22 this can become is 192.168.4.0/22 — the
  # whole unrouted range. A new use case gets its own subnet cut from
  # 192.168.7.0/24 instead.
  ip_cidr_range = "192.168.4.0/23"
  private_ip_google_access = false

  log_config {
    aggregation_interval = "INTERVAL_15_MIN"
    flow_sampling        = 0.1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "proxy" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-proxy-ew1"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "192.168.6.0/26"          # /26 is the documented minimum

  # ONE active proxy-only subnet per region per VPC. Both load balancers
  # share this. Do not create a second ACTIVE one.
  #
  # A proxy-only subnet cannot be resized in place. Growing the Envoy fleet
  # means creating a second proxy-only subnet in the reserved 192.168.6.64/26
  # below, marking it ACTIVE and flipping this one to BACKUP, then removing
  # this resource. That is why the reservation exists and must stay empty.
  purpose = "REGIONAL_MANAGED_PROXY"
  role    = "ACTIVE"
}

# 192.168.6.64/26 is deliberately left un-subnetted and is NOT free space.
# It is the same-size landing block for the proxy-only role swap described
# above. Do not allocate it to anything else.

resource "google_compute_subnetwork" "pscnat" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-pscnat-ew1"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "192.168.6.128/28"

  # Address translation for the published service Apigee connects to.
  # Can hold nothing else.
  purpose = "PRIVATE_SERVICE_CONNECT"
}

resource "google_compute_subnetwork" "internal" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-internal-ew1"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "192.168.6.144/28"        # .145 Backend ILB, .146 Apigee, .147 Vector Search
  private_ip_google_access = false
}

# 192.168.6.160/28 is deliberately left un-subnetted. The PSC endpoint to
# Google APIs is a GLOBAL internal address and must not overlap a subnet.
#
# 192.168.6.176 – .255 is growth for further platform subnets, and
# 192.168.7.0/24 is held for the workload subnets of future use cases.

# ── firewall · deny outbound by default, then allow three destinations ──
resource "google_compute_firewall" "egress_deny_all" {
  project            = var.project_id
  name               = "egress-deny-all"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 65000
  destination_ranges = ["0.0.0.0/0"]

  deny { protocol = "all" }

  log_config { metadata = "INCLUDE_ALL_METADATA" }
}

resource "google_compute_firewall" "egress_allow_psc" {
  project   = var.project_id
  name      = "egress-allow-psc"
  network   = google_compute_network.vpc.name
  direction = "EGRESS"
  priority  = 1000                          # lower number wins

  destination_ranges = [
    "192.168.6.164/32",   # Google APIs
    "192.168.6.146/32",   # Apigee
    "192.168.6.147/32",   # Vector Search
  ]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config { metadata = "INCLUDE_ALL_METADATA" }
}

resource "google_compute_firewall" "ingress_proxy_subnet" {
  project       = var.project_id
  name          = "ingress-allow-proxy-subnet"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = [google_compute_subnetwork.proxy.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  # Defensive rather than required: every backend is a serverless NEG, which
  # sits outside the VPC, so firewall rules do not gate it and health checks
  # are not used. This becomes necessary the moment anyone adds a VM backend.
  #
  # Deliberately NOT including 130.211.0.0/22 and 35.191.0.0/16 — nothing in
  # this design uses them.
}

# ── private DNS ─────────────────────────────────────────────────────────
resource "google_dns_managed_zone" "internal" {
  project     = var.project_id
  name        = "aicoe-dev-int"
  dns_name    = "aicoe-dev-int.colt.net."
  visibility  = "private"
  description = "Platform hostnames, resolvable only inside the VPC"

  private_visibility_config {
    networks { network_url = google_compute_network.vpc.id }
  }
}

resource "google_dns_record_set" "aihub" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.internal.name
  name         = "aihub.aicoe-dev-int.colt.net."
  type         = "A"
  ttl          = 300
  rrdatas      = ["10.110.73.20"]
}

# Records for aihub-api and llm are created in network/psc, because they
# point at an endpoint that does not exist until Apigee does.

resource "google_dns_managed_zone" "googleapis" {
  project    = var.project_id
  name       = "googleapis-private"
  dns_name   = "googleapis.com."
  visibility = "private"

  private_visibility_config {
    networks { network_url = google_compute_network.vpc.id }
  }
}

resource "google_dns_managed_zone" "runapp" {
  project    = var.project_id
  name       = "run-app-private"
  dns_name   = "run.app."
  visibility = "private"
  description = "Internal Cloud Run URLs, used by Cloud Tasks to reach the worker"

  private_visibility_config {
    networks { network_url = google_compute_network.vpc.id }
  }
}

# ── Shared VPC ──────────────────────────────────────────────────────────
resource "google_compute_shared_vpc_host_project" "host" {
  project = var.project_id
}

resource "google_compute_shared_vpc_service_project" "service" {
  for_each        = toset(var.service_projects)
  host_project    = google_compute_shared_vpc_host_project.host.project
  service_project = each.value
}

# ── outputs consumed by network/psc, infra/ingress, infra/st ────────────
output "vpc_self_link"              { value = google_compute_network.vpc.self_link }
output "subnet_ew1_self_link"       { value = google_compute_subnetwork.subnet_ew1.self_link }
output "cloudrun_subnet_self_link"  { value = google_compute_subnetwork.cloudrun.self_link }
output "proxy_subnet_self_link"     { value = google_compute_subnetwork.proxy.self_link }
output "pscnat_subnet_self_link"    { value = google_compute_subnetwork.pscnat.self_link }
output "internal_subnet_self_link"  { value = google_compute_subnetwork.internal.self_link }
output "private_zone_name"          { value = google_dns_managed_zone.internal.name }
output "googleapis_zone_name"       { value = google_dns_managed_zone.googleapis.name }

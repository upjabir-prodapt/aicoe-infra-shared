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
variable "region" { type = string }
variable "service_projects" {
  type        = list(string)
  description = "Projects attached to the Shared VPC."
}
variable "project_numbers" {
  type        = map(string)
  description = <<-EOT
    Project number per project, keyed the same as 1-org's existing_projects
    map (aihub-ui, apigee, st, ...). Published by 1-org as vars-handoff/
    1-org.auto.tfvars.json's project_numbers output; 3-network already
    depends on that same artifact for service_projects, so this adds no new
    cross-stage dependency. Needed to address Google-managed per-project
    "robot" service agents (e.g. serverless-robot-prod for Cloud Run), whose
    email embeds the *consuming* project's number, not its id.
  EOT
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
resource "google_compute_subnetwork" "subnet_ew3" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-subnet-ew3"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.110.73.0/24"

  # Forced off so every Google API call goes through the PSC endpoint,
  # giving one chokepoint that can be logged and restricted.
  private_ip_google_access = false

  log_config {
    aggregation_interval = "INTERVAL_15_MIN"
    flow_sampling        = 0.1 # full-rate flow logs cost more than the workload
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── everything below has NO route from the Colt network ─────────────────
resource "google_compute_subnetwork" "cloudrun" {
  project = var.project_id
  name    = "gclt-aicoe-dev-cloudrun-ew3"
  region  = var.region
  network = google_compute_network.vpc.id
  # 508 usable → 127 instance ceiling, at ~2 addresses per instance and a 4x
  # rollout peak. Cannot be grown in place: widening a subnet preserves its
  # network address, so the only /22 this can become is 192.168.4.0/22 — the
  # whole unrouted range. A new use case gets its own subnet cut from
  # 192.168.7.0/24 instead.
  ip_cidr_range            = "192.168.4.0/23"
  private_ip_google_access = false

  log_config {
    aggregation_interval = "INTERVAL_15_MIN"
    flow_sampling        = 0.1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Attaching a service project to the Shared VPC (google_compute_shared_vpc_
# service_project below) only authorizes the project as an XPN service
# project — it grants no principal permission to actually USE a subnet.
# Cloud Run's Direct VPC egress needs its per-consuming-project "serverless
# robot" service agent to hold compute.networkUser here specifically, and
# nothing in this codebase ever granted that to anyone, for any project,
# because gclt-aicoe-dev-aihub-ui is the first Cloud Run service anywhere in
# this platform to use Direct VPC egress into this Shared VPC — the gap was
# never exercised until its first real deploy on 2026-09-02.
#
# Symptom when this is missing: image pulls and starts fine
# (ContainerReady=True), but the revision never becomes Ready —
# ResourcesAvailable=False with the maximally unhelpful "The service has
# encountered an internal error. Please try again later", retried by Cloud
# Run's self-healing every ~15 minutes forever. There is no permission-denied
# message anywhere; this is discoverable only by noticing no
# compute.networkUser binding exists anywhere in the host project.
#
# Scoped to this one subnet, not project-wide: each consuming service's
# revision template names this subnet explicitly, so that's all it needs.
#
# One entry per project whose Cloud Run services use Direct VPC egress into
# this subnet. "st" (Translation + Sales-Agent) is added alongside
# "aihub-ui" pre-emptively: BUILD-LOG §14.1 shows this exact gap cost ~18
# minutes of a hung, unhelpful "internal error" deploy the first time it was
# missed, and st's Cloud Run services do not exist yet to prove the need
# empirically before their first deploy.
resource "google_compute_subnetwork_iam_member" "cloudrun_network_user" {
  for_each   = toset(["aihub-ui", "st"])
  project    = var.project_id
  region     = var.region
  subnetwork = google_compute_subnetwork.cloudrun.name
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:service-${var.project_numbers[each.key]}@serverless-robot-prod.iam.gserviceaccount.com"
}

# Preserve the already-applied aihub-ui grant across the single-resource →
# for_each conversion instead of destroying and recreating it.
moved {
  from = google_compute_subnetwork_iam_member.cloudrun_aihub_ui_network_user
  to   = google_compute_subnetwork_iam_member.cloudrun_network_user["aihub-ui"]
}

# gclt-aicoe-dev-proxy-ew3 (192.168.6.0/26) migrated to proxy_v2 below and
# deleted 2026-09-08 -- GAP-REGISTER B-04 (the 192.168.6.0/24 conflict with
# aicoeprod). Real procedure used, note for any future subnet migration of
# this kind: GCP rejects patching an ACTIVE proxy-only subnet directly to
# BACKUP ("Role can be patched only on a BACKUP subnetwork"). Create the new
# subnet as BACKUP first, then patch THAT one to ACTIVE -- promoting a
# BACKUP to ACTIVE demotes the previous ACTIVE automatically, since only one
# may hold that role at a time. Confirmed live afterward via a real HTTP
# request through both load balancers sharing this proxy subnet
# (aihub-fr: HTTP 302 with x-goog-iap-generated-response: true; backend-fr:
# HTTP 403 app-layer rejection, not a connection failure) -- both proven
# working on the new subnet before the old one was deleted.
resource "google_compute_subnetwork" "proxy_v2" {
  project = var.project_id
  name    = "gclt-aicoe-dev-proxy-ew3-v2"
  region  = var.region
  network = google_compute_network.vpc.id
  # NOT 192.168.5.0/26 -- confirmed live 2026-09-08 this conflicts with our
  # OWN gclt-aicoe-dev-cloudrun-ew3 (192.168.4.0/23, which spans .4.0-.5.255,
  # not just .4.0/24). aicoedev decommissioning freed that range on
  # aicoedev's side, but it was never actually free within THIS VPC. Using
  # 192.168.7.0/24 instead -- already reserved for exactly this in the
  # comment on redis_psc below, predating this migration, confirmed
  # non-overlapping with both our own cloudrun subnet and aicoeprod's
  # 192.168.6.0/24.
  ip_cidr_range = "192.168.7.0/26"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# 192.168.6.64/26 is deliberately left un-subnetted and is NOT free space.
# It is the same-size landing block for the proxy-only role swap described
# above. Do not allocate it to anything else.

# gclt-aicoe-dev-pscnat-ew3 (192.168.6.128/28) migrated to pscnat_v2 below and
# deleted 2026-09-08 -- GAP-REGISTER B-04 (the 192.168.6.0/24 conflict with
# aicoeprod). Note for any future subnet migration of this kind: an in-place
# nat_subnets update on the consuming google_compute_service_attachment,
# even after recreating the Apigee-side endpoint attachment to force a fresh
# connection, was NOT enough to release the old subnet's NAT IP allocation
# ("NAT subnetwork ... cannot be removed because there are NAT IP
# allocated") -- confirmed after a 1-hour wait too, so not just async
# release lag. What actually worked: a full destroy+recreate of the service
# attachment itself (terraform apply -replace), then recreating the Apigee
# endpoint attachment to reconnect to it.
resource "google_compute_subnetwork" "pscnat_v2" {
  project       = var.project_id
  name          = "gclt-aicoe-dev-pscnat-ew3-v2"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "192.168.7.64/28"
  purpose       = "PRIVATE_SERVICE_CONNECT"
}


# Allocation of 192.168.6.144/28:
#   .146 Apigee PSC endpoint, .147 Vector Search, .148 Model Armor,
#   .149 Backend ILB VIP.
# .144 (network), .145 (GCP default gateway), .158 and .159 are reserved by
# GCP and can never be assigned.
# gclt-aicoe-dev-internal-ew3 (192.168.6.144/28) migrated to internal_v2
# below and deleted 2026-09-08 -- GAP-REGISTER B-04. This was the
# highest-blast-radius piece of the whole 4-subnet migration: this subnet
# hosted Apigee's own PSC ingress endpoint (used by every app to reach
# Apigee at all -- 5-network-psc/main.tf), the Model Armor PSC endpoint, a
# reservation for Vector Search (not yet deployed), and backend_vip (6c).
# All four addresses moved to internal_v2's range; the DNS records
# aihub-api.aicoedev-int.colt.net / llm.aicoedev-int.colt.net updated
# automatically since they reference the resource, not a hardcoded string.
# Migrating google_compute_service_attachment.backends (6c) required a full
# destroy+recreate (its target_service reference changed along with
# backend-fr) -- same "recreate the service attachment, then recreate
# Apigee's endpoint attachment to reconnect" procedure already learned
# migrating pscnat-ew3.

resource "google_compute_subnetwork" "internal_v2" {
  project                  = var.project_id
  name                     = "gclt-aicoe-dev-internal-ew3-v2"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "192.168.7.80/28"
  private_ip_google_access = false
}

# 192.168.6.160/28 is deliberately left un-subnetted. The PSC endpoint to
# Google APIs is a GLOBAL internal address and must not overlap a subnet.
#
# 192.168.6.176/28 (formerly the Redis PSC subnet) and 192.168.6.192-.255 are
# now free -- GAP-REGISTER B-04: this whole 192.168.6.0/24 block conflicts
# with aicoeprod-proxy-subnet on the shared transit hub and everything that
# was here has migrated to 192.168.7.0/24 (proxy_v2, pscnat_v2, internal_v2,
# redis_psc_v2 -- see each resource below), which is genuinely free and was
# already reserved for exactly this kind of need before this migration
# started. Nothing should be newly allocated back into 192.168.6.0/24.

# gclt-aicoe-dev-redis-psc-ew3 (192.168.6.176/28) migrated to redis_psc_v2
# below and deleted 2026-09-08 -- GAP-REGISTER B-04. Unlike the pscnat
# migration, updating the Service Connection Policy's subnetworks list to
# redis_psc_v2 alone was NOT enough to move the already-running cluster's
# existing PSC connection -- the old subnet remained in use
# ("already being used by ... forwardingRules/sca-auto-fr-...", the
# Memorystore-managed forwarding rule) until the cluster itself was
# destroyed and recreated (terraform apply -replace
# google_redis_cluster.st_cache in 5-network-psc). That recreation is a
# full cache rebuild (new discovery endpoint, REDIS_HOST updated in both
# Translation and Sales-Agent) -- confirm before doing this again on a
# cluster with meaningful cached state, even though both apps fail open on
# cache misses by design.
resource "google_compute_subnetwork" "redis_psc_v2" {
  project                  = var.project_id
  name                     = "gclt-aicoe-dev-redis-psc-ew3-v2"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "192.168.7.96/28"
  private_ip_google_access = false
}

# Only ONE policy is permitted per (network, region, service_class).
# limit = 2 => headroom for a second cluster later without editing this.
resource "google_network_connectivity_service_connection_policy" "redis_cluster" {
  project       = var.project_id
  name          = "redis-cluster-scp"
  location      = var.region
  service_class = "gcp-memorystore-redis"
  description   = "Lets the Shared VPC auto-connect to Memorystore Redis Cluster over PSC."
  network       = google_compute_network.vpc.id

  psc_config {
    subnetworks = [google_compute_subnetwork.redis_psc_v2.id]
    limit       = 2
  }
}

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
  priority  = 1000 # lower number wins

  destination_ranges = [
    "192.168.6.164/32", # Google APIs -- standalone global PSC address, not
    # part of a subnet, not affected by the 192.168.6.0/24 conflict/migration
    "192.168.7.82/32", # Apigee (internal, PSC) -- migrated from 192.168.6.146
    "192.168.7.83/32", # Vector Search -- reserved, not yet deployed; migrated from 192.168.6.147
    "192.168.7.84/32", # Model Armor (regional) -- migrated from 192.168.6.148
    "192.168.7.85/32", # Backend ILB VIP (Apigee southbound to the backends) -- migrated from 192.168.6.149
  ]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config { metadata = "INCLUDE_ALL_METADATA" }
}

# The existing egress-allow-psc rule cannot be reused: it allows only
# tcp:443 to five specific /32s, and the base policy is egress-deny-all at
# priority 65000.
resource "google_compute_firewall" "egress_allow_redis" {
  project            = var.project_id
  name               = "egress-allow-redis"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [google_compute_subnetwork.redis_psc_v2.ip_cidr_range]

  allow {
    protocol = "tcp"
    # 6379 = discovery endpoint. 11000-13047 = Redis Cluster node ports;
    # not used by today's single-shard + standalone-client setup, but opened
    # so a future multi-shard / cluster-aware client does not fail obscurely.
    ports = ["6379", "11000-13047"]
  }

  log_config { metadata = "INCLUDE_ALL_METADATA" }
}

resource "google_compute_firewall" "ingress_proxy_subnet" {
  project       = var.project_id
  name          = "ingress-allow-proxy-subnet"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = [google_compute_subnetwork.proxy_v2.ip_cidr_range]

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

# Mirrors aicoedev project's "allow-onprem-ip" rule content (same ranges,
# same protocol, same direction) -- but NOT its priority. GCP evaluates
# firewall rules lowest-number-first, and aicoedev's own egress-deny-all
# sits at 65535, AFTER its allow-onprem-ip at 65534 -- so the allow rule
# wins there. This platform's egress-deny-all sits at 65000, BEFORE any
# priority in the 65001-65535 range, so copying aicoedev's literal 65534
# put the allow rule after the deny-all, not before it: confirmed live via
# a Network Intelligence Center connectivity test 2026-09-07 -- the packet
# was dropped by egress-deny-all despite this rule supposedly allowing it,
# because it never got evaluated first. Fixed by using 999, matching the
# existing egress_allow_psc/egress_allow_redis pattern (priority 1000) at
# one lower, so it is unambiguously evaluated before both of those and
# egress-deny-all alike.
resource "google_compute_firewall" "allow_zscaler_ips" {
  project            = var.project_id
  name               = "allow-zscaler-ips"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 999
  destination_ranges = ["10.100.209.0/29", "10.100.254.206/32", "10.100.4.66/32"]

  allow { protocol = "icmp" }

  log_config { metadata = "INCLUDE_ALL_METADATA" }
}

# Mirrors aicoedev's "allow-zscalerapp" rule byte-for-byte (same range, same
# protocol/port, same direction, same priority). This is the ingress half
# that actually lets Zscaler-proxied corporate client traffic reach the AI
# Hub ILB frontend (aihub_vip, 10.110.73.20, in 6c-gclt-aicoe-dev-ingress) --
# per the user 2026-09-07: there is no VPC peering involved in how corporate
# clients reach this IP at all; Colt's network team assigns a routable IP,
# DNS points at it, and matching traffic is proxied in through Zscaler.
# Named for what it actually does rather than copying aicoedev's app-specific
# name verbatim.
resource "google_compute_firewall" "ingress_allow_zscaler" {
  project       = var.project_id
  name          = "ingress-allow-zscaler-https"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 65534
  source_ranges = ["10.100.209.0/29"]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config { metadata = "INCLUDE_ALL_METADATA" }
}

# ── private DNS ─────────────────────────────────────────────────────────
resource "google_dns_managed_zone" "internal" {
  project     = var.project_id
  name        = "aicoedev-int"
  dns_name    = "aicoedev-int.colt.net."
  visibility  = "private"
  description = "Platform hostnames, resolvable only inside the VPC"

  private_visibility_config {
    networks { network_url = google_compute_network.vpc.id }
  }
}

resource "google_dns_record_set" "aihub" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.internal.name
  name         = "aihub.aicoedev-int.colt.net."
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
  project     = var.project_id
  name        = "run-app-private"
  dns_name    = "run.app."
  visibility  = "private"
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
output "vpc_self_link" { value = google_compute_network.vpc.self_link }
output "subnet_ew3_self_link" { value = google_compute_subnetwork.subnet_ew3.self_link }
output "cloudrun_subnet_self_link" { value = google_compute_subnetwork.cloudrun.self_link }



output "private_zone_name" { value = google_dns_managed_zone.internal.name }
output "googleapis_zone_name" { value = google_dns_managed_zone.googleapis.name }

output "redis_scp_id" { value = google_network_connectivity_service_connection_policy.redis_cluster.id }
output "proxy_v2_subnet_self_link" { value = google_compute_subnetwork.proxy_v2.self_link }
output "pscnat_v2_subnet_self_link" { value = google_compute_subnetwork.pscnat_v2.self_link }
output "internal_v2_subnet_self_link" { value = google_compute_subnetwork.internal_v2.self_link }
output "redis_psc_v2_subnet_id" { value = google_compute_subnetwork.redis_psc_v2.id }

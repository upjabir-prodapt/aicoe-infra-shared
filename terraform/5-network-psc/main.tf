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
variable "internal_v2_subnet_self_link" { type = string }
# Still supplied by 3-network's handoff but no longer consumed here: the
# Apigee PSC endpoint moved to the internal subnet. Kept declared so the
# handoff file does not error on an undeclared variable.
variable "subnet_ew3_self_link" { type = string }
variable "private_zone_name" { type = string }
variable "instance_service_attachment" {
  type        = string
  description = "From stage 4. This is why the network layer is split."
}
variable "gclt_aicoe_dev_st_project_id" {
  type        = string
  description = "The google_redis_cluster resource below lives in gclt-aicoe-dev-st, not this stage's own gclt-aicoe-dev-network project."
}
# Received via vars-handoff from stage 3 (redis_scp_id output). Not
# referenced directly in any resource block here: the Service Connection
# Policy lives in stage 3's own state, and cross-stage ordering is enforced
# by applying stages in numeric order (2 -> 3 -> 5), not by depends_on.
# Same pattern as subnet_ew3_self_link above.
variable "redis_scp_id" { type = string }

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
#
# Deliberately NON-ROUTABLE. The endpoint lives in the internal
# 192.168.7.80/28 block (migrated from 192.168.6.144/28 -- GAP-REGISTER
# B-04, that whole /24 conflicts with aicoeprod on the shared transit hub),
# not the Colt-routable 10.110.73.0/24. Only Cloud Run services attached to
# this VPC consume it; nothing outside GCP resolves or dials it, and the
# private zone aicoedev-int is VPC-scoped. This reverses the earlier "make
# it routable for Colt DNS" decision (docs/BUILD-LOG.md).
resource "google_compute_address" "apigee_endpoint" {
  project      = var.project_id
  name         = "psc-apigee-ip"
  region       = var.region
  subnetwork   = var.internal_v2_subnet_self_link
  address_type = "INTERNAL"
  address      = "192.168.7.82"
}

resource "google_compute_forwarding_rule" "apigee_endpoint" {
  project               = var.project_id
  name                  = "psc-apigee"
  region                = var.region
  network               = var.vpc_self_link
  subnetwork            = var.internal_v2_subnet_self_link
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
  rrdatas      = [google_compute_address.apigee_northbound_vip.address]
}

resource "google_dns_record_set" "llm" {
  project      = var.project_id
  managed_zone = var.private_zone_name
  name         = "llm.aicoedev-int.colt.net."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.apigee_northbound_vip.address]
}

# Both hostnames resolve to the same LB IP. Apigee selects the environment
# from the Host header, so the hostname is functional; the LB's job is only
# to terminate TLS with the right per-hostname cert via SNI.

# ── Apigee northbound LB — TLS termination, GAP-REGISTER R-06 ───────────
# CONFIRMED LIVE 2026-09-10: `google_compute_forwarding_rule.apigee_endpoint`
# above is a bare PSC consumer endpoint (load_balancing_scheme = ""), pure
# L4 passthrough straight to Apigee's own service attachment. Dialing it
# directly (confirmed via a temporary diagnostic VM, openssl s_client) never
# reaches any hostname-aware TLS config -- it always serves Apigee's own
# ephemeral internal cert (*.<org>.apigee.internal, ~24h rotating, unrelated
# to any real hostname). There is no API-exposed way to attach a keystore to
# an EnvironmentGroup for northbound PSC traffic (confirmed: apigeecli
# keystores/keyaliases upload succeeds but has zero effect on what's served;
# deleted after confirming). Per Google's own documented pattern
# ("Northbound networking with Private Service Connect"), a real hostname
# cert requires an actual regional internal Application Load Balancer in
# front of a PSC-typed NEG -- the same shape 6c-ingress already uses for
# aihub/backend, just with a PSC NEG backend instead of a Serverless NEG.
#
# `google_compute_forwarding_rule.apigee_endpoint` / `.apigee_endpoint`
# address are left in place, now unused by DNS -- not removed here, since
# deleting a live resource wasn't part of what was explained/approved for
# this change. Candidate for cleanup once this LB is confirmed working.

# The Apigee tenant project's service attachment lives outside this stage's
# var.project_id (gclt-aicoe-dev-network, the Shared VPC host); the LB
# resources below live in the SERVICE project instead (gclt-aicoe-dev-
# ingress), same convention 6-workloads/6c-gclt-aicoe-dev-ingress already
# uses for its own address/forwarding-rule/target-https-proxy ("the address
# object belongs in the service project, not the Shared VPC host project").
# Confirmed live 2026-09-10: a regional target_https_proxy's
# certificate_manager_certificates rejects a cert in a different project
# outright ("must belong to the same project as resource referencing it") --
# not just a style preference, an actual API constraint. The NEG and backend
# service must then also move here, since a backend service's backend
# group (NEG) has to be in the same project as the backend service itself.
variable "gclt_aicoe_dev_ingress_project_id" {
  type        = string
  description = "From 1-org. The cert-bearing project the northbound LB resources must live in (see comment above)."
}

resource "google_compute_region_network_endpoint_group" "apigee_psc" {
  project               = var.gclt_aicoe_dev_ingress_project_id
  name                  = "apigee-psc-neg"
  region                = var.region
  network               = var.vpc_self_link
  subnetwork            = var.internal_v2_subnet_self_link
  network_endpoint_type = "PRIVATE_SERVICE_CONNECT"
  psc_target_service    = var.instance_service_attachment
}

resource "google_compute_region_backend_service" "apigee_northbound" {
  project               = var.gclt_aicoe_dev_ingress_project_id
  name                  = "apigee-northbound-bs"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "HTTPS"

  # Set explicitly, not left to the provider: an omitted timeout_sec defaults
  # to 30s, and that default silently broke Sales-Agent on 2026-09-15. Grounded
  # search (Gemini plus the Google Search tool) does a live web search and
  # synthesis, which routinely runs past 30s, so the load balancer killed the
  # request mid-flight and returned
  #   504 {"message":"upstream request timeout","status":"Gateway Timeout"}
  # More than 40% of one job's search queries failed that way, which is over
  # SEARCH_MIN_SUCCESS_RATE (0.6), so the whole research job failed. Nothing in
  # the application was wrong; its own 60s per-query deadline never got to fire
  # because infrastructure cut the call at 30s first.
  #
  # TIMEOUT LAYERING, which is the actual point. Each layer outward must be
  # more generous than the one inside it, so the APPLICATION deadline is what
  # governs and callers get a clean, retryable app-level timeout instead of an
  # opaque infrastructure 504.
  #
  # SOUTHBOUND (llm.aicoedev-int.colt.net -> Vertex):
  #
  #   Sales-Agent SEARCH_TIMEOUT_SECONDS   60s   <- governs, fires first
  #   Apigee io.timeout.millis            120s   <- targets/vertex-gemini-target.xml
  #   this timeout_sec                    360s   <- outermost
  #
  # NORTHBOUND (aihub-api.aicoedev-int.colt.net -> Cloud Run), added with NaaS:
  #
  #   backend Cloud Run --timeout         300s   <- app repos' .gitlab-ci.yml
  #   Apigee io.timeout.millis            330s   <- aihub-api-v1/targets/backends.xml
  #                                                 and mcp-v1/targets/mcp.xml
  #   this timeout_sec                    360s   <- outermost
  #   (BFF upstream_timeout_seconds       420s   <- outside this LB entirely)
  #
  # RAISED 180 -> 360 for NaaS. Its /chat turn is synchronous SSE chaining MCP
  # tool calls against Colt On-Demand with LLM calls, and unlike Translation
  # and Sales-Agent it has no Cloud Tasks worker to offload the slow part onto,
  # so the whole turn sits on this path.
  #
  # Raising only one layer just moves the wall: until the NaaS work, this sat
  # at 180s while BOTH northbound Apigee targets were still on Apigee's 55s
  # default, so every northbound call — Translation and Sales-Agent included —
  # was capped at 55s no matter what this said. Change the set together.
  #
  # SHARED BACKEND, READ BEFORE RETUNING: the url map below sends BOTH
  # aihub-api.aicoedev-int.colt.net and llm.aicoedev-int.colt.net here via a
  # single default_service, so this value applies to the user-facing API
  # gateway AND the LLM gateway. Raising it to 360s therefore also loosens the
  # southbound ceiling; that path stays correctly ordered because its Vertex
  # target's 120s still governs, but the trade is deliberate and worth knowing
  # before anyone tunes it again. If the northbound API ever needs a tighter
  # bound than the LLM gateway, split this into two backend services and add
  # host-based rules to the url map rather than lowering this back.
  timeout_sec = 360

  backend {
    group = google_compute_region_network_endpoint_group.apigee_psc.id
    # Not a no-op default: for a NEG-backed regional backend service, the API
    # does NOT default an omitted capacity_scaler to 1.0 -- it silently ends
    # up 0.0 (0% of traffic routed). Confirmed live 2026-09-10: this exact
    # resource was created without this field and came up at capacityScaler:
    # 0.0, a full outage with no plan-time warning. See docs/BUILD-LOG.md
    # entries #33/#35 and GAP-REGISTER.
    capacity_scaler = 1.0
  }
}

resource "google_compute_region_url_map" "apigee_northbound" {
  project = var.gclt_aicoe_dev_ingress_project_id
  name    = "apigee-northbound-urlmap"
  region  = var.region
  # No real routing decision here -- Apigee itself selects the environment
  # from the Host header once traffic reaches it. One backend for both
  # hostnames.
  default_service = google_compute_region_backend_service.apigee_northbound.id
}

variable "aihub_api_certificate_id" {
  type        = string
  description = "From 2-foundations. GAP-REGISTER R-06."
}
variable "llm_certificate_id" {
  type        = string
  description = "From 2-foundations. GAP-REGISTER R-06."
}

resource "google_compute_region_target_https_proxy" "apigee_northbound" {
  project = var.gclt_aicoe_dev_ingress_project_id
  name    = "apigee-northbound-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.apigee_northbound.id
  # Both certs on one proxy -- GCP SNI-selects the right one per incoming
  # hostname (aihub-api.* vs llm.*), same as how a multi-domain LB normally
  # works. No per-hostname proxy needed since both share one backend.
  certificate_manager_certificates = [
    var.aihub_api_certificate_id,
    var.llm_certificate_id,
  ]
}

resource "google_compute_address" "apigee_northbound_vip" {
  project      = var.gclt_aicoe_dev_ingress_project_id
  name         = "apigee-northbound-vip"
  region       = var.region
  subnetwork   = var.internal_v2_subnet_self_link
  address_type = "INTERNAL"
  # .85 (originally picked here) turned out to already be reserved by
  # something outside normal `gcloud compute addresses`/instances/forwarding-
  # rules visibility - confirmed live 2026-09-10 by probing with a throwaway
  # google_compute_address at each candidate IP (create+delete): .83, .86,
  # .87, .88 all succeeded; .85 alone failed with "already being used by
  # another resource". Using .83 instead - the next free slot right after
  # .82 (raw PSC endpoint, now unused by DNS) in 192.168.7.80/28.
  address = "192.168.7.83"
}

resource "google_compute_forwarding_rule" "apigee_northbound" {
  project               = var.gclt_aicoe_dev_ingress_project_id
  name                  = "apigee-northbound-fr"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = var.vpc_self_link
  subnetwork            = var.internal_v2_subnet_self_link
  ip_address            = google_compute_address.apigee_northbound_vip.id
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.apigee_northbound.id
}

output "apigee_northbound_vip" { value = google_compute_address.apigee_northbound_vip.address }

output "apigee_endpoint_ip" { value = google_compute_address.apigee_endpoint.address }
output "google_apis_ip" { value = google_compute_global_address.google_apis.address }

# ── private DNS for the Google APIs PSC endpoint ─────────────────────────
# FOUND LIVE 2026-09-06: google_apis (the PSC endpoint above) had existed
# since this stage was first applied, but nothing ever routed
# *.googleapis.com to it -- confirmed the hard way, via a real Cloud Run
# deploy failure (sales-agent-worker's GCS FUSE asset mount failing with
# "lookup storage.googleapis.com on 169.254.169.254:53: no such host").
# private_ip_google_access is deliberately false on every subnet (see
# 3-network's subnet_ew3 comment: "every Google API call goes through the
# PSC endpoint, giving one chokepoint that can be logged and restricted") --
# so this DNS zone is not optional hardening, it is the *only* path any
# workload in this VPC has to reach a Google API at all. Same pattern
# already proven working for the Apigee and Model Armor endpoints above,
# generalized to the whole googleapis.com domain per Google's own
# documented pattern ("Create DNS records by using default DNS names").
resource "google_dns_managed_zone" "google_apis" {
  project    = var.project_id
  name       = "googleapis-private"
  dns_name   = "googleapis.com."
  visibility = "private"
  # No description set -- imported from a pre-existing, out-of-band zone
  # (found live 2026-09-06, not created by this apply) whose description was
  # empty; leaving unset avoids a spurious diff on every future plan.

  private_visibility_config {
    networks { network_url = var.vpc_self_link }
  }
}

resource "google_dns_record_set" "google_apis_apex" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.google_apis.name
  name         = "googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.google_apis.address]
}

resource "google_dns_record_set" "google_apis_wildcard" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.google_apis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["googleapis.com."]
}

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
#     subnetworks = [var.internal_v2_subnet_self_link]
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
  # Migrated from gclt-aicoe-dev-internal-ew3 (192.168.6.144/28) to
  # gclt-aicoe-dev-internal-ew3-v2 (192.168.7.80/28) -- GAP-REGISTER B-04.
  subnetwork  = "projects/${var.project_id}/regions/${var.region}/subnetworks/gclt-aicoe-dev-internal-ew3-v2"
  address     = "192.168.7.84"
  access_type = "REGIONAL"
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

# ── Shared Memorystore for Redis Cluster (Translation + Sales-Agent) ────
# Shared cache for Translation + Sales-Agent. ONE cluster, tenant-isolated by
# application-level key prefixes (translation-cache: / salesagent:search:) --
# Cluster mode has only DB 0 and, with AUTH_MODE_DISABLED, no per-tenant auth,
# so prefixes are the only isolation mechanism available. Both apps already
# implement this at every call site.
#
# shard_count MUST stay 1: neither backend uses a cluster-aware client, and a
# standalone redis-py client does not follow MOVED redirects. Raising this
# without first migrating both apps to redis.RedisCluster will break the cache.
#
# Lives in gclt-aicoe-dev-st (var.gclt_aicoe_dev_st_project_id), not this
# stage's own gclt-aicoe-dev-network project -- this stage was chosen because
# it already owns PSC consumer-side wiring and runs after 3-network, whose
# Service Connection Policy (var.redis_scp_id) must exist before this cluster
# can create. That ordering is enforced by applying stages in numeric order
# (2 -> 3 -> 5), not by depends_on: the SCP lives in stage 3's own state, and
# depends_on only accepts resource/module references, not a plain variable.
resource "google_redis_cluster" "st_cache" {
  project     = var.gclt_aicoe_dev_st_project_id
  name        = "st-cache"
  region      = var.region
  shard_count = 1

  psc_configs {
    # google_redis_cluster requires the short resource-name form
    # (projects/{project}/global/networks/{network}), not the full self-link
    # URL every other resource in this stage accepts -- confirmed live:
    # "Error 400: network must be set to a valid VPC network, in the form of
    # projects/{project_id}/global/networks/{network_id}: invalid argument".
    # Derive it from the same var.vpc_self_link everything else here uses,
    # rather than hardcoding the network name a second time.
    network = replace(var.vpc_self_link, "https://www.googleapis.com/compute/v1/", "")
  }

  # Upgraded from REDIS_SHARED_CORE_NANO 2026-09-06. One-way door: Google does
  # not allow moving back down to REDIS_SHARED_CORE_NANO once you leave it
  # (docs/infra/redis-memorystore-psc-setup.md SS5.3). Resizable further with
  # zero downtime via `gcloud redis clusters update` / re-applying this field
  # -- Google's own docs confirm node_type is a live, in-place resize.
  node_type     = "REDIS_STANDARD_SMALL"
  replica_count = 0

  transit_encryption_mode = "TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION"
  authorization_mode      = "AUTH_MODE_DISABLED"

  zone_distribution_config {
    mode = "SINGLE_ZONE"
    zone = "${var.region}-b"
  }

  deletion_protection_enabled = false # dev
}

output "redis_discovery_host" {
  value = google_redis_cluster.st_cache.discovery_endpoints[0].address
}
output "redis_discovery_port" {
  value = google_redis_cluster.st_cache.discovery_endpoints[0].port
}

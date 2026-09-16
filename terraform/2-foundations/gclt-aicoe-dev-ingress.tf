# gclt-aicoe-dev-ingress

module "gclt_aicoe_dev_ingress_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_ingress_project_id
  services = [
    "compute.googleapis.com",
    "iap.googleapis.com",
    "cloudkms.googleapis.com",
    "certificatemanager.googleapis.com",
    "secretmanager.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudresourcemanager.googleapis.com", # see gclt-aicoe-dev-aihub-ui.tf — codified platform-wide 2026-09-02
  ]
  agent_services   = ["iap.googleapis.com"]
  service_accounts = {}
}

# The Binary Authorization signing key is ASYMMETRIC — a signing key, not an
# encryption key. Using a symmetric key here fails in a way that is not
# obvious from the error.
resource "google_kms_key_ring" "gclt_aicoe_dev_ingress_ingress" {
  project  = var.gclt_aicoe_dev_ingress_project_id
  name     = "ingress-ew3"
  location = var.region
}

resource "google_kms_crypto_key" "gclt_aicoe_dev_ingress_attestor" {
  name     = "attestor-signing"
  key_ring = google_kms_key_ring.gclt_aicoe_dev_ingress_ingress.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = "EC_SIGN_P256_SHA256"
    protection_level = "SOFTWARE"
  }

  lifecycle { prevent_destroy = true }
}

resource "google_binary_authorization_attestor" "gclt_aicoe_dev_ingress_build" {
  project = var.gclt_aicoe_dev_ingress_project_id
  name    = "aicoe-build-attestor"

  attestation_authority_note {
    note_reference = google_container_analysis_note.gclt_aicoe_dev_ingress_note.name
    public_keys {
      id = data.google_kms_crypto_key_version.gclt_aicoe_dev_ingress_attestor.id
      pkix_public_key {
        public_key_pem      = data.google_kms_crypto_key_version.gclt_aicoe_dev_ingress_attestor.public_key[0].pem
        signature_algorithm = data.google_kms_crypto_key_version.gclt_aicoe_dev_ingress_attestor.public_key[0].algorithm
      }
    }
  }
}

resource "google_container_analysis_note" "gclt_aicoe_dev_ingress_note" {
  project = var.gclt_aicoe_dev_ingress_project_id
  name    = "aicoe-build-note"
  attestation_authority {
    hint { human_readable_name = "AI CoE build attestor" }
  }
}

data "google_kms_crypto_key_version" "gclt_aicoe_dev_ingress_attestor" {
  crypto_key = google_kms_crypto_key.gclt_aicoe_dev_ingress_attestor.id
}

output "gclt_aicoe_dev_ingress_attestor_name" { value = google_binary_authorization_attestor.gclt_aicoe_dev_ingress_build.name }
output "gclt_aicoe_dev_ingress_service_accounts" { value = module.gclt_aicoe_dev_ingress_baseline.service_accounts }

# --- TLS certificates - self-managed in Certificate Manager ---
# MIGRATION CONTEXT (2026-08-13): this environment REPLACES aicoedev, which is
# being decommissioned. We reuse the aicoedev-int.colt.net domains and the
# existing CA-issued certificates rather than Google's DNS-01 managed certs
# (the earlier managed-cert design - gate P4 - is superseded).
#
# The certs are SELF-MANAGED: PEM + private key are issued by Colt's CA (the
# openssl CSR process), stored in Secret Manager, and uploaded here. Cert
# Manager is only the delivery mechanism to the load balancer - it does NOT
# issue or renew. Renewal is manual: add a new secret version, then re-apply.
# The private key never transits tfvars or state in plaintext.

# Certs are gated behind a toggle so stage 2 can apply (creating the empty
# secret containers and everything else) BEFORE the PEMs exist. Populate the
# secrets, then re-apply with -var="certs_enabled=true" to create the certs.
variable "certs_enabled" {
  type        = bool
  default     = false
  description = "Create the Certificate Manager certs. Requires the PEM+key secret versions to exist first."
}

locals {
  # aihub/backend and aihub_api/llm are deliberately kept as TWO separate
  # maps feeding TWO separate resource addresses below (not one shared
  # for_each over all four). Terraform treats an entire for_each resource
  # address as one graph node: adding new keys (aihub_api/llm) to the SAME
  # for_each as aihub/backend made Terraform defer reading the data source
  # for every key - including the already-stable aihub/backend ones - to
  # apply-time, which then showed up as a false "must be replaced" on the
  # live-referenced aihub/backend certs (pem_certificate is ForceNew, so an
  # unknown-at-plan value there is conservatively treated as a change).
  # Confirmed the aihub/backend cert content itself has NOT drifted (hash-
  # compared state vs. live Certificate Manager vs. current Secret Manager
  # versions - all identical) before concluding this was a graph artifact,
  # not real drift. Splitting the resource address is the same
  # expand-then-contract pattern already used for the v1->v2 migration
  # above - a new resource address can't collaterally affect an unrelated
  # one the way a new for_each key on the same address can.
  existing_certificate_names = {
    aihub   = "aihub.aicoedev-int.colt.net"   # front door - existing aicoedev cert
    backend = "backend.aicoedev-int.colt.net" # backend LB - NEW cert
  }
  northbound_certificate_names = {
    aihub_api = "aihub-api.aicoedev-int.colt.net" # Apigee PSC northbound LB (GAP-REGISTER R-06)
    llm       = "llm.aicoedev-int.colt.net"       # Apigee PSC northbound LB (GAP-REGISTER R-06)
  }
  certificate_names = merge(local.existing_certificate_names, local.northbound_certificate_names)
}

resource "google_secret_manager_secret" "gclt_aicoe_dev_ingress_cert" {
  for_each  = local.existing_certificate_names
  project   = var.gclt_aicoe_dev_ingress_project_id
  secret_id = "tls-${each.key}-certificate"
  replication {
    user_managed {
      replicas { location = var.region }
    }
  }
  labels = { domain = replace(each.value, ".", "-") }
}

resource "google_secret_manager_secret" "gclt_aicoe_dev_ingress_key" {
  for_each  = local.existing_certificate_names
  project   = var.gclt_aicoe_dev_ingress_project_id
  secret_id = "tls-${each.key}-private-key"
  replication {
    user_managed {
      replicas { location = var.region }
    }
  }
  labels = { domain = replace(each.value, ".", "-") }
}

data "google_secret_manager_secret_version" "gclt_aicoe_dev_ingress_cert" {
  for_each = var.certs_enabled ? local.existing_certificate_names : {}
  project  = var.gclt_aicoe_dev_ingress_project_id
  secret   = google_secret_manager_secret.gclt_aicoe_dev_ingress_cert[each.key].secret_id
}

data "google_secret_manager_secret_version" "gclt_aicoe_dev_ingress_key" {
  for_each = var.certs_enabled ? local.existing_certificate_names : {}
  project  = var.gclt_aicoe_dev_ingress_project_id
  secret   = google_secret_manager_secret.gclt_aicoe_dev_ingress_key[each.key].secret_id
}

# --- Northbound (Apigee PSC LB) certs - separate resource addresses, see
# the locals comment above for why these are not merged into the blocks
# above despite being conceptually the same kind of thing. ---

resource "google_secret_manager_secret" "gclt_aicoe_dev_ingress_northbound_cert" {
  for_each  = local.northbound_certificate_names
  project   = var.gclt_aicoe_dev_ingress_project_id
  secret_id = "tls-${each.key}-certificate"
  replication {
    user_managed {
      replicas { location = var.region }
    }
  }
  labels = { domain = replace(each.value, ".", "-") }
}

resource "google_secret_manager_secret" "gclt_aicoe_dev_ingress_northbound_key" {
  for_each  = local.northbound_certificate_names
  project   = var.gclt_aicoe_dev_ingress_project_id
  secret_id = "tls-${each.key}-private-key"
  replication {
    user_managed {
      replicas { location = var.region }
    }
  }
  labels = { domain = replace(each.value, ".", "-") }
}

data "google_secret_manager_secret_version" "gclt_aicoe_dev_ingress_northbound_cert" {
  for_each = var.certs_enabled ? local.northbound_certificate_names : {}
  project  = var.gclt_aicoe_dev_ingress_project_id
  secret   = google_secret_manager_secret.gclt_aicoe_dev_ingress_northbound_cert[each.key].secret_id
}

data "google_secret_manager_secret_version" "gclt_aicoe_dev_ingress_northbound_key" {
  for_each = var.certs_enabled ? local.northbound_certificate_names : {}
  project  = var.gclt_aicoe_dev_ingress_project_id
  secret   = google_secret_manager_secret.gclt_aicoe_dev_ingress_northbound_key[each.key].secret_id
}

# REMOVED 2026-09-09 (was google_certificate_manager_certificate.gclt_aicoe_dev_ingress,
# cert-aihub/cert-backend): the documented renewal procedure above ("add a new
# secret version, then re-apply") does not actually work -- the provider marks
# pem_certificate/pem_private_key as unconditionally ForceNew, but the API
# refuses to delete a certificate still referenced by a target_https_proxy
# ("RESOURCE_STILL_IN_USE"), and both aihub-proxy/backend-proxy in 6c
# reference these. Confirmed live: the self-signed-placeholder-to-real-cert
# renewal this same day had to be applied out-of-band via `gcloud
# certificate-manager certificates update` instead, leaving that resource's
# Terraform state permanently out of sync with the live cert content
# (GAP-REGISTER B-05). Replaced by gclt_aicoe_dev_ingress_v2 below via the
# same expand-then-contract pattern used for the subnet migrations this
# session: created the new-named resource, repointed 6c's proxies at it
# (confirmed live, still-working HTTP 302/IAP response), confirmed the old
# certs showed empty usedBy, then removed this resource here. If this cert
# ever needs renewing again, expect the exact same ForceNew/still-referenced
# conflict -- repeat this same create-v3/repoint/remove-v2 pattern, don't
# just bump the secret version and re-apply in place.

# Reads the SAME already-correct secrets (no new
# secret versions needed) into a differently-NAMED Certificate Manager
# resource, avoiding the ForceNew/still-referenced conflict entirely, since
# creating a new resource is not subject to the same delete-while-in-use
# restriction. Once 6c references this instead of the resource above, the
# one above can be safely removed.
resource "google_certificate_manager_certificate" "gclt_aicoe_dev_ingress_v2" {
  for_each    = var.certs_enabled ? local.existing_certificate_names : {}
  project     = var.gclt_aicoe_dev_ingress_project_id
  location    = "europe-west3"
  name        = "cert-${each.key}-v2"
  description = "Self-managed, CA-issued - ${each.value} (v2, see GAP-REGISTER B-05)"
  self_managed {
    pem_certificate = data.google_secret_manager_secret_version.gclt_aicoe_dev_ingress_cert[each.key].secret_data
    pem_private_key = data.google_secret_manager_secret_version.gclt_aicoe_dev_ingress_key[each.key].secret_data
  }
}

# Northbound certs - separate resource address, see the locals comment above.
resource "google_certificate_manager_certificate" "gclt_aicoe_dev_ingress_northbound" {
  for_each = var.certs_enabled ? local.northbound_certificate_names : {}
  project  = var.gclt_aicoe_dev_ingress_project_id
  location = "europe-west3"
  # Certificate Manager resource IDs allow only lowercase letters, digits and
  # hyphens - each.key ("aihub_api") has an underscore, which google_secret_
  # manager_secret's secret_id tolerates but this API rejects outright
  # ("resource id must consists of no more than 63 characters: lower case
  # letters, digits and hyphens"). Swap _ for - here only; the map key itself
  # stays aihub_api everywhere else (it's also a valid HCL identifier).
  name        = "cert-${replace(each.key, "_", "-")}-v2"
  description = "Self-managed, CA-issued - ${each.value} (GAP-REGISTER R-06)"
  self_managed {
    pem_certificate = data.google_secret_manager_secret_version.gclt_aicoe_dev_ingress_northbound_cert[each.key].secret_data
    pem_private_key = data.google_secret_manager_secret_version.gclt_aicoe_dev_ingress_northbound_key[each.key].secret_data
  }
}

output "aihub_certificate_id" {
  description = "Consumed by 6c as the AI Hub frontend certificate."
  value       = var.certs_enabled ? google_certificate_manager_certificate.gclt_aicoe_dev_ingress_v2["aihub"].id : ""
}
output "backend_certificate_id" {
  description = "Consumed by 6c as the backend frontend certificate."
  value       = var.certs_enabled ? google_certificate_manager_certificate.gclt_aicoe_dev_ingress_v2["backend"].id : ""
}
output "aihub_api_certificate_id" {
  description = "Consumed by 5-network-psc as the Apigee (int env group) northbound LB certificate. GAP-REGISTER R-06."
  value       = var.certs_enabled ? google_certificate_manager_certificate.gclt_aicoe_dev_ingress_northbound["aihub_api"].id : ""
}
output "llm_certificate_id" {
  description = "Consumed by 5-network-psc as the Apigee (llm env group) northbound LB certificate. GAP-REGISTER R-06."
  value       = var.certs_enabled ? google_certificate_manager_certificate.gclt_aicoe_dev_ingress_northbound["llm"].id : ""
}

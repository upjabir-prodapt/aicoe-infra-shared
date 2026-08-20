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

output "gclt_aicoe_dev_ingress_attestor_name"    { value = google_binary_authorization_attestor.gclt_aicoe_dev_ingress_build.name }
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
  certificate_names = {
    aihub   = "aihub.aicoedev-int.colt.net"   # front door - existing aicoedev cert
    backend = "backend.aicoedev-int.colt.net" # backend LB - NEW cert
  }
}

resource "google_secret_manager_secret" "gclt_aicoe_dev_ingress_cert" {
  for_each  = local.certificate_names
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
  for_each  = local.certificate_names
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
  for_each   = var.certs_enabled ? local.certificate_names : {}
  project    = var.gclt_aicoe_dev_ingress_project_id
  secret     = google_secret_manager_secret.gclt_aicoe_dev_ingress_cert[each.key].secret_id
  depends_on = [google_secret_manager_secret.gclt_aicoe_dev_ingress_cert]
}

data "google_secret_manager_secret_version" "gclt_aicoe_dev_ingress_key" {
  for_each   = var.certs_enabled ? local.certificate_names : {}
  project    = var.gclt_aicoe_dev_ingress_project_id
  secret     = google_secret_manager_secret.gclt_aicoe_dev_ingress_key[each.key].secret_id
  depends_on = [google_secret_manager_secret.gclt_aicoe_dev_ingress_key]
}

resource "google_certificate_manager_certificate" "gclt_aicoe_dev_ingress" {
  for_each    = var.certs_enabled ? local.certificate_names : {}
  project     = var.gclt_aicoe_dev_ingress_project_id
  location    = "europe-west3"
  name        = "cert-${each.key}"
  description = "Self-managed, CA-issued - ${each.value}"
  self_managed {
    pem_certificate = data.google_secret_manager_secret_version.gclt_aicoe_dev_ingress_cert[each.key].secret_data
    pem_private_key = data.google_secret_manager_secret_version.gclt_aicoe_dev_ingress_key[each.key].secret_data
  }
}

output "aihub_certificate_id" {
  description = "Consumed by 6c as the AI Hub frontend certificate."
  value       = var.certs_enabled ? google_certificate_manager_certificate.gclt_aicoe_dev_ingress["aihub"].id : ""
}
output "backend_certificate_id" {
  description = "Consumed by 6c as the backend frontend certificate."
  value       = var.certs_enabled ? google_certificate_manager_certificate.gclt_aicoe_dev_ingress["backend"].id : ""
}

# gclt-aicoe-dev-ingress

module "gclt_aicoe_dev_ingress_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_ingress_project_id
  services = [
    "compute.googleapis.com",
    "iap.googleapis.com",
    "cloudkms.googleapis.com",
    "certificatemanager.googleapis.com",
    "binaryauthorization.googleapis.com",
  ]
  agent_services   = ["iap.googleapis.com"]
  service_accounts = { "tf-deployer" = { display_name = "Terraform deployer, ingress" } }
}

# The Binary Authorization signing key is ASYMMETRIC — a signing key, not an
# encryption key. Using a symmetric key here fails in a way that is not
# obvious from the error.
resource "google_kms_key_ring" "gclt_aicoe_dev_ingress_ingress" {
  project  = var.gclt_aicoe_dev_ingress_project_id
  name     = "ingress"
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

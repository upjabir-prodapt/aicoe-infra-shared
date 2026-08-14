# 0-bootstrap — run ONCE, MANUALLY, with an administrator's own credentials.
#
# This is the only stage that cannot run in the pipeline, because it creates
# the things the pipeline needs to exist: the state bucket and the identity
# CI authenticates as.
#
# Sequence:
#   1. terraform init          (local state)
#   2. terraform apply         (creates the bucket)
#   3. uncomment the backend block below
#   4. terraform init -migrate-state
#   5. commit, and never run this stage from CI again

terraform {
  required_version = ">= 1.9"
  backend "gcs" {} # step 3 — enabled 2026-08-12, state migrated
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
  }
}

variable "seed_project_id" {
  type        = string
  description = "Holds Terraform state and the CI service accounts. Separate from workload projects on purpose — it can create and modify everything else."
}
variable "region" { type = string }
variable "location" {
  type = string

  # Must equal var.region, not the "EU" multi-region this used to default to.
  # Two reasons, either of which is fatal on its own:
  #
  #   1. A bucket's CMEK key must live in the same location as the bucket. The
  #      key ring below is created at var.region, so an EU bucket fails at
  #      apply — after the ring exists, leaving stage 0 half-built with only
  #      local state to recover from.
  #   2. An EU multi-region bucket does not satisfy the
  #      in:europe-west1-locations residency policy.
  default = "europe-west1"

  validation {
    condition     = length(regexall("^[a-z]+-[a-z]+[0-9]$", var.location)) > 0
    error_message = "location must be a single region such as europe-west1, matching the CMEK key ring's location. A multi-region value fails at apply."
  }
}
variable "target_projects" {
  type        = list(string)
  description = "Every project that will have a Terraform service account."
}

# ── seed project APIs ───────────────────────────────────────────────────
# Everything is enabled through Terraform, per the 2026-08-12 decision.
# These four are what stage 0 itself needs: KMS for the state key, Storage
# for the bucket, IAM for the service accounts and the WIF pool, and
# IAM Credentials for service-account impersonation by the pipeline.
# google_project_service adopts already-enabled APIs cleanly, so applying
# this over a project where they were enabled by hand is a no-op.
resource "google_project_service" "seed" {
  for_each = toset([
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
  ])
  project            = var.seed_project_id
  service            = each.value
  disable_on_destroy = false
}

# ── state bucket ────────────────────────────────────────────────────────
resource "google_kms_key_ring" "state" {
  project    = var.seed_project_id
  name       = "tfstate"
  location   = var.region
  depends_on = [google_project_service.seed]
}

resource "google_kms_crypto_key" "state" {
  name            = "tfstate"
  key_ring        = google_kms_key_ring.state.id
  rotation_period = "7776000s"
  lifecycle { prevent_destroy = true }
}

data "google_storage_project_service_account" "gcs" {
  project = var.seed_project_id
}

resource "google_kms_crypto_key_iam_member" "gcs" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_bucket" "state" {
  project                     = var.seed_project_id
  name                        = "${var.seed_project_id}-tfstate"
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning { enabled = true }

  encryption { default_kms_key_name = google_kms_crypto_key.state.id }

  lifecycle_rule {
    condition { num_newer_versions = 20 }
    action { type = "Delete" }
  }

  # Losing this bucket means losing the record of every resource in the
  # estate. Deleting it is never the right answer to any problem.
  lifecycle { prevent_destroy = true }

  depends_on = [google_kms_crypto_key_iam_member.gcs]
}

# ── one Terraform service account per project ───────────────────────────
# Each stage impersonates the account for the project it touches, so a
# compromised pipeline for one stage cannot modify another project.

resource "google_service_account" "tf" {
  for_each     = toset(var.target_projects)
  project      = each.value
  account_id   = "tf-deployer"
  display_name = "Terraform deployer for ${each.value}"
}

# Each account may write only its own state prefix.
resource "google_storage_bucket_iam_member" "state_access" {
  for_each = google_service_account.tf
  bucket   = google_storage_bucket.state.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${each.value.email}"

  condition {
    title      = "own-prefix-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state.name}/objects/${each.key}/\")"
  }
}

output "state_bucket" { value = google_storage_bucket.state.name }
output "deployer_emails" { value = { for k, v in google_service_account.tf : k => v.email } }

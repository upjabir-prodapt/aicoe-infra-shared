# A key ring, its keys, and the service agent bindings — in the right order.
#
# WHY THE ORDERING MATTERS
# A CMEK-protected resource fails at creation if the relevant service agent
# cannot use the key. Terraform will happily create the key and the resource
# concurrently unless told otherwise, so every binding carries an explicit
# depends_on and consumers depend on this module's output.

variable "project_id"        { type = string }
variable "location"          { type = string }
variable "ring_name"         { type = string }
variable "keys" {
  type = map(object({
    rotation_period = optional(string, "7776000s") # 90 days
    purpose         = optional(string, "ENCRYPT_DECRYPT")
    algorithm       = optional(string, "GOOGLE_SYMMETRIC_ENCRYPTION")
  }))
}
variable "key_grants" {
  type        = map(list(string))
  description = "Key name to list of member emails needing encrypt/decrypt."
  default     = {}
}

resource "google_kms_key_ring" "ring" {
  project  = var.project_id
  name     = var.ring_name
  location = var.location
}

resource "google_kms_crypto_key" "key" {
  for_each        = var.keys
  name            = each.key
  key_ring        = google_kms_key_ring.ring.id
  purpose         = each.value.purpose
  rotation_period = each.value.purpose == "ENCRYPT_DECRYPT" ? each.value.rotation_period : null

  version_template {
    algorithm        = each.value.algorithm
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = true # destroying a key makes its data unreadable
  }
}

locals {
  grants = flatten([
    for key_name, members in var.key_grants : [
      for m in members : { key = key_name, member = m }
    ]
  ])
}

resource "google_kms_crypto_key_iam_member" "grant" {
  for_each      = { for g in local.grants : "${g.key}:${g.member}" => g }
  crypto_key_id = google_kms_crypto_key.key[each.value.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${each.value.member}"

  depends_on = [google_kms_crypto_key.key]
}

output "key_ids" {
  value = { for k, v in google_kms_crypto_key.key : k => v.id }
}

# Consumers depend on this rather than on key_ids, so Terraform waits for the
# bindings and not merely for the keys.
output "ready" {
  description = "Depend on this from any CMEK-protected resource."
  value       = join(",", [for g in google_kms_crypto_key_iam_member.grant : g.id])
}

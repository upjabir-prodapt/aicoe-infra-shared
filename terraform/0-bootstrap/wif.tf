# Workload Identity Federation — how GitLab authenticates to Google.
# Part of bootstrap because the pipeline cannot create the thing it needs
# in order to run.
#
# WHY THIS STACK IS SECURITY-CRITICAL
# One pool serves dev AND prod. The provider's attribute_condition is
# therefore the only thing preventing a dev pipeline from impersonating a
# production Terraform service account. Treat it as a control, not config.

variable "gitlab_issuer" {
  type        = string
  description = "GitLab instance issuer URL, for example https://amsgit01.colt.net"
}
variable "gitlab_audience" { type = string }
variable "allowed_repositories" {
  type        = list(string)
  description = "GitLab project_paths permitted to impersonate, e.g. [\"code-scanning-toolset/aicoe-terraform\"]. The Terraform repo plus every use-case app repo that deploys through this pool."
}

resource "google_iam_workload_identity_pool" "gitlab" {
  project                   = var.seed_project_id
  workload_identity_pool_id = "gitlab-pool"
  display_name              = "GitLab CI"
  description               = "Serves dev and prod. Separation is by attribute condition."

  # No depends_on. An earlier revision made this wait on a "baseline" module
  # that this stage never declared, so `terraform plan` failed outright with
  # "Reference to undeclared module". The pool depends only on
  # var.seed_project_id, which names a project that already exists.
}

resource "google_iam_workload_identity_pool_provider" "gitlab" {
  project                            = var.seed_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = "gitlab-provider"
  display_name                       = "GitLab OIDC"

  oidc {
    issuer_uri        = var.gitlab_issuer
    allowed_audiences = [var.gitlab_audience]

    # amsgit01 is internal-only: Google cannot fetch the OIDC discovery
    # document or JWKS over the internet, so the signing keys are embedded
    # here — the same pattern as the proven-working gitlab-pool in aicoedev.
    # OPERATIONAL CONSEQUENCE: when GitLab rotates its token-signing keys,
    # this file must be updated (re-fetch /oauth/discovery/keys) or token
    # exchange starts failing. The keys below were captured 2026-08-12.
    jwks_json = file("${path.module}/gitlab-jwks.json")
  }

  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.project_path"  = "assertion.project_path"
    "attribute.ref_protected" = "assertion.ref_protected"
    "attribute.environment"   = "assertion.environment"
    "attribute.ref"           = "assertion.ref"
  }

  # THE control. Without a condition, any repository on this GitLab instance
  # that can mint a token for the audience can impersonate any service
  # account bound to the pool — including production ones.
  # Covers the Terraform repo and the use-case app repos (translation,
  # sales-agent) that deploy through this pool. App repos additionally need
  # an SA binding (workloadIdentityUser) before their pipelines can
  # impersonate — that arrives with stage 6b.
  attribute_condition = <<-EOT
    attribute.project_path in ${jsonencode(var.allowed_repositories)} &&
    attribute.ref_protected == "true"
  EOT
}

output "pool_name" { value = google_iam_workload_identity_pool.gitlab.name }
output "provider_name" { value = google_iam_workload_identity_pool_provider.gitlab.name }
output "wif_project_number" { value = data.google_project.this.number }

data "google_project" "this" { project_id = var.seed_project_id }

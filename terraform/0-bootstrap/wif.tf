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
variable "allowed_repository" {
  type        = string
  description = "GitLab project_path permitted to impersonate, e.g. aicoe/terraform"
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
  attribute_condition = <<-EOT
    attribute.project_path == "${var.allowed_repository}" &&
    attribute.ref_protected == "true"
  EOT
}

output "pool_name"        { value = google_iam_workload_identity_pool.gitlab.name }
output "provider_name"    { value = google_iam_workload_identity_pool_provider.gitlab.name }
output "wif_project_number" { value = data.google_project.this.number }

data "google_project" "this" { project_id = var.seed_project_id }

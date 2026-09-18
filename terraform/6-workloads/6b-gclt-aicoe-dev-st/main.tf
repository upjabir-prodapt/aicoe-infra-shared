# infra/st — backend services and NEGs for the usecase Cloud Run services.
#
# The Cloud Run services themselves are built by the application teams. This
# stack creates the load balancer backends that must live alongside them, and
# the run.invoker grants that let Apigee call them.

terraform {
  required_version = ">= 1.9"
  backend "gcs" {}
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "apigee_runtime_sa" { type = string }
variable "worker_invoker_sa" { type = string }
variable "translation_api_sa" { type = string }
variable "salesagent_sa" { type = string }

# NaaS. Declared because 2-foundations publishes them in its handoff file and
# an undeclared value there is a warning on every plan -- not because this
# stage grants either of them anything. NaaS has no Cloud Tasks queue, so
# there is no enqueuer binding to make; the identities are consumed by the app
# repos' deploy jobs (--service-account=) and by 2-foundations' actAs grants.
variable "naas_api_sa" { type = string }
variable "mcp_sa" { type = string }

module "bs_translation" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-translation"
  cloud_run_service = "translation-api"
  enable_iap        = false # Cloud Run IAM handles this hop
}

module "bs_sales" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-sales"
  cloud_run_service = "sales-agent-api"
  enable_iap        = false
}

# ── NaaS · two services, both Apigee-fronted ────────────────────────────
# naas-agent-api is the user-facing half, reached at /api/naas/v1/** exactly
# like the two above. naas-mcp-server is NOT user-facing: its only caller is
# naas-agent-api, via the separate mcp-v1 Apigee proxy, because by the time
# the backend runs Apigee has already replaced the user's Entra JWT with
# x-colt-user-* headers -- there is no token left to forward, so that hop
# authenticates with an Apigee API key instead. It still needs a backend
# service and NEG because it is still reached through the internal LB.
module "bs_naas" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-naas"
  cloud_run_service = "naas-agent-api"
  enable_iap        = false
}

module "bs_mcp" {
  source            = "../../modules/cloudrun-backend"
  project_id        = var.project_id
  region            = var.region
  name              = "bs-mcp"
  cloud_run_service = "naas-mcp-server"
  enable_iap        = false
}

# ── the entire authentication design for the backend hop ────────────────
# Apigee sends a Google ID token in X-Serverless-Authorization whose audience
# is the Cloud Run service URL. Cloud Run validates it against run.invoker.
# No IAP, no OAuth client, no allUsers.

resource "google_cloud_run_v2_service_iam_member" "apigee_invoker" {
  # naas-mcp-server is in this list for the same reason as the three API
  # services: Apigee is its direct caller. Its own middleware verifies exactly
  # this -- the ID token's audience against MCP_SERVICE_URL and its email claim
  # against APIGEE_RUNTIME_SA_EMAIL -- so a missing binding here fails as a
  # Cloud Run 403 before the app sees the request at all.
  for_each = toset(["translation-api", "sales-agent-api", "naas-agent-api", "naas-mcp-server"])
  project  = var.project_id
  location = var.region
  name     = each.value
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.apigee_runtime_sa}"
}

# Both workers are Cloud Tasks-driven, not LB-fronted: they only need
# run.invoker for worker_invoker_sa (the identity Cloud Tasks' OIDC token
# carries), not a load balancer backend.
resource "google_cloud_run_v2_service_iam_member" "worker_invoker" {
  for_each = toset(["translation-worker", "sales-agent-worker"])
  project  = var.project_id
  location = var.region
  name     = each.value
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.worker_invoker_sa}"
}

# Guard rail: fail the plan if anyone has added a public binding.
#
# Widened from translation-api alone to every service this stage fronts. The
# single-service version was not a deliberate scope choice -- it was simply
# written before the other services existed, and left a new usecase outside
# the only real check in this stage.
locals {
  guarded_services = [
    "translation-api",
    "sales-agent-api",
    "naas-agent-api",
    "naas-mcp-server",
  ]
}

data "google_cloud_run_v2_service" "guarded" {
  for_each = toset(local.guarded_services)
  project  = var.project_id
  location = var.region
  name     = each.value
}

# Read the live IAM policy and assert no public principal is bound. This is
# a real check over real state, not the assert-true placeholder it replaces.
# The data source exports the policy as JSON in policy_data, so decode it.
data "google_cloud_run_v2_service_iam_policy" "guarded" {
  for_each = toset(local.guarded_services)
  project  = var.project_id
  location = var.region
  name     = data.google_cloud_run_v2_service.guarded[each.key].name
}

locals {
  # try() guards the case where the service currently has zero IAM bindings
  # (our exact state before this stage's first apply): policy_data is then
  # the literal string "{}" with no "bindings" key at all, not an empty
  # list -- indexing .bindings directly on that fails with "this object
  # does not have an attribute named bindings" rather than evaluating to
  # an empty policy, which is what a from-scratch or freshly-locked-down
  # service actually looks like.
  guarded_policy_members = flatten([
    for name in local.guarded_services :
    flatten([
      for b in try(jsondecode(data.google_cloud_run_v2_service_iam_policy.guarded[name].policy_data).bindings, []) : b.members
    ])
  ])
}

check "no_public_invoker" {
  assert {
    condition     = !contains(local.guarded_policy_members, "allUsers") && !contains(local.guarded_policy_members, "allAuthenticatedUsers")
    error_message = "A Cloud Run service must never grant allUsers or allAuthenticatedUsers."
  }
}

output "translation_backend_service_self_link" { value = module.bs_translation.self_link }
output "sales_backend_service_self_link" { value = module.bs_sales.self_link }
output "naas_backend_service_self_link" { value = module.bs_naas.self_link }
output "mcp_backend_service_self_link" { value = module.bs_mcp.self_link }

# ── async fan-out · translation worker ──────────────────────────────────
# The translation worker path depends on a Cloud Tasks queue, per the LLD's
# service integration matrix. The queue dispatches to the worker over OIDC:
# the worker_invoker_sa holds run.invoker on translation-worker-service, and
# each task carries an ID token whose audience is the worker's service URL.
# The queue is created here; the per-task http_target and oidc_token are set
# by the application when it enqueues, because the target URL is only known
# once the worker service exists.

resource "google_cloud_tasks_queue" "translation" {
  project  = var.project_id
  location = var.region
  name     = "translation-jobs"

  rate_limits {
    max_concurrent_dispatches = 10
    max_dispatches_per_second = 5
  }

  retry_config {
    max_attempts       = 5
    min_backoff        = "10s"
    max_backoff        = "300s"
    max_doublings      = 4
    max_retry_duration = "600s"
  }

  # No public dispatch. Tasks are enqueued by the translation-api service
  # account and dispatched to the worker as worker_invoker_sa.
}

output "translation_queue_id" {
  description = "Fully qualified queue id the translation-api enqueues to."
  value       = google_cloud_tasks_queue.translation.id
}

# ── async fan-out · sales-agent research worker ──────────────────────────
# Same shape as the translation queue: sales-agent-api enqueues, the worker
# dispatches over OIDC as worker_invoker_sa.

resource "google_cloud_tasks_queue" "research" {
  project  = var.project_id
  location = var.region
  name     = "research-jobs"

  rate_limits {
    max_concurrent_dispatches = 10
    max_dispatches_per_second = 5
  }

  retry_config {
    max_attempts       = 5
    min_backoff        = "10s"
    max_backoff        = "300s"
    max_doublings      = 4
    max_retry_duration = "600s"
  }

  # No public dispatch. Tasks are enqueued by the sales-agent-api service
  # account and dispatched to the worker as worker_invoker_sa.
}

output "research_queue_id" {
  description = "Fully qualified queue id the sales-agent-api enqueues to."
  value       = google_cloud_tasks_queue.research.id
}

# ── enqueuer IAM ──────────────────────────────────────────────────────────
# Queue-scoped, granted here rather than in 2-foundations, because the
# queues are resources of this stage and 2-foundations does not read this
# stage's state (only the reverse, via vars-handoff).
resource "google_cloud_tasks_queue_iam_member" "translation_api_enqueuer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.translation.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${var.translation_api_sa}"
}

resource "google_cloud_tasks_queue_iam_member" "salesagent_enqueuer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.research.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${var.salesagent_sa}"
}

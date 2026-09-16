# gclt-aicoe-dev-st

module "gclt_aicoe_dev_st_baseline" {
  source     = "../modules/project-baseline"
  project_id = var.gclt_aicoe_dev_st_project_id
  services = [
    "run.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudtasks.googleapis.com",
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "aiplatform.googleapis.com",
    "dlp.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "firestore.googleapis.com",
    "cloudresourcemanager.googleapis.com", # see gclt-aicoe-dev-aihub-ui.tf — codified platform-wide 2026-09-02
    # Shared Memorystore for Redis Cluster (Translation + Sales-Agent cache).
    # The cluster itself is created in stage 5-network-psc, not here: it cannot
    # exist until 3-network's gcp-memorystore-redis Service Connection Policy
    # does, and stages apply in numeric order.
    "redis.googleapis.com",
  ]
  agent_services = [
    "artifactregistry.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "secretmanager.googleapis.com", # needed for the CMEK app-config secrets below
  ]

  # One identity per service. A shared account means a compromise anywhere
  # is a compromise everywhere.
  service_accounts = {
    "translation-api-sa"    = { display_name = "Translation API" }
    "translation-worker-sa" = { display_name = "Translation worker" }
    "salesagent-sa"         = { display_name = "Sales research agent" }
    "mcp-sa"                = { display_name = "MCP server (future)" }
    "worker-invoker-sa"     = { display_name = "Cloud Tasks, invokes the worker" }
  }
}

module "gclt_aicoe_dev_st_kms" {
  source     = "../modules/kms-ring"
  project_id = var.gclt_aicoe_dev_st_project_id
  location   = var.region
  ring_name  = "st-ew3"
  keys = {
    "app-gcs"    = {}
    "bq"         = {}
    "vxai-index" = {}
    "secrets"    = {}
    "artifacts"  = {}
  }
  key_grants = {
    "artifacts"  = [module.gclt_aicoe_dev_st_baseline.agent_emails["artifactregistry.googleapis.com"]]
    "app-gcs"    = [module.gclt_aicoe_dev_st_baseline.agent_emails["storage.googleapis.com"]]
    "bq"         = [module.gclt_aicoe_dev_st_baseline.agent_emails["bigquery.googleapis.com"]]
    "vxai-index" = [module.gclt_aicoe_dev_st_baseline.agent_emails["aiplatform.googleapis.com"]]
    "secrets"    = [module.gclt_aicoe_dev_st_baseline.agent_emails["secretmanager.googleapis.com"]]
  }
}

resource "google_artifact_registry_repository" "gclt_aicoe_dev_st_containers" {
  project       = var.gclt_aicoe_dev_st_project_id
  location      = var.region
  repository_id = "containers"
  format        = "DOCKER"
  kms_key_name  = module.gclt_aicoe_dev_st_kms.key_ids["artifacts"]
  docker_config { immutable_tags = true }
  depends_on = [module.gclt_aicoe_dev_st_kms]
}

resource "google_binary_authorization_policy" "gclt_aicoe_dev_st_policy" {
  project = var.gclt_aicoe_dev_st_project_id
  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = [google_binary_authorization_attestor.gclt_aicoe_dev_ingress_build.id]
  }
}

# ── THE step that makes the AI gateway a control rather than a convention ─
# No workload service account holds aiplatform.user. Only the Apigee LLM
# runtime does, and that grant lives in static/llm. This check exists to make
# the absence deliberate and reviewable rather than accidental.
#
# See the LLD's decision log, D-30. Until this holds, every gateway control
# is advisory.

output "gclt_aicoe_dev_st_workload_service_accounts" {
  description = "None of these may hold roles/aiplatform.user anywhere."
  value       = module.gclt_aicoe_dev_st_baseline.service_accounts
}
output "gclt_aicoe_dev_st_kms_key_ids" { value = module.gclt_aicoe_dev_st_kms.key_ids }

# Scalar output named exactly for stage 6b's variable, so the
# .auto.tfvars.json handoff wires it without a rename. Same pattern as
# apigee_runtime_sa / apigee_llm_runtime_sa in gclt-aicoe-dev-apigee.tf.
output "worker_invoker_sa" {
  description = "Cloud Tasks invoker for the translation worker. Consumed by stage 6b."
  value       = module.gclt_aicoe_dev_st_baseline.service_accounts["worker-invoker-sa"]
}

# Scalar outputs named exactly for stage 6b's variables, same handoff
# pattern as worker_invoker_sa above — consumed for the queue-scoped
# cloudtasks.enqueuer grants in 6b.
output "translation_api_sa" {
  description = "Enqueues to translation-jobs. Consumed by stage 6b."
  value       = local.translation_api_sa
}
output "salesagent_sa" {
  description = "Enqueues to research-jobs. Consumed by stage 6b."
  value       = local.salesagent_sa
}

# ── data plane · job records and artefacts ──────────────────────────────
# The st project carries BigQuery for job records and GCS for source and
# translated artefacts, per the LLD's service integration matrix. Both are
# CMEK-protected — the policy check fails any dataset or bucket without a
# customer-managed key. Table schemas stay application-owned; only the
# dataset and buckets are platform resources.

resource "google_bigquery_dataset" "gclt_aicoe_dev_st_jobs" {
  project       = var.gclt_aicoe_dev_st_project_id
  dataset_id    = "translation_jobs"
  friendly_name = "Translation job records"
  location      = var.region

  default_encryption_configuration {
    kms_key_name = module.gclt_aicoe_dev_st_kms.key_ids["bq"]
  }

  depends_on = [module.gclt_aicoe_dev_st_kms]
}

# Sales-Agent's mirror of translation_jobs.
#
# CHANGED 2026-09-14: table schemas used to be application-owned — each repo's
# scripts/create_bigquery_tables.sh created them, and only the dataset was a
# platform resource. Nobody ever ran those scripts against this estate, so both
# datasets sat empty and every Translation submission died with
# "404 Table translation_jobs.translation_jobs was not found in location
# europe-west3" — after the request had already passed Apigee, minted its ID
# token and uploaded the source document to GCS. A creation step that lives in
# a script someone has to remember to run is not owned by anyone; the tables
# are now Terraform resources below. See docs/BUILD-LOG.md #38.
resource "google_bigquery_dataset" "gclt_aicoe_dev_st_sales_agent_jobs" {
  project       = var.gclt_aicoe_dev_st_project_id
  dataset_id    = "sales_agent_jobs"
  friendly_name = "Sales-Agent research job records"
  location      = var.region

  default_encryption_configuration {
    kms_key_name = module.gclt_aicoe_dev_st_kms.key_ids["bq"]
  }

  depends_on = [module.gclt_aicoe_dev_st_kms]
}

# ── BigQuery tables ─────────────────────────────────────────────────────
# Schemas are vendored under bigquery-schemas/ rather than read from the
# Translation/Sales-Agent repos: CI checks out only this repository, so a
# file() pointing at a sibling checkout would work locally and fail in the
# pipeline. The copies are authoritative for the table objects; the apps stay
# authoritative for what the columns mean. Keep them in step when either app
# changes a schema — BigQuery will accept additive NULLABLE columns in place,
# but a type change or a dropped column forces replacement, which
# deletion_protection below deliberately blocks.
#
# Partitioning and clustering were chosen from the actual queries in both
# repos, not from defaults (full inventory in docs/BUILD-LOG.md #38):
#   - Point lookups dominate — job_id / job_execution_id lead every cluster
#     list, because MERGE, UPDATE and every get-by-id filter on them.
#   - Only research_requests has a query that genuinely prunes by partition
#     (its list filters created_at >= 7 days). Elsewhere the DAY partition
#     earns its place through retention and BI, not through today's reads.
#   - business_unit columns exist on the job tables only as of 2026-09-14,
#     denormalised out of the cost_attribution / metadata JSON blobs by the
#     apps. BigQuery cannot cluster on a JSON_VALUE() expression, which is
#     why the denormalisation was needed at all. Note the list queries still
#     filter via JSON_VALUE, so that clustering benefits new analytical
#     queries rather than the existing reads until those WHERE clauses move
#     to the real columns.
#
# require_partition_filter is deliberately NOT set (defaults false). Turning
# it on would make every "WHERE job_id = ..." lookup fail outright, because
# those queries carry no time predicate — it would break both applications.
locals {
  gclt_aicoe_dev_st_translation_tables = {
    translation_jobs    = { partition = "submitted_at", clustering = ["job_id", "status", "business_unit"] }
    translation_costs   = { partition = "timestamp", clustering = ["job_id", "business_unit"] }
    dlp_mappings        = { partition = "masked_at", clustering = ["job_id"] }
    translation_reviews = { partition = "created_at", clustering = ["job_id"] }
  }

  gclt_aicoe_dev_st_sales_agent_tables = {
    research_requests = { partition = "created_at", clustering = ["job_execution_id", "status", "business_unit"] }
    cost_attribution  = { partition = "created_at", clustering = ["job_execution_id", "business_unit"] }
    agent_telemetry   = { partition = "created_at", clustering = ["job_execution_id"] }
    users_feedback    = { partition = "created_at", clustering = ["job_id"] }
  }
}

resource "google_bigquery_table" "gclt_aicoe_dev_st_translation" {
  for_each   = local.gclt_aicoe_dev_st_translation_tables
  project    = var.gclt_aicoe_dev_st_project_id
  dataset_id = google_bigquery_dataset.gclt_aicoe_dev_st_jobs.dataset_id
  table_id   = each.key
  schema     = file("${path.module}/bigquery-schemas/translation/${each.key}.json")

  time_partitioning {
    type  = "DAY"
    field = each.value.partition
  }
  clustering = each.value.clustering

  # These hold job history, cost records and (in dlp_mappings) pre-masking PII.
  # Terraform must never drop them: this blocks destroy AND any change that
  # would force replacement, so a schema change needing a rebuild is a
  # deliberate three-step, not an accident inside an unrelated apply.
  deletion_protection = true

  # This MUST be stated even though the dataset's default_encryption_configuration
  # already applies it. BigQuery stamps the inherited key onto each table, the
  # provider reads it back, and a config that says nothing reads as "remove the
  # CMEK" — which is a ForceNew change. Leave it out and every subsequent plan
  # proposes destroying and recreating all eight tables, with deletion_protection
  # then failing the apply. Caught on the first re-plan after creation, 2026-09-14.
  encryption_configuration {
    kms_key_name = module.gclt_aicoe_dev_st_kms.key_ids["bq"]
  }
}

resource "google_bigquery_table" "gclt_aicoe_dev_st_sales_agent" {
  for_each   = local.gclt_aicoe_dev_st_sales_agent_tables
  project    = var.gclt_aicoe_dev_st_project_id
  dataset_id = google_bigquery_dataset.gclt_aicoe_dev_st_sales_agent_jobs.dataset_id
  table_id   = each.key
  schema     = file("${path.module}/bigquery-schemas/sales-agent/${each.key}.json")

  time_partitioning {
    type  = "DAY"
    field = each.value.partition
  }
  clustering = each.value.clustering

  deletion_protection = true

  # Required for the same reason as the translation tables above — omitting it
  # reads as "drop the inherited CMEK" and forces replacement on every plan.
  encryption_configuration {
    kms_key_name = module.gclt_aicoe_dev_st_kms.key_ids["bq"]
  }
}

# CORRECTED 2026-09-05: this used to be ONE bucket ("...-artifacts") shared
# by aihub-bff, Translation, and Sales-Agent, each holding storage.objectAdmin
# on the whole bucket with no prefix scoping -- confirmed live via IAM policy
# inspection. That meant Sales-Agent's own SA could read/write/delete every
# Translation object and vice versa, a real cross-app blast-radius gap, not
# just a cosmetic difference from the old aicoeprod platform's per-app bucket
# convention (aicoesandox-vxai-translation-app-001 /
# aicoesandox-vxai-sales-app-001). Split into two dedicated buckets, matching
# that convention and closing the gap. The bucket was confirmed empty
# (`gcloud storage ls`, zero objects) before this split, so no data migration
# was needed.
locals {
  gclt_aicoe_dev_st_app_buckets = {
    "gclt-aicoe-dev-st-translation" = "translation"
    "gclt-aicoe-dev-st-sales-agent" = "sales-agent"
  }
}

resource "google_storage_bucket" "gclt_aicoe_dev_st_app" {
  for_each      = local.gclt_aicoe_dev_st_app_buckets
  project       = var.gclt_aicoe_dev_st_project_id
  name          = each.key
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  versioning { enabled = true }

  encryption {
    default_kms_key_name = module.gclt_aicoe_dev_st_kms.key_ids["app-gcs"]
  }

  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }

  depends_on = [module.gclt_aicoe_dev_st_kms]
}

# aihub-bff (cross-project: bucket lives in gclt-aicoe-dev-st, the identity in
# gclt-aicoe-dev-aihub-ui) writes source documents to whichever app's bucket
# the upload is destined for and mints V4 signed URLs for download -- so it
# needs write access to BOTH dedicated buckets, not just one.
#
# No extra KMS grant is needed on st-ew3/app-gcs: each bucket's
# default_kms_key_name is applied by the Storage service agent, which is
# already granted at the key_grants["app-gcs"] entry above.
resource "google_storage_bucket_iam_member" "gclt_aicoe_dev_st_app_bff" {
  for_each = google_storage_bucket.gclt_aicoe_dev_st_app
  bucket   = each.value.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${local.aihub_bff_sa}"
}

output "gclt_aicoe_dev_st_bq_dataset_id" { value = google_bigquery_dataset.gclt_aicoe_dev_st_jobs.dataset_id }
output "gclt_aicoe_dev_st_sales_agent_bq_dataset_id" { value = google_bigquery_dataset.gclt_aicoe_dev_st_sales_agent_jobs.dataset_id }
output "gclt_aicoe_dev_st_translation_bucket" { value = google_storage_bucket.gclt_aicoe_dev_st_app["gclt-aicoe-dev-st-translation"].name }
output "gclt_aicoe_dev_st_sales_agent_bucket" { value = google_storage_bucket.gclt_aicoe_dev_st_app["gclt-aicoe-dev-st-sales-agent"].name }

# ── app-config secrets ───────────────────────────────────────────────────
# One Secret Manager container per runtime process. Each holds a dotenv-style
# payload mounted at /secrets/.env by the deploy job's --set-secrets flag —
# not GitLab CI/CD variables. See GITLAB_CI_VARIABLES.md in each backend repo
# for the exact split between the two mechanisms.

locals {
  translation_api_sa      = module.gclt_aicoe_dev_st_baseline.service_accounts["translation-api-sa"]
  translation_worker_sa   = module.gclt_aicoe_dev_st_baseline.service_accounts["translation-worker-sa"]
  salesagent_sa           = module.gclt_aicoe_dev_st_baseline.service_accounts["salesagent-sa"]
  worker_invoker_sa_email = module.gclt_aicoe_dev_st_baseline.service_accounts["worker-invoker-sa"]

  gclt_aicoe_dev_st_app_secrets = {
    "translation-api-env"    = local.translation_api_sa
    "translation-worker-env" = local.translation_worker_sa
    "sales-agent-api-env"    = local.salesagent_sa
    "sales-agent-worker-env" = local.salesagent_sa
  }
}

resource "google_secret_manager_secret" "gclt_aicoe_dev_st_app_env" {
  for_each  = local.gclt_aicoe_dev_st_app_secrets
  project   = var.gclt_aicoe_dev_st_project_id
  secret_id = each.key

  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption { kms_key_name = module.gclt_aicoe_dev_st_kms.key_ids["secrets"] }
      }
    }
  }

  depends_on = [module.gclt_aicoe_dev_st_kms]
}

resource "google_secret_manager_secret_iam_member" "gclt_aicoe_dev_st_app_env_accessor" {
  for_each  = google_secret_manager_secret.gclt_aicoe_dev_st_app_env
  project   = var.gclt_aicoe_dev_st_project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.gclt_aicoe_dev_st_app_secrets[each.key]}"
}

output "gclt_aicoe_dev_st_app_secret_ids" {
  value = { for k, v in google_secret_manager_secret.gclt_aicoe_dev_st_app_env : k => v.secret_id }
}

# ── runtime IAM per service account ──────────────────────────────────────
# None of these — deliberately — includes roles/aiplatform.user. See D-30
# above; the LLM gateway (Apigee `llm` env) is the only sanctioned path to
# Vertex from this project.

# translation-api-sa
resource "google_bigquery_dataset_iam_member" "translation_api_bq_editor" {
  project    = var.gclt_aicoe_dev_st_project_id
  dataset_id = google_bigquery_dataset.gclt_aicoe_dev_st_jobs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${local.translation_api_sa}"
}
resource "google_project_iam_member" "translation_api_bq_jobuser" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${local.translation_api_sa}"
}
resource "google_storage_bucket_iam_member" "translation_api_gcs" {
  bucket = google_storage_bucket.gclt_aicoe_dev_st_app["gclt-aicoe-dev-st-translation"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.translation_api_sa}"
}
resource "google_service_account_iam_member" "translation_api_sa_user_on_worker_invoker" {
  service_account_id = "projects/${var.gclt_aicoe_dev_st_project_id}/serviceAccounts/${local.worker_invoker_sa_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.translation_api_sa}"
}
resource "google_project_iam_member" "translation_api_dlp_user" {
  # Translation has GOOGLE_DLP_ENABLED=true.
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/dlp.user"
  member  = "serviceAccount:${local.translation_api_sa}"
}

# translation-worker-sa — same BQ/GCS access as the API, plus KMS decrypt on
# st-ew3/app-gcs (it reads/writes the same CMEK-protected artifacts).
resource "google_bigquery_dataset_iam_member" "translation_worker_bq_editor" {
  project    = var.gclt_aicoe_dev_st_project_id
  dataset_id = google_bigquery_dataset.gclt_aicoe_dev_st_jobs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${local.translation_worker_sa}"
}
resource "google_project_iam_member" "translation_worker_bq_jobuser" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${local.translation_worker_sa}"
}
resource "google_storage_bucket_iam_member" "translation_worker_gcs" {
  bucket = google_storage_bucket.gclt_aicoe_dev_st_app["gclt-aicoe-dev-st-translation"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.translation_worker_sa}"
}
resource "google_kms_crypto_key_iam_member" "translation_worker_kms_decrypt" {
  crypto_key_id = module.gclt_aicoe_dev_st_kms.key_ids["app-gcs"]
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${local.translation_worker_sa}"
}

# salesagent-sa
resource "google_bigquery_dataset_iam_member" "salesagent_bq_editor" {
  project    = var.gclt_aicoe_dev_st_project_id
  dataset_id = google_bigquery_dataset.gclt_aicoe_dev_st_sales_agent_jobs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${local.salesagent_sa}"
}
resource "google_project_iam_member" "salesagent_bq_jobuser" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${local.salesagent_sa}"
}
resource "google_storage_bucket_iam_member" "salesagent_gcs" {
  bucket = google_storage_bucket.gclt_aicoe_dev_st_app["gclt-aicoe-dev-st-sales-agent"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.salesagent_sa}"
}
resource "google_service_account_iam_member" "salesagent_sa_user_on_worker_invoker" {
  service_account_id = "projects/${var.gclt_aicoe_dev_st_project_id}/serviceAccounts/${local.worker_invoker_sa_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.salesagent_sa}"
}

# salesagent-sa's GCS uploads fail with a distinct 403 that storage.objectAdmin
# above does NOT cover: "does not have serviceusage.services.use access to the
# Google Cloud project". Root cause is in the app code, not a missing storage
# permission -- src/shared/repositories/clients.py constructs
# storage.Client(project=settings.GOOGLE_CLOUD_PROJECT), and passing an
# explicit project to the Python storage client attaches it as a QUOTA
# PROJECT, which stamps an x-goog-user-project header on every JSON API call.
# GCS then additionally requires serviceusage.services.use on that quota
# project -- a separate check from the storage ACL. Translation's equivalent
# client (Translation/src/repository/__init__.py) calls storage.Client() with
# no project argument and never triggers this at all; that is the reason only
# salesagent-sa needs this grant. Confirmed live 2026-09-15, BUILD-LOG #44.
resource "google_project_iam_member" "salesagent_service_usage_consumer" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${local.salesagent_sa}"
}

# All three service accounts' OTel exporters have been failing identically
# since first deploy: "Failed to export span batch code: 403, reason:
# Forbidden" against https://telemetry.googleapis.com/v1/traces
# (OTEL_EXPORTER_OTLP_ENDPOINT, both repos' otel_setup.py). This is the
# NEWER Telemetry API, not the legacy Cloud Trace API -- it needs
# roles/telemetry.tracesWriter, NOT roles/cloudtrace.agent, and neither
# role existed anywhere in this project before now. Pre-existing and
# platform-wide, not introduced by the LLM gateway work; it fails open
# (ERROR-logged, pipeline continues), which is exactly why it went
# unnoticed until read deliberately. Every span from every deploy to date
# was silently dropped -- Cloud Trace has no data for this platform yet.
# Confirmed live 2026-09-15, BUILD-LOG #44.
resource "google_project_iam_member" "salesagent_telemetry_traces_writer" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/telemetry.tracesWriter"
  member  = "serviceAccount:${local.salesagent_sa}"
}
resource "google_project_iam_member" "translation_api_telemetry_traces_writer" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/telemetry.tracesWriter"
  member  = "serviceAccount:${local.translation_api_sa}"
}
resource "google_project_iam_member" "translation_worker_telemetry_traces_writer" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/telemetry.tracesWriter"
  member  = "serviceAccount:${local.translation_worker_sa}"
}

# translation-api-sa needs to sign its own GCS download URLs on Cloud Run,
# which has no private key -- generate_signed_url() falls back to the IAM
# Credentials API's signBlob, delegated via iam.Signer
# (Translation/src/repository/storage_repository.py:_get_signing_credentials).
# That call requires serviceAccountTokenCreator granted to the SA ON ITSELF,
# not a project-level role -- easy to miss since it never shows up auditing
# what the SA can do to *other* resources. Same pattern as
# apigee_runtime_token_creator (gclt-aicoe-dev-apigee.tf, BUILD-LOG #37),
# self-bound here instead of SA-to-SA. Confirmed live 2026-09-15: every
# download attempt fails with "Permission 'iam.serviceAccounts.signBlob'
# denied". BUILD-LOG #44.
resource "google_service_account_iam_member" "translation_api_self_token_creator" {
  service_account_id = "projects/${var.gclt_aicoe_dev_st_project_id}/serviceAccounts/${local.translation_api_sa}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.translation_api_sa}"
}

# Sales-Agent's gcs_repository.py has the identical generate_signed_url /
# iam.Signer code path but has never hit this error in logs -- either the
# download feature isn't exposed yet or hasn't been exercised. Added
# preemptively rather than waiting for the same outage to resurface here.
resource "google_service_account_iam_member" "salesagent_self_token_creator" {
  service_account_id = "projects/${var.gclt_aicoe_dev_st_project_id}/serviceAccounts/${local.salesagent_sa}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.salesagent_sa}"
}

# NOTE: cloudtasks.enqueuer for translation-api-sa (on translation-jobs) and
# salesagent-sa (on research-jobs) is granted in stage 6b, not here — the
# queues are 6b resources and this stage does not read 6b's state, only the
# reverse (via vars-handoff).

# ── tf-deployer CI IAM ────────────────────────────────────────────────────
# Same class of gap as BUILD-LOG §14 for aihub-ui's tf-deployer: WIF
# impersonation is already granted platform-wide (0-bootstrap/wif.tf), but
# nothing ever granted this project's own tf-deployer the IAM it needs to
# actually push images or deploy Cloud Run here, because st has never had a
# real deploy attempted before this workstream.
locals {
  st_tf_deployer = "tf-deployer@${var.gclt_aicoe_dev_st_project_id}.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "st_ci_ar_writer" {
  project    = var.gclt_aicoe_dev_st_project_id
  location   = google_artifact_registry_repository.gclt_aicoe_dev_st_containers.location
  repository = google_artifact_registry_repository.gclt_aicoe_dev_st_containers.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.st_tf_deployer}"
}

resource "google_project_iam_member" "st_ci_run_admin" {
  project = var.gclt_aicoe_dev_st_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${local.st_tf_deployer}"
}

# actAs on each of the three runtime identities `gcloud run deploy` targets.
# Scoped per-SA, not project-wide: tf-deployer must not be able to run as
# arbitrary other service accounts in this project.
resource "google_service_account_iam_member" "st_ci_run_as" {
  for_each = toset([
    local.translation_api_sa,
    local.translation_worker_sa,
    local.salesagent_sa,
  ])
  service_account_id = "projects/${var.gclt_aicoe_dev_st_project_id}/serviceAccounts/${each.value}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.st_tf_deployer}"
}

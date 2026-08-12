# Terraform readiness for a greenfield Dev build

**Assessed against LLD v2.0.2.** Development is unbuilt, so the Terraform is the build mechanism and every gap below is a build-time failure rather than a drift problem.

The repository's own `README.md` states four exclusions, and nothing in this register contradicts them. Cloud Run application code, Apigee proxies and products, project creation, and organisation policy are deliberately outside this Terraform. Findings below are things the repository appears to intend to create but does not.

---

## Fixed in this pass

Each of these stops the build outright. None would have been caught by a review that read the files individually — they only show up when the tree is resolved as Terraform resolves it.

| # | Finding | Detail |
|---|---|---|
| F-01 | **Module source paths resolved above the repository root** | `4-apigee`, `6a-aihub-ui` and `6b-st` referenced `../../../modules/…`, which from the repository root points outside the tree. `terraform init` fails before any plan. Corrected to `../modules/…` for the one-level stage and `../../modules/…` for the two-level stages |
| F-02 | **Twelve dangling resource references in `2-foundations`** | Resources were renamed to carry the full project identifier — `google_pubsub_topic.siem` became `…gclt_aicoe_dev_auditlogs_siem` — but the references to them were never updated. `terraform validate` fails with "Reference to undeclared resource". Affected the audit-log sinks and their writer identities, the Firestore session database, the Binary Authorization attestor and its KMS key and container-analysis note, and both Model Armor templates. All rewritten to the declared names, including one data source |
| F-03 | **Five duplicate variable declarations in `2-foundations`** | `project_id` was declared in five files, `region` in six, and `attestor_name`, `folder_id` and `apigee_llm_runtime_sa` in two each. A root module is the union of its `.tf` files, so these are "Duplicate variable declaration" errors. The canonical declarations in `providers.tf` are kept and the copies removed. `project_id` and `llm_project_id` were dead in this stage and are gone entirely |
| F-04 | **`project_id` was unset in every stage** | Each stage from 2 onward declares it as required with no default. The pipeline sets `TF_PROJECT`, but used it only to build the workload-identity impersonation URL — it never reached Terraform, and neither the tfvars file nor the artifacts supply it. Under `TF_INPUT=false` that is "No value for required variable" in eight stages. Now passed as `TF_VAR_project_id` in `.tf_stage`, deliberately not as `-var`, because `-var` errors on a stage that does not declare the variable and would break `1-org` |
| F-05 | **Stage 1 published values under names stage 2 could not consume** | Handoff is `terraform output -json` written to a `.auto.tfvars.json` artifact, so an output name must equal the consuming stage's variable name exactly. `1-org` emitted `project_ids` and `project_numbers` as maps, while `2-foundations` declares six individually-named `*_project_id` variables. Nothing bridged the two. `1-org` now also publishes each project id under the name its consumer declares, plus `network_project_id` and `apigee_project_id` for stages 4 and 6c, and `service_projects` for the Shared VPC attachment in stage 3 |
| F-06 | **`2-foundations/gclt-aicoe-dev-apigee.tf` did not exist** | The README's layout lists it. Stage 4 calls the service-agents and KMS modules directly but never `project-baseline`, so `apigee.googleapis.com` was never enabled on the Apigee project — and neither the service agent nor `google_apigee_organization` can be created without it. Written to match the other six foundations files, and it also creates the `apigee-int-runtime` and `apigee-llm-runtime` service accounts the rest of the design depends on |
| F-07 | **Values with no source anywhere** | `folder_id`, `org_log_project`, `apigee_llm_runtime_sa`, `apigee_runtime_sa`, `worker_invoker_sa` and the two certificate ids were required but supplied by neither the tfvars nor any artifact. Added to `envs/dev/terraform.tfvars` as `REPLACE_ME`, with a comment on each explaining what it is and where it comes from. They are placeholders, not guesses — see the note below |

**Verified after the fixes:** every root module parses, no duplicate declarations, no dangling references, all fifteen module sources resolve, and every required variable in all nine stages now has a source.

---

## Still blocking — needs a value or a decision from you

| # | Finding | What is needed |
|---|---|---|
| B-01 | **Seven `REPLACE_ME` values in `envs/dev/terraform.tfvars`** | `folder_id` and `org_log_project` are lookups. `apigee_llm_runtime_sa` and `apigee_runtime_sa` are now created by F-06 and can be wired through as artifact outputs instead of hand-entered — worth doing, since a typo in `apigee_llm_runtime_sa` silently breaks the grant that makes the AI gateway mandatory. `worker_invoker_sa` exists in the `st` foundations and can be wired the same way |
| B-02 | **Nothing provisions TLS certificates** | Both load balancers are HTTPS-only and `6c` needs two Certificate Manager ids. The LLD makes DNS-01 automation pre-requisite gate P4, so this may be intentionally out-of-band — but the repository should say which, rather than leaving two unexplained required variables |
| B-03 | **Cloud Run services must exist before stage 6** | `6a` and `6b` create serverless NEGs and `google_cloud_run_v2_service_iam_member` bindings against services named `aihub-bff`, `translation-api-service` and `sales-research-application`. The IAM bindings fail if those services do not exist. Application deployment is deliberately outside this repository, but the apply order in the README does not show where it slots in — and on a green-field build it must come before stage 6 |

## Missing against the LLD — the build succeeds but the platform is incomplete

| # | Finding | LLD reference | Note |
|---|---|---|---|
| M-01 | **No service connection policy for Vector Search.** No `google_network_connectivity_service_connection_policy` anywhere | Private Service Connect — automatic mode is recorded as "this design, in both environments" | Without it, every index deployment needs manual endpoint creation, which is the outcome automatic mode was chosen to avoid. The policy names a subnet, so it belongs in `3-network` or `5-network-psc` |
| M-02 | **No Cloud Tasks queue.** No `google_cloud_tasks_queue` | Cloud Tasks async fan-out, shown in the Development architecture and the service integration matrix | The translation worker path depends on it |
| M-03 | **No linked BigQuery dataset for the log bucket.** `google_logging_project_bucket_config` is created but no `google_logging_linked_dataset` | Logging architecture — `aicoe_dev_logs`, "SQL over logs, no second cost" | Log Analytics is enabled on the bucket; the linked dataset is the half that makes it queryable |
| M-04 | **No BigQuery datasets or GCS buckets for the service tenant project** | The `st` project is shown carrying BigQuery and GCS for job records and artefacts | Also relevant to the CMEK policy check, which fails any dataset or bucket without a customer-managed key |
| M-05 | **No monitoring or alerting resources at all.** No `google_monitoring_alert_policy`, no budget alerts | PR-19 (Cloud Run address consumption alert, threshold 250); certificate expiry alert at 30 days; Vertex AI budget alerting as the Sandbox compensating control | Each of these is a named commitment in the document with no implementation |

---

## Worth deciding before the build, not after

| # | Finding | Note |
|---|---|---|
| D-01 | **Subnet CIDRs are hardcoded in `3-network/main.tf`** rather than passed through `terraform.tfvars` | The LLD states Production repeats Development with different IPAM-allocated ranges. As written, Production cannot get different addresses without editing shared code. `envs/prod/terraform.tfvars` is otherwise all placeholders, so this is the one input that breaks the pattern |
| D-02 | **`dev` is baked into directory and resource names** | The README raises this itself and lists the two ways out. It notes renames get harder once state files carry the addresses — which argues for deciding now, while no state exists |
| D-03 | **Documentation drift in the README** | The layout section lists `2-foundations/gclt-aicoe-dev-apigee.tf`, which does not exist (B-01). The ordering-traps table cites `2-foundations/logging.tf`, but the file is `gclt-aicoe-dev-auditlogs.tf` |

---

## Verified as correct

- Every address in the Terraform matches the LLD's IP addressing plan — thirteen values cross-checked, including the routed range, all four subnets, all three internal VIPs, the global PSC address, and both reservations
- Every subnet sits inside `192.168.4.0/22` with no overlaps; each host address lands in its intended subnet; the global PSC address sits outside every real subnet
- The Cloud Run subnet arithmetic holds: 508 usable, ceiling 127
- Identity-Aware Proxy is correctly wired in `modules/cloudrun-backend` — the `iap` block on the backend service plus `roles/iap.httpsResourceAccessor` bindings, enabled for the AI Hub path only
- Stage ordering matches the LLD's dependency graph, including the network split at stages 3 and 5 around the Apigee gate at stage 4
- `prevent_destroy` is set on the three irreplaceable resources: the Apigee organisation, the Apigee instance, and the CSOC-pinned address
- All fifteen module references resolve, and every `.tf` file parses

# Running this Terraform locally — implementation guide

**AI CoE dev platform, revision R13.** How to apply the ten stages from a workstation, rather than from GitLab CI.

> **R13 supersedes R12's opening section.** R12 opened with seven blockers on the basis that the package could not be applied as shipped. Six are now resolved in the code and one is resolved for CI, so the instructions to patch files by hand before starting no longer apply — see §0. Addresses throughout are the `192.168.4.0/22` Development plan from LLD v2.0.2.

Companion to `README.md` (what the structure is and why) and the the LLD's **DevOps — Infrastructure as Code and CI/CD** section. This file is the operational one: exact commands, in order, with what to check before and after each.

**Audience:** an engineer with project-level admin on the eight projects, running a green-field build. Everything here assumes the estate already exists in GCP and that organisation policy is managed by the platform team outside Terraform — see the LLD's **DevOps — Infrastructure as Code and CI/CD** section.

---

## 0. What was wrong, and what is still yours to do

An earlier revision of this guide opened with seven blockers, B1 to B7, on the basis that the package could not be applied as shipped. **Most of those have since been resolved in the code itself.** The table below is the current position, kept in full rather than deleted, because "B3 is gone" is more useful to someone holding the old guide than silence.

| # | Original blocker | Position now |
|---|---|---|
| **B1** | `modules/` does not exist | **Resolved.** All four modules are present — `service-agents`, `kms-ring`, `cloudrun-backend`, `project-baseline` |
| **B2** | `2-foundations/` does not exist | **Resolved.** The stage exists, and now carries eight files: one per project plus `providers.tf`. `gclt-aicoe-dev-apigee.tf` was the last one missing and has been written — without it `apigee.googleapis.com` was never enabled, so stage 4 could not create the organisation |
| **B3** | `ci/validate-all.sh` does not exist | **Resolved.** Present, and it runs `init -backend=false` plus `validate` over every directory containing a `.tf` file |
| **B4** | `0-bootstrap/wif.tf` waits on a module the stage never declares | **Resolved in code.** The `depends_on` is gone. Nothing to do by hand |
| **B5** | Module source paths resolve outside the repository | **Resolved in code.** `4-apigee` now uses `../modules/…`, `6a` and `6b` use `../../modules/…` |
| **B6** | No stage's `project_id` is supplied | **Resolved for CI, and §2.3 covers local runs.** The pipeline now passes `TF_VAR_project_id` from `TF_PROJECT`. Note the original claim that per-stage tfvars files fix the pipeline too was wrong — CI passes only `envs/<env>/terraform.tfvars` and never reads a per-stage file |
| **B7** | State bucket location conflicts with its CMEK key | **Resolved in code.** `var.location` now defaults to `europe-west1`, matching the key ring, and a validation rule rejects a multi-region value. This also keeps the bucket inside the `in:europe-west1-locations` residency policy |

**Sequencing that is still yours, and will stop you at stage 6 if unplanned for:**

- **Deploy the Cloud Run services before stages 6a and 6b.** Both create serverless NEGs and `run.invoker` bindings referencing services *by name* — `aihub-bff`, `translation-api-service`, `sales-research-application`, `translation-worker-service` — and `6b` additionally has a `data "google_cloud_run_v2_service"` lookup that fails outright if the service is absent. Application code is deliberately outside this Terraform, per `README.md`, so someone has to deploy those four services first.
- **Both TLS certificates must exist in Certificate Manager before stage 6c**, which takes `aihub_certificate_id` and `backend_certificate_id` as inputs and creates neither. Issuance is gate **P4** in the LLD and carries an external lead time — it is not a same-day task.
- **Fill in the `REPLACE_ME` values** in `envs/dev/terraform.tfvars`: `folder_id`, `org_log_project`, `apigee_llm_runtime_sa`, `apigee_runtime_sa`, `worker_invoker_sa` and the two certificate ids.

> The structural checks that used to fail now pass: every root module parses, no duplicate variable declarations, no dangling resource or module references, all module sources resolve, and every required variable in all nine stages has a source.

---

## 1. Prerequisites

### 1.1 Tools

| Tool | Version | Note |
|---|---|---|
| Terraform | **≥ 1.9** | Every stage pins `required_version = ">= 1.9"`. The pipeline uses 1.9.8 — match it locally to avoid a state-format surprise later |
| `gcloud` | current | Needed for authentication, service-agent forcing, and every verification step below |
| `jq` | any | The stage-to-stage handoff is JSON. Not optional |

**On Windows** — the paths in this guide are POSIX and the handoff commands use `jq` pipelines. Use **Git Bash** or **WSL**. PowerShell equivalents are given for the handoff step (§2.4) because that is the one place the difference bites; elsewhere, run from Git Bash and the commands are literal.

### 1.2 Authentication

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project aicoe-sharedwif
```

`gcloud auth application-default login` is the one that matters — the Terraform Google provider reads Application Default Credentials, not the `gcloud` CLI's own session.

**Two ways to run, and they are not equivalent:**

| Mode | When | How |
|---|---|---|
| **As yourself** | The green-field build, and any debugging | ADC as above. Requires the roles in §1.3 held by *you* |
| **Impersonating `tf-deployer`** | Before handing over to CI, to prove the service accounts actually have enough permission | `export GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=tf-deployer@<project>.iam.gserviceaccount.com` — you need `roles/iam.serviceAccountTokenCreator` on that account |

**Do this deliberately at least once.** A build that only ever ran as a human administrator tells you nothing about whether the pipeline will work, and the first CI run is a bad place to find out.

**Workload Identity Federation is not used locally.** Stage 0 creates the pool and provider for GitLab's benefit; nothing in a local run authenticates through it.

### 1.3 Roles you need

Held by you (or by the impersonated account), at the stated scope:

| Scope | Role | For |
|---|---|---|
| `aicoe-sharedwif` | `roles/owner`, or the KMS + Storage + IAM admin set | Stage 0: key ring, bucket, service accounts |
| Each of the eight projects | `roles/iam.serviceAccountAdmin` | Stage 0 creates one `tf-deployer` per project, *in* that project |
| `AI COE` folder or organisation | **`roles/compute.xpnAdmin`** | Stage 3's Shared VPC host enablement and service-project attachment. Project-level roles are not enough, and this is the permission most often missing |
| `gclt-aicoe-dev-network` | `roles/compute.networkAdmin`, `roles/dns.admin` | Stages 3 and 5 |
| `gclt-aicoe-dev-apigee` | `roles/apigee.admin`, `roles/cloudkms.admin` | Stages 4 and 7 |
| `gclt-aicoe-dev-network` — **from the ingress deployer** | `roles/compute.admin` | Stage 6c creates two addresses in the *host* project while applying against the ingress project |
| Each workload project | `roles/run.admin`, `roles/compute.loadBalancerAdmin`, `roles/iap.admin` | Stages 6a, 6b, 6c |

### 1.4 External gates that must already be closed

From the LLD's **Day-1 operating model** — none of these is something Terraform can wait for:

- **P1 / P2** — IPAM has confirmed `192.168.4.0/22` and allocated `10.110.73.0/24`. Every subnet, firewall destination, DNS record and target server carries these ranges; a late rejection is a rebuild, not an edit.
- **P4** — both TLS certificates issued and present in Certificate Manager (blocks 6c).
- **P8** — host-project roles for PSC endpoint creation from service projects.
- **P9** — Apigee entitlement for **Extensible** policies confirmed (the `llm` environment is Intermediate for exactly this reason).

---

## 2. One-time local setup

### 2.1 Get the tree into the right shape

`.gitlab-ci.yml` sets `TF_ROOT = "${CI_PROJECT_DIR}"`, meaning **the contents of `terraform/` are the repository root**, not a subdirectory. Locally, work from that same root so the relative paths in this guide match CI:

```bash
cd "/c/Users/jabir.m/Documents/shared vpc/terraform"
export TF_ROOT="$PWD"
```

Everything below assumes `$TF_ROOT` is set and that you `cd` into a stage directory relative to it.

### 2.2 Blockers — nothing to patch by hand

Earlier revisions asked you to edit `0-bootstrap/wif.tf` and the module source paths before starting. **Both are fixed in the code.** If your copy still contains `depends_on = [module.baseline]` in `wif.tf`, or `../../../modules/` in `4-apigee`, `6a` or `6b`, you are working from a stale checkout — take a fresh one rather than re-applying the old patches.

### 2.3 Add per-stage tfvars — for local runs

**Three places supply values, and they do not overlap.** Keeping that separation is what stops the same value being maintained twice and drifting:

| Source | Carries | Used by |
|---|---|---|
| `envs/dev/terraform.tfvars` | Environment-wide values — region, the project inventory, `folder_id`, `org_log_project`, the service accounts, the certificate ids | Both CI and local |
| `.auto.tfvars.json` artifacts | Values one stage computes for another — subnet self-links, the Apigee service attachment, `service_projects`, `network_project_id`, `apigee_project_id` | Both CI and local (§2.4) |
| `envs/dev/stages/<stage>.tfvars` | **`project_id` only** — it differs per stage | Local only |

In CI, `project_id` arrives as `TF_VAR_project_id`, set from each job's `TF_PROJECT`. The pipeline never reads a per-stage file, so these files are purely a local convenience. Create one per stage:

```bash
mkdir -p envs/dev/stages
```

`envs/dev/stages/3-network.tfvars`
```hcl
project_id = "gclt-aicoe-dev-network"
# service_projects arrives from 1-org's artifact, derived from existing_projects.
# Set it here only if you are running 3-network without having run 1-org.
```

`envs/dev/stages/4-apigee.tfvars`
```hcl
project_id = "gclt-aicoe-dev-apigee"
# network_project_id arrives from 1-org's artifact.
# billing_type defaults to PAYG — set it explicitly if your entitlement differs
```

`envs/dev/stages/5-network-psc.tfvars`
```hcl
project_id = "gclt-aicoe-dev-network"
```

`envs/dev/stages/6a.tfvars`
```hcl
project_id = "gclt-aicoe-dev-aihub-ui"
```

`envs/dev/stages/6b.tfvars`
```hcl
project_id = "gclt-aicoe-dev-st"
# apigee_runtime_sa and worker_invoker_sa now live in envs/dev/terraform.tfvars,
# so both CI and local runs read one copy. Do not repeat them here.
```

`envs/dev/stages/6c.tfvars`
```hcl
project_id = "gclt-aicoe-dev-ingress"
# network_project_id and apigee_project_id arrive from 1-org's artifact.
# The two certificate ids are in envs/dev/terraform.tfvars — full resource IDs,
# not display names, and they come from Certificate Manager under gate P4.
```

`envs/dev/stages/7-apigee-runtime.tfvars`
```hcl
project_id = "gclt-aicoe-dev-apigee"
```

> **`2-foundations` now creates these service accounts**, in `gclt-aicoe-dev-apigee.tf` and `gclt-aicoe-dev-st.tf`, so they are no longer names taken from the LLD and typed in by hand. They are still passed as strings through `envs/dev/terraform.tfvars`, which means a typo is possible: Google accepts a binding to a principal that does not exist, and the failure surfaces at request time rather than at apply time. `apigee_llm_runtime_sa` is the one to check twice — it carries the sole `roles/aiplatform.user` grant, and a wrong value silently leaves the AI gateway unenforced. Wiring all three through as artifact outputs would remove the class of error entirely.

**Both files are passed on every command:** the shared one and the stage one. Terraform will warn — *"Value for undeclared variable"* — for shared values a given stage does not declare. **That warning is expected and harmless**, and it is the same behaviour the pipeline has.

### 2.4 The handoff, done by hand

In CI, each job publishes its outputs as a `.auto.tfvars.json` artifact and downstream jobs consume it via `needs: artifacts: true`. There is no artifact store locally, so you do it yourself. After every successful apply:

```bash
# from inside the stage directory
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/<stage-basename>.auto.tfvars.json"
```

Then, before planning a downstream stage, copy in **only the handoff files that stage consumes** (§4 lists them):

```bash
cp "$TF_ROOT/3-network.auto.tfvars.json" .
```

Terraform auto-loads any `*.auto.tfvars.json` in the working directory — no `-var-file` needed for these.

**PowerShell equivalent of the publish step**, if you are not in Git Bash:

```powershell
terraform output -json | jq 'map_values(.value)' | Out-File -Encoding utf8 "$env:TF_ROOT\<stage-basename>.auto.tfvars.json"
```

Watch the encoding — PowerShell's default `>` writes UTF-16, which Terraform cannot parse. `Out-File -Encoding utf8` is the fix.

> **Copy selectively, not with a wildcard.** `cp $TF_ROOT/*.auto.tfvars.json .` is what the CI does, and it works, but locally it means a stage picks up every output from every earlier stage — so a stale value from an abandoned run silently becomes an input. Copy the two or three files the stage actually needs.

---

## 3. The runbook

### 3.0 Stage 0 — bootstrap

**Manual, once, with your own credentials.** This is the only stage that cannot run in the pipeline, because it creates the things the pipeline needs in order to run at all.

`var.location` now defaults to `europe-west1` and a validation rule rejects a multi-region value, so there is nothing to set first — the bucket and its CMEK key ring land in the same location by construction. Override it only if you are deliberately moving both.

```bash
cd "$TF_ROOT/0-bootstrap"

# 1 — local state, because the bucket does not exist yet
terraform init

# 2 — review, then apply
terraform plan  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" -out=tfplan
terraform apply tfplan
```

**Read the plan before applying.** It should create: one KMS key ring, one key, one IAM member for the GCS service agent, one bucket, eight service accounts, eight conditional bucket IAM members, one WIF pool, one WIF provider. If it proposes to create a *project*, stop — you are running an older `1-org` by mistake.

Now migrate the state into the bucket it just created. **Capture the outputs first** — once the backend block is uncommented and not yet initialised, `terraform output` refuses to run:

```bash
# 3 — capture BEFORE touching the backend block
export TF_STATE_BUCKET="$(terraform output -raw state_bucket)"
echo "$TF_STATE_BUCKET"
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/0-bootstrap.auto.tfvars.json"

# 4 — now uncomment the backend block in 0-bootstrap/main.tf:
#       backend "gcs" {}

# 5 — migrate
terraform init -migrate-state \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=0-bootstrap"
```

Terraform will ask to copy the existing state to the new backend. Answer `yes`.

**Keep `TF_STATE_BUCKET` exported** — every later stage's `init` needs it. In a new shell, re-derive it as `<seed_project_id>-tfstate`, or read it back with `terraform output -raw state_bucket` from this directory once the backend is initialised.

**Then delete the local state files** — `terraform.tfstate` and `terraform.tfstate.backup` — and confirm they are not committed. They contain the full pre-migration state.

**Verify:**

```bash
gsutil ls "gs://$TF_STATE_BUCKET/0-bootstrap/"
gsutil versioning get "gs://$TF_STATE_BUCKET"          # expect: Enabled
gcloud iam service-accounts list --project=aicoe-sharedwif | grep tf-deployer
```

**Never run this stage from CI**, and never run it a second time casually — the bucket and the key both carry `prevent_destroy`, which is deliberate, but a re-run against drifted state is still an unpleasant afternoon.

---

### 3.1 Stage 1 — org (read-only)

Creates nothing. Looks up the seven other projects and publishes their IDs and numbers, so later stages and humans have one authoritative mapping.

```bash
cd "$TF_ROOT/1-org"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=1-org"

terraform plan  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/1-org.auto.tfvars.json"
```

**The plan should say `No changes`** — there are only `data` sources and outputs. If it proposes to create or destroy anything, the file has been reverted to the old project-factory version; see the LLD's **DevOps — Infrastructure as Code and CI/CD** section before going further.

**A failure here is informative:** `data "google_project"` errors if a project ID in `existing_projects` is wrong or you cannot see it. That is the cheapest possible check that your inventory matches reality, which is why this stage is worth running even though it changes nothing.

> **`1-org`'s outputs are consumed downstream — publish the artifact.** This was not true in earlier revisions and the guide said so; it is true now. `2-foundations` takes its six per-project ids from here, `3-network` takes `service_projects`, and stages 4 and 6c take `network_project_id` and `apigee_project_id`. Each is published under the exact name the consuming stage declares, because the handoff turns output names into variable names verbatim. `project_id` is the exception and still comes from the per-stage file locally, or `TF_VAR_project_id` in CI.

---

### 3.2 Stage 2 — foundations

**This stage exists and is applied by Terraform.** It carries one file per project plus `providers.tf`, and it enables the APIs, forces the service agents into existence ahead of any KMS binding, creates the KMS rings, Artifact Registry, the Binary Authorization attestor, the Model Armor templates and the whole logging estate.

The manual equivalents below are kept for two situations only: recovering when the stage has partly applied, and understanding what it does. **On a normal build, skip to stage 3.**

The manual path, if you need it:

**Enable the APIs** each project needs — Terraform will otherwise fail with "API not enabled", one service at a time:

```bash
# network
gcloud services enable compute.googleapis.com dns.googleapis.com \
  --project=gclt-aicoe-dev-network

# apigee
gcloud services enable apigee.googleapis.com cloudkms.googleapis.com \
  compute.googleapis.com --project=gclt-aicoe-dev-apigee

# workloads
for p in gclt-aicoe-dev-aihub-ui gclt-aicoe-dev-st gclt-aicoe-dev-ingress; do
  gcloud services enable run.googleapis.com compute.googleapis.com \
    cloudkms.googleapis.com artifactregistry.googleapis.com \
    certificatemanager.googleapis.com iap.googleapis.com --project="$p"
done
```

**Force the service agents into existence** — the single most expensive ordering trap in this build (the LLD's **Security Architecture and Operations** section). Agents are created lazily, so a KMS or IAM binding referencing one fails on a fresh project, sometimes with a message about the *key* rather than the missing account:

```bash
gcloud beta services identity create --service=apigee.googleapis.com \
  --project=gclt-aicoe-dev-apigee
gcloud beta services identity create --service=logging.googleapis.com \
  --project=gclt-aicoe-dev-auditlogs
gcloud beta services identity create --service=pubsub.googleapis.com \
  --project=gclt-aicoe-dev-auditlogs
gcloud beta services identity create --service=bigquery.googleapis.com \
  --project=gclt-aicoe-dev-auditlogs
gcloud beta services identity create --service=artifactregistry.googleapis.com \
  --project=gclt-aicoe-dev-st
gcloud beta services identity create --service=aiplatform.googleapis.com \
  --project=gclt-aicoe-dev-st
gcloud beta services identity create --service=storage.googleapis.com \
  --project=gclt-aicoe-dev-st
gcloud beta services identity create --service=bigquery.googleapis.com \
  --project=gclt-aicoe-dev-st
gcloud beta services identity create --service=artifactregistry.googleapis.com \
  --project=gclt-aicoe-dev-aihub-ui
gcloud beta services identity create --service=aiplatform.googleapis.com \
  --project=gclt-aicoe-dev-llm
```

**Record each returned address.** The number in the middle is the project *number*, not the ID, and differs per project — an agent address from one project will not work in another.

**Also still owed by this stage**, and out of scope for the commands above: KMS rings and keys per project, Artifact Registry with CMEK and immutable tags, Secret Manager containers, Binary Authorization attestor and policy, the 400-day log bucket, three folder sinks and their writer-identity grants, Firestore. **Stage 4 will fail without a KMS ring in the Apigee project.** Follow the LLD's **Security Architecture and Operations** section and §12 for the specifics, or write the stage.

---

### 3.3 Stage 3 — network

```bash
cd "$TF_ROOT/3-network"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=3-network"

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/3-network.tfvars" \
  -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/3-network.auto.tfvars.json"
```

**Check in the plan before applying:**

- Five subnets, with the CIDRs from the LLD's IP addressing plan — `10.110.73.0/24`, `192.168.4.0/23`, `192.168.6.0/26`, `192.168.6.128/28`, `192.168.6.144/28`.
- `192.168.6.160/28` is **not** subnetted. It is deliberately left free for the global PSC address in stage 5, which must not overlap a subnet.
- `192.168.6.64/26` is **not** subnetted either, and is not spare capacity. It is the reserved landing block for the proxy-only subnet's role swap, which is the only way that subnet can ever grow.
- `private_ip_google_access = false` on the three subnets that set it. This is forced off so every Google API call goes through the PSC endpoint.
- **One** proxy-only subnet with `role = "ACTIVE"`. There can be one active proxy-only subnet per region per VPC and both load balancers share it — do not let anyone add a second.
- `egress-deny-all` at priority 65000, and `egress-allow-psc` at 1000 (lower number wins).
- The `aihub` DNS record only. `aihub-api` and `llm` come in stage 5, because they point at an address that does not exist yet.

**Verify:**

```bash
gcloud compute networks subnets list \
  --project=gclt-aicoe-dev-network --network=gclt-aicoe-dev-vpc
gcloud compute shared-vpc get-host-project gclt-aicoe-dev-st
```

**If Shared VPC attachment fails with a permission error**, it is almost always `roles/compute.xpnAdmin` missing at the folder (§1.3) rather than anything in the code.

**`egress-allow-psc` is knowingly incomplete after this stage.** Two of its three destinations — the Apigee endpoint and Vector Search — do not exist yet. Revisit it after stages 4 and 5 or the gateway will be unreachable, and that presents as a mysterious timeout rather than a permission error.

---

### 3.4 Stage 4 — Apigee

**Slow — 30 to 60 minutes. Largely irreversible.** In CI this is `when: manual` with a 2-hour timeout. Locally, treat it with the same care: it is not a stage to run at the end of the day.

**Five settings are immutable after creation** (the LLD's **AI Gateway and Vertex AI — Apigee `llm` Environment** section). Confirm each in the plan before applying — a mistake here is not an edit, it is a deletion with a waiting period on a paid organisation:

| Setting | Value | Why it cannot change later |
|---|---|---|
| `disable_vpc_peering` | `true` | Peering is non-transitive, so a peered gateway could never be consumed by other usecase VPCs |
| `runtime_database_encryption_key_name` | the `runtime-db` key | Cannot be added to an existing organisation |
| `analytics_region` | `europe-west2` | Set at creation; EU per the residency policy |
| Environment types | `int` = BASE, `llm` = INTERMEDIATE | Extensible policies deploy only to intermediate or comprehensive |
| `consumer_accept_list` | the network project only | An unpinned list is an unlocked side door |

```bash
cd "$TF_ROOT/4-apigee"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=4-apigee"

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/4-apigee.tfvars" \
  -out=tfplan

# read it properly, then:
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/4-apigee.auto.tfvars.json"
```

**Expect the apply to sit on `google_apigee_organization` for tens of minutes with no output.** That is normal. Do not interrupt it — a killed apply mid-organisation-creation leaves state and reality disagreeing about a resource that takes an hour to recreate and cannot be deleted quickly.

**Verify:**

```bash
gcloud apigee organizations describe gclt-aicoe-dev-apigee
gcloud apigee environments list --organization=gclt-aicoe-dev-apigee   # int, llm
terraform output -raw instance_service_attachment                      # needed by stage 5
```

---

### 3.5 Stage 5 — network PSC

The reason the network stage is split. This one consumes stage 4's service attachment.

```bash
cd "$TF_ROOT/5-network-psc"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=5-network-psc"

# handoff — this stage needs both
cp "$TF_ROOT/3-network.auto.tfvars.json" .
cp "$TF_ROOT/4-apigee.auto.tfvars.json"  .

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/5-network-psc.tfvars" \
  -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/5-network-psc.auto.tfvars.json"
```

**Check in the plan:** the global address is `192.168.6.164` with `purpose = "PRIVATE_SERVICE_CONNECT"` and **no subnetwork** — it is a global internal address and must not sit inside a subnet. The regional address is `192.168.6.146` in the internal subnet. The forwarding rule targets `vpc-sc`, not `all-apis` — only perimeter-supported APIs, which is what keeps VPC Service Controls re-entry cheap.

**Verify, and this is the real test:**

```bash
gcloud compute forwarding-rules describe psc-apigee \
  --region=europe-west1 --project=gclt-aicoe-dev-network \
  --format="value(pscConnectionStatus)"      # expect: ACCEPTED
```

`ACCEPTED` depends on stage 4's `consumer_accept_list` containing the network project. If it says `PENDING` or `REJECTED`, the accept list is wrong — fix it in stage 4, not here.

**Now revisit `egress-allow-psc`** in stage 3 with the two real `/32` addresses, and re-apply stage 3.

---

### 3.6 Stages 6a and 6b — workloads

**Both need the Cloud Run services deployed first** (§0). Independent of each other — in CI they run in parallel; locally run them in either order.

```bash
# ---- 6a : the BFF and the platform's one IAP ----
cd "$TF_ROOT/6-workloads/6a-gclt-aicoe-dev-aihub-ui"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=6-workloads/6a-gclt-aicoe-dev-aihub-ui"

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/6a.tfvars" \
  -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' \
  > "$TF_ROOT/6a-gclt-aicoe-dev-aihub-ui.auto.tfvars.json"
```

`ui_user_group` is `REPLACE_ME` in the shipped tfvars — it is the Entra group object ID for `App-AICoE-UI-Users`. **Fill it in before applying**; an IAP binding to a placeholder principal will apply cleanly and then deny everyone.

```bash
# ---- 6b : usecase backends ----
cd "$TF_ROOT/6-workloads/6b-gclt-aicoe-dev-st"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=6-workloads/6b-gclt-aicoe-dev-st"

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/6b.tfvars" \
  -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' \
  > "$TF_ROOT/6b-gclt-aicoe-dev-st.auto.tfvars.json"
```

> **The `check "no_public_invoker"` block in `6b/main.tf` asserts `condition = true` and enforces nothing.** It is a placeholder that advertises a control it does not implement. The real check is `ci/policy-check.sh`, which you should run by hand before every local apply (§5). Do not read a green `check` here as evidence of anything.

**Verify no public binding actually exists:**

```bash
for s in translation-api-service sales-research-application; do
  gcloud run services get-iam-policy "$s" \
    --region=europe-west1 --project=gclt-aicoe-dev-st \
    --format=json | jq -e '.bindings[]?.members[]? | select(. == "allUsers" or . == "allAuthenticatedUsers")' \
    && echo "FAIL: $s has a public binding" || echo "ok: $s"
done
```

---

### 3.7 Stage 6c — ingress, the cross-project join

The URL maps here reference backend services created in two *other* projects. Both certificates must already exist (§0).

```bash
cd "$TF_ROOT/6-workloads/6c-gclt-aicoe-dev-ingress"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=6-workloads/6c-gclt-aicoe-dev-ingress"

# handoff — all three
cp "$TF_ROOT/3-network.auto.tfvars.json"                    .
cp "$TF_ROOT/6a-gclt-aicoe-dev-aihub-ui.auto.tfvars.json"   .
cp "$TF_ROOT/6b-gclt-aicoe-dev-st.auto.tfvars.json"         .

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/6c.tfvars" \
  -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' \
  > "$TF_ROOT/6c-gclt-aicoe-dev-ingress.auto.tfvars.json"
```

**If you skip a handoff file here the plan still succeeds** — Terraform prompts for the missing variable, you paste something plausible, and you get a load balancer pointing at nothing. This is precisely the failure the pipeline's `needs:` graph exists to prevent, and locally there is nothing preventing it but you. Copy all three.

**`10.110.73.20` carries `prevent_destroy`.** CSOC opened the firewall for that exact address; if it moves, users lose access and a new request starts its own lead time.

**Verify:**

```bash
gcloud compute forwarding-rules describe aihub-fr \
  --region=europe-west1 --project=gclt-aicoe-dev-ingress \
  --format="value(IPAddress)"                    # expect 10.110.73.20
gcloud compute service-attachments describe sa-backends \
  --region=europe-west1 --project=gclt-aicoe-dev-ingress
```

---

### 3.8 Stage 7 — Apigee runtime

The southbound attachment. **It consumes stage `6c`'s service attachment, not stage 5's** — the trap most likely to be gotten backwards from the stage numbers alone.

```bash
cd "$TF_ROOT/7-apigee-runtime"
terraform init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=7-apigee-runtime"

cp "$TF_ROOT/4-apigee.auto.tfvars.json"                     .
cp "$TF_ROOT/6c-gclt-aicoe-dev-ingress.auto.tfvars.json"    .

terraform plan \
  -var-file="$TF_ROOT/envs/dev/terraform.tfvars" \
  -var-file="$TF_ROOT/envs/dev/stages/7-apigee-runtime.tfvars" \
  -out=tfplan
terraform apply tfplan
terraform output -json | jq 'map_values(.value)' > "$TF_ROOT/7-apigee-runtime.auto.tfvars.json"
```

**The two KVM containers are created empty on purpose.** Terraform owns the container; `apigeecli` populates the values, in the proxy pipeline. An empty `backend-audiences` map is expected at this point, not a fault.

```bash
terraform output -raw endpoint_attachment_host   # the int environment's target server host
```

---

### 3.9 Proxies — not Terraform

```bash
export APIGEE_ORG=gclt-aicoe-dev-apigee
chmod +x "$TF_ROOT/ci/deploy-apigee-config.sh"
"$TF_ROOT/ci/deploy-apigee-config.sh"
```

Requires `apigeecli` on `PATH` and an `apigee/` directory of bundles, products and KVM values — **neither is in this package**. The script gates itself on two checks first: no Extensible policy in a Base-targeted proxy, and `UseEffectiveCount` present on every `SpikeArrest`. Both are correctness gates worth keeping.

### How far you can actually get today

Every stage is now structurally runnable. What remains is inputs and external dependencies, not missing code:

| Stage | Runnable now? |
|---|---|
| 0-bootstrap | **Yes** |
| 1-org | **Yes** |
| 2-foundations | **Yes**, once `folder_id`, `org_log_project` and `apigee_llm_runtime_sa` are filled in |
| 3-network | **Yes** |
| 4-apigee | **Yes** — allow 30 to 60 minutes |
| 5-network-psc | **Yes** — needs stage 4's output |
| 6a / 6b | Needs the Cloud Run services deployed first — see §0 |
| 6c | Needs 6a, 6b, and both certificates issued under gate P4 |
| 7 | Needs 6c |

**Stages 0 through 5 are a realistic first pass**: they prove your credentials, your project inventory and your `compute.xpnAdmin` grant, stand up the network, and get the slow Apigee provisioning under way — which is the long pole. Stage 6 onward waits on things outside this repository: application images and certificates.

---

## 4. Handoff reference

| Stage | Consumes | From | Publishes |
|---|---|---|---|
| `0-bootstrap` | — | — | `state_bucket`, `deployer_emails`, `pool_name`, `provider_name`, `wif_project_number` |
| `1-org` | — | — | `project_ids`, `project_numbers` *(currently unconsumed)* |
| `2-foundations` | — | — | *(stage absent)* |
| `3-network` | — | — | `vpc_self_link`, `subnet_ew1_self_link`, `cloudrun_subnet_self_link`, `proxy_subnet_self_link`, `pscnat_subnet_self_link`, `internal_subnet_self_link`, `private_zone_name`, `googleapis_zone_name` |
| `4-apigee` | — | — | `org_id`, `instance_service_attachment`, `environments` |
| `5-network-psc` | `vpc_self_link`, `internal_subnet_self_link`, `private_zone_name` | `3-network` | `apigee_endpoint_ip`, `google_apis_ip` |
| | `instance_service_attachment` | `4-apigee` | |
| `6a-aihub-ui` | *(none — ordering only)* | | `bff_backend_service_self_link` |
| `6b-st` | *(none — ordering only)* | | `translation_backend_service_self_link`, `sales_backend_service_self_link` |
| `6c-ingress` | `vpc_self_link`, `subnet_ew1_self_link`, `internal_subnet_self_link`, `pscnat_subnet_self_link` | `3-network` | `backend_service_attachment_id` |
| | `bff_backend_service_self_link` | `6a` | |
| | `translation_…`, `sales_backend_service_self_link` | `6b` | |
| `7-apigee-runtime` | `org_id` | `4-apigee` | `endpoint_attachment_host` |
| | `backend_service_attachment_id` | **`6c`** — not stage 5 | |

**6a and 6b consume nothing**, yet the pipeline gives them `needs: 5-network-psc`. That is a real ordering dependency — the network and its endpoints must exist before load balancer backends are meaningful — expressed where it can be enforced. Respect it locally too.

---

## 5. Before every apply

```bash
cd "$TF_ROOT"
terraform fmt -recursive -check -diff
./ci/policy-check.sh
```

`policy-check.sh` fails the build on a public IAM member, Cloud Run ingress set to `ALL`, a bucket/dataset/registry without CMEK, an irreplaceable resource without `prevent_destroy`, or a `google_service_account_key` resource. **It runs from the repository root**, not from a stage directory — its paths are relative.

`ci/validate-all.sh` exists and is what the pipeline runs — it does `init -backend=false` then `validate` in every directory containing a `.tf` file. Run it from the repository root. The per-stage loop below does the same thing by hand:

```bash
for d in 0-bootstrap 1-org 3-network 4-apigee 5-network-psc \
         6-workloads/6a-* 6-workloads/6b-* 6-workloads/6c-* 7-apigee-runtime; do
  (cd "$d" && terraform validate) || echo "FAILED: $d"
done
```

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Reference to undeclared module` on stage 0 | A stale checkout — this was fixed in code | Take a fresh checkout rather than re-patching |
| `Module not installed` / `module not found` on 4, 6a, 6b | A stale checkout — the source paths were fixed in code | As above. Correct paths are `../modules/…` for 4, `../../modules/…` for 6a and 6b |
| Terraform prompts for `project_id` | No per-stage tfvars file, running locally | §2.3. In CI this arrives as `TF_VAR_project_id` |
| `Reference to undeclared resource` in 2-foundations | A stale checkout — twelve references were left behind when resources were renamed to carry the project prefix | Take a fresh checkout |
| `Duplicate variable declaration` in 2-foundations | A stale checkout — `project_id` and `region` were declared in several files at once | Take a fresh checkout |
| `No value for required variable` on a `REPLACE_ME` | Expected until §0's placeholder list is filled in | Fill in `envs/dev/terraform.tfvars` |
| `Value for undeclared variable` warnings | Shared tfvars passed to a stage that does not declare them | **Expected.** Harmless, and matches CI behaviour |
| Bucket creation fails on the KMS key | A multi-region bucket with a regional key | `var.location` defaults to `europe-west1` and validates against multi-region values — check you have not overridden it |
| `Error 403: Permission denied` on Shared VPC attachment | `roles/compute.xpnAdmin` missing at the folder | §1.3 — a project-level role is not enough |
| KMS binding "succeeds" but resource creation fails citing the key | The service agent did not exist when the binding was made | Force the agent (§3.2), then re-apply. Do not rely on a second apply |
| PSC connection status `PENDING` | Stage 4's `consumer_accept_list` does not contain the network project | Fix in stage 4 |
| Stage 4 appears hung for 40 minutes | Normal — organisation provisioning | **Wait.** Interrupting is worse than waiting |
| Cannot reach the gateway after stage 5 | `egress-allow-psc` still points at placeholder destinations | Revisit stage 3 with the real `/32` addresses (§3.5) |
| `data "google_cloud_run_v2_service"` not found on 6b | The Cloud Run services are not deployed | Deploy the application first — §0 |
| Handoff JSON unreadable by Terraform | PowerShell wrote UTF-16 | `Out-File -Encoding utf8` (§2.4) |
| Two applies collide on one state | No `resource_group` equivalent locally | Do not run two stages against the same prefix at once. CI serialises this; you have to |

---

## 7. What you cannot undo

Know these before you start, not after.

- **The Apigee organisation.** Deleting a paid organisation has a mandatory waiting period. Its five immutable settings cannot be edited — they can only be re-chosen by destroying and recreating, which is why stage 4 is manually gated in CI and why you should read that plan twice.
- **KMS keys.** Deletion has a mandatory waiting period, and data encrypted with a destroyed key is permanently unreadable. **Never delete or disable a key in use.**
- **The state bucket.** Losing it means losing the record of every resource in the estate. `prevent_destroy` is set, and deleting it is never the right answer to any problem.
- **`10.110.73.20`.** `prevent_destroy` is set because CSOC opened the firewall for that exact address. Moving it costs a new CSOC request and its lead time.
- **Log bucket retention lock.** Deliberately *not* locked in dev. Locking is irreversible — a dev bucket that cannot be deleted for over a year. Lock it in production, where evidence tampering is the bigger risk.

**`terraform destroy` is not a supported operation on this estate.** Several stages will refuse it, several more would succeed and take out something that took an hour to build. If you need to start over on a stage, remove the specific resources deliberately.

---

## 8. Cross-references

| For | See |
|---|---|
| Why the structure is what it is | `README.md`, `docs/14-terraform-structure-decision.md` |
| The design record for stages and handoff | the LLD's **DevOps — Infrastructure as Code and CI/CD** section, §13.2, §13.4, §13.6 |
| Why projects and org policy are not Terraform-managed | the LLD's **DevOps — Infrastructure as Code and CI/CD** section, decision D-55 |
| Subnets, addresses, firewall, DNS | the LLD's **Networking** section |
| KMS rings, keys, and the service-agent ordering trap | the LLD's **Security Architecture and Operations** section, §10.8.1 |
| Apigee's five immutable settings | the LLD's **AI Gateway and Vertex AI — Apigee `llm` Environment** section |
| IAM inventory and service account names | the LLD's **Session lifecycle** section |
| External gates and their lead times | the LLD's **Day-1 operating model** |

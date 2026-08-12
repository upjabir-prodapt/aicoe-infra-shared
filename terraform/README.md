# Terraform — AI CoE platform

**Revision R12.** Structure follows Google's published landing-zone patterns. Reasoning and evidence in `docs/14-terraform-structure-decision.md`.

> **Amendment.** Project creation and organisation policy, both originally described below as Terraform-managed, are not. The platform team provisions and maintains projects and organisation policy (including the AI COE folder's hierarchical firewall policy) directly in the console. `1-org` was reduced accordingly — see "Projects and organisation policy" below, which replaces what this file used to call "The project factory."

---

## Layout

```
0-bootstrap/                         MANUAL, once. State bucket, WIF pool, CI identities
1-org/                               Read-only reference to the existing project estate —
                                      no creation, no organisation policy. See below
2-foundations/                       one file per project
  gclt-aicoe-dev-network.tf
  gclt-aicoe-dev-ingress.tf
  gclt-aicoe-dev-apigee.tf
  gclt-aicoe-dev-aihub-ui.tf
  gclt-aicoe-dev-st.tf
  gclt-aicoe-dev-llm.tf
  gclt-aicoe-dev-auditlogs.tf
3-network/                           VPC, subnets, firewall, DNS, Shared VPC
4-apigee/                            Org, instance, environments  SLOW · MANUAL GATE
5-network-psc/                       PSC endpoints — cannot exist before stage 4
6-workloads/
  6a-gclt-aicoe-dev-aihub-ui/        BFF backend service and NEG
  6b-gclt-aicoe-dev-st/              usecase backend services, run.invoker
  6c-gclt-aicoe-dev-ingress/         load balancer frontends — NEEDS 6a AND 6b
7-apigee-runtime/                    endpoint attachment, target servers, KVMs
modules/
ci/
envs/dev/  envs/prod/
```

## Where this folder goes

**`terraform/` is your repository.** Copy its **contents** to the repository root, not the folder itself, because `.gitlab-ci.yml` must sit at the root for GitLab to find it.

```
your-repo/
├── .gitlab-ci.yml
├── 0-bootstrap/
├── 1-org/
├── ...
└── envs/
```

If you would rather keep `terraform/` as a subdirectory of a larger repository, move `.gitlab-ci.yml` to that repository's root and set `TF_ROOT` back to `"${CI_PROJECT_DIR}/terraform"`. Both work; they cannot both be true at once, which is why this is stated rather than left to inference.

## The GCP folder structure this Terraform assumes

Confirmed against the console, not created by this Terraform:

```
Colt Organisation
└── AI COE                              organisation policy attaches HERE,
    │                                   hierarchical firewall policy too
    ├── shared
    │   ├── aicoe-sharedwif             THE SEED PROJECT — seed_project_id
    │   │                               in 0-bootstrap. GitLab WIF pool +
    │   │                               providers · state bucket
    │   ├── gclt-aicoe-dev-auditlogs
    │   ├── network/gclt-aicoe-dev-network
    │   ├── ingress/gclt-aicoe-dev-ingress
    │   ├── apigee/gclt-aicoe-dev-apigee
    │   ├── aihub/gclt-aicoe-dev-aihub-ui
    │   └── llm/gclt-aicoe-dev-llm
    └── Dev
        └── usecases/gclt-aicoe-dev-st
```

**A future `Prod` branch, parallel to `Dev`, is where production usecase projects would land** — see `docs/00-README.md`'s production section and the LLD's **Production Promotion Model**. Whether `shared` stays common to both environments or splits is not yet decided.

## Why one project appears in several stages

`gclt-aicoe-dev-st` shows up twice — as `2-foundations/gclt-aicoe-dev-st.tf` and as `6-workloads/6b-gclt-aicoe-dev-st/`. That is deliberate, and it is the thing most likely to confuse on first reading.

**Stages are phases of the build, not owners of a project.** The order is forced by real dependencies, so a project's resources land in whichever stage they can:

| Project | Referenced in | Foundations in | Workload resources in | Why split |
|---|---|---|---|---|
| `gclt-aicoe-dev-network` | 1-org | 2-foundations | 3-network, 5-network-psc | The VPC comes before workloads; the PSC endpoint comes after Apigee |
| `gclt-aicoe-dev-apigee` | 1-org | 2-foundations | 4-apigee, 7-apigee-runtime | The organisation is slow and gated; the endpoint attachment needs stage 6c |
| `gclt-aicoe-dev-st` | 1-org | 2-foundations | 6b | Its APIs and keys are needed early; its load balancer backends cannot exist until the network does |
| `gclt-aicoe-dev-aihub-ui` | 1-org | 2-foundations | 6a | Same |
| `gclt-aicoe-dev-ingress` | 1-org | 2-foundations | 6c | Its URL maps reference backend services from 6a and 6b, so it must be last of the three |
| `gclt-aicoe-dev-llm` | 1-org | 2-foundations | — | Holds no compute |
| `gclt-aicoe-dev-auditlogs` | 1-org | 2-foundations | — | Logging only |

**"Referenced in", not "created in".** Every project above already exists — `1-org` looks it up with a `data` source, it does not create it. See the next section.

Read a **column** to see the build order. Read a **row** to see everything that touches one project.

If you want a per-project view instead, that is a repository split rather than a folder rearrangement — see `docs/14-terraform-structure-decision.md`.

## Naming and environments

Directories, files, resource addresses and pipeline jobs all carry the **full project identifier**. A pipeline view names the project each job touches, and a resource address such as `module.gclt_aicoe_dev_st_kms` is unambiguous without opening the file.

**The trade-off, stated plainly.** Putting `dev` in the names pins this tree to the development environment. `envs/prod/terraform.tfvars` exists but the directory names contradict it. Two ways forward when production arrives:

| Option | What it means |
|---|---|
| **Parallel tree** | `terraform-prod/` with the same stages. Explicit, greppable, and duplicated |
| **Drop the environment from names** | `6a-gclt-aicoe-aihub-ui/`, with the project identifier built as `gclt-aicoe-${var.environment}-aihub-ui` |

The second is the conventional answer and what both Google reference patterns do. The first is easier to reason about during an incident. Decide before production exists rather than after — it is a rename either way, and renames get harder once state files carry the addresses.

**Numbered, not named.** The order is in the directory listing. `5-network-psc` obviously follows `4-apigee`, which is the non-obvious dependency most needing signposting — the PSC endpoint targets a service attachment that does not exist until Apigee is provisioned.

## How stages pass values

**No stage reads another stage's Terraform state.** Each publishes its outputs as a `.auto.tfvars.json` artifact; the next consumes it through `needs: artifacts: true`, and Terraform loads any file matching that pattern automatically.

Three consequences:

- A stage's service account needs access to **its own state and nothing else**
- What a stage consumes is visible in its `variable` blocks, not buried in a `data` block
- A stage can be planned in isolation by supplying a tfvars file by hand

This is the pattern Google's Fabric FAST uses, adapted to GitLab artifacts.

## Projects and organisation policy — not managed here

**This section replaces what earlier revisions called "The project factory."** That design — one YAML file per project under `1-org/data/projects/`, onboarding as a merge request, `expected_project_count` and `required_labels` as Terraform `check` blocks — is documented in `docs/14-terraform-structure-decision.md` as the rationale for the numbered-stage restructuring, and is **no longer how this repository works**.

**The eight projects already exist, under the folder structure above, and this Terraform does not create them.** `1-org/main.tf` instead holds a `role => project ID` map (`existing_projects`, set in `envs/<env>/terraform.tfvars`) and looks each one up with `data "google_project"`, so downstream stages still get project numbers, but nothing here can create, destroy, or rename a project.

**Organisation policy — including the AI COE folder's hierarchical firewall policy — is likewise owned by the platform team, applied directly at the folder, and not represented anywhere in this Terraform.** There is no `google_folder_organization_policy` resource in this repository. A plan here will never show organisation-policy drift; that has to be checked in the console or by whatever process the platform team already uses.

**What this means for cost-attribution labelling.** The `usecase` / `cost-centre` / `owner` labels described in `docs/14-terraform-structure-decision.md` are no longer enforced by a Terraform `check` or by `ci/policy-check.sh` (its label-checking step was removed along with the YAML directory it used to glob). If label enforcement matters, it needs an owner outside this repository, or a deliberate re-adoption of Terraform-managed project creation.

**If your organisation wants this back under Terraform later**, that is a deliberate reversal of a deliberate reversal — say so explicitly in `docs/14-terraform-structure-decision.md` and the LLD's decision log before reintroducing `google_project` or `google_folder_organization_policy` resources, or this file will start fighting whoever manages the console side by hand.

## Apply order

```
0  bootstrap        manual, once, with an administrator's own credentials
1  org              reads back the seven pre-existing projects — creates nothing
2  foundations      APIs, agents, KMS, registries, logging
3  network          VPC, subnets, firewall, DNS
4  apigee           org, instance, environments        30 to 60 min, manual
5  network-psc      PSC endpoints — needs 4
   ── application deploy ──  NOT Terraform, and NOT optional. See below
6a aihub-ui  ┐      backend services, in parallel
6b st        ┘
6c ingress          frontends — needs 6a and 6b, and both certificates
7  apigee-runtime   endpoint attachment, target servers
   proxies          apigeecli, not Terraform
```

**Two external dependencies sit inside that order, not beside it.**

The four Cloud Run services must be deployed *before* 6a and 6b. Both stages create serverless NEGs and `run.invoker` bindings that reference services by name, and 6b additionally does a `data "google_cloud_run_v2_service"` lookup that fails outright if the service is absent. Application code is out of scope for this Terraform, which makes it easy to read the numbered order as complete when it is not.

Both TLS certificates must exist in Certificate Manager before 6c, which consumes two certificate ids and creates neither. Issuance is gate P4 in the LLD and has an external lead time.

## Policy as code

`ci/policy-check.sh` runs on every merge request, before any plan. It fails the build on:

| Check | Why |
|---|---|
| `allUsers` or `allAuthenticatedUsers` in any binding | Blocked by org policy anyway, and never correct here |
| Cloud Run ingress set to `ALL` | The platform is internal-only |
| A bucket, dataset or registry without a customer-managed key | CMEK is a stated requirement |
| An irreplaceable resource without `prevent_destroy` | State bucket, Apigee organisation, the CSOC-pinned address |
| `google_service_account_key` anywhere | Org policy forbids downloadable keys |

This replaces a `check` block in an earlier revision that asserted `true` and enforced nothing. **The project-YAML label check that used to sit here was removed** along with project creation — see "Projects and organisation policy" above.

## Before the first apply

1. Run `0-bootstrap` by hand. It starts with local state, creates the bucket, then migrates into it
2. Fill in the `REPLACE_ME` values in `envs/dev/terraform.tfvars`, including `existing_projects`
3. Confirm spike S1 before stage 6 — the backend authentication mechanism is unverified
4. Set `SEED_PROJECT`, `TF_STATE_BUCKET` and `WIF_PROVIDER` as CI variables

## Ordering traps, and where each is handled

| Trap | Handled in |
|---|---|
| Service agent does not exist when a KMS binding references it | `modules/service-agents`, called before any CMEK resource |
| KMS binding must precede the resource it protects | `modules/kms-ring` `ready` output plus `depends_on` |
| Sink writer identity does not exist until the sink does | `2-foundations/gclt-aicoe-dev-auditlogs.tf`, two resources with an explicit dependency |
| PSC endpoint needs the Apigee instance | Stages 4 and 5, numbered apart |
| URL map references backend services in other projects | `needs:` with artifact handoff, stage 6c |
| Two pipelines applying the same state | `resource_group` per stage |
| The CSOC-pinned address moving | `prevent_destroy` on `10.110.73.20` |
| Organisation-policy or project-label drift | **Not handled here.** Neither is represented in this Terraform any more — see "Projects and organisation policy" above |

## What is not here

- **Cloud Run application code** — the console runbook's Cloud Run service sections are the contract
- **Apigee proxies and products** — `apigeecli`, per the console runbook's Apigee proxy deployment section
- **Project creation and organisation policy** — provisioned and maintained by the platform team directly in the console; see "Projects and organisation policy" above
- **Module versioning** — modules are referenced by relative path. For a platform team serving multiple usecase teams, move them to their own repository with git tags before the second team onboards

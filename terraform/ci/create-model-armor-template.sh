#!/usr/bin/env bash
# Model Armor template — creation and verification.
#
# THIS SCRIPT IS THE SOURCE OF TRUTH for the template's configuration. There is
# deliberately no `google_model_armor_template` resource anywhere under
# terraform/. See "Why this is not Terraform" below before adding one back.
#
#   ./create-model-armor-template.sh create   # provision it (once)
#   ./create-model-armor-template.sh verify   # print live config, to diff by eye
#
# Run from a host that can reach Google's REGIONAL endpoints -- Cloud Shell is
# the reliable choice. See "Where to run this".
#
#
# WHY THIS IS NOT TERRAFORM
# -------------------------
# Decided 2026-09-14, deliberately, and it is an exception to this repo's
# otherwise-total "infrastructure is Terraform" rule. It is the same treatment
# already given to Apigee API products, proxies, developer apps and keys
# (apigee/, docs/20, docs/21): provisioned outside Terraform, specified in the
# repository, documented as a procedure.
#
# The reason is that Model Armor's control plane is reachable ONLY at its
# regional endpoint, modelarmor.<region>.rep.googleapis.com. On the AI CoE
# workstation every *.googleapis.com name resolves to one restricted API VIP
# (192.168.2.3) that fronts the global hosts correctly but serves Google's
# default certificate for any *.rep.googleapis.com name, so the provider dies
# at TLS verification before authentication is attempted:
#
#   tls: failed to verify certificate: x509: certificate is valid for
#   *.google.com, ... not modelarmor.europe-west3.rep.googleapis.com
#
# That breaks far more than the initial create. Terraform REFRESHES every
# managed resource on every plan, so a single google_model_armor_template in a
# stage makes that ENTIRE STAGE unplannable from the workstation -- including
# operations with nothing to do with Model Armor. It was briefly in
# 7-apigee-runtime, which also owns the Apigee endpoint attachment, target
# server and KVM containers; keeping it there would have held all of those
# hostage to one resource's unusual network requirement. Whether GitLab CI can
# reach regional endpoints is untested, so moving the problem to CI would have
# been a guess, not a fix.
#
# WHAT WE GIVE UP, STATED PLAINLY: there is now no automated drift detection on
# this template. Someone can change a filter threshold in the console and
# nothing will fail. That is the actual cost of this decision. Two partial
# mitigations: `verify` below prints the live configuration for review, and
# ci/deploy-apigee-config.sh's fail_on_modelarmor_template_drift check parses
# the identifiers out of THIS FILE and fails the pipeline if the proxy policies
# reference a different template path. Neither compares filter settings.
#
#
# WHERE TO RUN THIS
# -----------------
# Any host with ordinary DNS and egress. The regional endpoint's public address
# is a normal Google anycast IP -- nothing about it is privileged. Cloud Shell
# works and needs no setup.
#
# gcloud defaults to the GLOBAL endpoint, which does not serve template CRUD and
# rejects it with a 403 that names the target project and your account:
#
#   PERMISSION_DENIED: Write access to project 'gclt-aicoe-dev-llm' was denied.
#   This command is authenticated as <user> ...
#
# That message reads exactly like an IAM failure and is not one. Google
# documents this wording as the global-endpoint symptom
# (docs.cloud.google.com/model-armor/troubleshooting). Ruled out on 2026-09-14,
# all confirmed, none of them the cause: the caller holds
# modelarmor.templates.create; modelarmor.googleapis.com is enabled on the
# project; gcp.resourceLocations permits europe-west3; gcp.restrictServiceUsage
# is ALLOW; and pinning the quota project changed nothing. Only the endpoint was
# wrong. Note that testIamPermissions returning a permission proves the IAM
# allow policy grants it and proves nothing about whether the endpoint you are
# calling can honour it.
#
# This script sets the override itself and unsets it on exit.
#
#
# THE CONFIGURATION, AND WHY
# --------------------------
# RAI filters at HIGH confidence only -- the permissive end of decision D-A
# (docs/21, docs/23). A lower threshold blocks the contract and HR text
# Translation handles routinely. Tighten per filter once there is real traffic
# to measure false positives against.
#
# Prompt-injection/jailbreak at MEDIUM_AND_ABOVE rather than HIGH: unlike the
# RAI filters it has no legitimate-business-content false-positive mode, and it
# is the filter that actually matters for a gateway relaying user-supplied text.
#
# SDP basic (INSPECT) and never advanced (REWRITE). This one is load-bearing.
# basic_config reports a verdict; an advanced_config deidentify template
# REWRITES the message body. A rewritten response body is how server-side Google
# Search grounding gets silently destroyed: Sales-Agent's search agent reads
# groundingMetadata.groundingChunks out of the response
# (src/worker/agents/search.py) to build its evidence list, and a de-identify
# pass that reserialises the body can drop those fields without erroring --
# zero evidence, HTTP 200, no signal anywhere. Google's terms also require the
# searchEntryPoint suggestions to be displayed, so dropping it is a compliance
# matter and not only a bug. Do not add --advanced-config-* flags without
# re-testing grounding end to end.
#
# ignore-partial-invocation-failures is OFF so a partially-failed scan is not
# reported as a clean pass. The failure mode worth guarding is a SKIPPED scan
# being read as "passed", not a filter match being missed.
#
#
# SETTINGS GOOGLE APPLIES THAT THIS SCRIPT DOES NOT ASK FOR
# ---------------------------------------------------------
# Verified against the live template 2026-09-14. Three fields appear that no
# flag here sets, and that this gcloud version exposes no flag for at all --
# so they CANNOT be pinned, only observed. If any of them matters to you,
# re-check it with `verify` after any recreate; a future default may differ.
#
#   multiLanguageDetection.enableMultiLanguageDetection: true
#       Wanted here, as it happens. Translation processes documents in many
#       languages, and filters that only work well on English would give a
#       false sense of coverage on everything else. Had this defaulted off it
#       would have been worth turning on deliberately.
#   filterVersionSelector.alias: FILTER_VERSION_ALIAS_STABLE
#       Google's stable filter model line, rather than a pinned version.
#   dataResidencyCompliant: true
#       Follows from europe-west3 having full Data Residency support.
#
# ignorePartialInvocationFailures does not appear in `describe` output at all.
# gcloud omits false booleans, so its absence is consistent with the intended
# false (fail closed) -- but note it is absence, not positive confirmation.

set -euo pipefail

PROJECT="${MODEL_ARMOR_PROJECT:-gclt-aicoe-dev-llm}"
LOCATION="${MODEL_ARMOR_LOCATION:-europe-west3}"
TEMPLATE="${MODEL_ARMOR_TEMPLATE:-aicoe-llm-gateway}"

ACTION="${1:-}"
if [ "$ACTION" != "create" ] && [ "$ACTION" != "verify" ]; then
  echo "usage: $(basename "$0") {create|verify}" >&2
  exit 2
fi

# Force the regional endpoint, and put the shell back afterwards -- left set,
# it silently redirects every later Model Armor command in this session to
# this one region. This forces the REGIONAL endpoint and is the opposite of
# the global-endpoint override CLAUDE.md rules out; it is also gcloud-local
# config, not Terraform provider config.
restore_endpoint() { gcloud config unset "api_endpoint_overrides/modelarmor" >/dev/null 2>&1 || true; }
trap restore_endpoint EXIT
gcloud config set "api_endpoint_overrides/modelarmor" \
  "https://modelarmor.${LOCATION}.rep.googleapis.com/" >/dev/null

if [ "$ACTION" = "verify" ]; then
  echo "Live configuration of ${TEMPLATE} in ${PROJECT}/${LOCATION}:"
  echo "(compare against THE CONFIGURATION section of this file -- nothing does this automatically)"
  echo
  gcloud model-armor templates describe "$TEMPLATE" \
    --project="$PROJECT" --location="$LOCATION" --format=yaml
  exit 0
fi

echo "Creating Model Armor template ${TEMPLATE} in ${PROJECT}/${LOCATION}"
gcloud model-armor templates create "$TEMPLATE" \
  --project="$PROJECT" \
  --location="$LOCATION" \
  --rai-settings-filters='filterType=dangerous,confidenceLevel=high' \
  --rai-settings-filters='filterType=harassment,confidenceLevel=high' \
  --rai-settings-filters='filterType=hate-speech,confidenceLevel=high' \
  --rai-settings-filters='filterType=sexually-explicit,confidenceLevel=high' \
  --pi-and-jailbreak-filter-settings-enforcement=enabled \
  --pi-and-jailbreak-filter-settings-confidence-level=medium-and-above \
  --malicious-uri-filter-settings-enforcement=enabled \
  --basic-config-filter-enforcement=enabled \
  --no-template-metadata-ignore-partial-invocation-failures \
  --template-metadata-log-sanitize-operations \
  --template-metadata-log-operations

echo
echo "Created. The proxy policies reference it as:"
echo "  projects/${PROJECT}/locations/${LOCATION}/templates/${TEMPLATE}"
echo "Run '$(basename "$0") verify' to review the live configuration."

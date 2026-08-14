#!/usr/bin/env bash
# Policy-as-code. Replaces the fake check block that used to sit in the
# workload stage advertising a control it did not enforce.
#
# These are the platform's hard invariants. If any HCL violates one, the
# merge request fails before a plan is ever produced.

set -euo pipefail
FAIL=0
say() { echo "  ✗ $1"; FAIL=1; }

echo "── policy checks"

# 1 · no public IAM members, anywhere
# Match grants only — a `check` block asserting their *absence* also contains
# the string, so exclude assertion lines from the match.
if grep -rEn '"(allUsers|allAuthenticatedUsers)"' --include='*.tf' . 2>/dev/null | grep -v 'contains(' >/dev/null 2>&1; then
  grep -rEn '"(allUsers|allAuthenticatedUsers)"' --include='*.tf' . | grep -v 'contains('
  say "public IAM member found — blocked by domain-restricted sharing anyway, and never correct here"
fi

# 2 · Cloud Run must not be publicly ingressable
if grep -rEn 'ingress\s*=\s*"INGRESS_TRAFFIC_ALL"' --include='*.tf' . >/dev/null 2>&1; then
  say "Cloud Run ingress set to ALL"
fi

# 3 · CMEK on every resource type that supports it
for res in google_storage_bucket google_bigquery_dataset google_artifact_registry_repository; do
  for f in $(grep -rl "resource \"$res\"" --include='*.tf' . 2>/dev/null || true); do
    grep -q -E 'kms_key_name|default_kms_key_name|kms_key_id' "$f" \
      || say "$res in $f has no customer-managed key"
  done
done

# 4 · destructive-resistance on the things that must not vanish
# Match actual resource declarations only — a comment mentioning the resource
# type (e.g. 2-foundations explaining why the org is not created there) must
# not pull the file into this check.
for f in $(grep -rlE '^resource "google_storage_bucket" "state"\|^resource "google_apigee_organization"\|^resource "google_compute_address" "aihub_vip"' --include='*.tf' . 2>/dev/null || true); do
  grep -q 'prevent_destroy' "$f" || say "$f holds an irreplaceable resource without prevent_destroy"
done

# 5 · REMOVED. Used to check every 1-org/data/projects/*.yaml file for
# usecase/cost-centre/owner labels. Projects are no longer created from a
# YAML factory here — they are pre-provisioned outside Terraform (see
# 1-org/main.tf's header comment) — so the directory this check globbed no
# longer exists. Left in place unguarded, it would silently misfire: with
# no matching files, the bare glob pattern falls through as a literal
# non-existent filename, and every label check below it would fail closed
# on a file that was never real. Removed rather than patched, because
# there is nothing left in this repository for it to check — cost
# attribution now lives wherever projects are provisioned. Recorded as an
# open item in the LLD's risk register (org policy / labelling drift is no
# longer visible to this pipeline).

# 6 · service account keys are never created in code
if grep -rn 'google_service_account_key' --include='*.tf' . >/dev/null 2>&1; then
  say "service account key resource found — org policy forbids these"
fi

[ $FAIL -eq 0 ] && echo "  ✓ all policy checks passed"
exit $FAIL

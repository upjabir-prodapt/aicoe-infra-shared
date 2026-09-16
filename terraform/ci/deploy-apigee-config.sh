#!/usr/bin/env bash
# Apigee configuration deployment — proxies, products, apps, KVM values.
#
# Not Terraform. Bundles and product definitions live in apigee/ in this
# repository; apigeecli applies them. Terraform created the KVM containers.
#
# There is no Binary Authorization for proxy bundles, so Git and this
# pipeline ARE the control. Console editing is withheld from humans and
# audit logs alert on deployment by any non-CI principal.

set -euo pipefail

ORG="${APIGEE_ORG:?}"
TOKEN="$(gcloud auth print-access-token)"

# Locate apigee/ rather than assuming the caller's cwd. README.md's
# "Repository root" note means this tree is run two different ways: in this
# repository apigee/ sits BESIDE terraform/, but once terraform/ is flattened
# to the repo root apigee/ sits beside ci/. A bare relative "apigee/..." is
# correct in exactly one of those and silently wrong in the other -- and
# "wrong" here means apigeecli is handed a non-existent folder, not a clean
# failure. Resolve from this script's own location so both layouts work.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if   [ -d "$SCRIPT_DIR/../apigee" ];    then APIGEE_DIR="$SCRIPT_DIR/../apigee"
elif [ -d "$SCRIPT_DIR/../../apigee" ]; then APIGEE_DIR="$SCRIPT_DIR/../../apigee"
else echo "ERROR: cannot locate apigee/ from $SCRIPT_DIR" >&2; exit 1
fi
APIGEE_DIR="$(cd "$APIGEE_DIR" && pwd)"
echo "using apigee config dir: $APIGEE_DIR"

# This org has Data Residency enabled (apiConsumerDataLocation: europe-west3,
# control plane hosting jurisdiction "de") and is only reachable through the
# regional control-plane host, never apigeecli's global default -- confirmed
# live 2026-09-07: every command below 404s with a misleading "resource
# organizations/... not found" without this flag, identical to the
# terraform/4-apigee and terraform/7-apigee-runtime apigee_custom_endpoint
# provider override this must match. See docs.cloud.google.com/apigee/docs/locations.
#
# apigeecli's -r/--region takes a BARE region code ("de"), not a full URL --
# different from Terraform's apigee_custom_endpoint, which needs the full
# "https://de-apigee.googleapis.com/v1/". Passing the full URL here produces
# a malformed request (apigeecli builds "https://<value>-apigee.googleapis.com"
# itself), confirmed live -- do not "fix" this to match the Terraform form.
REGION="de"

fail_on_extensible_policy_in_base_env() {
  # A single extensible policy reclassifies the whole proxy and forces the
  # environment up a tier. int is now INTERMEDIATE (GAP-REGISTER R-12 fixed
  # it from an incorrectly-provisioned BASE), but this check is left in
  # place deliberately: it is cheap insurance against a future regression,
  # not evidence int is still Base.
  #
  # NOTE: this list is incomplete. aihub-api-v1's own KVM-Get*Audience
  # policies use KeyValueMapOperations, and Apigee's own bundle-create
  # response reports hasExtensiblePolicy=true for this proxy -- a type this
  # blocklist doesn't cover. Not a live bug today only because int is
  # already INTERMEDIATE and tolerates extensible policies; if this check
  # is ever relied on to keep a Base environment Base, it needs
  # KeyValueMapOperations (and anything else Apigee itself classifies as
  # extensible) added, not just this hand-picked list.
  if grep -rlE '<(JavaScript|ServiceCallout|SanitizeUserPrompt|SanitizeModelResponse|LLMTokenQuota|PromptTokenLimit)\b' \
       "$APIGEE_DIR"/proxies/aihub-api-v1/ >/dev/null 2>&1; then
    echo "ERROR: extensible policy found in a proxy targeted at a Base environment" >&2
    exit 1
  fi
}

fail_on_missing_use_effective_count() {
  # SpikeArrest is per message processor unless UseEffectiveCount is true.
  # The default template sets it; this catches a hand-written policy.
  for f in $(grep -rl '<SpikeArrest' "$APIGEE_DIR"/proxies/ 2>/dev/null || true); do
    grep -q '<UseEffectiveCount>true</UseEffectiveCount>' "$f" || {
      echo "ERROR: $f has SpikeArrest without UseEffectiveCount=true" >&2; exit 1; }
  done
}

fail_on_jwt_policy_explicit_auth_source() {
  # Apigee strips the "Bearer " prefix ONLY when <Source> is omitted -- the
  # default source is already the Authorization header. Set <Source>
  # explicitly and the policy takes the variable verbatim, so it tries to
  # parse the literal string "Bearer eyJ..." as a JWT and fails before
  # signature verification is ever attempted. There is no option to request
  # stripping when <Source> is used.
  #
  # This shipped in VJ-EntraToken and produced a hard 401 on every request
  # with a provably valid token; it cost a long investigation because every
  # "is the token valid?" check passes while the policy never sees the token.
  # See docs/BUILD-LOG.md #37.
  for f in $(grep -rlE '<(VerifyJWT|DecodeJWT)\b' "$APIGEE_DIR"/proxies/ 2>/dev/null || true); do
    if grep -qiE '<Source>[[:space:]]*request\.header\.authorization[[:space:]]*</Source>' "$f"; then
      echo "ERROR: $f sets <Source>request.header.authorization</Source> on a JWT policy." >&2
      echo "       Remove the element entirely -- the default source is that header AND strips 'Bearer '." >&2
      exit 1
    fi
  done
}

fail_on_extractvariables_claim_copy() {
  # ExtractVariables extracts by pattern-matching message content: a
  # top-level <Variable name ref> with no <Pattern> child extracts nothing
  # and silently sets NO variables. Copying an already-decoded JWT claim to
  # a shorter name is assignment, not extraction -- it belongs in an
  # AssignMessage/<AssignVariable>.
  #
  # This shipped as EV-UserClaims. jwt_roles never resolved, so
  # NOT (jwt_roles Matches "*Role*") evaluated NOT false = true and every
  # request 403'd on a role the caller actually held. See docs/BUILD-LOG.md #37.
  for f in $(grep -rl '<ExtractVariables' "$APIGEE_DIR"/proxies/ 2>/dev/null || true); do
    if grep -qE '<(Variable|JWT)[^>]*(ref|source)="jwt\.' "$f"; then
      echo "ERROR: $f uses ExtractVariables to copy decoded JWT claims." >&2
      echo "       ExtractVariables needs a <Pattern> to extract anything; with none it sets nothing." >&2
      echo "       Use AssignMessage with <AssignVariable><Name>/<Ref> instead." >&2
      exit 1
    fi
  done
}

fail_on_modelarmor_template_drift() {
  # The Model Armor template is NOT Terraform-managed -- deliberately, see the
  # header of create-model-armor-template.sh. The proxy's SanitizeUserPrompt /
  # SanitizeModelResponse policies name it by literal resource path, and the
  # failure mode is not subtle: a path naming a template that does not exist
  # fails CLOSED with a policy error on every LLM call, so the whole gateway is
  # down rather than degraded.
  #
  # This check asks GCP what actually exists rather than comparing two strings
  # in the repository. Comparing the policies against a hardcoded expectation
  # only proves two files agree with each other -- both can be wrong together,
  # which is precisely the situation when someone renames or recreates the
  # template by hand. Listing the live templates makes "does the thing the
  # proxy points at exist?" a question about GCP, which is the question that
  # matters.
  #
  # Reaching Model Armor requires its REGIONAL endpoint; gcloud defaults to the
  # global one, which does not serve template CRUD and returns a 403 that looks
  # like an IAM error. Hence the override, restored afterwards.
  # Model Armor was removed from llm-gateway-v1 on 2026-09-15 (see
  # apigee/disabled/model-armor/README.md), so on the current bundle this loop
  # has nothing to iterate and the whole gate would pass in silence. Say so
  # instead, and skip the regional gcloud lookup that can no longer prove
  # anything. This function's own comments argue that a skipped check reported
  # as a pass is the failure mode to avoid; a gate that quietly checks zero
  # files is exactly that.
  if [ -z "$(grep -rl '<ModelArmor>' "$APIGEE_DIR"/proxies/ 2>/dev/null || true)" ]; then
    echo "NOTICE: no proxy references <ModelArmor> -- Model Armor template check SKIPPED." >&2
    echo "        There is NO prompt/response safety scanning on the LLM gateway." >&2
    echo "        See apigee/disabled/model-armor/README.md to restore it." >&2
    return 0
  fi

  local src project location live rc
  src="$SCRIPT_DIR/create-model-armor-template.sh"
  [ -f "$src" ] || { echo "ERROR: $src missing -- Model Armor template spec is gone." >&2; exit 1; }
  project="$(grep -oE '^PROJECT="\$\{MODEL_ARMOR_PROJECT:-[^}]+\}"' "$src" | sed 's/.*:-\(.*\)}"/\1/')"
  location="$(grep -oE '^LOCATION="\$\{MODEL_ARMOR_LOCATION:-[^}]+\}"' "$src" | sed 's/.*:-\(.*\)}"/\1/')"
  [ -n "$project" ] && [ -n "$location" ] || {
    echo "ERROR: could not parse project/location out of $src -- update this check to match." >&2
    exit 1; }

  local prev_ep
  prev_ep="$(gcloud config get-value "api_endpoint_overrides/modelarmor" 2>/dev/null || true)"
  gcloud config set "api_endpoint_overrides/modelarmor" \
    "https://modelarmor.${location}.rep.googleapis.com/" >/dev/null 2>&1 || true
  live="$(gcloud model-armor templates list \
            --project="$project" --location="$location" \
            --format='value(name)' 2>/dev/null)" && rc=0 || rc=$?
  if [ -n "$prev_ep" ] && [ "$prev_ep" != "(unset)" ]; then
    gcloud config set "api_endpoint_overrides/modelarmor" "$prev_ep" >/dev/null 2>&1 || true
  else
    gcloud config unset "api_endpoint_overrides/modelarmor" >/dev/null 2>&1 || true
  fi

  local referenced f
  for f in $(grep -rl '<ModelArmor>' "$APIGEE_DIR"/proxies/ 2>/dev/null || true); do
    referenced="$(grep -oE '<TemplateName>[^<]+</TemplateName>' "$f" | head -1 | sed 's|</\?TemplateName>||g')"
    [ -n "$referenced" ] || {
      echo "ERROR: $f has a <ModelArmor> block with no <TemplateName>." >&2; exit 1; }

    if [ "$rc" -ne 0 ] || [ -z "$live" ]; then
      # Whether CI can reach regional endpoints is still unverified (see
      # docs/BUILD-LOG.md #39). Degrade to a spelling check rather than either
      # failing the pipeline on an environment limitation or pretending the
      # live check ran. Say so loudly -- a skipped check reported as a pass is
      # the exact failure mode Model Armor's own EXECUTION_SKIPPED taught us.
      echo "WARNING: could not list Model Armor templates in ${project}/${location}." >&2
      echo "         Live existence check SKIPPED; falling back to a path-shape check only." >&2
      case "$referenced" in
        projects/"$project"/locations/"$location"/templates/*) : ;;
        *) echo "ERROR: $f references $referenced, wrong project/location for this estate." >&2
           exit 1 ;;
      esac
    else
      # Accept either form gcloud may print for `name`: the full resource path,
      # or the bare template id. Pinning to one spelling risks the worse
      # failure of the two -- a gate that rejects a correct tree because
      # gcloud's output format shifted, which trains people to bypass it.
      local ref_id
      ref_id="${referenced##*/}"
      grep -qxF "$referenced" <<<"$live" || grep -qxF "$ref_id" <<<"$live" || {
        echo "ERROR: $f references a Model Armor template that does not exist in GCP." >&2
        echo "       referenced: $referenced" >&2
        echo "       live templates in ${project}/${location}:" >&2
        sed 's/^/         /' <<<"$live" >&2
        echo "       Create it with ci/create-model-armor-template.sh, or fix the policy." >&2
        exit 1; }
    fi
  done
}

fail_on_extensible_policy_in_base_env
fail_on_missing_use_effective_count
fail_on_jwt_policy_explicit_auth_source
fail_on_extractvariables_claim_copy
fail_on_modelarmor_template_drift

# -f must point AT the apiproxy/ folder itself, not its parent -- apigeecli's
# own error is explicit about this ("--proxy-folder or -p must be a path to
# apiproxy folder") if you get it wrong, confirmed live 2026-09-07.
apigeecli apis create bundle -f "$APIGEE_DIR"/proxies/aihub-api-v1/apiproxy -n aihub-api-v1 -o "$ORG" -r "$REGION" -t "$TOKEN"
apigeecli apis deploy -n aihub-api-v1 -e int -o "$ORG" -r "$REGION" -t "$TOKEN" --ovr --wait \
  --sa "apigee-int-runtime@${ORG}.iam.gserviceaccount.com"

# llm-gateway-v1 -- the LLM gateway (docs/21 build procedure, docs/23 backend
# contract). Deployed to the llm environment as apigee-llm-runtime, the only
# identity holding roles/aiplatform.user in gclt-aicoe-dev-llm (LLD D-30).
#
# ORDER DEPENDENCY: this bundle's SUP-/SMR- policies reference the Model Armor
# template by literal resource path, and a missing template fails CLOSED on
# every call. terraform/7-apigee-runtime must have applied
# google_model_armor_template.llm_gateway before this runs. The gate below
# cannot verify that (it has no GCP read here), so it verifies the weaker but
# still useful property that the path in the policies matches the path
# Terraform builds.
apigeecli apis create bundle -f "$APIGEE_DIR"/proxies/llm-gateway-v1/apiproxy -n llm-gateway-v1 -o "$ORG" -r "$REGION" -t "$TOKEN"
apigeecli apis deploy -n llm-gateway-v1 -e llm -o "$ORG" -r "$REGION" -t "$TOKEN" --ovr --wait \
  --sa "apigee-llm-runtime@${ORG}.iam.gserviceaccount.com"

# --upsert is required: aicoe-standard already exists (created manually per
# docs/20 Part 1, before this pipeline existed). Without it, apigeecli
# products import attempts a create against an already-existing product and
# fails -- confirmed against apigeecli's own --help, not assumed.
apigeecli products import -f "$APIGEE_DIR"/products/products.json -o "$ORG" -r "$REGION" -t "$TOKEN" --upsert
apigeecli kvms entries import -m backend-audiences -e int -f "$APIGEE_DIR"/kvm/backend-audiences.json -o "$ORG" -r "$REGION" -t "$TOKEN"
# No allowed-models KVM import, deliberately, and this is not an omission to
# fix later: model allow-listing is done by the aicoe-llm product's native LLM
# Operations (docs/21 Section 2), which Apigee's own credential/operation
# matching enforces BEFORE any policy in the bundle runs. The KVM container
# Terraform still creates in 7-apigee-runtime is a leftover from the superseded
# design -- harmless unpopulated, and llm-gateway-v1 contains no policy that
# reads it. Populating it would create a second, unenforced allow-list.

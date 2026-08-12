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

fail_on_extensible_policy_in_base_env() {
  # A single extensible policy reclassifies the whole proxy and forces the
  # environment up a tier. The int environment is Base and must stay Standard.
  if grep -rlE '<(JavaScript|ServiceCallout|SanitizeUserPrompt|SanitizeModelResponse|LLMTokenQuota|PromptTokenLimit)\b' \
       apigee/proxies/aihub-api-v1/ >/dev/null 2>&1; then
    echo "ERROR: extensible policy found in a proxy targeted at a Base environment" >&2
    exit 1
  fi
}

fail_on_missing_use_effective_count() {
  # SpikeArrest is per message processor unless UseEffectiveCount is true.
  # The default template sets it; this catches a hand-written policy.
  for f in $(grep -rl '<SpikeArrest' apigee/proxies/ 2>/dev/null || true); do
    grep -q '<UseEffectiveCount>true</UseEffectiveCount>' "$f" || {
      echo "ERROR: $f has SpikeArrest without UseEffectiveCount=true" >&2; exit 1; }
  done
}

fail_on_extensible_policy_in_base_env
fail_on_missing_use_effective_count

apigeecli apis create bundle -f apigee/proxies/aihub-api-v1  -n aihub-api-v1  -o "$ORG" -t "$TOKEN"
apigeecli apis deploy -n aihub-api-v1 -e int -o "$ORG" -t "$TOKEN" --ovr --wait \
  --sa "apigee-int-runtime@${ORG}.iam.gserviceaccount.com"

apigeecli apis create bundle -f apigee/proxies/llm-gateway-v1 -n llm-gateway-v1 -o "$ORG" -t "$TOKEN"
apigeecli apis deploy -n llm-gateway-v1 -e llm -o "$ORG" -t "$TOKEN" --ovr --wait \
  --sa "apigee-llm-runtime@${ORG}.iam.gserviceaccount.com"

apigeecli products import -f apigee/products/products.json -o "$ORG" -t "$TOKEN"
apigeecli kvms entries import -m backend-audiences -e int -f apigee/kvm/backend-audiences.json -o "$ORG" -t "$TOKEN"
apigeecli kvms entries import -m allowed-models     -e llm -f apigee/kvm/allowed-models.json     -o "$ORG" -t "$TOKEN"

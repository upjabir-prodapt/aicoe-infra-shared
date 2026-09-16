# Model Armor — removed from `llm-gateway-v1`, retained for restore

**Status: removed from the deployed proxy on 2026-09-15. There is currently NO prompt or response
safety scanning on the LLM gateway.** That is a known, accepted state — not an oversight — and this
directory holds everything needed to put it back.

These files are deliberately **outside** `apiproxy/policies/`. A policy file left in that directory
ships inside the bundle even when no flow references it, and the Model Armor policies carry a
`<TemplateName>` pointing at a live GCP resource. Keeping them here means the deployed bundle is
genuinely clean.

## Why it was removed

Model Armor costs **two API calls per gateway request** (one scanning the prompt, one the response)
against a **1,200 QPM per-project quota**. That puts a hard ceiling of **600 gateway calls/minute** on
the whole platform, shared across Translation and Sales-Agent.

Measured production traffic already exceeds the burst shape that ceiling allows: a single large
Translation document job bursts to **12–17 LLM calls/second**, and one ~90,000-character document
issues **236 calls in 158 seconds**. A 255-page document would issue roughly 1,800.

A fail-open workaround (`continueOnError="true"` plus `RF-PromptBlocked`/`RF-ResponseBlocked` to
re-raise genuine detections) was built and then rejected before deployment. The reason is worth
keeping: Apigee delivers a real content match as a **policy error** —
`steps.sanitize.user.prompt.FilterMatched` — through the *same channel* as an infrastructure failure.
So `continueOnError="true"` swallows genuine detections too, and blocking then depends on reading
`filterMatchState` on the error path. **That variable has only ever been observed on a clean call.**
If Apigee does not populate it when it raises `FilterMatched`, a quota error and a real prompt
injection become indistinguishable, and flagged content passes silently.

Silently-unscanned traffic that *looks* protected is a worse outcome than having no scanning at all,
because only one of those two states is visible to the people relying on it. Hence: remove it
outright, be loud about the gap, and restore it properly once the quota allows.

## What must be true before restoring

1. **The Model Armor quota is raised.** Default is 1,200 QPM per project, adjustable to 1,200 without
   a request; beyond that, contact Cloud Customer Care
   (<https://docs.cloud.google.com/model-armor/quotas>). Size the ask as
   `target_gateway_calls_per_min × 2 × 1.3` for headroom. For `SA-SpikeArrest` at `20ps` (1,200
   gateway calls/min) that is roughly **3,100 QPM**; at `30ps`, roughly **4,700**.
2. **`SA-SpikeArrest` is re-derived against the new quota.** It currently sits at `20ps`, set while
   Model Armor was out of the flow and therefore **not** constrained by it. On restore the old
   relationship returns: `max gateway calls/min = Model Armor QPM ÷ 2`. Leaving `20ps` against an
   unchanged 1,200 QPM would over-subscribe by 2×. These two numbers are one ceiling expressed in two
   places — change them together.
3. **The `FilterMatched` behaviour is settled in a debug session**, if and only if you intend to
   restore with `continueOnError="true"`. Send a deliberately malicious prompt and confirm that
   `filterMatchState` is populated as `MATCH_FOUND` on the error path. If it is not, fail-open is not
   safely available and the policies must be restored with `continueOnError="false"`.
4. **The Model Armor template still exists.** Both policies reference
   `projects/gclt-aicoe-dev-llm/locations/europe-west3/templates/aicoe-llm-gateway`, created by
   `terraform/ci/create-model-armor-template.sh` (it is **not** Terraform-managed). Pointing at a
   missing template fails **closed** — an error on every call. `ci/deploy-apigee-config.sh` gates on
   this via a live `gcloud` lookup.

## How to restore

Copy the six policy files back into the bundle:

```bash
cd apigee
cp disabled/model-armor/{SUP-SanitizeUserPrompt,SMR-SanitizeModelResponse}.xml \
   disabled/model-armor/{RF-PromptBlocked,RF-ResponseBlocked}.xml \
   disabled/model-armor/{EV-PromptAndResponse,EV-ModelResponseText}.xml \
   proxies/llm-gateway-v1/apiproxy/policies/

# and swap the scan-verdict stub back to the verdict-reading version
cp disabled/model-armor/AM-ScanVerdict.xml.verdict-version \
   proxies/llm-gateway-v1/apiproxy/policies/AM-ScanVerdict.xml
```

Then restore the flow steps in `proxies/llm-gateway-v1/apiproxy/proxies/default.xml`. Both removal
sites carry a comment naming exactly what was there.

**Request flow** — after `LTQ-Enforce`, before `AM-StripIdentityHeaders`:

```xml
<Step><Name>EV-PromptAndResponse</Name></Step>
<Step><Name>SUP-SanitizeUserPrompt</Name></Step>
<Step>
  <Name>RF-PromptBlocked</Name>
  <Condition>SanitizeUserPrompt.SUP-SanitizeUserPrompt.filterMatchState = "MATCH_FOUND"</Condition>
</Step>
```

**Response flow** — `EV-ModelResponseText` and `SMR-SanitizeModelResponse` go *first*, before
`LTQ-Count`; `RF-ResponseBlocked` goes **last, after `ML-Attribution`**:

```xml
<Step><Name>EV-ModelResponseText</Name></Step>
<Step><Name>SMR-SanitizeModelResponse</Name></Step>
<!-- ... LTQ-Count, AM-ScanVerdict, ML-Attribution ... -->
<Step>
  <Name>RF-ResponseBlocked</Name>
  <Condition>SanitizeModelResponse.SMR-SanitizeModelResponse.filterMatchState = "MATCH_FOUND"</Condition>
</Step>
```

That ordering is not cosmetic. Raising a fault ends the response flow, so putting `RF-ResponseBlocked`
next to `SMR-` (mirroring the request side) would skip `LTQ-Count`, `AM-ScanVerdict` and
`ML-Attribution` — every blocked response would go unlogged and its tokens uncounted, which is exactly
the case most worth a record.

`RF-PromptBlocked` and `RF-ResponseBlocked` are only needed if restoring with
`continueOnError="true"`. With `continueOnError="false"` Apigee blocks on a match by itself and they
are redundant — but read point 3 above before choosing fail-open.

## Traps already paid for — do not re-derive these

- **`UserPromptSource`/`LLMResponseSource` must be set explicitly.** The policy defaults use *negative*
  array indices, which Apigee's message-template `jsonPath()` resolves to an empty string, and an empty
  prompt is a **fatal** `Template was resolved to empty string`, not a skipped scan.
- **The JSONPath must be unquoted.** Quoting it fails the same way. That cost a deploy cycle.
- **`LLMResponseSource` is the real element name**, not `ModelResponseSource`. The invented name
  validated *and deployed* cleanly, then was silently ignored at runtime — Apigee does not reject
  unrecognised elements. A green deploy proves nothing here.
- **`jsonPath()` in a message template does not extract from the Vertex body**; `ExtractVariables` uses
  a different JSONPath implementation and does. That is why `EV-PromptAndResponse` exists at all rather
  than the policies reading the payload directly.
- **The region appears in four places** and all must agree: both policy `<TemplateName>`s,
  `terraform/7-apigee-runtime/model-armor.tf`'s `llm_region`, and the target endpoint `<URL>`.

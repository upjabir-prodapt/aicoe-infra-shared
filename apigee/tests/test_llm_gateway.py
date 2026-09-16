#!/usr/bin/env python3
"""End-to-end smoke test for the Apigee `llm` gateway (proxy `llm-gateway-v1`).

WHERE THIS CAN RUN
------------------
NOT from the AI CoE workstation. `llm.aicoedev-int.colt.net` does not resolve
there (confirmed 2026-09-14); it is an internal name served inside the VPC.
Run it from something on the VPC path -- a Cloud Run job or service in
gclt-aicoe-dev-st, or a VM in gclt-aicoe-dev-vpc.

The gateway also serves a Colt-internal-CA certificate, which Python's default
trust store rejects with CERTIFICATE_VERIFY_FAILED. Pass --ca-bundle pointing
at the Colt CA (shared_ui/aihub-ui/certs/colt-internal-ca.pem in this estate),
or set REQUESTS_CA_BUNDLE. Baking that CA into the app images is tracked as
T-1/S-1 in docs/23; this script does not need it baked in, only supplied.

WHAT IT CHECKS, AND WHY EACH ONE
--------------------------------
Each check is written so a PASS means something specific. The point is to
distinguish "the gateway is up" from "the gateway is enforcing what we think
it enforces" -- an HTTP 200 alone proves neither.

Usage:
    ./test_llm_gateway.py --api-key "$LLM_GATEWAY_API_KEY" \
        --ca-bundle /path/to/colt-internal-ca.pem

    # before any developer app exists, the auth checks alone are still useful:
    ./test_llm_gateway.py --ca-bundle /path/to/colt-internal-ca.pem
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

try:
    import requests
except ImportError:
    sys.exit("requires `requests` (pip install requests)")


DEFAULT_BASE = "https://llm.aicoedev-int.colt.net/v1"
DEFAULT_MODEL = "gemini-2.5-flash"

# Matches the identity contract in docs/23 section 4.2. The gateway's
# AM-Identity policy reads these and defaults them to system/unattributed when
# absent, so omitting them is legal -- it just makes the call unattributable.
HDR_OID = "x-colt-user-oid"
HDR_DEPT = "x-colt-user-department"


class Results:
    def __init__(self) -> None:
        self.rows: list[tuple[str, bool | None, str]] = []

    def record(self, name: str, ok: bool | None, detail: str = "") -> None:
        self.rows.append((name, ok, detail))
        mark = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
        print(f"  [{mark}] {name}" + (f" -- {detail}" if detail else ""))

    @property
    def failed(self) -> int:
        return sum(1 for _, ok, _ in self.rows if ok is False)

    def summary(self) -> None:
        passed = sum(1 for _, ok, _ in self.rows if ok is True)
        skipped = sum(1 for _, ok, _ in self.rows if ok is None)
        print(f"\n{passed} passed, {self.failed} failed, {skipped} skipped")


def body(prompt: str, grounded: bool = False) -> dict[str, Any]:
    """A Vertex generateContent body.

    Deliberately the bare shape google-genai sends when project and location
    are both None -- that is what makes the client omit the
    projects/.../locations/... path segment the proxy's TargetEndpoint supplies.
    """
    payload: dict[str, Any] = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.0},
    }
    if grounded:
        payload["tools"] = [{"googleSearch": {}}]
    return payload


def call(
    session: requests.Session,
    base: str,
    model: str,
    *,
    api_key: str | None,
    identity: bool,
    grounded: bool = False,
    prompt: str = "Reply with the single word: ok",
    timeout: int = 60,
) -> requests.Response:
    headers = {"Content-Type": "application/json"}
    if api_key is not None:
        headers["x-apikey"] = api_key
    if identity:
        headers[HDR_OID] = "test-harness-oid"
        headers[HDR_DEPT] = "platform-engineering"
    url = f"{base}/publishers/google/models/{model}:generateContent"
    return session.post(url, headers=headers, json=body(prompt, grounded), timeout=timeout)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default=os.environ.get("LLM_GATEWAY_BASE_URL", DEFAULT_BASE))
    ap.add_argument("--api-key", default=os.environ.get("LLM_GATEWAY_API_KEY"))
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--ca-bundle", default=os.environ.get("REQUESTS_CA_BUNDLE"),
                    help="PEM for the Colt internal CA. Without it TLS verification fails.")
    ap.add_argument("--insecure", action="store_true",
                    help="Skip TLS verification. Diagnosis only -- never a fix, and never in CI.")
    ap.add_argument("--rate-limit-probe", action="store_true",
                    help="Send a burst to prove SA-SpikeArrest returns 429. Consumes real quota.")
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    s = requests.Session()
    s.verify = False if args.insecure else (args.ca_bundle or True)
    if args.insecure:
        requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]

    r = Results()
    print(f"gateway: {base}\nmodel:   {args.model}\n")

    # ---- 1. reachability and TLS -------------------------------------------
    # Any HTTP status proves DNS, routing and TLS all worked. A connection
    # error here means the remaining results would be meaningless, so stop.
    print("connectivity")
    try:
        probe = call(s, base, args.model, api_key=None, identity=False, timeout=30)
        r.record("TLS handshake and routing", True, f"HTTP {probe.status_code}")
    except requests.exceptions.SSLError as e:
        r.record("TLS handshake and routing", False, f"TLS verification failed: {e}")
        print("\nSupply the Colt internal CA with --ca-bundle. See this file's header.")
        r.summary()
        return 1
    except requests.exceptions.RequestException as e:
        r.record("TLS handshake and routing", False, str(e))
        print("\nName does not resolve or is unroutable -- are you running inside the VPC?")
        r.summary()
        return 1

    # ---- 2. the API key is actually enforced -------------------------------
    # VA-ApiKey must reject an absent and a bogus key. If either returns 200
    # the gateway is open, which is worse than it being down.
    print("\nauthentication (VA-ApiKey)")
    r.record("no x-apikey is rejected", probe.status_code in (401, 403),
             f"HTTP {probe.status_code}, expected 401/403")
    try:
        bad = call(s, base, args.model, api_key="not-a-real-key", identity=False, timeout=30)
        r.record("invalid x-apikey is rejected", bad.status_code in (401, 403),
                 f"HTTP {bad.status_code}, expected 401/403")
    except requests.exceptions.RequestException as e:
        r.record("invalid x-apikey is rejected", False, str(e))

    # ---- 3. unknown path falls through to 404, not to Vertex ----------------
    # proxies/default.xml has a no-match RouteRule precisely so an unrecognised
    # shape 404s here instead of being forwarded with a guessed path.
    try:
        nf = s.post(f"{base}/definitely/not/a/model:generateContent",
                    headers={"Content-Type": "application/json",
                             **({"x-apikey": args.api_key} if args.api_key else {})},
                    json=body("x"), timeout=30)
        r.record("unrecognised path returns 404", nf.status_code == 404,
                 f"HTTP {nf.status_code}, expected 404")
    except requests.exceptions.RequestException as e:
        r.record("unrecognised path returns 404", False, str(e))

    if not args.api_key:
        print("\nno --api-key given; skipping everything that needs a valid credential")
        for name in ("generateContent succeeds", "identity headers accepted",
                     "google_search grounding survives the proxy", "spike arrest returns 429"):
            r.record(name, None, "needs --api-key")
        r.summary()
        return 1 if r.failed else 0

    # ---- 4. a real inference call ------------------------------------------
    print("\ninference")
    try:
        ok = call(s, base, args.model, api_key=args.api_key, identity=True, timeout=90)
        if ok.status_code != 200:
            r.record("generateContent succeeds", False,
                     f"HTTP {ok.status_code}: {ok.text[:300]}")
        else:
            data = ok.json()
            cands = data.get("candidates") or []
            text = ""
            if cands:
                text = "".join(p.get("text", "") for p in cands[0].get("content", {}).get("parts", []))
            r.record("generateContent succeeds", bool(cands),
                     f"{len(cands)} candidate(s), text={text[:60]!r}")
            usage = data.get("usageMetadata") or {}
            r.record("usageMetadata present (LTQ-Count can meter tokens)", bool(usage),
                     json.dumps(usage) if usage else "absent -- token quota cannot count")
    except requests.exceptions.RequestException as e:
        r.record("generateContent succeeds", False, str(e))

    # ---- 5. identity headers are accepted ----------------------------------
    # Only proves the proxy does not reject them. Whether attribution actually
    # lands has to be read from Cloud Logging -- see the note printed at the end.
    try:
        anon = call(s, base, args.model, api_key=args.api_key, identity=False, timeout=90)
        r.record("identity headers accepted (and optional)",
                 anon.status_code == 200, f"HTTP {anon.status_code} without identity headers")
    except requests.exceptions.RequestException as e:
        r.record("identity headers accepted (and optional)", False, str(e))

    # ---- 6. grounding survives the proxy -----------------------------------
    # The one check that a 200 genuinely cannot substitute for. Model Armor
    # configured to REWRITE responses (SDP advanced_config) can strip
    # groundingMetadata without erroring: Sales-Agent would get zero evidence
    # on a successful call, with no signal anywhere. See docs/23 I-6.
    print("\ngrounding (docs/23 I-6)")
    try:
        g = call(s, base, args.model, api_key=args.api_key, identity=True, grounded=True,
                 prompt="Who is the current CEO of Colt Technology Services? Cite sources.",
                 timeout=120)
        if g.status_code != 200:
            r.record("google_search grounding survives the proxy", False,
                     f"HTTP {g.status_code}: {g.text[:300]}")
        else:
            gd = g.json()
            cands = gd.get("candidates") or []
            meta = (cands[0].get("groundingMetadata") if cands else None) or {}
            chunks = meta.get("groundingChunks") or []
            r.record("google_search grounding survives the proxy", bool(chunks),
                     f"{len(chunks)} groundingChunks"
                     if chunks else "NO groundingChunks -- evidence would be empty, silently")
            r.record("searchEntryPoint preserved (display is required by Google's terms)",
                     bool(meta.get("searchEntryPoint")),
                     "present" if meta.get("searchEntryPoint") else "stripped")
    except requests.exceptions.RequestException as e:
        r.record("google_search grounding survives the proxy", False, str(e))

    # ---- 7. spike arrest, opt-in ------------------------------------------
    print("\nrate limiting")
    if not args.rate_limit_probe:
        r.record("spike arrest returns 429", None, "not run; pass --rate-limit-probe")
    else:
        # SA-SpikeArrest is 10ps, derived from Model Armor's 1,200 QPM ceiling
        # at two Model Armor calls per request. 25 rapid calls should trip it.
        codes: list[int] = []
        for _ in range(25):
            try:
                codes.append(call(s, base, args.model, api_key=args.api_key,
                                  identity=True, prompt="ok", timeout=30).status_code)
            except requests.exceptions.RequestException:
                codes.append(0)
            time.sleep(0.02)
        r.record("spike arrest returns 429", 429 in codes,
                 f"statuses seen: {sorted(set(codes))}")

    print(
        "\nNot checked here, because it cannot be seen from the client side:\n"
        "  * attribution -- read the llm-gateway-attribution log in\n"
        "    gclt-aicoe-dev-apigee and confirm the department field is your value,\n"
        "    not 'unattributed'.\n"
        "  * Model Armor scan verdicts -- the same log carries scan_* fields.\n"
        "    EXECUTION_SKIPPED means that filter did NOT scan the content and the\n"
        "    call succeeded anyway. 'unset' means the flow-variable name in\n"
        "    AM-ScanVerdict is wrong for this Apigee version and needs confirming\n"
        "    in a debug session. Neither is a pass."
    )
    r.summary()
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())

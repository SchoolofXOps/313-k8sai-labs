#!/usr/bin/env bash
# addon-serving — verify the inference serving layer on a running grid-core.
#
# READ-ONLY on the cluster's object set. It changes nothing: the one request it
# issues is a completion request through the router, which is what the layer is
# for, and the only local side effect is a port forward this script starts and
# kills.
#
# IT BRANCHES ON SIZE, exactly as create.sh does.
#   At the minimum size it ASSERTS THE FENCE: the layer's namespace carries no
#   workload, the skip token is printed, and the measured figure that justifies
#   the fence is restated. Exit 0 — the fence verified is a successful outcome,
#   and a non-zero exit there would make a correctly-fenced layer
#   indistinguishable from a broken one.
#   At the installing size — and under the author-only SERVING_OVER_BUDGET
#   override — it asserts the layer is up and then SERVES A REAL REQUEST.
#
# THE ONE ASSERTION THE SERVING REQUIREMENT ACTUALLY NEEDS, and why it is shaped
# this way. The request is sent through the ROUTER and THE RESPONSE IS READ FROM
# THE ROUTER. A request sent straight to a simulator would return HTTP 200 with
# a well-formed body, exit 0, and look identical — while proving that the
# simulator works and saying NOTHING about the routing path, which is the half
# the requirement names. So the port forward targets the router's own data-plane
# service, and the endpoint choice is then read back from the data plane's access
# log: the destination header the endpoint picker SET, and the upstream the data
# plane actually CONNECTED to. Those two agreeing is the router having chosen.
#
# WHAT THIS FILE DELIBERATELY DOES NOT ASSERT: a prefix-cache routing outcome
# from a repeated-prefix replay. That null result was MEASURED THREE WAYS in
# Phase 1 — residency SATURATES within the first pass of a small prefix set over
# a small fleet, every endpoint then scores alike, the max-score pick becomes an
# arbitrary tie-break, and the cache-aware policy is observationally identical to
# the random control (50% and 65% mean per-prefix concentration against a control
# at 54% and 67%). An assertion built on that replay would pass or fail for
# reasons unrelated to routing. It is the natural assertion to reach for, which
# is why the exclusion is stated here with its reason rather than left implicit.
# The experiment that CAN tell the policies apart seeds uneven residency first
# and lives in the harness, not in a verify.
#
# THE ORDER OF THE ASSERTIONS IS LOAD-BEARING. The layer's workload count is
# asserted NON-ZERO before anything is asserted about the workloads, because
# "every workload is available" over zero workloads is VACUOUSLY TRUE and a
# verify that reports clean over an un-applied layer is this phase's named
# failure mode.
#
# NO PERFORMANCE NUMBER IS ASSERTED anywhere in this file or in checks.json: no
# latency, no token rate, no percentage. The response is judged WELL-FORMED, not
# fast. A timing figure asserted by a learner's own checks file fails on a slower
# laptop and teaches the learner that the course is wrong.
#
# Usage:
#   bash verify.sh
#   SIZE=16 bash verify.sh
#   SERVING_OVER_BUDGET=1 bash verify.sh          # author-only
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: read-only on the object set.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
HARNESS_DIR="${LABS_DIR}/serving/sim-router"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-spike-03}"

REQUIRED_SIZE=16
MEASURED_PEAK_MB=5227
MEASURED_OVER_MB=727
SERVING_OVER_BUDGET="${SERVING_OVER_BUDGET:-0}"

# The model name the simulator fleet was launched with, and the prompt. The
# prompt is short on purpose: the simulator defaults to a 1024-token context and
# refuses anything longer with an HTTP 400 naming both numbers, so a long prompt
# here would fail for a reason that has nothing to do with routing.
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
FWD_ENVOY_PORT="${FWD_ENVOY_PORT:-18181}"
# The data plane's access log flushes on an interval, so the endpoint choice is
# read after that interval has passed rather than immediately.
LOG_FLUSH_WAIT="${LOG_FLUSH_WAIT:-8}"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

# --- 1. the base cluster ------------------------------------------------------
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer has no cluster to be on." >&2
    echo "      Run the base profile first:  ${BASE}" >&2
    echo "      then apply the layer:        ${APPLY}" >&2
    exit 1
    ;;
esac

# --- 2. the size gate, emitted from the one place that owns the token ---------
GATE_OUT="$(bash "${LABS_TOOLS}/size-gate.sh" "${REQUIRED_SIZE}" -- true)"

LAYER_WORKLOADS="vllm-render sim sim-router-epp sim-router-envoy"

count_layer_workloads() {
  if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    printf '0'
    return 0
  fi
  kcn get deploy -o json 2>/dev/null \
    | jq -r '[.items[].metadata.name
              | select(. == "vllm-render" or . == "sim" or . == "sim-router-epp" or . == "sim-router-envoy")]
             | length' 2>/dev/null || printf '0'
}

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required — the workload count and the response shape are both read by folding JSON," >&2
  echo "      which jsonpath cannot do." >&2
  echo "      Install it (brew install jq) and re-run; this script changes nothing." >&2
  exit 1
fi

# --- 3. THE FENCED BRANCH -----------------------------------------------------
if [ -n "${GATE_OUT}" ] && [ "${SERVING_OVER_BUDGET}" != "1" ]; then
  FOUND="$(count_layer_workloads)"
  if [ "${FOUND}" -ne 0 ]; then
    echo "FAIL: ${FOUND} layer workload(s) exist in namespace '${NAMESPACE}' at SIZE=${SIZE}," >&2
    echo "      where this layer is FENCED and must apply nothing." >&2
    echo "      A fenced create that silently installed anyway would exit 0 and look" >&2
    echo "      identical, and on this machine it would then exhaust memory and take the" >&2
    echo "      cluster rather than the script — which is why the fence is asserted on the" >&2
    echo "      object set and not on create.sh's exit code." >&2
    echo "      Remove them: bash ${ADDON_DIR}/teardown.sh" >&2
    exit 1
  fi
  printf '%s\n' "${GATE_OUT}"
  echo "FENCE: measured ${MEASURED_PEAK_MB} MiB of summed container peak against this size's ${BUDGET_MB} MiB"
  echo "  lab budget — ${MEASURED_OVER_MB} MiB over. Approved re-cut, 2026-10-05: REAL at SIZE=${REQUIRED_SIZE},"
  echo "  READ-ALONG here, with the committed Phase-1 captures standing in for the live run."
  echo
  echo "OK: addon-serving fenced at SIZE=${SIZE} and verified as fenced — 0 layer workloads in namespace '${NAMESPACE}', which is the asserted post-condition rather than an absence nobody looked for."
  echo "  exiting 0 is deliberate: the fence verified is a successful outcome, not a broken layer"
  echo "  no prefix-cache routing claim is made from a repeated-prefix replay — that null result was measured three ways"
  echo "  verify it where it installs:  SIZE=${REQUIRED_SIZE} bash ${ADDON_DIR}/verify.sh"
  echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
  exit 0
fi

OVERRIDE_ACTIVE=0
if [ -n "${GATE_OUT}" ] && [ "${SERVING_OVER_BUDGET}" = "1" ]; then
  OVERRIDE_ACTIVE=1
fi

# --- 4. THE INSTALLING BRANCH: the empty guard first -------------------------
assert_kubectl_version

if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' does not exist — the layer is not applied to this cluster." >&2
  echo "      Apply it: ${APPLY}" >&2
  exit 1
fi

FOUND="$(count_layer_workloads)"
if [ "${FOUND}" -lt 1 ]; then
  echo "FAIL: zero layer workloads in namespace '${NAMESPACE}', so this layer verifies nothing." >&2
  echo "      This is asserted BEFORE anything about the workloads, because 'every workload" >&2
  echo "      is available' over zero workloads is vacuously true." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi

TOTAL=0
READY=0
for _d in ${LAYER_WORKLOADS}; do
  TOTAL=$((TOTAL + 1))
  _rep="$(kcn get "deploy/${_d}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [ "${_rep:-0}" -ge 1 ]; then READY=$((READY + 1)); fi
done
if [ "${FOUND}" -ne "${TOTAL}" ] || [ "${READY}" -ne "${TOTAL}" ]; then
  echo "FAIL: ${FOUND} of ${TOTAL} layer workloads present and ${READY} of ${TOTAL} available in '${NAMESPACE}'." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get deploy,pods -o wide" >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi

SIM_REPLICAS="$(kcn get deploy/sim -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
if [ "${SIM_REPLICAS:-0}" -lt 2 ]; then
  echo "FAIL: the simulator fleet reports ${SIM_REPLICAS:-0} available replica(s)." >&2
  echo "      A router with fewer than two endpoints has nothing to choose BETWEEN: every" >&2
  echo "      request reaches the only endpoint whether the picker works or not, so an" >&2
  echo "      endpoint-choice assertion on one endpoint proves nothing." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get pods -l app=sim -o wide" >&2
  exit 1
fi

# --- 5. a REAL REQUEST THROUGH THE ROUTER, with the response read from it -----
# The forward targets the router's own data-plane Service, never a simulator
# Pod. A fresh local port is walked to, because a kill of a previous forward
# returns before the socket is released and the next forward's readiness check
# can then succeed against the DYING previous one — a failure that is invisible
# in the request log, because every response is still HTTP 200.
FWD_PID=""
stop_forward() {
  if [ -n "${FWD_PID}" ]; then
    kill "${FWD_PID}" 2>/dev/null || true
    wait "${FWD_PID}" 2>/dev/null || true
  fi
  FWD_PID=""
}
trap stop_forward EXIT

FWD_PORT="${FWD_ENVOY_PORT}"
_tries=0
while nc -z 127.0.0.1 "${FWD_PORT}" 2>/dev/null; do
  _tries=$((_tries + 1))
  if [ "${_tries}" -gt 50 ]; then
    echo "FAIL: no free local port in ${FWD_ENVOY_PORT}..$((FWD_ENVOY_PORT + 50)) to forward the router's data plane." >&2
    exit 1
  fi
  FWD_PORT=$((FWD_ENVOY_PORT + _tries))
done

kcn port-forward svc/sim-router-envoy "${FWD_PORT}:8081" >/dev/null 2>&1 &
FWD_PID=$!
_up=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if nc -z 127.0.0.1 "${FWD_PORT}" 2>/dev/null; then _up=1; break; fi
  sleep 1
done
if [ "${_up}" -ne 1 ]; then
  echo "FAIL: the port forward to the router's data plane never came up on 127.0.0.1:${FWD_PORT}." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get svc sim-router-envoy -o yaml" >&2
  exit 1
fi

# A tag unique to this run, so the access-log line read back below is THIS
# request's and not a line left by an earlier one.
REQ_TAG="verify-$(date -u +%Y%m%dT%H%M%SZ)-$$"

# The probe is written to a temp file and then RUN, rather than fed to `python3 -`
# from a heredoc inside a command substitution. That second form is the shape
# this project has already been bitten by once: a heredoc nested inside `$( )` is
# not reliably parsed by the shell version that ships as /bin/bash on the
# authoring platform, and the failure mode here was the worst kind — the
# substitution produced nothing, the variable was never assigned, and the script
# ran all the way to its success line before `set -u` caught it. Measured, and
# fixed the way labs/clusters/grid-core/create.sh already composes its own
# generated file.
PROBE_PY="$(mktemp "${TMPDIR:-/tmp}/addon-serving-probe.XXXXXX")"
probe_cleanup() { rm -f "${PROBE_PY}"; stop_forward; }
cat > "${PROBE_PY}" <<'PY'
import json, sys, urllib.request

base, model, tag = sys.argv[1], sys.argv[2], sys.argv[3]
body = json.dumps({"model": model,
                   "prompt": "Routing check %s. Name one Kubernetes object." % tag,
                   "max_tokens": 4, "temperature": 0}).encode()
req = urllib.request.Request(base + "/v1/completions", data=body, method="POST",
                             headers={"Content-Type": "application/json",
                                      "X-GSD-TAG": tag})
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        status = r.status
        payload = json.loads(r.read().decode())
except Exception as exc:                       # reported, never swallowed
    print("response=unreachable reason=%s" % type(exc).__name__)
    raise SystemExit(0)

# WELL-FORMED, not fast. Four structural facts from the protocol's own schema;
# no duration, no token rate, nothing timed.
choices = payload.get("choices") or []
ok_model = payload.get("model") == model
ok_object = payload.get("object") == "text_completion"
ok_text = bool(choices) and isinstance(choices[0].get("text"), str)
ok_usage = int((payload.get("usage") or {}).get("prompt_tokens") or 0) > 0
print("response=http status=%s model_echoed=%s object=%s choices=%d text=%s prompt_tokens_counted=%s"
      % (status, "yes" if ok_model else "no", "yes" if ok_object else "no",
         len(choices), "yes" if ok_text else "no", "yes" if ok_usage else "no"))
PY

trap probe_cleanup EXIT
set +e
RESPONSE_REPORT="$(python3 "${PROBE_PY}" "http://127.0.0.1:${FWD_PORT}" "${MODEL}" "${REQ_TAG}" 2>/dev/null)"
set -e
rm -f "${PROBE_PY}"
trap stop_forward EXIT

case "${RESPONSE_REPORT:-}" in
  "response=http status=200 model_echoed=yes object=yes choices=1 text=yes prompt_tokens_counted=yes") : ;;
  *)
    echo "FAIL: the request through the router did not return a well-formed completion." >&2
    echo "      Report: '${RESPONSE_REPORT:-<no output>}'" >&2
    echo "      The request was sent to the ROUTER'S data-plane Service, deliberately — a" >&2
    echo "      request sent straight to a simulator would return 200 and prove nothing" >&2
    echo "      about the routing path." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/sim-router-envoy" >&2
    echo "               kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/sim-router-epp" >&2
    exit 1
    ;;
esac
stop_forward
trap - EXIT

# --- 6. the ROUTER'S OWN STATE shows it chose an endpoint --------------------
# Read from the data plane's access log, which carries both halves: the
# ENDPOINT PICKER'S OWN DECISION, published by the picker into the data plane's
# dynamic metadata, and the upstream the data plane actually CONNECTED to.
# Either alone is weak — a decision nothing acted on is not routing, and a
# connection with no decision behind it is the data plane load-balancing on its
# own — so the assertion is that both are present and EQUAL.
#
# WHERE THE PICKER'S DECISION IS READ FROM, and a correction measured here. The
# obvious field to read is the destination REQUEST HEADER the picker sets, and
# the access-log format carries it. It is ALWAYS `-`: the data plane's request-
# header log operator reflects the headers as RECEIVED FROM THE DOWNSTREAM
# CLIENT, and the picker's header is a mutation applied to the UPSTREAM request,
# so it is never visible there. Asserting on it would have failed every run for
# a reason that has nothing to do with routing. The picker's decision IS in the
# log, in the dynamic metadata the picker publishes — which also carries its
# per-endpoint scores, so the same field shows that it considered the whole
# fleet rather than one endpoint.
#
# The log flushes on an interval, so it is read after that interval.
sleep "${LOG_FLUSH_WAIT}"
LOG_LINE="$(kcn logs deploy/sim-router-envoy --tail=400 2>/dev/null \
  | /usr/bin/grep -F "tag=${REQ_TAG}" | tail -1 || true)"
if [ -z "${LOG_LINE}" ]; then
  echo "FAIL: the router's data-plane access log carries no line for this request's tag '${REQ_TAG}'." >&2
  echo "      Without it the endpoint choice cannot be read, and a 200 alone does not show" >&2
  echo "      that the picker chose anything." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/sim-router-envoy --tail=50" >&2
  exit 1
fi
CHOSEN="$(printf '%s' "${LOG_LINE}" | sed -n 's/.* chosen=\([^ ]*\).*/\1/p')"
CODE="$(printf '%s' "${LOG_LINE}" | sed -n 's/.* code=\([^ ]*\).*/\1/p')"
SCORES_JSON="$(printf '%s' "${LOG_LINE}" | sed -n 's/.* scores=\(.*\) dur=.*/\1/p')"
PICKED="$(printf '%s' "${SCORES_JSON}" \
  | jq -r '.["x-gateway-destination-endpoint"] // empty' 2>/dev/null || true)"
SCORED_ENDPOINTS="$(printf '%s' "${SCORES_JSON}" \
  | jq -r '(.["x-gateway-destination-endpoint-scores"] // {}) | length' 2>/dev/null || true)"
SCORED_ENDPOINTS="${SCORED_ENDPOINTS:-0}"
if [ -z "${CHOSEN}" ] || [ "${CHOSEN}" = "-" ] || [ -z "${PICKED}" ]; then
  echo "FAIL: the access-log line for '${REQ_TAG}' shows picker-decision='${PICKED:-<none>}' and connected-upstream='${CHOSEN:-<none>}'." >&2
  echo "      A decision nothing acted on is not routing; a connection with no decision" >&2
  echo "      behind it is the data plane load-balancing on its own. Neither is the router" >&2
  echo "      choosing an endpoint." >&2
  echo "      Line: ${LOG_LINE}" >&2
  exit 1
fi
if [ "${CHOSEN}" != "${PICKED}" ]; then
  echo "FAIL: the endpoint picker decided '${PICKED}' and the data plane connected to '${CHOSEN}'." >&2
  echo "      They must be the same endpoint: the data plane resolves its upstream FROM the" >&2
  echo "      picker's decision, so a disagreement means the request did not go where the" >&2
  echo "      router said." >&2
  echo "      Line: ${LOG_LINE}" >&2
  exit 1
fi
if [ "${SCORED_ENDPOINTS}" -lt 2 ]; then
  echo "FAIL: the picker published scores for ${SCORED_ENDPOINTS} endpoint(s)." >&2
  echo "      A picker that scored one endpoint had nothing to choose between, so the" >&2
  echo "      agreement above would hold whether it worked or not." >&2
  echo "      Line: ${LOG_LINE}" >&2
  exit 1
fi

OVERRIDE_NOTE=""
if [ "${OVERRIDE_ACTIVE}" = "1" ]; then
  OVERRIDE_NOTE=" under the AUTHOR-ONLY SERVING_OVER_BUDGET override at SIZE=${SIZE}, ${MEASURED_OVER_MB} MiB over this size's ${BUDGET_MB} MiB budget"
fi

echo "OK: addon-serving verified on '${CLUSTER_NAME}'${OVERRIDE_NOTE} — ${READY}/${TOTAL} layer workloads available across ${SIM_REPLICAS} simulator endpoint(s), and a well-formed completion READ FROM THE ROUTER (${RESPONSE_REPORT}, HTTP ${CODE:-200} in the data plane's own access log) on an endpoint the picker chose: the picker's own decision '${PICKED}' equals the upstream the data plane connected to '${CHOSEN}', and it published scores for ${SCORED_ENDPOINTS} endpoints."
echo "  the response was read from the ROUTER, not from a simulator — a request straight to a simulator returns 200 and says nothing about the routing path"
echo "  Standalone Mode: no gateway controller, no service mesh, no serverless layer, no inference-pool custom resource"
echo "  no prefix-cache routing claim is made from a repeated-prefix replay — residency saturates and the comparison then measures tie-breaking, measured three ways"
echo "  no performance number is asserted: the response is judged WELL-FORMED, never fast"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"

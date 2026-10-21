#!/usr/bin/env bash
# addon-ops — verify the operations layer on a running grid-core.
#
# READ-ONLY on the cluster's object set. It changes nothing: it reads three
# components' own state documents through port forwards it starts and kills.
#
# THE ORDER OF THE ASSERTIONS IS LOAD-BEARING, and it is the same rule the other
# four layers in this profile learned: a NON-ZERO COUNT is asserted before
# anything is asserted about the things counted. "Every workload is Available"
# over zero workloads is vacuously true, and "every scrape target is healthy"
# over zero targets is vacuously true twice over — a verify that reports clean
# over an un-applied layer is this phase's named failure mode.
#
# NO ASSERTION IN THIS LAYER IS MADE ON A POD PHASE, and for this layer that is
# not a style rule, it is the whole point. A metrics collector whose every
# scrape target is DOWN is Running, Ready, and its Deployment is Available. It
# has collected nothing. The Pod's phase cannot tell that state from a working
# install, so the health of the collection is read from the COLLECTOR'S OWN
# TARGET STATE, the dashboard's version from the DASHBOARD'S OWN health
# endpoint, and the cost tool's readiness from the COST TOOL'S OWN readiness
# endpoint.
#
# WHY THE DASHBOARD'S REPORTED MAJOR IS ASSERTED. The pinned major is a forward
# schema contract: dashboard JSON is schema-versioned against the major it was
# authored on, and the course generates dashboards in a later phase. The pin
# also OVERRIDES the chart's own appVersion — no published chart in that series
# ships the pinned major — so the chart-and-image pairing this layer installs is
# not one upstream tests. Reading the running instance's own version is what
# turns that pin from a line in a values file into something that fails HERE
# rather than in the phase whose dashboards stop rendering. PINS.md section 4.
#
# NO COST FIGURE IS ASSERTED, AND THE ABSENCE IS DELIBERATE RATHER THAN AN
# OMISSION. The cost tool runs with no cloud integration and no real pricing, so
# every rate it uses is a default standing in for a price nobody paid. A check
# that asserted a number would be a claim the course cannot support, which is
# exactly what its evidence standard exists to prevent. What this file asserts
# is that the tool answers its own readiness endpoint — which it only does after
# its startup query against the collector succeeds, so the readiness IS the
# "it found the collector" assertion rather than a second one beside it.
#
# NO PERFORMANCE NUMBER IS ASSERTED anywhere in this file or in checks.json: no
# latency, no scrape duration, no sample rate, no percentage, no cost.
#
# Usage:
#   bash verify.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   NAMESPACE        the layer's namespace (default grid-ops)
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: read-only on the object set.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
. "${ADDON_DIR}/ops-lib.sh"
assert_size

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-grid-ops}"
PINS="${ADDON_DIR}/PINS.md"

# The pinned dashboard MAJOR. Derived from the register rather than written
# here, so this script cannot become a second authority on the pin — the same
# reason the size gate is the only emitter of its skip token.
GRAFANA_MAJOR="$(sed -n 's/^\*\*Pinned: Grafana `\([0-9]\{1,\}\)\..*$/\1/p' "${PINS}" | sed -n '1,1p')"

LAYER_DEPLOYMENTS="prometheus-server grafana opencost"

FWD_PROM_PORT="${FWD_PROM_PORT:-19090}"
FWD_GRAFANA_PORT="${FWD_GRAFANA_PORT:-19300}"
FWD_OPENCOST_PORT="${FWD_OPENCOST_PORT:-19003}"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

trap 'fwd_stop; ops_probe_cleanup' EXIT

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

if ! kc wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' is Ready." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes; then ${BASE}" >&2
  exit 1
fi

for _tool in jq nc python3; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required — the workload count is read by folding JSON, and the" >&2
    echo "      three component states are read over port forwards." >&2
    echo "      Install it and re-run; this script changes nothing." >&2
    exit 1
  fi
done

if [ -z "${GRAFANA_MAJOR}" ]; then
  echo "FAIL: could not read the pinned dashboard major out of ${PINS}." >&2
  echo "      Section 4 of that file must carry a line of the exact form" >&2
  echo "        **Pinned: Grafana \`<version>\`.**" >&2
  echo "      The major is READ from the register rather than written here, so" >&2
  echo "      this script cannot become a second authority on the pin." >&2
  exit 1
fi

# --- 2. THE EMPTY GUARD, BEFORE ANYTHING ABOUT THE WORKLOADS ------------------
if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' does not exist — the layer is not applied to this cluster." >&2
  echo "      Apply it: ${APPLY}" >&2
  exit 1
fi

FOUND="$(kcn get deploy -o json 2>/dev/null \
  | jq -r '[.items[].metadata.name
            | select(. == "prometheus-server" or . == "grafana" or . == "opencost")]
           | length' 2>/dev/null || printf '0')"
if [ "${FOUND:-0}" -lt 1 ]; then
  echo "FAIL: zero layer workloads in namespace '${NAMESPACE}', so this layer verifies nothing." >&2
  echo "      This is asserted BEFORE anything about the workloads, because" >&2
  echo "      'every workload is Available' over zero workloads is vacuously true." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi

TOTAL=0
READY=0
for _d in ${LAYER_DEPLOYMENTS}; do
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

# --- 3. the COLLECTOR'S OWN TARGET STATE, count first -------------------------
if ! fwd_start "${CONTEXT}" "${NAMESPACE}" "svc/prometheus-server" 80 "${FWD_PROM_PORT}"; then
  echo "FAIL: could not forward to the metrics collector's Service." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get svc prometheus-server -o yaml" >&2
  exit 1
fi
TARGET_REPORT="$(ops_probe targets "http://127.0.0.1:${FWD_PORT}")"
fwd_stop

case "${TARGET_REPORT}" in
  "reachable=yes "*) : ;;
  *)
    echo "FAIL: the metrics collector did not answer its own target endpoint." >&2
    echo "      probe: ${TARGET_REPORT:-<no output>}" >&2
    echo "      The Deployment being Available says a container started. It does" >&2
    echo "      not say the collector is serving, which is why this is read from" >&2
    echo "      the collector rather than from Kubernetes." >&2
    exit 1
    ;;
esac

TARGETS_TOTAL="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*targets_total=\([0-9]\{1,\}\).*/\1/p')"
TARGETS_UP="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*targets_up=\([0-9]\{1,\}\).*/\1/p')"
TARGET_JOBS="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*jobs=\([^ ]*\).*/\1/p')"
TARGET_NOT_UP="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*not_up=\([^ ]*\).*/\1/p')"

if [ "${TARGETS_TOTAL:-0}" -lt 1 ]; then
  echo "FAIL: the collector reports ${TARGETS_TOTAL:-0} active scrape targets." >&2
  echo "      probe: ${TARGET_REPORT}" >&2
  echo "      This is asserted BEFORE target health, because 'at least one target" >&2
  echo "      is healthy' over zero targets is vacuously false in a way that reads" >&2
  echo "      like a scrape failure, and the real fault is a scrape configuration" >&2
  echo "      with no jobs in it at all." >&2
  echo "      The configuration is the serverFiles section of values.yaml, which" >&2
  echo "      REPLACES the chart's default rather than extending it." >&2
  exit 1
fi
if [ "${TARGETS_UP:-0}" -lt 1 ]; then
  echo "FAIL: ${TARGETS_UP:-0} of ${TARGETS_TOTAL} scrape targets report healthy." >&2
  echo "      probe: ${TARGET_REPORT}" >&2
  echo "      A collector whose every target is down is Running, Ready and" >&2
  echo "      Available and has collected nothing." >&2
  echo "      Inspect the collector's own view, which is where this was read:" >&2
  echo "        kubectl --context ${CONTEXT} -n ${NAMESPACE} port-forward svc/prometheus-server 9090:80" >&2
  echo "        then open /api/v1/targets" >&2
  exit 1
fi

# --- 4. the DASHBOARD'S OWN health endpoint, and the pinned major -------------
if ! fwd_start "${CONTEXT}" "${NAMESPACE}" "svc/grafana" 80 "${FWD_GRAFANA_PORT}"; then
  echo "FAIL: could not forward to the dashboard Service." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get svc grafana -o yaml" >&2
  exit 1
fi
GRAFANA_REPORT="$(ops_probe grafana-health "http://127.0.0.1:${FWD_PORT}")"
fwd_stop

case "${GRAFANA_REPORT}" in
  "reachable=yes status=200 database=ok "*) : ;;
  *)
    echo "FAIL: the dashboard did not answer its own health endpoint with a healthy database." >&2
    echo "      probe: ${GRAFANA_REPORT:-<no output>}" >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/grafana" >&2
    exit 1
    ;;
esac
GRAFANA_REPORTED_MAJOR="$(printf '%s' "${GRAFANA_REPORT}" | sed -n 's/.*major=\([0-9]\{1,\}\).*/\1/p')"
GRAFANA_REPORTED_VERSION="$(printf '%s' "${GRAFANA_REPORT}" | sed -n 's/.*version=\([^ ]*\).*/\1/p')"
if [ "${GRAFANA_REPORTED_MAJOR:-}" != "${GRAFANA_MAJOR}" ]; then
  echo "FAIL: the dashboard reports version '${GRAFANA_REPORTED_VERSION:-<none>}' (major ${GRAFANA_REPORTED_MAJOR:-<none>})," >&2
  echo "      and PINS.md pins major ${GRAFANA_MAJOR}." >&2
  echo "      That pin is a FORWARD SCHEMA CONTRACT, not a version preference:" >&2
  echo "      the dashboards a later phase generates are schema-versioned against" >&2
  echo "      the major they were authored on, so a silent drift here would be" >&2
  echo "      discovered as dashboards that fail to render, in a different phase," >&2
  echo "      by somebody who did not change this." >&2
  echo "      Note that this layer OVERRIDES its chart's own appVersion to reach" >&2
  echo "      the pinned major — see PINS.md section 4 — so the most likely cause" >&2
  echo "      is image.tag/image.sha in values.yaml drifting from the register." >&2
  exit 1
fi

# --- 5. the COST TOOL'S OWN readiness endpoint, and NO cost figure ------------
if ! fwd_start "${CONTEXT}" "${NAMESPACE}" "svc/opencost" 9003 "${FWD_OPENCOST_PORT}"; then
  echo "FAIL: could not forward to the cost tool's Service." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get svc opencost -o yaml" >&2
  exit 1
fi
OPENCOST_REPORT="$(ops_probe opencost-health "http://127.0.0.1:${FWD_PORT}")"
fwd_stop
trap 'ops_probe_cleanup' EXIT

case "${OPENCOST_REPORT}" in
  "reachable=yes status=200") : ;;
  *)
    echo "FAIL: the cost tool did not answer its own readiness endpoint." >&2
    echo "      probe: ${OPENCOST_REPORT:-<no output>}" >&2
    echo "      It blocks at startup until its query against the metrics collector" >&2
    echo "      succeeds, so a collector that is not serving shows up here as the" >&2
    echo "      cost tool never becoming ready." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/opencost" >&2
    exit 1
    ;;
esac

NOT_UP_NOTE=""
if [ -n "${TARGET_NOT_UP:-}" ] && [ "${TARGET_NOT_UP}" != "-" ]; then
  NOT_UP_NOTE="; unhealthy jobs: ${TARGET_NOT_UP}"
fi

echo "OK: addon-ops verified on '${CLUSTER_NAME}' — ${READY}/${TOTAL} layer workloads available in '${NAMESPACE}', the collector reports ${TARGETS_UP} of ${TARGETS_TOTAL} scrape targets healthy from its OWN target state (jobs: ${TARGET_JOBS}${NOT_UP_NOTE}), the dashboard answers its own health endpoint reporting version ${GRAFANA_REPORTED_VERSION} against the pinned major ${GRAFANA_MAJOR}, and the cost tool answers its own readiness endpoint."
echo "  nothing here was read from a Pod phase: a collector whose every target is down is Running, Ready and Available and has collected nothing"
echo "  the cost tool's readiness IS the 'it found the collector' assertion — it blocks at startup until its query against the collector succeeds"
echo "  NO COST FIGURE is asserted: with no cloud integration and no real pricing, any number it computes is arithmetic over a fabricated rate"
echo "  no performance number is asserted anywhere in this layer — no latency, no scrape duration, no sample rate, no percentage"
echo "  the dashboard major is a FORWARD SCHEMA CONTRACT and it overrides the chart's own appVersion — PINS.md section 4"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"

#!/usr/bin/env bash
# addon-dra — the KEP-4680 device-health probe.
#
# It creates ONE claiming Pod, drives ONE health transition in each direction,
# asserts both from OBJECT STATE, and removes everything it made.
#
# WHERE THE SIGNAL IS READ, and why it is not a metric. KEP-4680 device health is
# not a Prometheus series this layer scrapes — it is a field the kubelet writes
# onto the claiming Pod:
#
#   pod.status.containerStatuses[].allocatedResourcesStatus[].resources[].health
#
# so the assertion is object state. `ResourceHealthStatus` and
# `ResourceHealthStatusMessage` are beta and ENABLED BY DEFAULT from Kubernetes
# 1.36, so this needs no extra feature gate on top of the three grid-core
# already sets.
#
# NOTHING HERE ASSERTS A POD PHASE. A Running phase proves nothing about whether
# a device was allocated or whether it is healthy. The waits below are waits for
# the FIELDS to appear — the claim's `.status.allocation`, then the container's
# `allocatedResourcesStatus` — never for a phase, and the Phase-1 precedent is
# explicit about why: SPIKE-04's negative control has no pods at all to have a
# phase.
#
# ───────────────────────────────────────────────────────────────────────────────
# DEMO ONLY — quoted from upstream rather than paraphrased, because the course
# states what the tool states
# (dra-example-driver v0.5.0 demo/examples/health-reporting/health-reporting.yaml:23-27):
#
#   > DEMO ONLY: the `health.example.com/<device>` annotation override exists
#   > solely to make this example driver's health reporting easy to exercise by
#   > hand. It lets anyone who can annotate the driver pod declare any device
#   > healthy/unhealthy/unknown, which is a health-control capability. A real
#   > driver MUST derive health from actual device telemetry and must NOT ship an
#   > annotation-driven override.
#
# That is this probe's own threat statement (T-03-08, accepted with its
# disclosure rather than mitigated away: removing the override would mean forking
# the driver, and the override is the only way to exercise the real health path
# by hand). It is also M4's lesson material. This probe is never to be presented
# as a production pattern.
# ───────────────────────────────────────────────────────────────────────────────
#
# THE ANNOTATION PREFIX IS NOT THIS COURSE'S DRIVER NAME. It is the fixed string
# `health.example.com/`, hardcoded in the driver at
# `cmd/dra-example-kubeletplugin/driver.go:305`. Renaming the driver to
# `sim-accelerator.example.com` does NOT rename this prefix, and the two look
# like they should match. They do not.
#
# SUPPORTED VALUES ARE EXACTLY `healthy`, `unhealthy`, `unknown`, lower-cased and
# trimmed. Anything else is IGNORED WITH A LOG LINE and the device returns to
# simulation (`driver.go:419-436`) — so a typo produces a probe that reports no
# transition and no error, which reads as a clean run that asserted nothing. The
# value is therefore validated against the three before it is sent.
#
# THE DEVICE IS DERIVED, NEVER NAMED. The chain, in this order, each step reading
# the previous step's output:
#   1. the node the claiming Pod landed on          .spec.nodeName
#   2. the claim the Pod's request resolved to      .status.resourceClaimStatuses[]
#   3. THE DEVICE, from the claim's own allocation  .status.allocation.devices.results[0].device
#   4. the driver pod ON THAT NODE                  label + --field-selector spec.nodeName
# Upstream's own example is careful about step 3 and says why — it reads "the
# device actually allocated to its claim (not necessarily the first one)". A
# hardcoded device name is a probe that passes where the allocation happened to
# match and silently measures nothing where it did not. Step 4 matters for the
# same class of reason: there is one driver pod per node and the annotation only
# affects devices on its own node, so selecting by label alone would annotate the
# wrong pod on any multi-worker cluster — which is exactly what the larger
# machine size is.
#
# WHAT IT ASSERTS AND WHAT IT CANNOT. `allocatedResourcesStatus[].resources[]`
# carries a `resourceID` that names the DRIVER but NOT the device
# (`k8s.<driverName>/gpu=common`, measured on this host). The device name appears
# in the entry's `message`. So the health reading is tied to the derived device by
# asserting the message names it, rather than by a resourceID match that the API
# does not offer.
#
# The devices are SYNTHETIC. The driver's own device names, its model string and
# its 80Gi `memory` capacity are Go constants in its source and are not readings
# of anything — STANDARDS.md C15 requires a caption wherever that text reaches a
# page, and this probe's output contains it.
#
# Usage:
#   bash health-probe.sh            # the full probe: unhealthy, then back to healthy
#   bash health-probe.sh steady     # steady state only: assert the device reports Healthy
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Prerequisite: the DRA layer is applied and verified —
#   bash labs/clusters/grid-core/addons/dra/create.sh
#   bash labs/clusters/grid-core/addons/dra/verify.sh
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: it removes its own namespace and its own annotation on the way out,
# on success and on failure, so a re-run starts from the same state.
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
assert_kubectl_version

MODE="${1:-full}"
case "${MODE}" in
  full|steady) : ;;
  *)
    echo "FAIL: unknown mode '${MODE}'. Usage: bash health-probe.sh [steady]" >&2
    exit 2
    ;;
esac

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

DRIVER_NS="${NAMESPACE:-dra-example-driver}"
RELEASE="${RELEASE:-dra-example-driver}"
DAEMONSET="${RELEASE}-kubeletplugin"

# Names this probe owns. Pitfall 1's rule: wherever the lab controls a name it
# relabels it. The namespace, the template, the request and the Pod are all the
# lab's, so none of them carries a device-vendor word.
PROBE_NS="${PROBE_NS:-sim-device-health}"
CLAIM_TEMPLATE="single-sim-device"
REQUEST_NAME="device"
PROBE_POD="claimant"

# The holder container. `registry.k8s.io/pause` is used rather than upstream
# example's ubuntu image for two reasons: it is 262 KiB against ~30 MiB, and it
# is ALREADY PRELOADED on a kind v1.37 node, so this probe pulls nothing. Pinned
# by its manifest-list INDEX digest, per PLAT-01 — resolved on this host with
#   docker exec grid-core-worker ctr -n k8s.io images ls | grep pause
# which reported linux/amd64,linux/arm/v7,linux/arm64,linux/ppc64le,linux/s390x.
# The container needs no shell: it only has to exist and hold the claim, because
# the health field is written by the kubelet and not by anything in the image.
HOLDER_IMAGE="${HOLDER_IMAGE:-registry.k8s.io/pause@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a}"

ALLOC_TIMEOUT="${ALLOC_TIMEOUT:-180}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

# The two values this probe sends, overridable ONLY so the validation below can
# be exercised: `DOWN_VALUE=broken bash health-probe.sh` must FAIL before it
# creates anything. A validation that no command can reach is untested code, and
# the failure it guards against — a value the driver silently ignores — is one
# that produces a clean-looking run which asserted nothing.
WANT_DOWN="${DOWN_VALUE:-unhealthy}"
WANT_UP="${UP_VALUE:-healthy}"

APPLY="bash ${ADDON_DIR}/create.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

VALUES_FILE="${ADDON_DIR}/values.yaml"
DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" 2>/dev/null | head -1 || true)"
if [ -z "${DRIVER_NAME}" ]; then
  echo "FAIL: could not read driverName out of ${VALUES_FILE}." >&2
  exit 1
fi

# --- the three values the driver accepts, validated BEFORE anything is sent ----
# driver.go:419-436 lower-cases and trims, then switches on exactly these three
# and IGNORES anything else with a log line. An ignored value leaves the device
# in simulation, so the probe would see no transition and no error.
assert_health_value() {
  case "$1" in
    healthy|unhealthy|unknown) return 0 ;;
    *)
      echo "FAIL: '$1' is not a health override value the driver accepts." >&2
      echo "      Supported values are exactly: healthy, unhealthy, unknown" >&2
      echo "      (cmd/dra-example-kubeletplugin/driver.go:419-436). Anything else is" >&2
      echo "      IGNORED with a log line and the device returns to simulation — so sending" >&2
      echo "      it would produce a probe that reports no transition and no error." >&2
      exit 1
      ;;
  esac
}

# --- preflight ----------------------------------------------------------------
# Both values are validated HERE, before a namespace or a Pod exists, so a typo
# costs nothing. They are re-validated immediately before each annotate below, so
# the "checked before it is sent" guarantee holds at the point of sending too.
assert_health_value "${WANT_DOWN}"
assert_health_value "${WANT_UP}"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to read allocatedResourcesStatus, which is a nested list." >&2
  echo "      Install it (brew install jq) and re-run; nothing has been created." >&2
  exit 1
fi

# Captured and matched with `case`, never a pipe into a quiet grep under `pipefail`.
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found." >&2
    echo "      Run: bash ${PROFILE_DIR}/create.sh && ${APPLY}" >&2
    exit 1
    ;;
esac

if ! kc -n "${DRIVER_NS}" get "ds/${DAEMONSET}" >/dev/null 2>&1; then
  echo "FAIL: DaemonSet ${DRIVER_NS}/${DAEMONSET} not found — the DRA layer is not applied." >&2
  echo "      Apply it: ${APPLY}" >&2
  exit 1
fi

if ! kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" >/dev/null 2>&1; then
  echo "FAIL: no DeviceClass named '${DRIVER_NAME}' — the claim below would stay Pending forever." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi

DEVICE_HEALTH_ENV="$(kc -n "${DRIVER_NS}" get "ds/${DAEMONSET}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DEVICE_HEALTH")].value}' 2>/dev/null || true)"
case "${DEVICE_HEALTH_ENV}" in
  true|True|TRUE) : ;;
  *)
    echo "FAIL: the driver's DEVICE_HEALTH env is '${DEVICE_HEALTH_ENV:-<unset>}', not true." >&2
    echo "      With health reporting off the driver advertises no health service and" >&2
    echo "      WatchHealthStatus returns ErrHealthNotSupported, so there is nothing to probe." >&2
    echo "      values.yaml sets kubeletPlugin.deviceHealth: true for this reason; re-apply: ${APPLY}" >&2
    exit 1
    ;;
esac

# --- cleanup, registered before anything is created ---------------------------
# Removes the probe's namespace (which takes the Pod and its ResourceClaim with
# it) and its own annotation on the driver pod, on success AND on failure. A
# probe that leaves a device pinned unhealthy would poison the next layer's
# verify, and a probe that leaves a claiming Pod behind holds a device allocated.
# The namespace delete is BOUNDED: this runs inside the EXIT trap, and an
# unbounded `--wait=true` on a Pod whose finalizer never clears would hang here
# and mask whatever failure triggered the trap.
CLEANED=0
cleanup() {
  if [ "${CLEANED}" -eq 1 ]; then return 0; fi
  CLEANED=1
  if [ -n "${DRIVER_POD:-}" ] && [ -n "${DEVICE:-}" ]; then
    kc annotate -n "${DRIVER_NS}" "${DRIVER_POD}" "health.example.com/${DEVICE}-" >/dev/null 2>&1 || true
  fi
  kc delete namespace "${PROBE_NS}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A previous interrupted run could have left the namespace behind. Terminating is
# the case that matters: an apply into a Terminating namespace exits 0 and
# creates nothing.
PROBE_NS_PHASE="$(kc get namespace "${PROBE_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ -n "${PROBE_NS_PHASE}" ]; then
  echo "==> namespace '${PROBE_NS}' is left over (phase ${PROBE_NS_PHASE}); removing it first" >&2
  kc delete namespace "${PROBE_NS}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  _w=0
  while [ "${_w}" -lt 120 ]; do
    if ! kc get namespace "${PROBE_NS}" >/dev/null 2>&1; then break; fi
    sleep 2
    _w=$((_w + 2))
  done
  if kc get namespace "${PROBE_NS}" >/dev/null 2>&1; then
    echo "FAIL: namespace '${PROBE_NS}' is still present after ${_w}s; refusing to apply into it." >&2
    exit 1
  fi
fi

# --- one claiming Pod ---------------------------------------------------------
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${PROBE_NS}
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  namespace: ${PROBE_NS}
  name: ${CLAIM_TEMPLATE}
spec:
  spec:
    devices:
      requests:
      - name: ${REQUEST_NAME}
        exactly:
          deviceClassName: ${DRIVER_NAME}
---
apiVersion: v1
kind: Pod
metadata:
  namespace: ${PROBE_NS}
  name: ${PROBE_POD}
spec:
  restartPolicy: Never
  containers:
  - name: holder
    image: ${HOLDER_IMAGE}
    resources:
      claims:
      - name: ${REQUEST_NAME}
  resourceClaims:
  - name: ${REQUEST_NAME}
    resourceClaimTemplateName: ${CLAIM_TEMPLATE}
EOF

# --- the derivation chain -----------------------------------------------------
# 1. the node, read from the Pod the scheduler placed.
NODE=""
_w=0
while [ "${_w}" -lt "${ALLOC_TIMEOUT}" ]; do
  NODE="$(kc -n "${PROBE_NS}" get pod "${PROBE_POD}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [ -n "${NODE}" ]; then break; fi
  sleep 3
  _w=$((_w + 3))
done
if [ -z "${NODE}" ]; then
  echo "FAIL: Pod ${PROBE_NS}/${PROBE_POD} was not scheduled onto a node within ${_w}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${PROBE_NS} describe pod ${PROBE_POD}" >&2
  exit 1
fi

# 2. the claim the Pod's request resolved to — the generated name, not a guess.
CLAIM=""
_w=0
while [ "${_w}" -lt "${ALLOC_TIMEOUT}" ]; do
  CLAIM="$(kc -n "${PROBE_NS}" get pod "${PROBE_POD}" \
    -o jsonpath="{.status.resourceClaimStatuses[?(@.name=='${REQUEST_NAME}')].resourceClaimName}" 2>/dev/null || true)"
  if [ -n "${CLAIM}" ]; then break; fi
  sleep 3
  _w=$((_w + 3))
done
if [ -z "${CLAIM}" ]; then
  echo "FAIL: no ResourceClaim name on the Pod's .status.resourceClaimStatuses after ${_w}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${PROBE_NS} get pod ${PROBE_POD} -o yaml" >&2
  exit 1
fi

# 3. THE DEVICE, from the claim's own allocation result. Never hardcoded.
DEVICE=""
_w=0
while [ "${_w}" -lt "${ALLOC_TIMEOUT}" ]; do
  DEVICE="$(kc -n "${PROBE_NS}" get resourceclaim "${CLAIM}" \
    -o jsonpath='{.status.allocation.devices.results[0].device}' 2>/dev/null || true)"
  if [ -n "${DEVICE}" ]; then break; fi
  sleep 3
  _w=$((_w + 3))
done
if [ -z "${DEVICE}" ]; then
  echo "FAIL: ResourceClaim ${PROBE_NS}/${CLAIM} has no .status.allocation.devices.results[0].device after ${_w}s." >&2
  echo "      A claim with no allocation means the DeviceClass matched no device." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${PROBE_NS} get resourceclaim ${CLAIM} -o yaml" >&2
  exit 1
fi

ALLOC_DRIVER="$(kc -n "${PROBE_NS}" get resourceclaim "${CLAIM}" \
  -o jsonpath='{.status.allocation.devices.results[0].driver}' 2>/dev/null || true)"
ALLOC_POOL="$(kc -n "${PROBE_NS}" get resourceclaim "${CLAIM}" \
  -o jsonpath='{.status.allocation.devices.results[0].pool}' 2>/dev/null || true)"

# 4. the driver pod ON THAT NODE. The field selector is what makes this correct
#    on a multi-worker cluster: the annotation only affects devices on its own
#    node, so a label-only selection would annotate the wrong pod.
DRIVER_POD="$(kc -n "${DRIVER_NS}" get pod \
  -l app.kubernetes.io/component=kubeletplugin \
  --field-selector "spec.nodeName=${NODE}" -o name 2>/dev/null | head -1 || true)"
if [ -z "${DRIVER_POD}" ]; then
  echo "FAIL: no kubelet-plugin pod on node '${NODE}'." >&2
  echo "      The claiming Pod landed on a node whose driver pod is missing, so the" >&2
  echo "      health override has nowhere to be set." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${DRIVER_NS} get pods -o wide" >&2
  exit 1
fi

echo "derivation: node=${NODE}  claim=${CLAIM}  device=${DEVICE}  driver=${ALLOC_DRIVER}  pool=${ALLOC_POOL}  driver-pod=${DRIVER_POD}"
echo "  (the device was DERIVED from the claim's own allocation result; the device name,"
echo "   the model string and the 80Gi capacity in this layer's output are SYNTHETIC)"

# --- reading the health field -------------------------------------------------
# The entry is selected by the REQUEST name — `claim:<request>` — because the
# API's resourceID names the driver and not the device
# (`k8s.<driverName>/gpu=common`, measured). The device is tied to the reading by
# asserting the message names it, below.
read_health() {
  kc -n "${PROBE_NS}" get pod "${PROBE_POD}" -o json 2>/dev/null \
    | jq -r --arg n "claim:${REQUEST_NAME}" '
        [ .status.containerStatuses[]?.allocatedResourcesStatus[]?
          | select(.name == $n) | .resources[]? ]
        | if length == 0 then "" else (.[0].health // "") end' 2>/dev/null || true
}
read_health_message() {
  kc -n "${PROBE_NS}" get pod "${PROBE_POD}" -o json 2>/dev/null \
    | jq -r --arg n "claim:${REQUEST_NAME}" '
        [ .status.containerStatuses[]?.allocatedResourcesStatus[]?
          | select(.name == $n) | .resources[]? ]
        | if length == 0 then "" else (.[0].message // "") end' 2>/dev/null || true
}
dump_health() {
  kc -n "${PROBE_NS}" get pod "${PROBE_POD}" -o json 2>/dev/null \
    | jq '[ .status.containerStatuses[]?.allocatedResourcesStatus[]? ]'
}

# Poll until the field reports $1, or fail naming what it reported instead. An
# explicit timeout and a named failure, never a bare sleep.
await_health() {
  local want="$1" label="$2" got="" waited=0
  while [ "${waited}" -lt "${HEALTH_TIMEOUT}" ]; do
    got="$(read_health)"
    if [ "${got}" = "${want}" ]; then
      echo "  ${label}: allocatedResourcesStatus reports health=${got} after ${waited}s"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "FAIL: ${label}: allocatedResourcesStatus reports health='${got:-<absent>}' after ${waited}s; expected '${want}'." >&2
  echo "      A health override value the driver does not recognise is IGNORED with a log" >&2
  echo "      line and the device returns to simulation, so a device that stays Healthy" >&2
  echo "      after an 'unhealthy' annotation is the signature of a value that never landed." >&2
  echo "      Driver log: kubectl --context ${CONTEXT} -n ${DRIVER_NS} logs ${DRIVER_POD} --tail=40" >&2
  dump_health >&2 || true
  exit 1
}

# The health field must exist at all before any transition is driven.
_w=0
FIRST_HEALTH=""
while [ "${_w}" -lt "${ALLOC_TIMEOUT}" ]; do
  FIRST_HEALTH="$(read_health)"
  if [ -n "${FIRST_HEALTH}" ]; then break; fi
  sleep 3
  _w=$((_w + 3))
done
if [ -z "${FIRST_HEALTH}" ]; then
  echo "FAIL: the claiming Pod has no allocatedResourcesStatus entry named 'claim:${REQUEST_NAME}' after ${_w}s." >&2
  echo "      That field is written by the kubelet from the driver's health stream;" >&2
  echo "      ResourceHealthStatus is beta and default-on from Kubernetes 1.36, so its" >&2
  echo "      absence points at the driver's health service rather than at a cluster gate." >&2
  echo "      Driver log: kubectl --context ${CONTEXT} -n ${DRIVER_NS} logs ${DRIVER_POD} --tail=40" >&2
  exit 1
fi

if [ "${MODE}" = "steady" ]; then
  if [ "${FIRST_HEALTH}" != "Healthy" ]; then
    echo "FAIL: in the steady state the derived device reports health='${FIRST_HEALTH}', not 'Healthy'." >&2
    echo "      values.yaml sets simulateHealthChanges: false, so a device changes state only" >&2
    echo "      when something changes it. A non-Healthy steady state means an override from an" >&2
    echo "      earlier run was left on the driver pod." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${DRIVER_NS} get ${DRIVER_POD} -o jsonpath='{.metadata.annotations}'" >&2
    exit 1
  fi
  STEADY_MESSAGE="$(read_health_message)"
  case "${STEADY_MESSAGE}" in
    *"${DEVICE}"*) : ;;
    *)
      echo "FAIL: the health message '${STEADY_MESSAGE}' does not name the derived device '${DEVICE}'," >&2
      echo "      so the reading cannot be tied to the device this probe derived." >&2
      exit 1
      ;;
  esac
  echo "steady state, read from object state:"
  dump_health
  echo
  echo "OK: the derived device '${DEVICE}' on node '${NODE}' reports health=Healthy at pod.status.containerStatuses[].allocatedResourcesStatus, with the driver's own message naming it — read as object state, never as a Pod phase."
  exit 0
fi

# --- transition 1: healthy -> unhealthy ---------------------------------------
assert_health_value "${WANT_DOWN}"
echo
echo "transition 1 — forcing '${WANT_DOWN}' via the DEMO-ONLY annotation override on ${DRIVER_POD}"
echo "  prefix 'health.example.com/' is fixed by the driver (driver.go:305) and is NOT this course's driverName"
kc annotate -n "${DRIVER_NS}" "${DRIVER_POD}" "health.example.com/${DEVICE}=${WANT_DOWN}" --overwrite
await_health "Unhealthy" "after '${WANT_DOWN}'"
DOWN_DUMP="$(dump_health)"
DOWN_MESSAGE="$(read_health_message)"
printf '%s\n' "${DOWN_DUMP}"
case "${DOWN_MESSAGE}" in
  *"${DEVICE}"*) : ;;
  *)
    echo "FAIL: the unhealthy message '${DOWN_MESSAGE}' does not name the derived device '${DEVICE}'." >&2
    exit 1
    ;;
esac

# --- transition 2: unhealthy -> healthy ---------------------------------------
# A ONE-WAY probe cannot tell a real signal from a device that was unhealthy all
# along, so the return transition is asserted too.
assert_health_value "${WANT_UP}"
echo
echo "transition 2 — returning to '${WANT_UP}', because a one-way probe cannot distinguish a real"
echo "  signal from a device that was unhealthy from the start"
kc annotate -n "${DRIVER_NS}" "${DRIVER_POD}" "health.example.com/${DEVICE}=${WANT_UP}" --overwrite
await_health "Healthy" "after '${WANT_UP}'"
UP_DUMP="$(dump_health)"
UP_MESSAGE="$(read_health_message)"
printf '%s\n' "${UP_DUMP}"
case "${UP_MESSAGE}" in
  *"${DEVICE}"*) : ;;
  *)
    echo "FAIL: the healthy message '${UP_MESSAGE}' does not name the derived device '${DEVICE}'." >&2
    exit 1
    ;;
esac

echo
echo "OK: a KEP-4680 health transition was driven in BOTH directions on the derived device '${DEVICE}' (node '${NODE}', pool '${ALLOC_POOL}', driver '${ALLOC_DRIVER}') and read both times from pod.status.containerStatuses[].allocatedResourcesStatus — Healthy -> Unhealthy -> Healthy, object state throughout, no Pod phase asserted, no feature gate beyond the cluster's defaults (ResourceHealthStatus is beta and default-on from Kubernetes 1.36)."
echo "  override: DEMO ONLY — it lets anyone who can annotate the driver pod declare any device healthy/unhealthy/unknown, which is a health-control capability. A real driver must derive health from device telemetry and must not ship an annotation-driven override."
echo "  the device name in this output is SYNTHETIC — it is a Go constant in the driver, not a device"

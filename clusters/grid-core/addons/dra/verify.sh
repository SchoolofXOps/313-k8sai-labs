#!/usr/bin/env bash
# addon-dra — verify the synthetic-device layer on a running grid-core.
#
# READ-ONLY. It changes nothing on the cluster and it asserts OBJECT STATE
# only: the driver name carried on every ResourceSlice, the DeviceClass's name,
# the text of its CEL selector, the per-slice device count, the published PCIe
# root attribute, and the digest the running pod actually resolved. No assertion
# anywhere in this file is about a Pod phase, and none is a performance number.
#
# THE ORDER OF THE ASSERTIONS IS LOAD-BEARING. The slice count is asserted
# NON-ZERO before anything is asserted about the slices' contents, because
# "every slice reports the right driver" over zero slices is VACUOUSLY TRUE and
# a verify that reports clean over an un-applied layer is this phase's named
# failure mode (T-03-10). The same empty-versus-empty guard
# scripts/standards/standards-selfref.mjs uses, for the same reason.
#
# Usage:
#   bash verify.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: read-only.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-dra-example-driver}"
RELEASE="${RELEASE:-dra-example-driver}"
DAEMONSET="${RELEASE}-kubeletplugin"

VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- 1. the base cluster ------------------------------------------------------
# Captured and matched with `case`, never a pipe into a quiet grep under `pipefail`.
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

# SIMULATED NODES EXCLUDED, for the reason create.sh records at the same line:
# the kueue-kwok layer's kwok fleet are non-control-plane Node objects, so the
# plain selector counted them as workers and the slice-per-worker comparison
# below then failed at 1 of 10 while the DaemonSet was correctly 1/1. Measured in
# plan 03-03's ordering predicate. `type!=kwok` also matches a node with no
# `type` label, so every real node is kept.
WORKERS="$(kc get nodes -l '!node-role.kubernetes.io/control-plane,type!=kwok' --no-headers 2>/dev/null | wc -l | tr -d ' ')"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required — the per-device assertions below aggregate across every" >&2
  echo "      slice and every device, which jsonpath cannot do." >&2
  echo "      Install it (brew install jq) and re-run; this script changes nothing." >&2
  exit 1
fi

for _f in "${VALUES_FILE}" "${RENDERED}"; do
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} not found — the layer's own artifacts are missing from the tree." >&2
    echo "      Apply the layer, which regenerates the rendered manifest: ${APPLY}" >&2
    exit 1
  fi
done

# Read from the committed artifacts, never repeated as literals here.
DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
EXPECTED_DEVICES="$(sed -n 's/^[[:space:]]\{1,\}numDevices:[[:space:]]*\([0-9]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
PINNED_IMAGE="$(sed -n 's|^[[:space:]]*image:[[:space:]]*\(registry.k8s.io/dra-example-driver/dra-example-driver@sha256:[0-9a-f]\{1,\}\).*$|\1|p' "${RENDERED}" | head -1)"
PINNED_DIGEST="${PINNED_IMAGE##*@}"
if [ -z "${DRIVER_NAME}" ] || [ -z "${EXPECTED_DEVICES}" ] || [ -z "${PINNED_DIGEST}" ]; then
  echo "FAIL: could not read the driver name and device count from ${VALUES_FILE}," >&2
  echo "      or a digest-pinned driver image from ${RENDERED}." >&2
  echo "      All three are read from the committed artifacts rather than hardcoded here." >&2
  exit 1
fi

# --- 2. the layer's DaemonSet -------------------------------------------------
if ! kc -n "${NAMESPACE}" get "ds/${DAEMONSET}" >/dev/null 2>&1; then
  echo "FAIL: DaemonSet ${NAMESPACE}/${DAEMONSET} not found — the layer is not applied to this cluster." >&2
  echo "      Apply it: ${APPLY}" >&2
  exit 1
fi

DS_DESIRED="$(kc -n "${NAMESPACE}" get "ds/${DAEMONSET}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
DS_READY="$(kc -n "${NAMESPACE}" get "ds/${DAEMONSET}" -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
DS_DESIRED="${DS_DESIRED:-0}"
DS_READY="${DS_READY:-0}"
if [ "${DS_DESIRED}" -lt 1 ] || [ "${DS_READY}" -ne "${DS_DESIRED}" ]; then
  echo "FAIL: DaemonSet ${DAEMONSET} reports ${DS_READY}/${DS_DESIRED} ready." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} describe ds/${DAEMONSET}" >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi

# --- 3. THE EMPTY GUARD: a non-zero slice count, before any content assertion -
SLICE_JSON="$(kc get resourceslices -o json 2>/dev/null || true)"
if [ -z "${SLICE_JSON}" ]; then
  echo "FAIL: could not read ResourceSlices from the cluster." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices" >&2
  exit 1
fi
SLICE_COUNT="$(printf '%s' "${SLICE_JSON}" | jq -r '.items | length')"
if [ "${SLICE_COUNT}" -lt 1 ]; then
  echo "FAIL: zero ResourceSlices on '${CLUSTER_NAME}', so this layer advertises no devices." >&2
  echo "      This is asserted BEFORE anything about the slices' contents, because" >&2
  echo "      'every slice reports the right driver' over zero slices is vacuously true." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi
if [ "${SLICE_COUNT}" -ne "${WORKERS}" ]; then
  echo "FAIL: ${SLICE_COUNT} ResourceSlice(s) but ${WORKERS} worker node(s) — one slice per node is expected." >&2
  echo "      The kubelet plugin is a DaemonSet and the control plane carries kind's NoSchedule" >&2
  echo "      taint, so a mismatch means a worker has no registered plugin." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get pods -o wide" >&2
  exit 1
fi

# --- 4. the driver name on EVERY slice ----------------------------------------
DRIVERS_SEEN="$(printf '%s' "${SLICE_JSON}" | jq -r '[.items[].spec.driver] | unique | join(",")')"
if [ "${DRIVERS_SEEN}" != "${DRIVER_NAME}" ]; then
  echo "FAIL: the distinct spec.driver values across ${SLICE_COUNT} ResourceSlice(s) are '${DRIVERS_SEEN}'," >&2
  echo "      not the single expected '${DRIVER_NAME}'." >&2
  echo "      That name is the whole of what this layer renames, and a chart rendered without" >&2
  echo "      the committed values.yaml would still roll out and still report Ready." >&2
  echo "      Re-apply from the committed values: ${APPLY}" >&2
  exit 1
fi

# --- 5. the DeviceClass and its CEL selector ----------------------------------
DC_NAME="$(kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ "${DC_NAME}" != "${DRIVER_NAME}" ]; then
  echo "FAIL: no DeviceClass named '${DRIVER_NAME}' on this cluster (got '${DC_NAME:-<none>}')." >&2
  echo "      The chart derives the DeviceClass name from the same driverName value, so the" >&2
  echo "      slice driver and this name cannot disagree unless two renders were mixed." >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi

DC_CEL="$(kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" \
            -o jsonpath='{.spec.selectors[0].cel.expression}' 2>/dev/null || true)"
case "${DC_CEL}" in
  *"${DRIVER_NAME}"*) : ;;
  *)
    echo "FAIL: the DeviceClass's CEL selector is '${DC_CEL:-<empty>}', which does not name '${DRIVER_NAME}'." >&2
    echo "      A DeviceClass whose selector names a different driver matches no device, and" >&2
    echo "      every claim against it stays Pending with no error on the claim." >&2
    exit 1
    ;;
esac

# --- 6. the per-slice device count --------------------------------------------
DEVICE_COUNTS="$(printf '%s' "${SLICE_JSON}" | jq -r '[.items[].spec.devices | length] | unique | join(",")')"
if [ "${DEVICE_COUNTS}" != "${EXPECTED_DEVICES}" ]; then
  echo "FAIL: the distinct per-slice device counts are '${DEVICE_COUNTS}', not the single expected '${EXPECTED_DEVICES}'." >&2
  echo "      The expected count is read from ${VALUES_FILE} (kubeletPlugin.numDevices)." >&2
  exit 1
fi
TOTAL_DEVICES="$(printf '%s' "${SLICE_JSON}" | jq -r '[.items[].spec.devices[]] | length')"
# The device-count assert above already forces this to be at least the configured
# count, so this is defence in depth rather than a second guard — but the next
# assertion compares two counts, and `0 -ne 0` is TRUE for the wrong reason. The
# empty-versus-empty property belongs to the assertion that depends on it.
if [ "${TOTAL_DEVICES}" -lt 1 ]; then
  echo "FAIL: zero devices across ${SLICE_COUNT} ResourceSlice(s)." >&2
  echo "      Asserted here rather than left to the attribute check below, because that" >&2
  echo "      check compares a published count against a total and 0 of 0 would satisfy it." >&2
  exit 1
fi

# --- 7. the PCIe root attribute on EVERY device -------------------------------
# Present and NON-EMPTY, never equal to one particular value: with pcieRoots
# left empty the driver assigns its two default roots round-robin by device
# index, so an even-indexed device and an odd-indexed device carry different
# strings by design.
WITH_PCIEROOT="$(printf '%s' "${SLICE_JSON}" | jq -r '
  [ .items[].spec.devices[].attributes["resource.kubernetes.io/pcieRoot"].string
    | select(. != null and . != "") ] | length')"
if [ "${WITH_PCIEROOT}" -ne "${TOTAL_DEVICES}" ]; then
  echo "FAIL: ${WITH_PCIEROOT} of ${TOTAL_DEVICES} devices publish a non-empty" >&2
  echo "      resource.kubernetes.io/pcieRoot attribute." >&2
  echo "      values.yaml sets gpuPublishPCIeRoot explicitly for this reason — the chart" >&2
  echo "      default is false and an earlier spike observed the attribute published anyway," >&2
  echo "      so the value is stated rather than relied on." >&2
  exit 1
fi
PCIEROOTS_SEEN="$(printf '%s' "${SLICE_JSON}" | jq -r '
  [ .items[].spec.devices[].attributes["resource.kubernetes.io/pcieRoot"].string ] | unique | join(",")')"

# --- 8. the digest the running pod resolved -----------------------------------
RUNNING_IMAGE_ID="$(kc -n "${NAMESPACE}" get pod -l app.kubernetes.io/component=kubeletplugin \
                      -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
case "${RUNNING_IMAGE_ID}" in
  *"${PINNED_DIGEST}"*) : ;;
  *)
    echo "FAIL: the running driver pod's imageID is '${RUNNING_IMAGE_ID:-<empty>}'," >&2
    echo "      which does not carry the digest pinned in ${RENDERED} (${PINNED_DIGEST})." >&2
    echo "      A written pin proves what was asked for; imageID is what the node resolved." >&2
    exit 1
    ;;
esac

echo "OK: addon-dra verified on '${CLUSTER_NAME}' — ${SLICE_COUNT} ResourceSlice(s) all reporting spec.driver '${DRIVER_NAME}', DeviceClass '${DC_NAME}' with a CEL selector naming the same driver, ${EXPECTED_DEVICES} synthetic devices per slice (${TOTAL_DEVICES} total) each publishing resource.kubernetes.io/pcieRoot, and the running plugin on the pinned digest."
echo "  the devices are SIMULATED — the driver's own device names, model string and 80Gi capacity are constants in its source, not readings"
echo "  driver:     ${DRIVER_NAME} (read from values.yaml)"
echo "  pcieRoot:   ${PCIEROOTS_SEEN} (assigned round-robin by device index)"
echo "  daemonset:  ${NAMESPACE}/${DAEMONSET} — ${DS_READY}/${DS_DESIRED} ready on ${WORKERS} worker(s)"
echo "  image:      ${PINNED_IMAGE}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"

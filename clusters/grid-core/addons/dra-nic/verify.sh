#!/usr/bin/env bash
# addon-dra-nic — verify the synthetic-NIC layer on a running grid-core.
#
# READ-ONLY. It changes nothing on the cluster and asserts OBJECT STATE only:
# the DeviceClass and its CEL selector, this driver's ResourceSlices (one per
# worker, the configured number of synthetic NICs on each), the
# `resource.kubernetes.io/pcieRoot` attribute on every synthetic NIC, that every
# root a synthetic NIC carries is also carried by one of addon-dra's synthetic
# devices on the same node, the plugin DaemonSet ready, and the digest every
# running plugin container resolved. No assertion is a Pod phase and none is a
# performance number. The driver's `100G` bandwidth capacity is never read: it
# is a constant in the driver's source, and asserting it would be asserting a
# figure no device produced.
#
# ONLY THIS DRIVER'S SLICES are counted. addon-dra's slices are on the same
# nodes, and a count over every slice would be wrong by exactly that many.
#
# THE SLICE COUNT IS ASSERTED NON-ZERO FIRST, before anything about the slices'
# contents: "every synthetic NIC publishes pcieRoot" over zero slices is
# vacuously true, and a verify that reports clean over an un-applied layer is
# the failure this order exists to close.
#
# Usage:
#   bash verify.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract: every hard assert prints `FAIL: <what>` and an
# `Inspect:` line to stderr and exits 1; on success exactly one line beginning
# `OK:` is printed.
#
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
DRA_DIR="${PROFILE_DIR}/addons/dra"

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

NAMESPACE="dra-example-driver-nic"
RELEASE="dra-example-driver-nic"
DAEMONSET="${RELEASE}-kubeletplugin"
POD_SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=kubeletplugin"

VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"
DRA_VALUES="${DRA_DIR}/values.yaml"

APPLY="bash ${ADDON_DIR}/create.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

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
    echo "      Inspect: kind get clusters" >&2
    exit 1
    ;;
esac

if ! kc wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' is Ready." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required — the per-device assertions aggregate across slices and devices." >&2
  echo "      Inspect: command -v jq" >&2
  exit 1
fi

WORKERS="$(kc get nodes -l '!node-role.kubernetes.io/control-plane,type!=kwok' --no-headers 2>/dev/null | wc -l | tr -d ' ')"

for _f in "${VALUES_FILE}" "${RENDERED}" "${DRA_VALUES}"; do
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} not found — a layer's committed artifact is missing from the tree." >&2
    echo "      Inspect: ls ${ADDON_DIR} ${DRA_DIR}" >&2
    exit 1
  fi
done

DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
EXPECTED_DEVICES="$(sed -n 's/^[[:space:]]\{1,\}numDevices:[[:space:]]*\([0-9]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
DRA_DRIVER="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${DRA_VALUES}" | head -1)"
PINNED_IMAGE="$(sed -n 's|^[[:space:]]*image:[[:space:]]*\(registry.k8s.io/dra-example-driver/dra-example-driver@sha256:[0-9a-f]\{1,\}\).*$|\1|p' "${RENDERED}" | head -1)"
PINNED_DIGEST="${PINNED_IMAGE##*@}"
if [ -z "${DRIVER_NAME}" ] || [ -z "${EXPECTED_DEVICES}" ] || [ -z "${DRA_DRIVER}" ] || [ -z "${PINNED_DIGEST}" ]; then
  echo "FAIL: could not read the driver names and device count from the values files," >&2
  echo "      or a digest-pinned driver image from ${RENDERED}." >&2
  echo "      Inspect: sed -n '/^driverName/p;/numDevices/p' ${VALUES_FILE}" >&2
  exit 1
fi

# --- 2. the DaemonSet ---------------------------------------------------------
if ! kc -n "${NAMESPACE}" get "ds/${DAEMONSET}" >/dev/null 2>&1; then
  echo "FAIL: DaemonSet ${NAMESPACE}/${DAEMONSET} not found — the layer is not applied to this cluster." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get ds" >&2
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
  exit 1
fi

# --- 3. THE EMPTY GUARD: this driver's slices, non-zero and one per worker ----
SLICE_JSON="$(kc get resourceslices -o json 2>/dev/null || true)"
if [ -z "${SLICE_JSON}" ]; then
  echo "FAIL: could not read ResourceSlices from the cluster." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices" >&2
  exit 1
fi
NIC_JSON="$(printf '%s' "${SLICE_JSON}" | jq -c --arg d "${DRIVER_NAME}" '[.items[] | select(.spec.driver == $d)]')"
SLICE_COUNT="$(printf '%s' "${NIC_JSON}" | jq -r 'length')"
if [ "${SLICE_COUNT}" -lt 1 ]; then
  echo "FAIL: zero ResourceSlices for driver '${DRIVER_NAME}', so this layer advertises no synthetic NICs." >&2
  echo "      Asserted before anything about their contents, because a property of every" >&2
  echo "      slice in an empty set is vacuously true." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l ${POD_SELECTOR}" >&2
  exit 1
fi
if [ "${SLICE_COUNT}" -ne "${WORKERS}" ]; then
  echo "FAIL: ${SLICE_COUNT} ResourceSlice(s) for driver '${DRIVER_NAME}' but ${WORKERS} worker node(s); one per worker is expected." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get pods -o wide" >&2
  exit 1
fi
SLICE_NODES="$(printf '%s' "${NIC_JSON}" | jq -r '[.[].spec.nodeName] | unique | join(",")')"

# --- 4. the DeviceClass and its CEL selector ----------------------------------
DC_NAME="$(kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ "${DC_NAME}" != "${DRIVER_NAME}" ]; then
  echo "FAIL: no DeviceClass named '${DRIVER_NAME}' on this cluster (got '${DC_NAME:-<none>}')." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get deviceclasses.resource.k8s.io" >&2
  exit 1
fi
DC_CEL="$(kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" -o jsonpath='{.spec.selectors[0].cel.expression}' 2>/dev/null || true)"
case "${DC_CEL}" in
  *"'${DRIVER_NAME}'"*) : ;;
  *)
    echo "FAIL: the DeviceClass's CEL selector is '${DC_CEL:-<empty>}', which does not name '${DRIVER_NAME}'." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get deviceclasses.resource.k8s.io ${DRIVER_NAME} -o yaml" >&2
    exit 1
    ;;
esac

# --- 5. the per-slice synthetic-NIC count -------------------------------------
DEVICE_COUNTS="$(printf '%s' "${NIC_JSON}" | jq -r '[.[].spec.devices | length] | unique | map(tostring) | join(",")')"
if [ "${DEVICE_COUNTS}" != "${EXPECTED_DEVICES}" ]; then
  echo "FAIL: the distinct per-slice synthetic-NIC counts are '${DEVICE_COUNTS}', not the single expected '${EXPECTED_DEVICES}'." >&2
  echo "      The expected count is read from ${VALUES_FILE} (kubeletPlugin.numDevices)." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices -o yaml" >&2
  exit 1
fi
TOTAL_DEVICES="$(printf '%s' "${NIC_JSON}" | jq -r '[.[].spec.devices[]] | length')"
if [ "${TOTAL_DEVICES}" -lt 1 ]; then
  echo "FAIL: zero synthetic NICs across ${SLICE_COUNT} ResourceSlice(s)." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices -o yaml" >&2
  exit 1
fi

# --- 6. pcieRoot on EVERY synthetic NIC ---------------------------------------
WITH_ROOT="$(printf '%s' "${NIC_JSON}" | jq -r --arg k resource.kubernetes.io/pcieRoot '
  [ .[].spec.devices[].attributes[$k].string | select(. != null and . != "") ] | length')"
if [ "${WITH_ROOT}" -ne "${TOTAL_DEVICES}" ]; then
  echo "FAIL: ${WITH_ROOT} of ${TOTAL_DEVICES} synthetic NICs publish a non-empty resource.kubernetes.io/pcieRoot." >&2
  echo "      values.yaml sets netPublishPCIeRoot: true because the chart default is false." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices -o yaml" >&2
  exit 1
fi
NIC_ROOTS="$(printf '%s' "${NIC_JSON}" | jq -r --arg k resource.kubernetes.io/pcieRoot '[ .[].spec.devices[].attributes[$k].string ] | unique | join(",")')"

# --- 7. every synthetic NIC's root is shared with a synthetic device ----------
# The property the co-allocation lab rests on, read as object state: on each
# node, every root a synthetic NIC carries is also carried by at least one of
# addon-dra's synthetic devices on that same node. Without it a `matchAttribute`
# claim across the two drivers has no pair to find.
UNSHARED="$(printf '%s' "${SLICE_JSON}" | jq -r --arg nic "${DRIVER_NAME}" --arg acc "${DRA_DRIVER}" --arg k resource.kubernetes.io/pcieRoot '
  def roots($d; $n): [ .items[] | select(.spec.driver == $d and .spec.nodeName == $n) | .spec.devices[].attributes[$k].string | select(. != null) ] | unique;
  . as $all
  | [ .items[] | select(.spec.driver == $nic) | .spec.nodeName ] | unique
  | map(. as $n | ($all | roots($nic; $n)) - ($all | roots($acc; $n)) | length) | add // 0')"
ACC_DEVICES="$(printf '%s' "${SLICE_JSON}" | jq -r --arg acc "${DRA_DRIVER}" '[ .items[] | select(.spec.driver == $acc) | .spec.devices[] ] | length')"
if [ "${ACC_DEVICES}" -lt 1 ] || [ "${UNSHARED}" -ne 0 ]; then
  echo "FAIL: ${UNSHARED} synthetic-NIC root(s) are not published by any of addon-dra's ${ACC_DEVICES} synthetic device(s) on the same node." >&2
  echo "      This layer needs addon-dra applied with its pcieRoot attribute published." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices -o yaml" >&2
  exit 1
fi

# --- 8. the digest EVERY running plugin container resolved --------------------
RUNNING_IMAGE_IDS="$(kc -n "${NAMESPACE}" get pod -l "${POD_SELECTOR}" \
                       --field-selector status.phase=Running -o json 2>/dev/null \
                     | jq -r '[.items[].status.containerStatuses[]?.imageID] | join(" ")' 2>/dev/null || true)"
PODS_SEEN=0
PODS_PINNED=0
for _id in ${RUNNING_IMAGE_IDS}; do
  PODS_SEEN=$((PODS_SEEN + 1))
  case "${_id}" in
    *"${PINNED_DIGEST}"*) PODS_PINNED=$((PODS_PINNED + 1)) ;;
  esac
done
if [ "${PODS_SEEN}" -lt 1 ] || [ "${PODS_PINNED}" -ne "${PODS_SEEN}" ]; then
  echo "FAIL: ${PODS_PINNED}/${PODS_SEEN} running synthetic-NIC plugin container(s) carry the digest pinned in ${RENDERED} (${PINNED_DIGEST})." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get pods -o jsonpath='{..imageID}'" >&2
  exit 1
fi

echo "OK: addon-dra-nic verified on '${CLUSTER_NAME}' — ${SLICE_COUNT} ResourceSlice(s) for driver '${DRIVER_NAME}' on ${SLICE_NODES}, ${EXPECTED_DEVICES} synthetic NICs per slice (${TOTAL_DEVICES} total) each publishing resource.kubernetes.io/pcieRoot, every root shared with a '${DRA_DRIVER}' synthetic device on the same node, DeviceClass '${DC_NAME}', and the running plugin on the pinned digest."
echo "  the NICs are SYNTHETIC — the driver's own device names, model string and bandwidth capacity are constants in its source, not readings"
echo "  pcieRoot:   ${NIC_ROOTS} (assigned round-robin by device index, as addon-dra's are)"
echo "  daemonset:  ${NAMESPACE}/${DAEMONSET} — ${DS_READY}/${DS_DESIRED} ready on ${WORKERS} worker(s)"
echo "  image:      ${PINNED_IMAGE}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"

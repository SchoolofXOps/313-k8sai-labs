#!/usr/bin/env bash
# addon-nvml-mock — verify the mock-device layer on a running grid-core.
#
# It asserts OBJECT STATE only: the mock's DaemonSet Ready on the labelled
# worker and nowhere else; with the consumers on, the worker's allocatable for
# the device plugin's resource — SELECTED BY ITS `/gpu` SUFFIX, so the vendor
# literal is never needed — non-zero, the exporter's DaemonSet Ready, and the
# exporter serving per-device series; in mock-only mode, that neither consumer
# is on the cluster; and in both modes, that every running container is on its
# registered digest. No assertion is a performance number, and no value of any
# metric is read.
#
# IT IS READ-ONLY, every step of it, so it is safe to re-run at any point of a
# lab, including after the lab's own Xid injections. The one thing it cannot
# show by reading is the exporter's Xid family, because the exporter exports no
# Xid series until an Xid is held. That needs a write, so it lives in a script
# of its own that this one does not run: xid-probe.sh injects one Xid on the
# last mock device, reads it, resets that device and replaces the exporter Pod.
# Its header says when it refuses rather than disturb a learner's held Xids.
#
# The mode is READ from the cluster — create.sh writes it onto the mock's
# namespace — so this script verifies the layer that was applied rather than
# the one somebody remembers applying.
#
# Usage:
#   bash verify.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# (with an `Inspect:` hint) and exits 1; on success exactly one line beginning
# `OK:` is printed.
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
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NS_MOCK="mokka"
NS_EXPORTER="dcgm-exporter"
NS_PLUGIN="kube-system"
DS_MOCK="nvml-mock"
DS_PLUGIN="nvidia-device-plugin-mock"
DS_EXPORTER="dcgm-exporter"
WORKER="${CLUSTER_NAME}-worker"
MODE_ANNOTATION="addon-nvml-mock.example.com/consumers"
PINS="${ADDON_DIR}/PINS.md"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

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
    echo "      Inspect: kind get clusters. Run the base profile first:  ${BASE}" >&2
    echo "      then apply the layer:  ${APPLY}" >&2
    exit 1
    ;;
esac
if ! kc wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' is Ready." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required — the assertions below fold across every Pod and every node." >&2
  exit 1
fi

pin_of() {
  sed -n "s#^| \`\\($1@sha256:[0-9a-f]\\{64\\}\\)\`.*\$#\\1#p" "${PINS}" | sed -n '1p'
}
MOCK_DIGEST="$(pin_of 'ghcr.io/nvidia/nvml-mock')"; MOCK_DIGEST="${MOCK_DIGEST##*@}"
PLUGIN_DIGEST="$(pin_of 'nvcr.io/nvidia/k8s-device-plugin')"; PLUGIN_DIGEST="${PLUGIN_DIGEST##*@}"
EXPORTER_DIGEST="$(pin_of 'nvcr.io/nvidia/k8s/dcgm-exporter')"; EXPORTER_DIGEST="${EXPORTER_DIGEST##*@}"
if [ -z "${MOCK_DIGEST}" ] || [ -z "${PLUGIN_DIGEST}" ] || [ -z "${EXPORTER_DIGEST}" ]; then
  echo "FAIL: could not read the three registered image digests out of ${PINS}." >&2
  echo "      Inspect: the table in PINS.md § 2" >&2
  exit 1
fi

# --- 2. the mode the layer was applied with -----------------------------------
if ! kc get namespace "${NS_MOCK}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NS_MOCK}' not found — the layer is not applied to this cluster." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get namespaces. Apply it: ${APPLY}" >&2
  exit 1
fi
MODE="$(kc get namespace "${NS_MOCK}" -o json 2>/dev/null | jq -r --arg k "${MODE_ANNOTATION}" '.metadata.annotations[$k] // ""' 2>/dev/null)" || MODE=""
case "${MODE}" in
  device-plugin,dcgm-exporter|none) : ;;
  *)
    echo "FAIL: namespace '${NS_MOCK}' carries mode '${MODE:-<none>}' in ${MODE_ANNOTATION}, which create.sh never writes." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NS_MOCK} -o yaml. Re-apply: ${APPLY}" >&2
    exit 1
    ;;
esac

# ds_ready <namespace> <name> -> "<ready>/<desired>"
ds_ready() {
  kc -n "$1" get ds "$2" -o json 2>/dev/null \
    | jq -r '"\(.status.numberReady // 0)/\(.status.desiredNumberScheduled // 0)"' 2>/dev/null || echo "0/0"
}
assert_ds_ready() {
  _r="$(ds_ready "$1" "$2")"
  if [ "${_r%%/*}" -lt 1 ] || [ "${_r%%/*}" != "${_r##*/}" ]; then
    echo "FAIL: DaemonSet $1/$2 reports ${_r} ready." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n $1 describe ds/$2. Re-apply: ${APPLY}" >&2
    exit 1
  fi
}
# pinned_running <namespace> <selector> <digest> <what>
pinned_running() {
  _ids="$(kc -n "$1" get pod -l "$2" --field-selector status.phase=Running -o json 2>/dev/null \
          | jq -r '[.items[].status | (.initContainerStatuses // []) + (.containerStatuses // []) | .[].imageID] | join(" ")' 2>/dev/null || true)"
  _seen=0; _ok=0
  for _id in ${_ids}; do
    _seen=$((_seen + 1))
    case "${_id}" in *"$3"*) _ok=$((_ok + 1)) ;; esac
  done
  if [ "${_seen}" -lt 1 ] || [ "${_ok}" -ne "${_seen}" ]; then
    echo "FAIL: ${_ok}/${_seen} running $4 container(s) carry the registered digest $3." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n $1 get pod -l $2 -o jsonpath='{..imageID}'" >&2
    exit 1
  fi
}

# --- 3. the mock: Ready, on the labelled worker only, on its pin --------------
assert_ds_ready "${NS_MOCK}" "${DS_MOCK}"
PLACEMENT="$(kc -n "${NS_MOCK}" get pod -l app.kubernetes.io/name=nvml-mock -o json 2>/dev/null \
             | jq -r '"\([.items[].spec.nodeName] | unique | join(","))"' 2>/dev/null)" || PLACEMENT=""
if [ "${PLACEMENT}" != "${WORKER}" ]; then
  echo "FAIL: the mock's Pods are on '${PLACEMENT:-<none>}', not on '${WORKER}' alone." >&2
  echo "      Anywhere else, its node agent rewrites that node's containerd too." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes -L mokka.nvidia.com/type" >&2
  exit 1
fi
pinned_running "${NS_MOCK}" "app.kubernetes.io/name=nvml-mock" "${MOCK_DIGEST}" "mock"

# --- 4a. mock-only: neither consumer is on the cluster ------------------------
if [ "${MODE}" = "none" ]; then
  if kc -n "${NS_PLUGIN}" get "ds/${DS_PLUGIN}" >/dev/null 2>&1 || kc get namespace "${NS_EXPORTER}" >/dev/null 2>&1; then
    echo "FAIL: the layer was applied mock-only, but a consumer is on the cluster." >&2
    echo "      A second device plugin advertising the same resource is what mock-only mode exists to prevent." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_PLUGIN} get ds; kubectl --context ${CONTEXT} get ns ${NS_EXPORTER}" >&2
    exit 1
  fi
  echo "OK: addon-nvml-mock verified on '${CLUSTER_NAME}' (none: mock only) — the mock's DaemonSet Ready on '${WORKER}' only and on its registered digest, with no device plugin and no exporter on the cluster."
  echo "  the devices are MOCK DEVICES served by a mock NVML library; nothing here reads or measures hardware"
  exit 0
fi

# --- 4b. the device plugin: Ready, registering a resource selected by suffix --
assert_ds_ready "${NS_PLUGIN}" "${DS_PLUGIN}"
pinned_running "${NS_PLUGIN}" "name=${DS_PLUGIN}" "${PLUGIN_DIGEST}" "device plugin"
RESOURCE="$(kc get node "${WORKER}" -o json 2>/dev/null \
            | jq -r '[.status.allocatable // {} | to_entries[] | select(.key | endswith("/gpu")) | "\(.key)=\(.value)"] | first // ""' 2>/dev/null)" || RESOURCE=""
if [ -z "${RESOURCE}" ] || [ "${RESOURCE#*=}" = "0" ]; then
  echo "FAIL: node '${WORKER}' advertises no non-zero allocatable resource ending in '/gpu' (read: '${RESOURCE:-none}')." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_PLUGIN} logs -l name=${DS_PLUGIN}" >&2
  exit 1
fi

# --- 4c. the exporter: Ready, on its pin, serving per-device series ----------
assert_ds_ready "${NS_EXPORTER}" "${DS_EXPORTER}"
pinned_running "${NS_EXPORTER}" "app.kubernetes.io/name=dcgm-exporter" "${EXPORTER_DIGEST}" "exporter"
EXPORTER_POD="$(kc -n "${NS_EXPORTER}" get pod -l app.kubernetes.io/name=dcgm-exporter --field-selector status.phase=Running -o json 2>/dev/null \
                | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name] | first // ""' 2>/dev/null)" || EXPORTER_POD=""
DEVICES=""
if [ -n "${EXPORTER_POD}" ]; then
  # A read through the API server's Pod proxy. Only the device-index label is
  # taken from each line; no value of any series.
  METRICS="$(kc get --raw "/api/v1/namespaces/${NS_EXPORTER}/pods/${EXPORTER_POD}:9400/proxy/metrics" 2>/dev/null)" || METRICS=""
  DEVICES="$(printf '%s\n' "${METRICS}" | sed -n 's/^DCGM_FI_DEV_[A-Z_]*.*[{,]gpu="\([0-9]\{1,\}\)".*$/\1/p' | sort -un | wc -l | tr -d ' ')"
fi
if [ -z "${DEVICES}" ] || [ "${DEVICES}" = "0" ]; then
  echo "FAIL: the exporter Pod '${EXPORTER_POD:-none}' serves no per-device series." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_EXPORTER} logs ${EXPORTER_POD:-ds/${DS_EXPORTER}}" >&2
  exit 1
fi

echo "OK: addon-nvml-mock verified on '${CLUSTER_NAME}' (${MODE}) — the mock Ready on '${WORKER}' only, the device plugin registering '${RESOURCE%%=*}' (non-zero allocatable, selected by its /gpu suffix), the exporter Ready and serving series for ${DEVICES} mock devices, and every container on its registered digest. Read-only: the Xid round trip writes, so it is a separate step, bash ${ADDON_DIR}/xid-probe.sh"
echo "  the devices are MOCK DEVICES served by a mock NVML library; no value of any metric was read, and nothing here measures hardware"

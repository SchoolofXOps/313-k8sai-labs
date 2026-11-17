#!/usr/bin/env bash
# addon-nvml-mock — teardown.
#
# READ THIS SENTENCE BEFORE RUNNING IT. This removes the mock-device LAYER — the
# two consumers if they are on, the mock's namespace and everything in it, and
# the worker label that placed it — AND IT LEAVES THE grid-core CLUSTER RUNNING.
# A profile's teardown.sh deletes its cluster; this one does not. The base
# cluster's teardown is labs/clusters/grid-core/teardown.sh.
#
# WHAT IT CANNOT PROMISE, AND READS INSTEAD. The mock's node agent rewrote the
# worker's containerd when it started: a drop-in under /etc/containerd/conf.d,
# two CDI specs, the default runtime handler moved from runc to the vendor
# container runtime, and a containerd restart (SPIKE-09, three arms). Upstream's
# chart says the node agent reverts that setup when its Pod stops. This script
# does not take that on trust: after the mock is gone it reads the worker's
# default runtime handler and the drop-in back out of the node and prints what
# it read. Whatever it reads, RECREATING grid-core is the way back to a worker
# that never had the mock:
#   bash labs/clusters/grid-core/teardown.sh && bash labs/clusters/grid-core/create.sh
#
# THE DEVICE PLUGIN'S RESOURCE OUTLIVES THE PLUGIN in the node's status. While
# its ALLOCATABLE count is non-zero, a DRA DeviceClass mapping the same name does
# not take part in scheduling (SPIKE-09 configuration B). MEASURED by plan 05-37,
# two runs: allocatable read 0 at once while CAPACITY kept the old count (4), and
# in an earlier run capacity was still listed 420 s later; the KEY never left the
# status in either run. With capacity 4 and allocatable 0, the extended-resource
# bridge DID serve a one-device Pod through DRA
# (planning/lab-tests/raw/05-addon-nvml-mock/17b-bridge-after-teardown.txt).
# So this script waits, bounded, for the `/gpu`-suffixed ALLOCATABLE to be zero
# or absent, prints what capacity and allocatable read at the end, and says how
# long it took.

# NO TOOL VERSION ASSERT HERE, for the same reason the base profile's teardown
# has none: a teardown must never be the thing that refuses to run.
#
# Usage:
#   bash teardown.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   RESOURCE_TIMEOUT   seconds to wait for the plugin's resource to read zero
#                      in the worker's allocatable (default 420)
#
# Idempotent: exits 0 when the layer, or the cluster, is already absent.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NS_MOCK="mokka"
NS_EXPORTER="dcgm-exporter"
NS_PLUGIN="kube-system"
DS_PLUGIN="nvidia-device-plugin-mock"
WORKER="${CLUSTER_NAME}-worker"
NODE_LABEL_KEY="mokka.nvidia.com/type"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"
CONSUMERS="${ADDON_DIR}/consumers-pinned.yaml"
RESOURCE_TIMEOUT="${RESOURCE_TIMEOUT:-420}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "kind cluster '${CLUSTER_NAME}' is absent — the layer has no cluster to be removed from. Nothing to do."
    exit 0
    ;;
esac

# --- 1. the consumers first: they run on the mock's driver root ---------------
# Every wait is BOUNDED (a bare --wait=true means --timeout=0s, which waits
# forever), and every delete is `|| true`d, so the absence asserts in step 5 —
# not these exit codes — are what the closing line rests on.
if [ -f "${CONSUMERS}" ]; then
  kc delete -f "${CONSUMERS}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
else
  kc -n "${NS_PLUGIN}" delete ds "${DS_PLUGIN}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  kc delete namespace "${NS_EXPORTER}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
fi

# --- 2. the mock --------------------------------------------------------------
# The node agent's revert runs inside its Pod's termination grace period, so the
# Pod is deleted and waited on before the namespace goes.
if [ -f "${RENDERED}" ]; then
  kc -n "${NS_MOCK}" delete -f "${RENDERED}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
fi
kc delete namespace "${NS_MOCK}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
kc label node "${WORKER}" "${NODE_LABEL_KEY}-" >/dev/null 2>&1 || true

# --- 3. read the worker's container runtime back ------------------------------
# Read out of the node, never assumed from the chart's documentation. Polled
# briefly, because the revert ends in a containerd restart.
DEFAULT_RUNTIME=""
DROPIN="unread"
_w=0
while [ "${_w}" -lt 60 ]; do
  DEFAULT_RUNTIME="$(docker exec "${WORKER}" crictl info 2>/dev/null \
                     | jq -r '.config.containerd.defaultRuntimeName // ""' 2>/dev/null || true)"
  if docker exec "${WORKER}" test -e /etc/containerd/conf.d/50-mokka.toml >/dev/null 2>&1; then
    DROPIN=present
  else
    DROPIN=absent
  fi
  if [ "${DEFAULT_RUNTIME}" = "runc" ] && [ "${DROPIN}" = "absent" ]; then break; fi
  sleep 3
  _w=$((_w + 3))
done
# What the revert does NOT remove, read rather than assumed (plan 05-37 measured
# both): the `imports` line the agent added to config.toml, which now points at an
# empty directory, and the toolkit's symlinks under /usr/bin. Neither is a
# runtime handler, so containerd does not use them; they are named so nobody
# mistakes the worker for one that never had the mock.
RESIDUE=""
if docker exec "${WORKER}" sh -c 'sed -n "/^imports/p" /etc/containerd/config.toml' 2>/dev/null | sed -n '/conf\.d/p' | sed -n '1p' | { read -r _l && [ -n "${_l}" ]; }; then
  RESIDUE="${RESIDUE} config.toml imports line;"
fi
if docker exec "${WORKER}" test -L /usr/bin/nvidia-container-runtime >/dev/null 2>&1; then
  RESIDUE="${RESIDUE} toolkit symlinks in /usr/bin;"
fi
if [ "${DEFAULT_RUNTIME}" = "runc" ] && [ "${DROPIN}" = "absent" ]; then
  RUNTIME_NOTE="read back after ${_w}s: the worker's default runtime handler is runc again and the mock's containerd drop-in is gone (the node agent reverted its setup); left behind, unused:${RESIDUE:- nothing found}"
else
  RUNTIME_NOTE="read back after ${_w}s: the worker's default runtime handler is '${DEFAULT_RUNTIME:-unread}' and the mock's containerd drop-in is ${DROPIN} — NOT reverted; recreate grid-core for a worker that never had the mock"
fi

# --- 4. wait for the plugin's resource to reach zero on the worker ------------
# Selected by the `/gpu` suffix, never named. The list call's success is kept
# separate from the read, so "could not look" is never read as "gone". A key at
# "0" is the end state, not a leftover: the kubelet keeps it, and the bridge
# works beside it (measured; see the header).
_w=0
LEFT=""
while [ "${_w}" -lt "${RESOURCE_TIMEOUT}" ]; do
  if NODE_JSON="$(kc get node "${WORKER}" -o json 2>/dev/null)"; then
    LEFT="$(printf '%s' "${NODE_JSON}" | jq -r '[.status.allocatable // {} | to_entries[] | select((.key | endswith("/gpu")) and .value != "0") | "\(.key)=\(.value)"] | join(",")' 2>/dev/null || echo unread)"
  else
    LEFT="unread"
  fi
  if [ -z "${LEFT}" ]; then break; fi
  sleep 10
  _w=$((_w + 10))
done
RESOURCE_SECONDS="${_w}"
RESOURCE_READ="$(kc get node "${WORKER}" -o json 2>/dev/null \
                 | jq -r '.status as $s | [($s.capacity // {}) | keys[] | select(endswith("/gpu"))]
                          | if length == 0 then "no /gpu-suffixed key in the status"
                            else map("\(.) capacity=\($s.capacity[.]) allocatable=\($s.allocatable[.] // "absent")") | join("; ") end' 2>/dev/null || echo unread)"

# --- 5. the closing line has to be earned -------------------------------------
rc=0
for _ns in "${NS_EXPORTER}" "${NS_MOCK}"; do
  _waited=0
  while [ "${_waited}" -lt 120 ] && kc get namespace "${_ns}" >/dev/null 2>&1; do
    sleep 3
    _waited=$((_waited + 3))
  done
  if kc get namespace "${_ns}" >/dev/null 2>&1; then
    echo "FAIL: namespace '${_ns}' is still present after teardown." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${_ns} -o yaml" >&2
    rc=1
  fi
done
if kc -n "${NS_PLUGIN}" get ds "${DS_PLUGIN}" >/dev/null 2>&1; then
  echo "FAIL: DaemonSet ${NS_PLUGIN}/${DS_PLUGIN} is still present after teardown." >&2
  rc=1
fi
if _labelled="$(kc get nodes -l "${NODE_LABEL_KEY}" -o name 2>/dev/null)"; then
  if [ -n "${_labelled}" ]; then
    echo "FAIL: node(s) still carry the mock's placement label: ${_labelled}" >&2
    rc=1
  fi
else
  echo "FAIL: could not list nodes on context '${CONTEXT}', so the label's removal cannot be verified." >&2
  rc=1
fi
if [ -n "${LEFT}" ]; then
  echo "FAIL: after ${RESOURCE_SECONDS}s node '${WORKER}' still reads '${LEFT}' in its allocatable." >&2
  echo "      The plugin is gone; the kubelet has not zeroed its resource yet. A DRA DeviceClass mapping" >&2
  echo "      the same name will not take part in scheduling until it does." >&2
  echo "      Re-run this teardown to wait again, or recreate grid-core." >&2
  rc=1
fi
if [ "${rc}" -ne 0 ]; then
  echo "FAIL: addon-nvml-mock teardown left objects behind, or could not verify their removal." >&2
  echo "      Re-run: bash ${ADDON_DIR}/teardown.sh" >&2
  exit 1
fi

echo "addon-nvml-mock layer torn down: the consumers, namespace '${NS_MOCK}' and the worker's placement label are removed, and the plugin's resource read zero (or absent) in '${WORKER}''s allocatable after ${RESOURCE_SECONDS}s."
echo "  read at the end: ${RESOURCE_READ} — only allocatable has to be zero for the extended-resource bridge to serve a Pod (measured, plan 05-37)"
echo "  ${RUNTIME_NOTE}"
echo "  recreating grid-core is always the way back to a worker that never had the mock"
echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown. Re-verifying the base:"
bash "${PROFILE_DIR}/verify.sh"

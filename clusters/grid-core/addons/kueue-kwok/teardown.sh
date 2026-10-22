#!/usr/bin/env bash
# addon-kueue-kwok — teardown.
#
# READ THIS SENTENCE BEFORE RUNNING IT. This removes the queueing and
# simulated-fleet LAYER — the gang object sets and their namespaces, every
# simulated node, the kwok controller with its stages, CRDs and RBAC, the Kueue
# install with its CRDs and its namespace — AND IT LEAVES THE grid-core CLUSTER
# RUNNING.
#
# That is the opposite of what a PROFILE's teardown.sh does: a profile's teardown
# deletes its cluster. Both files are called teardown.sh, which is a convenience
# for a learner reading a directory and a trap for a reader who assumes the
# semantics transfer. They do not. The base cluster's teardown is
# labs/clusters/grid-core/teardown.sh and it deletes the cluster.
#
# ---------------------------------------------------------------------------
# THE ORDER IS LOAD-BEARING, AND IT IS NOT THE OBVIOUS ONE
# ---------------------------------------------------------------------------
# Kueue puts a FINALIZER on every Workload it manages. Deleting the Kueue
# controller first leaves those finalizers with nobody to clear them, and then
# the gang namespaces hang in Terminating forever — and a later `kubectl apply`
# into a Terminating namespace EXITS 0 AND CREATES NOTHING, so the next create
# run would report a successful install of nothing.
#
# So: the gangs go first and their Workloads are waited out WHILE THE CONTROLLER
# IS STILL RUNNING; then the fleet; then Kueue itself.
#
# NO TOOL VERSION ASSERT HERE, for the same reason the base profile's teardown
# has none: removing objects works with any supported client, and a teardown must
# never be the thing that refuses to run. A learner who cannot delete what they
# installed is worse off than one running a slightly skewed kubectl.
#
# Usage:
#   bash teardown.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Idempotent: exits 0 when the layer, or the cluster, is already absent.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# PATH prepend only. See the header: no version assert.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
KWOK_ATTACH_DIR="${LABS_DIR}/kwok/attach"

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NAMESPACE="${NAMESPACE:-kueue-system}"
RENDERED="${ADDON_DIR}/kueue-rendered-pinned.yaml"
GANGS_FILE="${ADDON_DIR}/tas-gangs-v1beta2.yaml"
TENANTS_FILE="${ADDON_DIR}/three-tenant-v1beta2.yaml"

# grep -qx (exact whole line), never grep -q: 'grid-core' must not match
# 'grid-core-dra'. Captured into a variable and matched with `case` so a
# successful match cannot return 141 under pipefail.
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

kc() { kubectl --context "${CONTEXT}" "$@"; }

rc=0

# --- 1. the gang object sets, while the controller can still clear finalizers --
echo "==> Removing the gang object sets and their namespaces"
for _f in "${GANGS_FILE}" "${TENANTS_FILE}"; do
  if [ -f "${_f}" ]; then
    # By FILE, so the cluster-scoped objects in them — the Topology, the
    # ResourceFlavor, the ClusterQueues and the Cohort — go too rather than
    # surviving a namespace delete.
    #
    # `--wait=false`, deliberately: the objects in these files carry Kueue
    # finalizers, and `--wait=true` with no `--timeout` waits FOREVER if the
    # controller that clears them is not there — the exact state this script's
    # header describes. The bounded Workload-finalizer poll below is the wait.
    kc delete -f "${_f}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
done

echo "==> Waiting for Kueue to clear its Workload finalizers (controller still up)"
_waited=0
WL_LEFT=0
while [ "${_waited}" -lt 120 ]; do
  WL_LEFT="$(kc get workloads.kueue.x-k8s.io -A --no-headers 2>/dev/null | /usr/bin/grep -c . || true)"
  WL_LEFT="${WL_LEFT:-0}"
  if [ "${WL_LEFT}" -eq 0 ]; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if [ "${WL_LEFT}" -ne 0 ]; then
  echo "NOTE: ${WL_LEFT} Kueue Workload(s) still present after ${_waited}s; the CRD delete below"
  echo "      removes them with their CRD. Recorded rather than hidden: if this happens"
  echo "      on a cluster whose Workloads belong to something else, stop and look."
fi

# The gang NAMESPACES, polled to absence while the controller and the fleet are
# still up. `--wait=false` above displaced the only wait that held namespace
# termination inside this window: the Workload poll reads Workloads, not
# namespaces, and the Jobs and StatefulSets in those namespaces have pods bound
# to fake nodes whose GC needs the fleet. A namespace still Terminating when
# step 4 runs answers `kc get namespace` successfully and FAILs the assertion —
# intermittently, because fake-node deletion usually rescues it. Bounded, so a
# finalizer nobody clears cannot hang this; step 4 is still what decides.
GANG_NAMESPACES="kueue-kwok-tas kueue-kwok-tas-block tenant-a tenant-b tenant-c"
echo "==> Waiting for the gang namespaces to finish terminating (controller and fleet still up)"
_waited=0
NS_LEFT=0
while [ "${_waited}" -lt 120 ]; do
  NS_LEFT=0
  for _ns in ${GANG_NAMESPACES}; do
    if kc get namespace "${_ns}" >/dev/null 2>&1; then NS_LEFT=$((NS_LEFT + 1)); fi
  done
  if [ "${NS_LEFT}" -eq 0 ]; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if [ "${NS_LEFT}" -ne 0 ]; then
  echo "NOTE: ${NS_LEFT} gang namespace(s) still present after ${_waited}s; continuing, and step 4"
  echo "      FAILs if any is still there once the fleet and Kueue are gone."
fi

# --- 2. the simulated fleet ---------------------------------------------------
# Driven, not duplicated: setup.sh owns the enumerated kwok object set and its
# own post-removal asserts.
if [ -f "${KWOK_ATTACH_DIR}/setup.sh" ]; then
  echo "==> Removing the simulated fleet and the kwok controller"
  CONTEXT="${CONTEXT}" CLUSTER_NAME="${CLUSTER_NAME}" \
    bash "${KWOK_ATTACH_DIR}/setup.sh" teardown || rc=1
else
  echo "NOTE: ${KWOK_ATTACH_DIR}/setup.sh is absent; removing simulated nodes by label instead."
  kc delete nodes -l type=kwok --ignore-not-found >/dev/null 2>&1 || true
fi

# --- 3. Kueue ----------------------------------------------------------------
echo "==> Removing the Kueue install"
if [ -f "${RENDERED}" ]; then
  # By FILE: the rendered object set carries the eleven CRDs, the ClusterRoles,
  # the ClusterRoleBindings, the webhook configurations and the APIService, none
  # of which a namespace delete would reach. Bounded: an unbounded `--wait=true`
  # hangs on any finalizer nobody is left to clear, and the asserts in step 4
  # are what the OK line rests on, not this wait.
  kc delete -f "${RENDERED}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
else
  echo "NOTE: ${RENDERED} is absent, so the cluster-scoped Kueue objects are removed by name instead."
  kc delete crd \
    admissionchecks.kueue.x-k8s.io clusterqueues.kueue.x-k8s.io cohorts.kueue.x-k8s.io \
    localqueues.kueue.x-k8s.io multikueueclusters.kueue.x-k8s.io multikueueconfigs.kueue.x-k8s.io \
    provisioningrequestconfigs.kueue.x-k8s.io resourceflavors.kueue.x-k8s.io \
    topologies.kueue.x-k8s.io workloadpriorityclasses.kueue.x-k8s.io workloads.kueue.x-k8s.io \
    --ignore-not-found >/dev/null 2>&1 || true
fi
kc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true

# --- 4. the OK line has to be earned -----------------------------------------
# Assert what it claims: the layer is gone, and the real cluster is still here.
FAKE_LEFT="$(kc get nodes -l type=kwok -o name 2>/dev/null | /usr/bin/grep -c . || true)"
if [ "${FAKE_LEFT:-0}" != "0" ]; then
  echo "FAIL: ${FAKE_LEFT} simulated node(s) still present after teardown." >&2
  rc=1
fi
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' still present after teardown." >&2
  rc=1
fi
if kc get crd clusterqueues.kueue.x-k8s.io >/dev/null 2>&1; then
  echo "FAIL: the Kueue CRDs are still present after teardown." >&2
  rc=1
fi
for _ns in ${GANG_NAMESPACES}; do
  if kc get namespace "${_ns}" >/dev/null 2>&1; then
    echo "FAIL: namespace '${_ns}' still present after teardown." >&2
    rc=1
  fi
done
REAL_LEFT="$(kc get node "${CLUSTER_NAME}-control-plane" -o name 2>/dev/null || true)"
if [ -z "${REAL_LEFT}" ]; then
  echo "FAIL: the real control-plane node is gone — the teardown was not confined to" >&2
  echo "      the layer, so 'the cluster is still running' cannot be claimed." >&2
  rc=1
fi

if [ "${rc}" -ne 0 ]; then
  echo "FAIL: addon-kueue-kwok teardown left objects behind, or could not verify removal." >&2
  echo "      Re-run: bash ${ADDON_DIR}/teardown.sh" >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get crd | /usr/bin/grep -e kueue -e kwok" >&2
  echo "               kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

echo "addon-kueue-kwok layer torn down: the gang object sets and their namespaces, every simulated node, the kwok controller with its stages, CRDs and RBAC, and the Kueue install with its CRDs and namespace '${NAMESPACE}' are removed."
echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
echo "  confirm the base survived:  bash ${PROFILE_DIR}/verify.sh"
echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"

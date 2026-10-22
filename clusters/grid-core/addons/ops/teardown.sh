#!/usr/bin/env bash
# addon-ops — remove the operations layer and LEAVE THE CLUSTER RUNNING.
#
# IT REMOVES: the three releases this layer applied — the metrics collector,
# the dashboard surface and the cost tool — their cluster-scoped RBAC, and the
# layer's own namespace. IT LEAVES: the grid-core cluster itself, every node,
# every feature gate and every other addon layer, exactly as it found them.
# That sentence is the contract; everything below implements it.
#
# THERE IS NO DELETION ORDER BETWEEN THE THREE COMPONENTS, AND THE ABSENCE IS A
# DECISION RATHER THAN AN OMISSION. The storage layer next door has a real
# ordering rule — its clients must go before its servers or the teardown
# deadlocks, measured — so the absence of one here would otherwise read as
# something nobody thought about. Two reasons it genuinely does not apply:
#
#   1. PERSISTENCE IS OFF FOR ALL THREE. No PersistentVolumeClaim, no volume to
#      reclaim, so there is no finalizer that waits on another component.
#   2. The only runtime dependency runs the OTHER way and is recovered by a
#      restart rather than by an ordering rule: the cost tool queries the
#      collector at startup and EXITS FATALLY if that query fails — measured,
#      `FTL Failed to create Prometheus data source`, exit and CrashLoopBackOff
#      rather than an in-process retry. A collector deleted first therefore
#      leaves the cost tool restarting for the few seconds before its own Pod
#      is deleted, which costs nothing and blocks nothing. The same behaviour
#      on the way IN is why create.sh applies the collector first.
#
# So the whole object set is deleted in one call and the namespace deletion is
# what actually reclaims it.
#
# THE NAMESPACE DELETION IS WAITED FOR, NOT FIRED AND FORGOTTEN. A namespace
# left Terminating is indistinguishable from a namespace that is gone until the
# next create tries to apply into it — and `kubectl apply` into a Terminating
# namespace EXITS 0 AND CREATES NOTHING. So this waits, and create.sh waits
# again on the way in; two guards, because the failure is silent on both sides.
#
# IT ASSERTS NO TOOL VERSION. A teardown that refused to run because a client
# binary drifted would strand a cluster carrying a layer nobody can remove.
# The create path is where the pins are asserted, and the teardown's job is to
# get the cluster back to the state the base profile left it in.
#
# Usage:
#   bash teardown.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   NAMESPACE        the layer's namespace (default grid-ops)
#   NS_TIMEOUT       seconds to wait for namespace deletion (default 180)
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: removing a layer that is already absent reports what it checked
# and exits 0.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"

# NO SIZE ASSERT HERE, for the reason the base profile's teardown states: this
# script reads no per-size value, and a teardown must never be the thing that
# refuses to run — a learner who mistyped SIZE could not remove their own layer,
# and would be left with three Deployments and their cluster-scoped RBAC
# behind. serving/teardown.sh asserts SIZE because its fence branch genuinely
# reads it; nothing below does.

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NAMESPACE="${NAMESPACE:-grid-ops}"
NS_TIMEOUT="${NS_TIMEOUT:-180}"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- 1. the cluster this layer would be removed FROM --------------------------
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "OK: addon-ops teardown — kind cluster '${CLUSTER_NAME}' does not exist, so this layer has nothing to remove and no cluster to leave running."
    echo "  nothing was deleted; this is the already-clean state, reported rather than assumed"
    exit 0
    ;;
esac

if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer on context '${CONTEXT}', so nothing can be removed." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  echo "      The cluster has NOT been touched." >&2
  exit 1
fi

# --- 2. delete the object set, then the namespace -----------------------------
# The committed render is the deletion subject when it is present, because it
# is exactly what was applied — including the CLUSTER-SCOPED ClusterRoles and
# ClusterRoleBindings all three charts create, which a namespace deletion alone
# would leave behind. When it is absent the namespace deletion is still run, so
# a tree that lost the file can still clean up what is reclaimable.
DELETED_FROM_RENDER="no"
if [ -f "${RENDERED}" ]; then
  if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    kc delete -f "${RENDERED}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    DELETED_FROM_RENDER="yes"
  else
    # No namespace means the namespaced objects are already gone, but the
    # cluster-scoped ones are not namespaced and can outlive it.
    kc delete -f "${RENDERED}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    DELETED_FROM_RENDER="cluster-scoped only"
  fi
fi

NS_EXISTED="no"
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  NS_EXISTED="yes"
  kc delete namespace "${NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

_waited=0
while [ "${_waited}" -lt "${NS_TIMEOUT}" ]; do
  if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then break; fi
  sleep 2
  _waited=$((_waited + 2))
done
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  _phase="$(kc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "FAIL: namespace '${NAMESPACE}' is still present (phase ${_phase:-unknown}) after ${_waited}s." >&2
  echo "      This waits rather than returning, because a namespace left" >&2
  echo "      Terminating looks identical to one that is gone until the next" >&2
  echo "      create tries to apply into it — and kubectl apply into a" >&2
  echo "      Terminating namespace exits 0 and creates nothing." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NAMESPACE} -o yaml" >&2
  echo "      The cluster itself is untouched and still running." >&2
  exit 1
fi

# --- 3. read back what is left -------------------------------------------------
# The cluster-scoped leftovers are checked by NAME rather than inferred from the
# namespace being gone, because they are not namespaced and the namespace
# deletion does not reclaim them.
CLUSTER_SCOPED="prometheus-server grafana-clusterrole opencost"
LEFTOVER=""
for _n in ${CLUSTER_SCOPED}; do
  if kc get clusterrole "${_n}" >/dev/null 2>&1; then LEFTOVER="${LEFTOVER} clusterrole/${_n}"; fi
done
for _n in prometheus-server grafana-clusterrolebinding opencost; do
  if kc get clusterrolebinding "${_n}" >/dev/null 2>&1; then LEFTOVER="${LEFTOVER} clusterrolebinding/${_n}"; fi
done
if [ -n "${LEFTOVER}" ]; then
  echo "FAIL: cluster-scoped objects this layer created are still present:${LEFTOVER}" >&2
  echo "      A namespace deletion does not reclaim them — they are not" >&2
  echo "      namespaced — so a teardown that only deleted the namespace would" >&2
  echo "      leave RBAC behind on a cluster the learner keeps using." >&2
  echo "      Remove them: kubectl --context ${CONTEXT} delete -f ${RENDERED} --ignore-not-found" >&2
  exit 1
fi

NODES_READY="$(kc get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {n++} END {printf "%d", n+0}')"
NODES_TOTAL="$(kc get nodes --no-headers 2>/dev/null | awk 'END {printf "%d", NR+0}')"
if [ "${NODES_TOTAL}" -lt 1 ] || [ "${NODES_READY}" -ne "${NODES_TOTAL}" ]; then
  echo "FAIL: after the teardown the cluster reports ${NODES_READY}/${NODES_TOTAL} nodes Ready." >&2
  echo "      This layer removes an object set and must leave the cluster" >&2
  echo "      running; a teardown that took the cluster with it is the failure" >&2
  echo "      this assertion exists for." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

echo "OK: addon-ops removed from '${CLUSTER_NAME}' — namespace '${NAMESPACE}' gone (existed before this run: ${NS_EXISTED}), no cluster-scoped RBAC left behind, and the cluster is STILL RUNNING with ${NODES_READY}/${NODES_TOTAL} nodes Ready."
echo "  deleted from the committed render: ${DELETED_FROM_RENDER}"
echo "  no deletion order between the three components, and that is a decision: persistence is off for all three so no volume is reclaimed, and the one runtime dependency is recovered by a Pod restart rather than by an ordering rule"
echo "  no tool version is asserted here — a teardown that refused on a drifted client binary would strand a cluster carrying a layer nobody can remove"
echo "  the cluster is left for the next layer: bash ${PROFILE_DIR}/verify.sh"

#!/usr/bin/env bash
# addon-dra — teardown.
#
# READ THIS SENTENCE BEFORE RUNNING IT. This removes the synthetic-device LAYER
# — the driver's namespace and everything in it, its cluster-scoped RBAC, its
# validating admission policy, its DeviceClass and the ResourceSlices it
# published — AND IT LEAVES THE grid-core CLUSTER RUNNING.
#
# That is the opposite of what a PROFILE's teardown.sh does: a profile's
# teardown deletes its cluster. Both files are called teardown.sh, which is a
# convenience for a learner reading a directory and a trap for a reader who
# assumes the semantics transfer. They do not. The base cluster's teardown is
# labs/clusters/grid-core/teardown.sh and it deletes the cluster.
#
# NO TOOL VERSION ASSERT HERE, for the same reason the base profile's teardown
# has none: removing objects works with any supported client, and a teardown
# must never be the thing that refuses to run. A learner who cannot delete what
# they installed is worse off than one running a slightly skewed kubectl.
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
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NAMESPACE="${NAMESPACE:-dra-example-driver}"
VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"

kc() { kubectl --context "${CONTEXT}" "$@"; }

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

DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" 2>/dev/null | head -1 || true)"

if [ -f "${RENDERED}" ]; then
  # The rendered manifest carries the cluster-scoped objects too — the
  # ClusterRole, the ClusterRoleBinding, the DeviceClass, the
  # ValidatingAdmissionPolicy and its binding — so deleting by file is what
  # makes this removal complete rather than namespace-shaped.
  kc delete -f "${RENDERED}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
else
  echo "NOTE: ${RENDERED} is absent, so the cluster-scoped objects are removed by name instead."
  kc delete deviceclasses.resource.k8s.io "${DRIVER_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kc delete validatingadmissionpolicybinding.admissionregistration.k8s.io \
     resourceslices-policy-dra-example-driver --ignore-not-found >/dev/null 2>&1 || true
  kc delete validatingadmissionpolicy.admissionregistration.k8s.io \
     resourceslices-policy-dra-example-driver --ignore-not-found >/dev/null 2>&1 || true
  kc delete clusterrolebinding dra-example-driver-role-binding --ignore-not-found >/dev/null 2>&1 || true
  kc delete clusterrole dra-example-driver-role --ignore-not-found >/dev/null 2>&1 || true
fi

kc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

# A ResourceSlice is owned by its Node, not by the driver's namespace, so the
# kubelet plugin deletes its own slices on graceful shutdown. Give it a window,
# then remove whatever is left by name: an orphan slice advertising devices no
# plugin is behind would make the next layer's verify read a fleet that is not
# there.
LEFTOVER=0
if [ -n "${DRIVER_NAME}" ]; then
  _waited=0
  while [ "${_waited}" -lt 60 ]; do
    LEFTOVER="$(kc get resourceslices -o jsonpath="{range .items[?(@.spec.driver=='${DRIVER_NAME}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null | /usr/bin/grep -c . || true)"
    LEFTOVER="${LEFTOVER:-0}"
    if [ "${LEFTOVER}" -eq 0 ]; then break; fi
    sleep 3
    _waited=$((_waited + 3))
  done
  if [ "${LEFTOVER}" -ne 0 ]; then
    echo "NOTE: ${LEFTOVER} ResourceSlice(s) for driver '${DRIVER_NAME}' outlived the plugin's shutdown; removing them by name."
    for _slice in $(kc get resourceslices -o jsonpath="{range .items[?(@.spec.driver=='${DRIVER_NAME}')]}{.metadata.name}{' '}{end}" 2>/dev/null || true); do
      kc delete resourceslices.resource.k8s.io "${_slice}" --ignore-not-found >/dev/null 2>&1 || true
    done
  fi
fi

echo "addon-dra layer torn down: namespace '${NAMESPACE}', its cluster-scoped RBAC and admission policy, DeviceClass '${DRIVER_NAME}' and the ResourceSlices it published are removed."
echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
echo "  confirm the base survived:  bash ${PROFILE_DIR}/verify.sh"
echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"

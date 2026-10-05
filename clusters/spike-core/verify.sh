#!/usr/bin/env bash
# spike-core profile — verify
# Asserts the spike-core cluster exists, both nodes are Ready, the kubelet
# reports a 1.37.x version (the pin), and the API server answers /readyz.
# Read-only and idempotent — it creates and changes nothing.
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to
# stderr and exits 1. On success exactly ONE line beginning `OK:` is printed;
# anything after it is an indented informational probe, not an assertion.
#
# Usage:
#   bash verify.sh
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/spike-core.kubeconfig   # isolated; never touch other clusters
#
# Idempotent: safe to re-run any number of times.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# See create.sh for the full note. Short version: the stale /usr/local/bin/kind
# (v0.32.0) and ~/.rd/bin/kubectl shims resolve FIRST from a login shell, so
# this script prepends the brew prefix itself instead of trusting the caller's
# PATH. Override with LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

# A prepend is not a resolution guarantee: if the pinned kind is absent from
# that prefix the stale v0.32.0 runs and this script would report on the wrong
# cluster. create.sh asserted this; verify.sh did not (WR-01).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)/pinned-bin.sh"
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="spike-core"
CONTEXT="${CONTEXT:-kind-spike-core}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-/tmp/spike-core.kubeconfig}"

RECREATE="bash ${PROFILE_DIR}/teardown.sh && bash ${PROFILE_DIR}/create.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "FAIL: kind cluster '${CLUSTER_NAME}' not found. Run: bash ${PROFILE_DIR}/create.sh" >&2
  exit 1
fi

echo "Waiting for all nodes to be Ready ..."
if ! kc wait --for=condition=Ready node --all --timeout=180s; then
  echo "FAIL: nodes did not all reach Ready within 180s. Inspect: kubectl --context ${CONTEXT} get nodes; then ${RECREATE}" >&2
  exit 1
fi

NODE_COUNT="$(kc get nodes --no-headers | wc -l | tr -d ' ')"
if [ "${NODE_COUNT}" -ne 2 ]; then
  echo "FAIL: expected 2 nodes (1 control-plane + 1 worker), found ${NODE_COUNT}. Recreate: ${RECREATE}" >&2
  exit 1
fi

if ! kc get node "${CLUSTER_NAME}-worker" >/dev/null 2>&1; then
  echo "FAIL: worker node '${CLUSTER_NAME}-worker' not found. Recreate: ${RECREATE}" >&2
  exit 1
fi

KUBELET_VERSION="$(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
case "${KUBELET_VERSION}" in
  v1.37.*) : ;;
  *)
    echo "FAIL: kubelet reports ${KUBELET_VERSION}, but this course pins Kubernetes 1.37.x. Check KIND_IMAGE, then ${RECREATE}" >&2
    exit 1
    ;;
esac

if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer. Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  exit 1
fi

# Hard assert: all three create-time-immutable feature gates are enabled. This
# runs AFTER the node-Ready and /readyz asserts, because both must hold before
# the API server's feature surface can be read at all.
FEATURE_GATES="${FEATURE_GATES:-GenericWorkload DRAWorkloadResourceClaims NodeLifecycleConditions}"
GATE_METRICS="$(kc get --raw /metrics 2>/dev/null || true)"
GATE_CMDLINE="$(kc -n kube-system get pod \
                  "kube-apiserver-${CLUSTER_NAME}-control-plane" \
                  -o jsonpath='{.spec.containers[0].command}' 2>/dev/null || true)"
MISSING_GATES=""
for gate in ${FEATURE_GATES}; do
  if printf '%s\n' "${GATE_METRICS}" \
       | grep -E "^kubernetes_feature_enabled\{name=\"${gate}\"" \
       | grep -q ' 1$'; then
    continue
  fi
  case "${GATE_CMDLINE}" in
    *"${gate}=true"*) continue ;;
  esac
  MISSING_GATES="${MISSING_GATES} ${gate}"
done
if [ -n "${MISSING_GATES}" ]; then
  echo "FAIL: feature gate(s) not enabled on this cluster:${MISSING_GATES}." >&2
  echo "      They are immutable after create, so this cannot be patched — recreate: ${RECREATE}" >&2
  exit 1
fi

echo "OK: spike-core verified — 2/2 nodes Ready, kubelet ${KUBELET_VERSION}, API server /readyz healthy, all 3 feature gates enabled."
echo "  context:    ${CONTEXT}"
echo "  kubeconfig: ${KUBECONFIG}"
echo "  gates:      ${FEATURE_GATES// /, }"
kc get nodes

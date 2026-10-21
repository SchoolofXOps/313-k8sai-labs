#!/usr/bin/env bash
# addon-dataplane — teardown.
#
# READ THIS SENTENCE BEFORE RUNNING IT. This removes the storage data-path LAYER
# — the four paths' client and server workloads, their claims, the namespace,
# the cluster-scoped objects the network-filesystem path creates, the volumes it
# released, and the payload bytes left on the host directory — AND IT LEAVES THE
# grid-core CLUSTER RUNNING.
#
# That is the opposite of what a PROFILE's teardown.sh does: a profile's
# teardown deletes its cluster. Both files are called teardown.sh, which is a
# convenience for a learner reading a directory and a trap for a reader who
# assumes the semantics transfer. They do not. The base cluster's teardown is
# labs/clusters/grid-core/teardown.sh and it deletes the cluster.
#
# THE DELETION ORDER IS AN ASSERTION, NOT A CONVENTION, and it is the reason this
# file drives the harness's own teardown rather than deleting a namespace.
# Deleting the network-filesystem SERVER before its CLIENTS deadlocks namespace
# deletion: the client's mount inside the node carries the protocol's default
# hard option, so once the server's cluster IP stops answering, the kubelet's
# unmount never returns, the client Pod object is never removed, and the
# namespace sits Terminating with a content-deletion failure naming pods. That is
# a MEASURED Phase-1 finding — it is what happens to anyone who deletes an
# in-cluster network-filesystem server before its clients — and the failure
# presents as a HANG rather than as an error. So the clients go first, and the
# harness also carries a bounded force path for a hard mount whose server has
# already gone, which only a lazy unmount can clear.
#
# IT WAITS FOR NAMESPACE DELETION BEFORE RETURNING. `kubectl apply` into a
# Terminating namespace exits 0 and creates nothing, so a later re-create that
# trusted apply's exit code would report an empty run as a successful one.
#
# NO TOOL VERSION ASSERT HERE, for the same reason the base profile's teardown
# has none: removing objects works with any supported client, and a teardown
# must never be the thing that refuses to run. A learner who cannot delete what
# they installed is worse off than one running a slightly skewed client.
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
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
HARNESS_DIR="${LABS_DIR}/storage/four-path"

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NAMESPACE="${NAMESPACE:-spike-02}"
export NAMESPACE CONTEXT

# How long to wait for the namespace to actually go away after the harness's own
# teardown returns. The harness already waits; this is the layer asserting the
# post-condition rather than trusting it, and it is bounded so the hang the
# ordering prevents cannot become a hang here instead.
NS_TIMEOUT="${NS_TIMEOUT:-180}"

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

# The harness owns the ordering (clients, then servers, then the namespace, then
# the released volumes, then the three cluster-scoped objects) and it asserts its
# own leftovers. Driving it is what keeps one deletion order in one place.
# Its output is PREFIXED rather than passed through, for the same reason
# create.sh prefixes it: both scripts honour the same reporting contract, and two
# of them doing so in one stream would emit two success lines for one outcome.
set +e
bash "${HARNESS_DIR}/run.sh" teardown 2>&1 | sed 's/^/  harness| /'
HARNESS_RC="${PIPESTATUS[0]}"
set -e
if [ "${HARNESS_RC}" -ne 0 ]; then
  echo "FAIL: the four-path harness's teardown exited ${HARNESS_RC}; the layer may be partly removed." >&2
  echo "      Re-run with the harness's own output unprefixed for the full detail:" >&2
  echo "        bash ${HARNESS_DIR}/run.sh teardown" >&2
  exit 1
fi

# Post-condition, asserted rather than assumed.
_waited=0
while [ "${_waited}" -lt "${NS_TIMEOUT}" ]; do
  if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' is still present ${_waited}s after the teardown returned." >&2
  echo "      A Terminating namespace accepts \`kubectl apply\` and creates nothing, so a later" >&2
  echo "      re-create that trusted apply's exit code would report an empty run as a" >&2
  echo "      successful one — which is why this is asserted here instead of being left to" >&2
  echo "      the next create." >&2
  echo "      The usual cause is a stranded hard network-filesystem mount in the node." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NAMESPACE} -o yaml" >&2
  echo "      Re-run:  bash ${ADDON_DIR}/teardown.sh" >&2
  exit 1
fi

echo "addon-dataplane layer torn down: the four paths' workloads, their claims, namespace '${NAMESPACE}', the released volumes and the network-filesystem path's cluster-scoped objects are removed, and the host payload bytes are gone."
echo "  the clients were deleted BEFORE the network-filesystem server, which is what prevents the measured namespace-deletion deadlock."
echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
echo "  confirm the base survived:  bash ${PROFILE_DIR}/verify.sh"
echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"

#!/usr/bin/env bash
# addon-serving — teardown.
#
# READ THIS SENTENCE BEFORE RUNNING IT. This removes the inference serving LAYER
# — the tokenizer service, the simulator fleet, the router's endpoint picker and
# the router's own data plane, together with their namespace and everything in it
# — AND IT LEAVES THE grid-core CLUSTER RUNNING.
#
# That is the opposite of what a PROFILE's teardown.sh does: a profile's
# teardown deletes its cluster. Both files are called teardown.sh, which is a
# convenience for a learner reading a directory and a trap for a reader who
# assumes the semantics transfer. They do not. The base cluster's teardown is
# labs/clusters/grid-core/teardown.sh and it deletes the cluster.
#
# IT BRANCHES ON SIZE, exactly as create.sh and verify.sh do. At the minimum
# size the layer was never installed, so this is a NO-OP that exits 0 AND SAYS
# SO. A teardown that reported a removal it did not perform is the same class of
# defect as a create that reported an install it did not perform.
#
# NO TOOL VERSION ASSERT HERE, for the same reason the base profile's teardown
# has none: removing objects works with any supported client, and a teardown must
# never be the thing that refuses to run. A learner who cannot delete what they
# installed is worse off than one running a slightly skewed client.
#
# Usage:
#   bash teardown.sh
#   SIZE=16 bash teardown.sh
#   SERVING_OVER_BUDGET=1 bash teardown.sh        # author-only
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
LABS_TOOLS="${LABS_DIR}/tools"
HARNESS_DIR="${LABS_DIR}/serving/sim-router"

. "${LABS_TOOLS}/size-gate.sh"
assert_size

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"
export CONTEXT

NAMESPACE="${NAMESPACE:-spike-03}"
export NAMESPACE

REQUIRED_SIZE=16
SERVING_OVER_BUDGET="${SERVING_OVER_BUDGET:-0}"
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

GATE_OUT="$(bash "${LABS_TOOLS}/size-gate.sh" "${REQUIRED_SIZE}" -- true)"

if [ -n "${GATE_OUT}" ] && [ "${SERVING_OVER_BUDGET}" != "1" ]; then
  printf '%s\n' "${GATE_OUT}"
  # Say what was looked at, not merely that nothing happened. A no-op that
  # reported "nothing to remove" without having looked would read identically
  # on a cluster where the fence had been bypassed.
  LEFT=0
  if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    LEFT="$(kc -n "${NAMESPACE}" get deploy --no-headers 2>/dev/null | /usr/bin/grep -c . || true)"
    LEFT="${LEFT:-0}"
  fi
  if [ "${LEFT}" -ne 0 ]; then
    echo "NOTE: namespace '${NAMESPACE}' carries ${LEFT} Deployment(s) at a size where this layer is fenced."
    echo "      Removing them, because something installed them and the fence says they do not belong here."
    kc delete namespace "${NAMESPACE}" --wait=true --timeout="${NS_TIMEOUT}s" >/dev/null 2>&1 || true
  fi
  echo "addon-serving teardown at SIZE=${SIZE}: NOTHING TO REMOVE — the layer is fenced at this size and was never installed."
  echo "  checked: namespace '${NAMESPACE}' carried ${LEFT} Deployment(s) before this ran."
  echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
  echo "  confirm the base survived:  bash ${PROFILE_DIR}/verify.sh"
  echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"
  exit 0
fi

# The harness owns the removal, and it removes by NAMESPACE rather than by file
# deliberately: a partially-applied run would leave strays that a per-file delete
# would miss. Its output is PREFIXED so exactly one reporting contract speaks at
# column 0 here.
set +e
bash "${HARNESS_DIR}/setup.sh" teardown 2>&1 | sed 's/^/  harness| /'
HARNESS_RC="${PIPESTATUS[0]}"
set -e
if [ "${HARNESS_RC}" -ne 0 ]; then
  echo "FAIL: the serving harness's teardown exited ${HARNESS_RC}; the layer may be partly removed." >&2
  echo "      Re-run with the harness's own output unprefixed for the full detail:" >&2
  echo "        bash ${HARNESS_DIR}/setup.sh teardown" >&2
  exit 1
fi

# Post-condition, asserted rather than assumed: a Terminating namespace accepts
# `kubectl apply` and creates nothing, so a later re-create that trusted apply's
# exit code would report an empty run as a successful one.
_waited=0
while [ "${_waited}" -lt "${NS_TIMEOUT}" ]; do
  if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' is still present ${_waited}s after the teardown returned." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NAMESPACE} -o yaml" >&2
  echo "      Re-run:  bash ${ADDON_DIR}/teardown.sh" >&2
  exit 1
fi

echo "addon-serving layer torn down: the tokenizer service, the simulator fleet, the endpoint picker, the router's own data plane and namespace '${NAMESPACE}' are removed."
echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
echo "  confirm the base survived:  bash ${PROFILE_DIR}/verify.sh"
echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"

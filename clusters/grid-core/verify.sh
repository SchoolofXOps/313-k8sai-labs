#!/usr/bin/env bash
# grid-core profile — verify
# Asserts the grid-core cluster exists, every node is Ready, the node count
# AGREES WITH THE REQUESTED SIZE, the kubelet reports a 1.37.x version (the
# pin), the API server answers /readyz, and all three create-time-immutable
# feature gates are on.
# Read-only and idempotent — it creates and changes nothing.
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to
# stderr and exits 1. On success exactly ONE line beginning `OK:` is printed;
# anything after it is an indented informational probe, not an assertion.
#
# THE NODE COUNT IS READ FROM THE CLUSTER, never trusted from the environment.
# That is the whole value of this assert rather than a defensive flourish: one
# cluster NAME serves both sizes, so the only thing separating a SIZE=8 cluster
# from a SIZE=16 one is a read. A verify.sh that compared $SIZE against itself
# would pass happily on a cluster created at the other size — which is the exact
# failure gates_enabled_on_cluster() exists to prevent for feature gates, in a
# second place.
#
# Usage:
#   bash verify.sh                # verify at the default SIZE
#   SIZE=16 bash verify.sh        # expect 1 control-plane + 2 workers
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export SIZE=8                           # or 16. Must match the create.
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # isolated; never touch other clusters
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
# cluster. Both asserts are SOURCED from the one place that owns them.
LABS_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)"
. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

# 1 control-plane + the per-size worker count, read from course.config.json.
WORKER_NODES="$(size_value worker_nodes)"
EXPECTED_NODES=$((1 + WORKER_NODES))

# The budget travels with the size here too, so a measurement taken by anything
# this script is the parent of is adjudicated against the right number. See
# create.sh for what the export does and does not reach. measure.sh's own
# default stays 4500, which is correct for the unqualified 8 GB case.
BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

RECREATE="SIZE=${SIZE} bash ${PROFILE_DIR}/teardown.sh && SIZE=${SIZE} bash ${PROFILE_DIR}/create.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "FAIL: kind cluster '${CLUSTER_NAME}' not found. Run: SIZE=${SIZE} bash ${PROFILE_DIR}/create.sh" >&2
  exit 1
fi

echo "Waiting for every REAL node to be Ready ..."
if ! kc wait --for=condition=Ready node -l '!type' --all --timeout=180s; then
  echo "FAIL: the real nodes did not all reach Ready within 180s. Inspect: kubectl --context ${CONTEXT} get nodes; then ${RECREATE}" >&2
  exit 1
fi

# The size cross-check. Read, then compare. The message names BOTH numbers,
# because "wrong node count" without them sends a reader to the wrong place:
# the usual cause is a correct cluster being verified at the other SIZE, not a
# broken cluster.
#
# REAL NODES ONLY, and this selector is load-bearing rather than tidy.
# MEASURED 2026-10-14, CI run 38491797177 on both arms and reproduced locally:
# with the queueing layer applied, this script read ELEVEN nodes against an
# expected two and failed — because `addon-kueue-kwok` adds nine SIMULATED Node
# objects, and a simulated node is not a machine. The remedy this FAIL printed
# was also actively wrong: it told the reader to tear the cluster down and
# recreate it, which would have destroyed the layer they had just applied, for a
# disagreement that did not exist.
#
# `-l '!type'` is the project's existing idiom for the distinction, not a new
# one: `addons/kueue-kwok/verify.sh` already selects real nodes with `!type` and
# the simulated fleet with `type=kwok`, and `labs/kwok/attach/setup.sh` is what
# puts `type=kwok` on every fake node. This file was the one place that counted
# both kinds together, which made the base profile's verify NON-COMPOSABLE with
# any layer that adds Node objects — and the base is re-verified under an
# applied layer by design, both in the CI job and in every layer's `next:` line.
#
# The assertion is not weakened by the selector; it is narrowed to what it
# always meant. It still fails on a cluster created at the other SIZE, which is
# the failure it exists to catch, and the simulated fleet is counted — exactly,
# against its own declared size — by the layer that creates it.
NODE_COUNT="$(kc get nodes -l '!type' --no-headers | wc -l | tr -d ' ')"
SIMULATED_COUNT="$(kc get nodes -l type=kwok --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${NODE_COUNT}" -ne "${EXPECTED_NODES}" ]; then
  echo "FAIL: SIZE=${SIZE} expects ${EXPECTED_NODES} real nodes (1 control-plane + ${WORKER_NODES} worker(s)), found ${NODE_COUNT} on the cluster." >&2
  echo "      The count was READ from the cluster, not taken from SIZE, so this is a real disagreement." >&2
  echo "      Simulated nodes are excluded from it and are not the cause: ${SIMULATED_COUNT} carry the type=kwok label." >&2
  echo "      Either verify at the size this cluster was CREATED at, or recreate at this one:" >&2
  echo "        ${RECREATE}" >&2
  echo "      Node count is create-time-immutable — kind has no node-add path, so it cannot be adjusted in place." >&2
  exit 1
fi

if ! kc get node "${CLUSTER_NAME}-worker" >/dev/null 2>&1; then
  echo "FAIL: worker node '${CLUSTER_NAME}-worker' not found. Recreate: ${RECREATE}" >&2
  exit 1
fi

# EVERY real node, not `.items[0]` of an unordered list. The old form read the
# first node the API server happened to return, and with a simulated fleet
# applied that list contains nodes whose kubeletVersion is FABRICATED by the
# kwok controller — it only kept reading the control plane because
# `grid-core-control-plane` sorts before `kwok-node-0`, which is an accident of
# naming and not a property anything asserts. The set is read and compared, so a
# single drifted node cannot hide behind a compliant one either.
KUBELET_VERSIONS="$(kc get nodes -l '!type' \
  -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' \
  | sort -u | tr '\n' ' ' | sed 's/ *$//')"
KUBELET_VERSION="${KUBELET_VERSIONS%% *}"
for _v in ${KUBELET_VERSIONS}; do
  case "${_v}" in
    v1.37.*) : ;;
    *)
      echo "FAIL: a real node's kubelet reports ${_v}, but this course pins Kubernetes 1.37.x." >&2
      echo "      Versions across the ${NODE_COUNT} real node(s): ${KUBELET_VERSIONS}" >&2
      echo "      Check KIND_IMAGE, then ${RECREATE}" >&2
      exit 1
      ;;
  esac
done

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

echo "OK: grid-core verified at SIZE=${SIZE} — ${NODE_COUNT}/${EXPECTED_NODES} real nodes Ready, kubelet ${KUBELET_VERSION}, API server /readyz healthy, all 3 feature gates enabled (${FEATURE_GATES// /, })."
echo "  context:    ${CONTEXT}"
echo "  kubeconfig: ${KUBECONFIG}"
echo "  size:       SIZE=${SIZE} -> 1 control-plane + ${WORKER_NODES} worker(s), read back from the cluster"
if [ "${SIMULATED_COUNT}" -gt 0 ]; then
  echo "  simulated:  ${SIMULATED_COUNT} node(s) carry type=kwok and are EXCLUDED from every assertion above."
  echo "              They are not machines, they carry no kubelet, and nothing on them is a GPU. The layer"
  echo "              that created them is what counts them, against its own declared fleet size."
else
  echo "  simulated:  none — no node on this cluster carries the type=kwok label"
fi
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
kc get nodes

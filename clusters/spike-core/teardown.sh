#!/usr/bin/env bash
# spike-core profile — teardown
# Deletes the spike-core kind cluster entirely, and every workload with it.
#
# Mechanism: `kind delete cluster` removes the node containers, so the cgroups
# measure.sh reads disappear with them — read any measurement BEFORE tearing
# down, never after.
#
# ONE CLUSTER PROFILE AT A TIME (ROADMAP § Standing Constraints #1): run this
# before creating a different profile, and at the end of every plan, so no
# later plan inherits a running cluster.
#
# Usage:
#   bash teardown.sh
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#
# Idempotent: exits 0 when the cluster is already absent.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# See create.sh. No version assert here on purpose: deleting a cluster works
# with either kind build, and a teardown must never be the thing that refuses
# to run. Override with LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

CLUSTER_NAME="spike-core"

# grep -qx (exact whole line), never grep -q: 'spike-core' must not match a
# future 'spike-core-dra'.
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "spike-core profile torn down: cluster '${CLUSTER_NAME}' deleted."
else
  echo "kind cluster '${CLUSTER_NAME}' already absent — nothing to do."
fi

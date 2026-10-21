#!/usr/bin/env bash
# grid-sandbox profile — teardown
# Deletes the grid-sandbox kind cluster AND RECREATES THE BASE PROFILE, so the
# learner is never left with no cluster and continuity returns to the base
# without a second command.
#
# THIS IS THE ONLY TEARDOWN IN THE COURSE THAT CREATES ANYTHING, and the
# reason is the whole reason a dedicated profile is safe here. grid-sandbox
# exists only because the sandbox runtime handler is written into a node
# image's containerd configuration at IMAGE BUILD TIME and cannot be applied
# to a running cluster. To exist it has to REPLACE the base on a
# one-profile-at-a-time machine — grid-sandbox/create.sh deletes grid-core to
# make room. A teardown that only deleted the sandbox would leave the learner
# with nothing, having silently consumed the cluster every other module's
# addon layers apply onto. ROADMAP Success Criterion 1 requires the restore,
# and this is where it happens.
#
# THE RECREATE IS NOT FIRE-AND-FORGET. It runs the base profile's own
# verify.sh and asserts the `OK:` line that script prints, then FAILs naming
# the manual command if it does not appear. A teardown that deleted the
# sandbox and left a HALF-CREATED base is worse than one that left the sandbox
# running: the learner's next command fails against a cluster they believe
# exists, and nothing in between told them otherwise.
#
# THE EMPTY CASE CONVERGES, it does not short-circuit. With no grid-sandbox
# cluster present this script still ends with a running, verified base. That
# is the difference between a teardown that is IDEMPOTENT — same end state
# however many times you run it — and one that is merely TOLERANT of being run
# twice. Converging is what makes "run the teardown" a safe instruction to
# give a learner whose machine is in an unknown state.
#
# NO VERSION ASSERT AND NO SIZE ASSERT HERE, for the reason the base profile's
# teardown already states: deleting a cluster works with either kind build,
# the cluster name does not vary with SIZE, and a teardown must never be the
# thing that refuses to run. SIZE is still READ — it is an exported variable
# by contract — and passed through to the base profile's create and verify, so
# a learner who worked at SIZE=16 gets a SIZE=16 base back. If SIZE is unset
# the base profile's own default applies; if it is invalid the base profile's
# own assert_size rejects it, with the right message, at the point the value
# is actually used.
#
# Mechanism note: `kind delete cluster` removes the node containers, so the
# cgroups labs/tools/measure.sh reads disappear with them — take any
# measurement BEFORE running this, never after.
#
# Usage:
#   bash teardown.sh
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   SKIP_BASE_RECREATE=1                    # delete only; see below
#
# SKIP_BASE_RECREATE exists for exactly one caller: a harness that is about to
# create a different profile itself, or a measurement run that wants the VM
# empty. It is NOT the learner's path, and the default is the restore.
#
# Idempotent: exits 0 when the sandbox cluster is already absent, and still
# converges on a verified base.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# See create.sh. No version assert here on purpose. Override with
# LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

CLUSTER_NAME="grid-sandbox"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"
BASE_PROFILE="grid-core"
BASE_PROFILE_DIR="${LABS_DIR}/clusters/${BASE_PROFILE}"
# The base profile's OWN kubeconfig. An inherited KUBECONFIG pointing at
# /tmp/grid-sandbox.kubeconfig would make the recreated base write its context
# into the deleted profile's file, and the learner's next `kubectl` would read
# a context for a cluster that no longer exists.
BASE_KUBECONFIG="${BASE_KUBECONFIG:-/tmp/grid-core.kubeconfig}"
SKIP_BASE_RECREATE="${SKIP_BASE_RECREATE:-}"

# Whole-line match through a captured variable, never `kind get clusters |
# grep -qx`: 'grid-core' must not match 'grid-core-dra', and under
# `set -o pipefail` a successful grep match returns 141 via SIGPIPE.
kind_cluster_exists() {
  local clusters
  clusters="$(kind get clusters 2>/dev/null || true)"
  case "
${clusters}
" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

if kind_cluster_exists "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "grid-sandbox profile torn down: cluster '${CLUSTER_NAME}' deleted."
else
  echo "kind cluster '${CLUSTER_NAME}' already absent — nothing to delete."
fi

if [ -n "${SKIP_BASE_RECREATE}" ]; then
  echo "SKIP_BASE_RECREATE is set — the base profile '${BASE_PROFILE}' was NOT recreated."
  echo "  You have no cluster. Restore it with:"
  echo "    bash ${BASE_PROFILE_DIR}/create.sh"
  exit 0
fi

echo
echo "Restoring the base profile '${BASE_PROFILE}' — you are never left with no cluster."
if kind_cluster_exists "${BASE_PROFILE}"; then
  echo "  '${BASE_PROFILE}' is already running; create.sh will reuse it."
fi

RESTORE_BY_HAND="bash ${BASE_PROFILE_DIR}/create.sh && bash ${BASE_PROFILE_DIR}/verify.sh"

if ! env KUBECONFIG="${BASE_KUBECONFIG}" bash "${BASE_PROFILE_DIR}/create.sh"; then
  echo "FAIL: the base profile '${BASE_PROFILE}' could not be recreated after the sandbox was deleted." >&2
  echo "      YOU CURRENTLY HAVE NO CLUSTER. Run this by hand and read its output:" >&2
  echo "        ${RESTORE_BY_HAND}" >&2
  exit 1
fi

# The recreate is only finished when the base profile's OWN verify says so.
# Captured, then matched with `case` against the `OK:` line that script's
# reporting contract guarantees — never `| grep -q`, which returns 141 on a
# successful match under `set -o pipefail`.
echo
echo "Verifying the restored base profile with its own verify.sh ..."
BASE_VERIFY_OUT="$(env KUBECONFIG="${BASE_KUBECONFIG}" bash "${BASE_PROFILE_DIR}/verify.sh" 2>&1 || true)"
printf '%s\n' "${BASE_VERIFY_OUT}" | sed -n 's/^/  | /p'
case "
${BASE_VERIFY_OUT}
" in
  *"
OK: "*) : ;;
  *)
    echo "FAIL: '${BASE_PROFILE}' was recreated but its own verify.sh did not print its OK: line." >&2
    echo "      The sandbox is deleted and the base is HALF-CREATED, which is worse than either" >&2
    echo "      end state on its own: your next command will fail against a cluster you believe" >&2
    echo "      exists. Recreate it by hand and read the output:" >&2
    echo "        bash ${BASE_PROFILE_DIR}/teardown.sh && ${RESTORE_BY_HAND}" >&2
    exit 1
    ;;
esac

echo
echo "OK: grid-sandbox torn down and '${BASE_PROFILE}' restored and verified — continuity is back on the base."
echo "  base kubeconfig: ${BASE_KUBECONFIG}, context: kind-${BASE_PROFILE}"
echo "  the sandbox node image is left in the local image store; rebuilding is not needed to"
echo "  re-create this profile, only ${PROFILE_DIR}/create.sh is."

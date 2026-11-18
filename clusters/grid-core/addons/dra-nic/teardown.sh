#!/usr/bin/env bash
# addon-dra-nic — teardown.
#
# READ THIS SENTENCE BEFORE RUNNING IT. This removes the synthetic-NIC LAYER —
# its namespace and everything in it, its cluster-scoped RBAC, its validating
# admission policy, its DeviceClass and the ResourceSlices its driver published
# — AND IT LEAVES addon-dra AND THE grid-core CLUSTER RUNNING. It removes only
# what create.sh applied: every object it deletes is named in this layer's own
# rendered-pinned.yaml, or is a ResourceSlice whose driver is this layer's.
#
# Then it re-runs labs/clusters/grid-core/verify.sh and addons/dra/verify.sh,
# because a layer teardown that left the base or the layer under it broken has
# not finished its job. addons/dra/verify.sh only passes once this layer's
# slices are gone, so that second read is also the proof they are.
#
# No tool version assert here, for the base profile's reason: a teardown must
# never be the thing that refuses to run.
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

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
DRA_DIR="${PROFILE_DIR}/addons/dra"

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NAMESPACE="dra-example-driver-nic"
VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"

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

DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" 2>/dev/null | head -1 || true)"
if [ ! -f "${RENDERED}" ]; then
  echo "FAIL: ${RENDERED} is absent, so this teardown cannot know what create.sh applied." >&2
  echo "      It removes only what that file names and will not guess at names." >&2
  echo "      Restore it (git checkout -- ${RENDERED}) and re-run: bash ${ADDON_DIR}/teardown.sh" >&2
  exit 1
fi

# Every wait is BOUNDED (`--wait=true` alone waits forever), and a bound is not
# a post-condition: the absence asserts below are what the closing line rests on.
kc delete -f "${RENDERED}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
kc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true

# A ResourceSlice is owned by its Node, not by the namespace. The plugin deletes
# its own slices on graceful shutdown; whatever outlives that is removed by name,
# selected by THIS driver only, so addon-dra's slices are never touched.
if [ -n "${DRIVER_NAME}" ]; then
  _waited=0
  LEFTOVER=0
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

# --- the closing line has to be earned ---------------------------------------
rc=0
_waited=0
while [ "${_waited}" -lt 180 ]; do
  if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' is still present after ${_waited}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NAMESPACE} -o yaml" >&2
  rc=1
fi
# Every object the committed file names must now be gone. `kubectl get -f` on a
# file whose objects are all absent prints nothing on stdout; the list call's
# own failure is told apart from "none left" by asking the API server first.
if kc get --raw='/readyz' >/dev/null 2>&1; then
  SURVIVORS="$(kc get -f "${RENDERED}" -o name --ignore-not-found 2>/dev/null || true)"
  if [ -n "${SURVIVORS}" ]; then
    echo "FAIL: objects named in ${RENDERED} are still present after teardown:" >&2
    printf '      %s\n' ${SURVIVORS} >&2
    rc=1
  fi
else
  echo "FAIL: the API server on '${CONTEXT}' did not answer, so removal cannot be verified." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  rc=1
fi
if [ -n "${DRIVER_NAME}" ]; then
  if _slices="$(kc get resourceslices -o jsonpath="{range .items[?(@.spec.driver=='${DRIVER_NAME}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null)"; then
    _left="$(printf '%s\n' "${_slices}" | /usr/bin/grep -c . || true)"
    if [ "${_left:-0}" -ne 0 ]; then
      echo "FAIL: ${_left} ResourceSlice(s) for driver '${DRIVER_NAME}' survived teardown." >&2
      echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices" >&2
      rc=1
    fi
  else
    echo "FAIL: could not list ResourceSlices on context '${CONTEXT}', so their removal cannot be verified." >&2
    rc=1
  fi
else
  echo "FAIL: driverName is unreadable from ${VALUES_FILE}, so this driver's ResourceSlices cannot be asserted gone." >&2
  rc=1
fi
if [ "${rc}" -ne 0 ]; then
  echo "FAIL: addon-dra-nic teardown left objects behind, or could not verify removal." >&2
  echo "      Re-run: bash ${ADDON_DIR}/teardown.sh" >&2
  exit 1
fi

echo "addon-dra-nic layer torn down: namespace '${NAMESPACE}', its cluster-scoped RBAC and admission policy, DeviceClass '${DRIVER_NAME}' and the ResourceSlices it published are removed."
echo "  re-verifying what this layer was applied onto — the base, then addon-dra:"

# --- re-verify what is underneath ---------------------------------------------
bash "${PROFILE_DIR}/verify.sh"
if kc get namespace dra-example-driver >/dev/null 2>&1; then
  bash "${DRA_DIR}/verify.sh"
else
  echo "NOTE: addon-dra is not applied on '${CLUSTER_NAME}' (no namespace dra-example-driver), so it is not re-verified."
fi

echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"

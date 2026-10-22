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
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
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
  #
  # Every wait here is BOUNDED. `--wait=true` alone means `--timeout=0s`, which
  # waits forever, and the namespace holds a DaemonSet whose kubelet-plugin
  # socket can keep a Pod's finalizer from clearing. A teardown that never
  # returns cannot be rescued by `|| true` — nothing returns to it — and a
  # teardown must never be the thing that refuses to run. A BOUND IS NOT A
  # POST-CONDITION: an expired wait is swallowed here, so the absence asserts in
  # the final step — not this delete's exit code — are what the closing line
  # rests on. Without them a 180s timeout would be a silent false success.
  kc delete -f "${RENDERED}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
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

kc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true

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

# --- the closing line has to be earned ---------------------------------------
# Every delete above is bounded and `|| true`d, so none of their exit codes says
# anything. What says the layer is gone is OBJECT STATE, read back here: the
# namespace (polled, because a namespace delete is asynchronous and a
# kubelet-plugin finalizer is the thing most likely to hold it Terminating), then
# every cluster-scoped object the rendered manifest created, by name. Any
# survivor is a FAIL with the inspect command, never a NOTE — the next create
# meets a Terminating namespace, and an apply into one exits 0 and creates
# nothing, so a teardown that claimed success here would poison the next run
# while leaving a success line in the learner's scrollback.
rc=0
_waited=0
while [ "${_waited}" -lt 180 ]; do
  if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  _phase="$(kc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "FAIL: namespace '${NAMESPACE}' is still present (phase ${_phase:-unknown}) after ${_waited}s —" >&2
  echo "      most likely Terminating on a kubelet-plugin finalizer the driver did not clear." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NAMESPACE} -o yaml" >&2
  echo "               kubectl --context ${CONTEXT} -n ${NAMESPACE} get pods -o wide" >&2
  rc=1
fi
# The DeviceClass is asserted by name ONLY when the name is known — the same
# guard the ResourceSlice sweep above carries. DRIVER_NAME comes from a sed over
# values.yaml with `|| true`, so it is empty when that file is missing or its
# key moved; an empty name would turn `kc get deviceclasses.resource.k8s.io`
# into a type-wide list, which exits 0 whether or not anything exists, and a
# clean teardown would print a blank-named FAIL and exit 1.
if [ -z "${DRIVER_NAME}" ]; then
  echo "NOTE: driverName is unreadable from ${VALUES_FILE}, so the DeviceClass (and the ResourceSlices)" >&2
  echo "      cannot be asserted by name. Inspect: kubectl --context ${CONTEXT} get deviceclasses.resource.k8s.io" >&2
fi
for _o in "clusterrole dra-example-driver-role" \
          "clusterrolebinding dra-example-driver-role-binding" \
          "validatingadmissionpolicy.admissionregistration.k8s.io resourceslices-policy-dra-example-driver" \
          "validatingadmissionpolicybinding.admissionregistration.k8s.io resourceslices-policy-dra-example-driver" \
          "deviceclasses.resource.k8s.io ${DRIVER_NAME}"; do
  # An entry whose name is empty ends in the separating space; skip it rather
  # than list the whole type.
  case "${_o}" in *" ") continue ;; esac
  # Intentional word-splitting: each entry is "<kind> <name>".
  # shellcheck disable=SC2086
  if kc get ${_o} >/dev/null 2>&1; then
    echo "FAIL: ${_o} is still present after teardown." >&2
    rc=1
  fi
done
# The ResourceSlices, re-read — the closing line names them, so they are
# asserted like everything else it names. The sweep above is a bounded poll and
# a best-effort delete-by-name, which proves nothing. The list call's exit
# status is kept SEPARATE from the count: `kc get ... | grep -c . || true`
# reads an unreachable API server as "zero slices", and a post-condition that
# cannot tell "none left" from "could not look" is not one.
if [ -n "${DRIVER_NAME}" ]; then
  if _slices="$(kc get resourceslices -o jsonpath="{range .items[?(@.spec.driver=='${DRIVER_NAME}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null)"; then
    _left="$(printf '%s\n' "${_slices}" | /usr/bin/grep -c . || true)"
    if [ "${_left:-0}" -ne 0 ]; then
      echo "FAIL: ${_left} ResourceSlice(s) for driver '${DRIVER_NAME}' survived teardown — the next" >&2
      echo "      layer's verify would read a fleet that is not there." >&2
      echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices" >&2
      rc=1
    fi
  else
    echo "FAIL: could not list ResourceSlices on context '${CONTEXT}', so their removal cannot be verified." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get resourceslices" >&2
    rc=1
  fi
fi
if [ "${rc}" -ne 0 ]; then
  echo "FAIL: addon-dra teardown left objects behind, or could not verify removal." >&2
  echo "      Re-run: bash ${ADDON_DIR}/teardown.sh" >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get clusterrole,clusterrolebinding,deviceclasses.resource.k8s.io | /usr/bin/grep dra-example" >&2
  exit 1
fi

echo "addon-dra layer torn down: namespace '${NAMESPACE}', its cluster-scoped RBAC and admission policy, DeviceClass '${DRIVER_NAME}' and the ResourceSlices it published are removed."
echo "  the kind cluster '${CLUSTER_NAME}' IS STILL RUNNING — this is a layer teardown, not a profile teardown."
echo "  confirm the base survived:  bash ${PROFILE_DIR}/verify.sh"
echo "  delete the cluster itself:  bash ${PROFILE_DIR}/teardown.sh"

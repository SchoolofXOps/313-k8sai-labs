#!/usr/bin/env bash
# grid-sandbox profile — verify
# Asserts the grid-sandbox cluster exists, every node is Ready, the node count
# AGREES WITH THE REQUESTED SIZE, the kubelet reports a 1.37.x version (the
# pin), the API server answers /readyz, the sandbox runtime binary is present
# INSIDE the node container, the RuntimeClass resolves to the handler the node
# image registered, and — the assertion the whole script exists for — a Pod
# running under that RuntimeClass reports the SANDBOX KERNEL IDENTITY read
# from INSIDE ITSELF.
#
# A RUNNING PHASE PROVES NOTHING. This is the single most important sentence
# in this file. A RuntimeClass is only a NAME; the kubelet hands its `handler`
# to containerd, which looks that name up among its own runtime handlers. If
# the handler is absent or the stanza was written in a dialect containerd
# ignored, containerd serves the Pod with the DEFAULT RUNTIME and the Pod
# reaches Running exactly as it would have under the sandbox. A successful
# create, a Ready node, a Running Pod and a healthy cluster are all
# BYTE-IDENTICAL in the silent-fallback case. The kernel identity read from
# within the Pod is the only evidence that distinguishes them.
#
# The assertion below is LIFTED from .github/workflows/arch-matrix.yml rather
# than re-invented, so the laptop arm and the CI arm assert the same thing on
# the same evidence. SPIKE-01 proved nested runsc on arm64 AND amd64 by
# exactly this read: `Linux version 4.19.0-gvisor` from inside the Pod against
# host kernels 6.18.36-0-virt and 6.17.0-1022-azure. See
# planning/lab-tests/spike-01-gvisor.md.
#
# A CAPABILITY DIFFERENTIAL IS NOT PROOF OF ISOLATION, and this script
# deliberately does not assert one. The natural next assertion — "this file is
# unreadable inside and readable outside, therefore it is isolated" — is the
# overclaim SPIKE-01's own "What the probe does not establish" section exists
# to forbid. What the differential establishes is that the workload is
# executing against a DIFFERENT KERNEL, implemented by the sandbox's
# user-space kernel. It establishes nothing about kernel escapes, side
# channels, supply chain, or isolation under load, none of which were tested.
# So this script asserts IDENTITY, which is a fact, and never SECURITY, which
# is a judgement against a threat model nobody here declared.
#
# ORDER IS LOAD-BEARING: the runtime binary is proven present inside the node
# BEFORE a Pod is asked to use it. Without that step a failure at the Pod
# stage cannot distinguish a missing binary from a containerd
# misconfiguration, and those have different remedies — rebuild the image
# versus fix the handler stanza.
#
# Read-only with ONE exception, stated rather than hidden: it applies the
# RuntimeClass and creates a probe Pod, then deletes the probe Pod. The
# RuntimeClass is left in place because it is the object the lab consumes;
# the Pod is a verification artefact and is cleaned up.
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to
# stderr and exits 1. On success exactly ONE line beginning `OK:` is printed,
# and it NAMES THE KERNEL IDENTITY it read from inside the Pod; anything after
# it is an indented informational probe, not an assertion.
#
# THE NODE COUNT IS READ FROM THE CLUSTER, never trusted from the environment,
# for the reason the base profile's verify.sh states: one cluster NAME serves
# both sizes, so a verify that compared $SIZE against itself would pass on a
# cluster created at the other size.
#
# Usage:
#   bash verify.sh                # verify at the default SIZE
#   SIZE=16 bash verify.sh        # expect 1 control-plane + 2 workers
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export SIZE=8                           # or 16. Must match the create.
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/grid-sandbox.kubeconfig   # isolated; never touch other clusters
#
# Idempotent: safe to re-run any number of times.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# See create.sh for the full note. Short version: the stale /usr/local/bin/kind
# (v0.32.0) and ~/.rd/bin/kubectl shims resolve FIRST from a login shell.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

LABS_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)"
. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-sandbox"
CONTEXT="${CONTEXT:-kind-grid-sandbox}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-sandbox.kubeconfig}"

# The runtime handler name. ONE literal, used for the binary probe, the
# RuntimeClass object and the Pod's runtimeClassName, because a mismatch
# between any two of them is the silent-fallback failure this script exists to
# catch and three copies is three chances to introduce it.
RUNTIME_HANDLER="${RUNTIME_HANDLER:-runsc}"
RUNTIMECLASS_FILE="${LABS_DIR}/sandbox/runsc-node/runtimeclass.yaml"

# The substring the sandbox's own kernel reports in /proc/version. The sentry
# presents a fixed synthetic kernel identity; see spike-01-gvisor.md, where it
# read `Linux version 4.19.0-gvisor` on BOTH architectures.
SANDBOX_KERNEL_TOKEN="${SANDBOX_KERNEL_TOKEN:-gvisor}"

# Digest-pinned, per PLAT-01, and the same digest the CI arm uses so both arms
# probe with the identical workload.
PROBE_IMAGE="${PROBE_IMAGE:-busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e}"
PROBE_POD="${PROBE_POD:-runsc-probe}"

WORKER_NODES="$(size_value worker_nodes)"
EXPECTED_NODES=$((1 + WORKER_NODES))

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

RECREATE="bash ${PROFILE_DIR}/teardown.sh && SIZE=${SIZE} bash ${PROFILE_DIR}/create.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# Whole-line match through a captured variable, never `kind get clusters |
# grep -qx`: under `set -o pipefail` a successful match returns 141 via
# SIGPIPE. Same reason as create.sh.
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found. Run: SIZE=${SIZE} bash ${PROFILE_DIR}/create.sh" >&2
    exit 1
    ;;
esac

echo "Waiting for all nodes to be Ready ..."
if ! kc wait --for=condition=Ready node --all --timeout=180s; then
  echo "FAIL: nodes did not all reach Ready within 180s. Inspect: kubectl --context ${CONTEXT} get nodes; then ${RECREATE}" >&2
  exit 1
fi

NODE_COUNT="$(kc get nodes --no-headers | wc -l | tr -d ' ')"
if [ "${NODE_COUNT}" -ne "${EXPECTED_NODES}" ]; then
  echo "FAIL: SIZE=${SIZE} expects ${EXPECTED_NODES} nodes (1 control-plane + ${WORKER_NODES} worker(s)), found ${NODE_COUNT} on the cluster." >&2
  echo "      The count was READ from the cluster, not taken from SIZE, so this is a real disagreement." >&2
  echo "      Either verify at the size this cluster was CREATED at, or recreate at this one:" >&2
  echo "        ${RECREATE}" >&2
  echo "      Node count is create-time-immutable — kind has no node-add path." >&2
  exit 1
fi

KUBELET_VERSION="$(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
case "${KUBELET_VERSION}" in
  v1.37.*) : ;;
  *)
    echo "FAIL: kubelet reports ${KUBELET_VERSION}, but this course pins Kubernetes 1.37.x." >&2
    echo "      The node image is built FROM a digest-pinned 1.37.0 base; a different minor here" >&2
    echo "      means the image was built from a different base. Rebuild it:" >&2
    echo "        bash ${LABS_DIR}/sandbox/runsc-node/build.sh && ${RECREATE}" >&2
    exit 1
    ;;
esac

if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer. Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  exit 1
fi

# --- the runtime is IN THE NODE, proven before any Pod is asked to use it ----
NODE_CONTAINER="${CLUSTER_NAME}-control-plane"
if [ "${WORKER_NODES}" -gt 0 ]; then NODE_CONTAINER="${CLUSTER_NAME}-worker"; fi
RUNTIME_SEEN="$(docker exec "${NODE_CONTAINER}" "${RUNTIME_HANDLER}" --version 2>&1 || true)"
case "${RUNTIME_SEEN}" in
  *"${RUNTIME_HANDLER}"*) : ;;
  *)
    echo "FAIL: '${RUNTIME_HANDLER} --version' inside the node container '${NODE_CONTAINER}' did not" >&2
    echo "      identify the runtime; it printed: ${RUNTIME_SEEN}" >&2
    echo "      The binary is installed into the node image at BUILD time, so this means the" >&2
    echo "      cluster was created from the wrong image. Check which image the node runs:" >&2
    echo "        docker inspect -f '{{.Config.Image}}' ${NODE_CONTAINER}" >&2
    echo "      then rebuild and recreate:" >&2
    echo "        bash ${LABS_DIR}/sandbox/runsc-node/build.sh && ${RECREATE}" >&2
    exit 1
    ;;
esac

# --- the RuntimeClass object, and the handler name it carries ----------------
kc apply -f "${RUNTIMECLASS_FILE}" >/dev/null
RC_HANDLER="$(kc get runtimeclass "${RUNTIME_HANDLER}" -o jsonpath='{.handler}' 2>/dev/null || true)"
if [ "${RC_HANDLER}" != "${RUNTIME_HANDLER}" ]; then
  echo "FAIL: RuntimeClass '${RUNTIME_HANDLER}' carries handler '${RC_HANDLER}', expected '${RUNTIME_HANDLER}'." >&2
  echo "      The handler name must match, character for character, the containerd runtime" >&2
  echo "      stanza the node image registered. A mismatch does not error: containerd falls" >&2
  echo "      back to the default runtime and the Pod still reaches Running." >&2
  echo "      Fix ${RUNTIMECLASS_FILE} and re-run this script." >&2
  exit 1
fi

# --- the probe Pod, and the one assertion that is not optional ---------------
# Deleted first so a stale Pod from an earlier run cannot answer for this one.
kc delete pod "${PROBE_POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  labels:
    app.kubernetes.io/name: ${PROBE_POD}
    app.kubernetes.io/part-of: grid-sandbox
spec:
  runtimeClassName: ${RUNTIME_HANDLER}
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      command: ["sh", "-c", "sleep 600"]
YAML

if ! kc wait --for=condition=Ready "pod/${PROBE_POD}" --timeout=180s >/dev/null; then
  echo "FAIL: the probe Pod never became Ready under runtimeClassName: ${RUNTIME_HANDLER}." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} describe pod ${PROBE_POD}" >&2
  echo "      A Pod stuck Pending usually means no node admits the RuntimeClass; a Pod that" >&2
  echo "      fails to start usually means the handler stanza is malformed." >&2
  kc describe pod "${PROBE_POD}" >&2 || true
  exit 1
fi

POD_PROC_VERSION="$(kc exec "${PROBE_POD}" -- cat /proc/version 2>&1 || true)"
POD_UNAME_R="$(kc exec "${PROBE_POD}" -- uname -r 2>&1 || true)"
NODE_PROC_VERSION="$(docker exec "${NODE_CONTAINER}" cat /proc/version 2>&1 || true)"

case "${POD_PROC_VERSION}" in
  *"${SANDBOX_KERNEL_TOKEN}"*|*gVisor*|*GVISOR*) : ;;
  *)
    echo "FAIL: /proc/version read from INSIDE the probe Pod reports:" >&2
    echo "        ${POD_PROC_VERSION}" >&2
    echo "      which does not name the sandbox kernel. containerd served this Pod with the" >&2
    echo "      DEFAULT RUNTIME and the Pod is NOT sandboxed — and nothing outside the Pod says" >&2
    echo "      so: the create succeeded, the node is Ready and the Pod is Running." >&2
    echo "      For contrast, the node's own kernel is:" >&2
    echo "        ${NODE_PROC_VERSION}" >&2
    echo "      Check the handler stanza inside the node:" >&2
    echo "        docker exec ${NODE_CONTAINER} tail -n 12 /etc/containerd/config.toml" >&2
    echo "      and the runtime containerd actually used:" >&2
    echo "        docker exec ${NODE_CONTAINER} ctr -n k8s.io containers ls" >&2
    kc delete pod "${PROBE_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    exit 1
    ;;
esac

NODE_IMAGE_IN_USE="$(docker inspect -f '{{.Config.Image}}' "${NODE_CONTAINER}" 2>/dev/null || true)"

kc delete pod "${PROBE_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

echo "OK: grid-sandbox verified at SIZE=${SIZE} — ${NODE_COUNT}/${EXPECTED_NODES} nodes Ready, kubelet ${KUBELET_VERSION}, API server /readyz healthy, RuntimeClass ${RUNTIME_HANDLER} resolves, and the probe Pod reported the kernel identity ${POD_UNAME_R} from INSIDE itself."
echo "  /proc/version in-Pod:  ${POD_PROC_VERSION}"
echo "  /proc/version on node: ${NODE_PROC_VERSION}"
echo "  node image in use:     ${NODE_IMAGE_IN_USE}"
echo "  context:    ${CONTEXT}"
echo "  kubeconfig: ${KUBECONFIG}"
echo "  size:       SIZE=${SIZE} -> 1 control-plane + ${WORKER_NODES} worker(s), read back from the cluster"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "  NOTE: the two kernel lines above are an IDENTITY difference, not a security result."
echo "        A capability differential observed inside the sandbox is not proof of isolation."
kc get nodes

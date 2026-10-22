#!/usr/bin/env bash
# addon-dataplane — apply the STORAGE DATA-PATH layer onto a running grid-core.
#
# THIS IS A LAYER, NOT A PROFILE. It creates no cluster. It applies onto the
# cluster `labs/clusters/grid-core/create.sh` already made, and its teardown.sh
# removes the layer and leaves that cluster running.
#
# WHY IT IS A LAYER, stated here so a later phase does not re-derive it. The
# only create-time candidate the storage work has is the worker's bind mount —
# `extraMounts` is an argument to `docker run` for the node container, so it
# exists only if it was present when the node was created, and it cannot be
# added to a running cluster. THE BASE PROFILE ALREADY CARRIES IT: the host
# directory exists on the VM, the mount costs no measured memory, and
# labs/storage/four-path/run.sh carries the error message proving the constraint
# was hit for real when the mount was absent. Nothing else the storage lab needs
# is create-time — the secondary-network pieces are custom resources and daemon
# sets, and the NUMA-alignment piece is hardware-only and out of scope. So a
# dedicated profile is forced ONLY if the base deliberately DECLINES a free
# mount, and declining a free mount to manufacture a profile is the inverse of
# the admission test.
#
# WHAT IT APPLIES — four storage paths, each a server and/or a client workload
# in one namespace, plus the probe the clients run:
#   s3        an S3-PROTOCOL object store, reached over HTTP on the Pod network
#   nfs       an in-cluster userspace-Ganesha server dynamically provisioning an
#             RWX claim
#   pvc       a claim on the cluster's default StorageClass
#   hostpath  a Pod volume onto the node's create-time bind mount, so the
#             payload lands on the host filesystem with no CSI layer and no
#             container-overlay layer in between
#
# THE OBJECT-STORAGE PATH IS NAMED FOR ITS PROTOCOL, NEVER FOR A VENDOR. The
# protocol is what is being taught, and the previous stand-in's community image
# is no longer anonymously pullable from any of its three registries — which is
# why the pin changed and why a vendor name in a path label ages badly. The pin
# is an `@sha256` multi-architecture index digest at an exact release, so the
# same reference resolves on this arm64 host and on an amd64 runner.
#
# TEARDOWN ORDERING IS AN ASSERTION, NOT A CONVENTION. Deleting the
# network-filesystem server before its clients DEADLOCKS namespace deletion: the
# client's mount inside the node carries the protocol's default hard option, so
# once the server's cluster IP stops answering, the kubelet's unmount never
# returns and the namespace sits Terminating forever. That is a measured
# Phase-1 finding, and the failure presents as a HANG rather than an error.
# teardown.sh deletes the clients first for that reason.
#
# WHAT THIS LAYER MAY AND MAY NOT CLAIM. Two scope limits were MEASURED and they
# travel with the layer rather than living in a spike record nobody reads at
# authoring time. They are restated in verify.sh's header and in the generated
# labs/storage/four-path/harness-config.md:
#   * no claim distinguishing the provisioned-volume path from the bind-mount
#     path on this runtime — the default provisioner resolves to a bind mount,
#     not a separate data path, and the measured gap was 3.3% on write and 10.6%
#     on read, inside the spread;
#   * no absolute throughput figure presented as disk performance — the guest
#     cannot evict the host's page cache. What IS reproducible is the tier split
#     (local filesystem above network protocol, 16 of 16 measurements) and the
#     cold first write on the network path, 3.5 MiB/s in both runs and 69-125x
#     slower than steady state.
#
# Usage:
#   bash create.sh                 # apply the layer onto a running grid-core
#   bash create.sh && bash verify.sh
#
# Env:
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale shim
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   SIZE        8 or 16 (default 8) — validated by labs/tools/size-gate.sh
#   NAMESPACE   the layer's namespace (default: the harness's own)
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: re-applying re-applies the same objects and leaves the object set
# unchanged.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
HARNESS_DIR="${LABS_DIR}/storage/four-path"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

# The harness's own namespace and node-side mount path. Read from one place and
# exported so the harness and this layer cannot disagree about either.
NAMESPACE="${NAMESPACE:-spike-02}"
export NAMESPACE
HOSTPATH_NODE="${HOSTPATH_NODE:-/mnt/spike-02-hostpath}"
HOSTPATH_HOST="${HOSTPATH_HOST:-/var/lib/313-spike-02-hostpath}"
WORKER_NODE="${WORKER_NODE:-${CLUSTER_NAME}-worker}"
export HOSTPATH_NODE HOSTPATH_HOST WORKER_NODE

# The four path ids this layer applies. The harness accepts a subset for
# re-measuring one path in isolation; the LAYER always applies all four, because
# a layer that applied three of four would still exit 0 and the missing path
# would simply not be mentioned.
PATHS="s3 nfs pvc hostpath"
export PATHS

kc() { kubectl --context "${CONTEXT}" "$@"; }

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

# --- 1. the base cluster, before anything expensive ---------------------------
# Captured and matched with `case`, never a pipe into a quiet grep under
# `pipefail`: a successful match makes the writer take SIGPIPE and the pipeline
# returns 141.
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer applies ONTO a running cluster and creates none." >&2
    echo "      Run the base profile first:  ${BASE}" >&2
    echo "      then re-run:                 ${APPLY}" >&2
    exit 1
    ;;
esac

if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer on context '${CONTEXT}'." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  echo "      Then:    bash ${PROFILE_DIR}/verify.sh" >&2
  exit 1
fi

if ! kc wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' reached Ready within 180s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes; then ${BASE}" >&2
  exit 1
fi

if ! kc get node "${WORKER_NODE}" >/dev/null 2>&1; then
  echo "FAIL: worker node '${WORKER_NODE}' not found on '${CLUSTER_NAME}'." >&2
  echo "      Every client Pod in this layer is pinned to that node, because the" >&2
  echo "      bind-mount path only exists there." >&2
  echo "      Recreate the base profile: ${BASE}" >&2
  exit 1
fi

for _tool in docker; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required — the mount assertion below reads the node container itself." >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}' yet." >&2
    exit 1
  fi
done

# --- 2. THE MOUNT, READ FROM THE NODE CONTAINER -------------------------------
# Read, never trusted. A learner holding a cluster created before this layer
# existed has a worker with no such mount, and `extraMounts` CANNOT be added to
# a running cluster — so the only honest outcome is a refusal that names the
# recreate command. Asserting it here rather than letting the harness discover it
# means nothing is applied before the refusal.
if ! docker exec "${WORKER_NODE}" sh -c "test -d '${HOSTPATH_NODE}'" >/dev/null 2>&1; then
  echo "FAIL: '${HOSTPATH_NODE}' is not present inside the node container '${WORKER_NODE}'." >&2
  echo "      The bind mount this layer's fourth path needs is CREATE-TIME-ONLY: it is an" >&2
  echo "      argument to the node container's own creation, so it exists only if it was" >&2
  echo "      declared before the cluster was made, and adding it to a running cluster" >&2
  echo "      silently does nothing." >&2
  echo "      It is declared in ${PROFILE_DIR}/create.sh (host '${HOSTPATH_HOST}')," >&2
  echo "      so the remedy is to recreate the base profile:" >&2
  echo "        bash ${PROFILE_DIR}/teardown.sh && ${BASE}" >&2
  echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
  exit 1
fi
MOUNT_SOURCE="$(docker inspect "${WORKER_NODE}" \
  --format "{{range .Mounts}}{{if eq .Destination \"${HOSTPATH_NODE}\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null || true)"
if [ -z "${MOUNT_SOURCE}" ]; then
  echo "FAIL: the node container '${WORKER_NODE}' has no bind whose destination is '${HOSTPATH_NODE}'." >&2
  echo "      The directory exists inside the node but it is not a bind from the host, so" >&2
  echo "      the fourth path would measure the container's own overlay filesystem while" >&2
  echo "      claiming to measure the host filesystem." >&2
  echo "      Recreate the base profile: bash ${PROFILE_DIR}/teardown.sh && ${BASE}" >&2
  exit 1
fi
echo "mount: ${MOUNT_SOURCE} -> ${HOSTPATH_NODE} in ${WORKER_NODE} (create-time bind, carried by the base profile)"

# --- 3. the digest pins the layer is about to apply ---------------------------
# The image that reaches the cluster is decided in TWO places, so this is two
# assertions and the report line says which it is quoting. The committed
# TEMPLATES carry a placeholder where every image goes; the first pass proves
# they hold no tag-form literal of their own, counting a placeholder as a
# reference and not as unpinned. What the placeholder BECOMES is a shell
# variable in run.sh, and each of the three is env-overridable — so the second
# pass asserts every override present in this environment carries an @sha256
# digest, because a template scan passes while `S3_IMAGE=some/image:latest`
# applies a tag. run.sh asserts the fully SUBSTITUTED stream once more at the
# moment it exists, immediately before its own apply; that is the gate that
# sees exactly what is applied, and this layer's report names it rather than
# claiming it. Counted as well as checked: a manifest set with zero image
# references would otherwise satisfy "no unpinned reference".
PIN_REPORT="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(.*\)$/\1/p' \
                "${HARNESS_DIR}"/s3.yaml "${HARNESS_DIR}"/nfs.yaml \
                "${HARNESS_DIR}"/pvc.yaml "${HARNESS_DIR}"/hostpath.yaml \
              | awk 'BEGIN{n=0;bad=0}{n++; if (index($0,"@sha256:")==0 && index($0,"__")==0) bad++}END{printf "image_refs=%d unpinned=%d\n", n, bad}')"
case "${PIN_REPORT}" in
  "image_refs=0 "*|*"unpinned=0") : ;;
  *) : ;;
esac
PIN_REFS="${PIN_REPORT#image_refs=}"; PIN_REFS="${PIN_REFS%% *}"
PIN_BAD="${PIN_REPORT##*unpinned=}"
if [ "${PIN_REFS}" -lt 1 ] || [ "${PIN_BAD}" -ne 0 ]; then
  echo "FAIL: the layer's committed templates report '${PIN_REPORT}'." >&2
  echo "      Every image this layer applies must be an @sha256 digest reference, and a" >&2
  echo "      manifest set with zero references is a truncated or mis-read tree rather" >&2
  echo "      than a clean one. Nothing has been applied." >&2
  exit 1
fi
PIN_OVERRIDES=0
for _var in S3_IMAGE NFS_IMAGE CLIENT_IMAGE; do
  _val="${!_var:-}"
  [ -n "${_val}" ] || continue
  PIN_OVERRIDES=$((PIN_OVERRIDES + 1))
  case "${_val}" in
    *@sha256:*) : ;;
    *)
      echo "FAIL: ${_var} is set in this environment to '${_val}', which carries no @sha256 digest." >&2
      echo "      That value replaces the template placeholder and is what the cluster would pull," >&2
      echo "      and the template assert above cannot see it. Every image this layer applies" >&2
      echo "      must be an @sha256 digest reference. Nothing has been applied." >&2
      echo "      Either unset ${_var} to take the harness's pinned default, or set it to a" >&2
      echo "      digest reference: ${_var}=<repository>@sha256:<64 hex>" >&2
      exit 1
      ;;
  esac
done
echo "digest-pin: ${PIN_REPORT} across the four committed templates (placeholders counted as references); ${PIN_OVERRIDES} image override(s) in this environment, all digest-pinned; the substituted stream is asserted by run.sh before its apply"

# --- 4. apply, by driving the harness rather than duplicating it --------------
# The harness owns the probe, the manifests, the placeholder substitution and
# the namespace-Terminating wait. `apply` is its install half with no
# measurement taken: an apply that also measured would cost the serialized
# single-machine queue a full four-path sweep every time a layer is applied.
if [ ! -x "${HARNESS_DIR}/run.sh" ] && [ ! -f "${HARNESS_DIR}/run.sh" ]; then
  echo "FAIL: ${HARNESS_DIR}/run.sh not found — the layer drives the harness and does not reimplement it." >&2
  exit 1
fi

# The harness's output is PREFIXED rather than passed through, so that exactly
# one line in this script's stdout begins `OK:` — the layer's own. The harness
# keeps the same reporting contract, and two scripts both honouring it in one
# stream would otherwise emit two success lines for one outcome.
set +e
CONTEXT="${CONTEXT}" bash "${HARNESS_DIR}/run.sh" apply 2>&1 | sed 's/^/  harness| /'
HARNESS_RC="${PIPESTATUS[0]}"
set -e
if [ "${HARNESS_RC}" -ne 0 ]; then
  echo "FAIL: the four-path harness's apply exited ${HARNESS_RC}; the layer is not installed." >&2
  echo "      Re-run with the harness's own output unprefixed for the full detail:" >&2
  echo "        bash ${HARNESS_DIR}/run.sh apply" >&2
  exit 1
fi

# --- 5. read the applied object set back --------------------------------------
SERVERS_READY=0
for _d in s3-server nfs-provisioner; do
  _rep="$(kc -n "${NAMESPACE}" get "deploy/${_d}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [ "${_rep:-0}" -ge 1 ]; then SERVERS_READY=$((SERVERS_READY + 1)); fi
done
CLIENTS_READY=0
for _d in client-s3 client-nfs client-pvc client-hostpath; do
  _rep="$(kc -n "${NAMESPACE}" get "deploy/${_d}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [ "${_rep:-0}" -ge 1 ]; then CLIENTS_READY=$((CLIENTS_READY + 1)); fi
done
if [ "${CLIENTS_READY}" -ne 4 ] || [ "${SERVERS_READY}" -ne 2 ]; then
  echo "FAIL: after the apply, ${SERVERS_READY}/2 server(s) and ${CLIENTS_READY}/4 path client(s) report an available replica." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get deploy,pods -o wide" >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi

echo
echo "OK: addon-dataplane applied onto '${CLUSTER_NAME}' — 4 storage paths (${PATHS}), ${SERVERS_READY} in-cluster server(s) and ${CLIENTS_READY} path client(s) available in namespace '${NAMESPACE}'."
echo "  the object-storage path is named for its PROTOCOL, not for a vendor — the protocol is what is taught"
echo "  mount:      ${MOUNT_SOURCE} -> ${HOSTPATH_NODE} (create-time; carried by the base profile at zero measured memory cost)"
echo "  images:     ${PIN_REPORT}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: bash ${ADDON_DIR}/verify.sh"
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-addon-dataplane-size${SIZE} FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_TOOLS}/measure.sh read grid-core-addon-dataplane"
echo "              (read it BEFORE any teardown — kind delete removes the cgroups the figure comes from)"
echo "  measure the paths themselves (a full four-path sweep, not run by this layer):"
echo "                FILTER=${CLUSTER_NAME} bash ${LABS_TOOLS}/measure.sh run storage-four-path -- bash ${HARNESS_DIR}/run.sh"

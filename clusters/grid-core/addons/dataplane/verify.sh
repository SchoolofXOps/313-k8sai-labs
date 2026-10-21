#!/usr/bin/env bash
# addon-dataplane — verify the storage data-path layer on a running grid-core.
#
# READ-ONLY. It changes nothing on the cluster and it asserts OBJECT STATE only:
# the count of path workloads, each server's available replicas, each client's
# volume mounted at the expected path, the bind-mount path resolving to the host
# directory rather than to the node's overlay filesystem, and the
# object-storage endpoint answering a protocol-level request.
#
# IT ASSERTS NO THROUGHPUT NUMBER, and neither does checks.json. A throughput
# figure is a MEASUREMENT, not a check: asserted by a learner's own checks file
# it fails on a slower laptop and teaches the learner that the course is wrong.
# The measurement lives in labs/storage/four-path/run.sh and publishes its
# configuration beside its figures.
#
# THE ORDER OF THE ASSERTIONS IS LOAD-BEARING. The path-workload count is
# asserted NON-ZERO before anything is asserted about the workloads, because
# "every path's server is available" over zero paths is VACUOUSLY TRUE and a
# verify that reports clean over an un-applied layer is this phase's named
# failure mode.
#
# ------------------------------------------------------------------------------
# THE TWO SCOPE LIMITS THIS LAYER CARRIES. Both were MEASURED, and they bind what
# any lesson built on this layer may claim. They are stated here, in the layer
# itself, rather than left in a spike record nobody reads at authoring time; the
# generated labs/storage/four-path/harness-config.md carries the same two in the
# same words.
#
#   1. NO CLAIM DISTINGUISHING THE PROVISIONED-VOLUME PATH FROM THE BIND-MOUNT
#      PATH. On this runtime the default StorageClass's provisioner resolves to a
#      bind mount, not a CSI data path, so a claim on the default class costs
#      nothing measurable against a raw node-directory volume. Measured gap:
#      3.3% on write and 10.6% on read, against a run-to-run spread of 57.2% and
#      23.1% that the harness established for itself. The two are reported as
#      NOT DISTINGUISHABLE, never as equal — that is a statement about this
#      harness and this disk, not about the paths. This is also the honest answer
#      to the ordering edge: where two paths measure within each other's spread,
#      the record states the null result rather than ordering them.
#
#   2. NO ABSOLUTE THROUGHPUT FIGURE PRESENTED AS DISK PERFORMANCE. The guest
#      cannot evict the host's page cache, so an absolute number measures the
#      cache as much as the disk. What IS reproducible: the tier split — both
#      local-filesystem paths above both network-protocol paths, 16 of 16
#      measurements — and the cold first write on the network-filesystem path,
#      3.5 MiB/s in both independent runs and 69-125x slower than the same
#      path's second write, while the two local paths show no such penalty.
#      Within-tier ordering is not reproducible on this hardware and must not be
#      claimed.
# ------------------------------------------------------------------------------
#
# Usage:
#   bash verify.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed, and that
# line names the number of paths verified.
#
# Idempotent: read-only.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"

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

NAMESPACE="${NAMESPACE:-spike-02}"
HOSTPATH_NODE="${HOSTPATH_NODE:-/mnt/spike-02-hostpath}"
HOSTPATH_HOST="${HOSTPATH_HOST:-/var/lib/313-spike-02-hostpath}"
WORKER_NODE="${WORKER_NODE:-${CLUSTER_NAME}-worker}"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

# --- 1. the base cluster ------------------------------------------------------
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer has no cluster to be on." >&2
    echo "      Run the base profile first:  ${BASE}" >&2
    echo "      then apply the layer:        ${APPLY}" >&2
    exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required — the mount assertions below aggregate across every client Pod," >&2
  echo "      which jsonpath cannot do." >&2
  echo "      Install it (brew install jq) and re-run; this script changes nothing." >&2
  exit 1
fi

if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL: namespace '${NAMESPACE}' does not exist — the layer is not applied to this cluster." >&2
  echo "      Apply it: ${APPLY}" >&2
  exit 1
fi

# --- 2. THE EMPTY GUARD: a non-zero path-workload count, before any content ---
# One line, jq-computed, so the count is read rather than inferred from a
# selector that happened to match nothing.
DEPLOY_JSON="$(kcn get deploy -o json 2>/dev/null || true)"
if [ -z "${DEPLOY_JSON}" ]; then
  echo "FAIL: could not read Deployments from namespace '${NAMESPACE}'." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get deploy" >&2
  exit 1
fi
PATH_CLIENTS="$(printf '%s' "${DEPLOY_JSON}" | jq -r '
  [ .items[].metadata.name
    | select(. == "client-s3" or . == "client-nfs" or . == "client-pvc" or . == "client-hostpath") ]
  | length')"
if [ "${PATH_CLIENTS}" -lt 1 ]; then
  echo "FAIL: zero path workloads in namespace '${NAMESPACE}', so this layer verifies nothing." >&2
  echo "      This is asserted BEFORE anything about the workloads, because 'every path's" >&2
  echo "      server is available' over zero paths is vacuously true." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi
if [ "${PATH_CLIENTS}" -ne 4 ]; then
  echo "FAIL: ${PATH_CLIENTS} of 4 path clients present in namespace '${NAMESPACE}'." >&2
  echo "      A layer that applied three of four would still exit 0 and the missing path" >&2
  echo "      would simply not be mentioned, so the count is asserted and not reported." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get deploy" >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi

# --- 3. each path's server is available ---------------------------------------
# Two in-cluster servers: the object-storage endpoint and the
# network-filesystem provisioner. The provisioned-volume and bind-mount paths
# need no server of their own, which is itself part of what the lab compares.
SERVERS_OK=0
for _d in s3-server nfs-provisioner; do
  _rep="$(printf '%s' "${DEPLOY_JSON}" | jq -r --arg n "${_d}" '
    [ .items[] | select(.metadata.name == $n) | (.status.availableReplicas // 0) ] | add // 0')"
  if [ "${_rep}" -lt 1 ]; then
    echo "FAIL: server Deployment '${_d}' reports ${_rep} available replica(s) in '${NAMESPACE}'." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} describe deploy/${_d}" >&2
    echo "      Re-apply: ${APPLY}" >&2
    exit 1
  fi
  SERVERS_OK=$((SERVERS_OK + 1))
done

# --- 4. each client's volume is mounted at the expected path ------------------
# OBJECT STATE, read off the running Pod rather than by exec: the three
# filesystem paths each mount their own volume at /target, and the
# object-storage path deliberately has no /target because its data path is the
# protocol itself. Both halves are asserted — a client-s3 that grew a /target
# would mean the manifests were mixed.
POD_JSON="$(kcn get pods -l spike=spike-02 -o json 2>/dev/null || true)"
if [ -z "${POD_JSON}" ]; then
  echo "FAIL: could not read Pods from namespace '${NAMESPACE}'." >&2
  exit 1
fi
MOUNT_REPORT="$(printf '%s' "${POD_JSON}" | jq -r '
  [ .items[]
    | select(.status.phase == "Running")
    | select(.metadata.labels.app | startswith("client-"))
    | { app: .metadata.labels.app,
        target: ([ .spec.containers[].volumeMounts[]? | select(.mountPath == "/target") ] | length) } ]
  | { fs_with_target: ([ .[] | select(.app != "client-s3") | select(.target > 0) ] | length),
      fs_total:       ([ .[] | select(.app != "client-s3") ] | length),
      s3_with_target: ([ .[] | select(.app == "client-s3") | select(.target > 0) ] | length),
      s3_total:       ([ .[] | select(.app == "client-s3") ] | length) }
  | "fs_mounted=\(.fs_with_target)/\(.fs_total) protocol_clients=\(.s3_total) protocol_with_volume=\(.s3_with_target)"')"
FS_MOUNTED="${MOUNT_REPORT#fs_mounted=}"; FS_MOUNTED="${FS_MOUNTED%%/*}"
FS_TOTAL="${MOUNT_REPORT#*fs_mounted=*/}"; FS_TOTAL="${FS_TOTAL%% *}"
S3_TOTAL="${MOUNT_REPORT#*protocol_clients=}"; S3_TOTAL="${S3_TOTAL%% *}"
S3_VOL="${MOUNT_REPORT##*protocol_with_volume=}"
if [ "${FS_TOTAL}" -ne 3 ] || [ "${FS_MOUNTED}" -ne 3 ] || [ "${S3_TOTAL}" -ne 1 ] || [ "${S3_VOL}" -ne 0 ]; then
  echo "FAIL: the client mount set reads '${MOUNT_REPORT}'." >&2
  echo "      Expected exactly three filesystem clients each mounting a volume at /target," >&2
  echo "      and exactly one protocol client with no such volume — its data path is the" >&2
  echo "      protocol, so a /target on it would mean two manifests were mixed." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get pods -o json | jq '.items[].spec.containers[].volumeMounts'" >&2
  exit 1
fi

# --- 5. the bind-mount path resolves to the HOST directory --------------------
# Two independent reads, because either alone can be satisfied for the wrong
# reason: the node container's own bind table names the host source (so the
# directory is not merely present inside the node), and the filesystem type at
# that path differs from the node root's (so it is not the container overlay
# wearing the right name).
MOUNT_SOURCE="$(docker inspect "${WORKER_NODE}" \
  --format "{{range .Mounts}}{{if eq .Destination \"${HOSTPATH_NODE}\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null || true)"
if [ "${MOUNT_SOURCE}" != "${HOSTPATH_HOST}" ]; then
  echo "FAIL: the node container '${WORKER_NODE}' binds '${MOUNT_SOURCE:-<nothing>}' at '${HOSTPATH_NODE}'," >&2
  echo "      not the declared host directory '${HOSTPATH_HOST}'." >&2
  echo "      That mount is CREATE-TIME-ONLY and is declared in ${PROFILE_DIR}/create.sh," >&2
  echo "      so the remedy is to recreate the base profile:" >&2
  echo "        bash ${PROFILE_DIR}/teardown.sh && ${BASE}" >&2
  exit 1
fi
FSTYPE_MOUNT="$(docker exec "${WORKER_NODE}" stat -f -c %T "${HOSTPATH_NODE}" 2>/dev/null | tr -d '[:space:]' || true)"
FSTYPE_ROOT="$(docker exec "${WORKER_NODE}" stat -f -c %T / 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "${FSTYPE_MOUNT}" ] || [ -z "${FSTYPE_ROOT}" ]; then
  echo "FAIL: could not read the filesystem type at '${HOSTPATH_NODE}' and at '/' inside '${WORKER_NODE}'." >&2
  echo "      Inspect: docker exec ${WORKER_NODE} stat -f -c %T ${HOSTPATH_NODE}" >&2
  exit 1
fi
if [ "${FSTYPE_MOUNT}" = "${FSTYPE_ROOT}" ]; then
  echo "FAIL: '${HOSTPATH_NODE}' and '/' inside '${WORKER_NODE}' report the same filesystem type" >&2
  echo "      ('${FSTYPE_MOUNT}'), so the bind-mount path is resolving to the node's own" >&2
  echo "      overlay filesystem rather than to the host directory. The fourth path would" >&2
  echo "      then measure the overlay while the lab claimed it measured the host disk." >&2
  echo "      Recreate the base profile: bash ${PROFILE_DIR}/teardown.sh && ${BASE}" >&2
  exit 1
fi

# --- 6. the object-storage endpoint answers a PROTOCOL-level request ----------
# Not a port check and not a Pod phase: a listening socket proves a process is
# up, and a Running phase proves less than that. The assertion is that the
# endpoint answers the protocol's own bucket-listing request with the protocol's
# own document element. Issued from inside the path's client Pod, with the
# client's own standard library, so nothing is installed to make the assertion.
S3_CLIENT_POD="$(kcn get pod -l app=client-s3 \
  -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
if [ -z "${S3_CLIENT_POD}" ]; then
  echo "FAIL: no Running client Pod for the object-storage path in '${NAMESPACE}'." >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi
S3_PROBE="$(kcn exec "${S3_CLIENT_POD}" -- python3 -c '
import sys, urllib.request
try:
    r = urllib.request.urlopen("http://s3:8333/", timeout=30)
    body = r.read(4096).decode("utf-8", "replace")
except Exception as exc:
    print("protocol=unreachable reason=%s: %s" % (type(exc).__name__, exc))
    sys.exit(0)
elem = "ListAllMyBucketsResult" in body
print("protocol=http status=%s list_buckets_document=%s" % (r.status, "yes" if elem else "no"))
' 2>/dev/null || true)"
case "${S3_PROBE}" in
  "protocol=http status=200 list_buckets_document=yes") : ;;
  *)
    echo "FAIL: the object-storage endpoint did not answer a protocol-level bucket listing." >&2
    echo "      Probe reported: '${S3_PROBE:-<no output>}'" >&2
    echo "      A listening socket is not an answering endpoint, and a Running phase is" >&2
    echo "      less than either, so the assertion is on the protocol's own response." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/s3-server" >&2
    exit 1
    ;;
esac

echo "OK: addon-dataplane verified on '${CLUSTER_NAME}' — 4 of 4 storage paths verified (s3 nfs pvc hostpath): ${SERVERS_OK} in-cluster server(s) available, ${MOUNT_REPORT}, the bind-mount path resolving to the host directory on a different filesystem from the node root, and the object-storage endpoint answering a protocol-level bucket listing."
echo "  no throughput figure is asserted anywhere in this layer — that is a measurement, not a check"
echo "  bind mount: ${MOUNT_SOURCE} -> ${HOSTPATH_NODE} (${FSTYPE_MOUNT}, against '${FSTYPE_ROOT}' at the node root)"
echo "  protocol:   ${S3_PROBE}"
echo "  SCOPE LIMIT 1: no claim distinguishes the provisioned-volume path from the bind-mount path here — measured 3.3% on write, 10.6% on read, inside a 57.2% / 23.1% spread"
echo "  SCOPE LIMIT 2: no absolute throughput figure is disk performance — claimable: the tier split (16 of 16) and the network path's 3.5 MiB/s cold first write, 69-125x slower than its second"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"

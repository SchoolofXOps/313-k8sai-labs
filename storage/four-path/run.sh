#!/usr/bin/env bash
# four-path storage harness — measure the same three things on four storage paths
#
# The four paths (one Deployment + whatever PV/PVC/Service each needs):
#   s3        an S3-protocol object store Pod, backed by a PVC on `standard`
#   nfs       an in-cluster NFS server (userspace Ganesha) dynamically
#             provisioning an RWX PVC, backed by a PVC on `standard`
#   pvc       a plain PVC on kind's default `standard` StorageClass
#             (rancher.io/local-path), i.e. a directory inside the node
#             container's overlay filesystem
#   hostpath  a hostPath Pod volume onto the node's `extraMounts` bind mount,
#             so the payload lands on the host filesystem with NO CSI layer and
#             NO container-overlay layer in between
#
# Mechanism — why one implementation measures all four. Every path is measured
# by the SAME Python probe (probe.py, generated below into a ConfigMap), run by
# `kubectl exec` inside that path's own client Pod. One code path, one clock
# (time.monotonic), one payload generator, one chunk size. The only thing that
# differs between the four numbers is the storage path under the write, which
# is the entire point: a harness that measured four paths four different ways
# would be measuring its own implementations.
#
# Mechanism — how the page cache is kept out of the figures. An unsynced write
# measures RAM, and a re-read of a file you just wrote measures the page cache.
# Both would report numbers several times too fast. So:
#   * every write is timed INCLUDING os.fsync(), so the figure is a durable
#     write, not a write to dirty pages;
#   * every read is preceded by posix_fadvise(POSIX_FADV_DONTNEED) on that
#     exact file, which asks the kernel to drop its clean page-cache pages.
#     fadvise needs no root, unlike /proc/sys/vm/drop_caches, which is not
#     writable from inside a Pod;
#   * every repetition writes a DISTINCTLY NAMED payload, so no path and no
#     repetition can ever read another's cached bytes.
#   The one place this cannot reach is the S3 path's SERVER-side page cache —
#   the client cannot evict pages in another Pod. That limit is stated in
#   harness-config.md rather than hidden.
#
# Paths are measured STRICTLY SEQUENTIALLY, never in parallel: all four resolve
# to the same backing disk, so two concurrent paths would be measuring
# contention with each other instead of their own overhead.
#
# Usage:
#   bash run.sh                                   # measure every path, RUNS reps each
#   PATHS="pvc hostpath" bash run.sh              # re-measure a subset in isolation
#   SIZE_MB=512 RUNS=3 bash run.sh                # bigger payload, more reps
#   bash run.sh teardown                          # delete the namespace and the host payload dir
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"          # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/spike-core.kubeconfig   # isolated; never touch other clusters
#
# Wrap it for peak RSS (D-15), which is how SPIKE-05's data accrues for free.
# FILTER is required and is NOT optional polish: this harness publishes its
# reading under the label `storage-four-path`, but the containers it actually
# runs on are the spike-core kind nodes. Without FILTER the profile label is
# used as the docker name pattern, matches nothing, and the whole run is
# `unmeasured` — which is how this very line came to be the invocation that
# measured nothing. `measure.sh read` now exits non-zero in that case.
#   FILTER=spike-core bash labs/tools/measure.sh run storage-four-path \
#     -- bash labs/storage/four-path/run.sh
#
# Idempotent: re-running re-applies the manifests (server-side unchanged),
# regenerates harness-config.md, and measures again into fresh payload names.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Identical story to labs/clusters/spike-core/create.sh: on this build host a
# stale /usr/local/bin/kind and a stale ~/.rd/bin/kubectl resolve FIRST from a
# login shell, and an `export PATH` only lives as long as the shell that ran
# it. So the script resolves the pinned binaries itself. Override with
# LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

# --- knobs --------------------------------------------------------------------
# Payload size per path per repetition. 256 MiB is NOT sized to exceed the
# VM's page cache — that would need >7.74 GiB and would blow the 4500 MiB lab
# budget on its own. Cache influence is removed explicitly instead (fsync +
# POSIX_FADV_DONTNEED, see the header). 256 MiB is chosen as the largest
# payload for which four paths x RUNS reps x two independent runs still fits
# the single-machine validation budget, while staying far enough above the
# per-operation fixed costs that the throughput figure is dominated by the
# transfer and not by open(2)/HTTP setup.
SIZE_MB="${SIZE_MB:-256}"
# Repetitions per path WITHIN one invocation. The two runs ROADMAP SC2 requires
# are two independent INVOCATIONS of this script (namespace recreated between
# them); RUNS is the floor of repetitions inside each, not the ceiling. Two
# reps per invocation is what lets within-run and between-run spread be told
# apart — a single rep per invocation cannot distinguish them.
RUNS="${RUNS:-2}"
# Which paths to measure, space-separated, so one path can be re-measured in
# isolation after a failure without disturbing the others' figures.
# `s3` and not `minio`: the four-path design named MinIO as the S3 stand-in,
# but as of 2026-10-05 the MinIO community image is not anonymously pullable
# from Docker Hub, quay.io or ghcr.io (evidence:
# planning/lab-tests/raw/spike-02/probe-minio-image-availability.log), so the
# S3 path runs SeaweedFS instead. The path is labelled for what it actually
# runs — calling a SeaweedFS figure a MinIO figure would be exactly the kind of
# claim the Lab Truth Contract forbids. See minio.yaml and harness-config.md.
PATHS="${PATHS:-s3 nfs pvc hostpath}"
NAMESPACE="${NAMESPACE:-spike-02}"
CONTEXT="${CONTEXT:-kind-spike-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/spike-core.kubeconfig}"

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This harness never invokes kind, so only the client is asserted. Nothing
# asserted kubectl anywhere before (WR-01), although the course pins 1.37.x and
# the recorded hazard is a shim that has served a two-minor-old client.
. "$(cd "${HARNESS_DIR}/../../tools" && pwd)/pinned-bin.sh"
assert_kubectl_version
CONFIG_OUT="${CONFIG_OUT:-${HARNESS_DIR}/harness-config.md}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/spike-02-results}"

# Images, every one pinned by @sha256 INDEX digest (immutable, and the same pin
# resolves on linux/arm64 here and linux/amd64 in CI). Resolved with
# `docker buildx imagetools inspect`; captures in
# planning/lab-tests/raw/spike-02/digest-images.log.
#   S3 object store — SeaweedFS 4.03, linux/amd64 + linux/arm64.
S3_IMAGE="${S3_IMAGE:-chrislusf/seaweedfs@sha256:d24be3bc1d6e8e305c095c446cb9a00d40e3afdac82fb2a1cc96f2d42c4a8e80}"
#   NFS server — upstream SIG-Storage nfs-ganesha-server-and-external-provisioner
#   v4.0.8, linux/amd64 + linux/arm64. USERSPACE Ganesha: it does not need the
#   VM's kernel nfsd module. The NFS CLIENT side still needs the kernel `nfs`
#   module in the VM; see harness-config.md.
NFS_IMAGE="${NFS_IMAGE:-registry.k8s.io/sig-storage/nfs-provisioner@sha256:c825f3d5e28bde099bd7a3daace28772d412c9157ad47fa752a9ad0baafc118d}"
#   Measurement client — python:3.13-alpine, linux/amd64 + linux/arm64. Chosen
#   because the probe needs time.monotonic, os.posix_fadvise and a streaming
#   HTTP client, all of which are Python standard library: the client installs
#   nothing at run time, so no measurement depends on a package resolving.
CLIENT_IMAGE="${CLIENT_IMAGE:-python@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a}"
#   The node's extraMounts bind-mount target (declared create-time in
#   labs/clusters/spike-core/create.sh) and its host side.
HOSTPATH_HOST="${HOSTPATH_HOST:-/var/lib/313-spike-02-hostpath}"
HOSTPATH_NODE="${HOSTPATH_NODE:-/mnt/spike-02-hostpath}"
WORKER_NODE="${WORKER_NODE:-spike-core-worker}"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# teardown
# -----------------------------------------------------------------------------
# ORDER MATTERS HERE, and getting it wrong deadlocks the namespace.
#
# Measured live on this host (planning/lab-tests/raw/spike-02/run-2/
# diagnose-stuck-namespace.log): a plain `kubectl delete namespace` deletes the
# NFS server Pod and its Service at the same time as the NFS client Pod. The
# client's mount inside the node carries NFS's default `hard` option, so once
# the server's ClusterIP stops answering, kubelet's `umount` BLOCKS FOREVER.
# The client Pod object is then never removed, and the namespace sits
# Terminating with:
#
#   NamespaceDeletionContentFailure=True :: unexpected items still remain in
#   namespace: spike-02 for gvr: /v1, Resource=pods
#
# This is not a harness quirk — it is what happens to anyone who deletes an
# in-cluster NFS server before its clients, and it is the reason the clients go
# first here. The bounded force path below exists because a `hard` mount whose
# server is already gone can only be cleared with a lazy umount.
cmd_teardown() {
  echo "Tearing down the four-path harness ..."
  if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    # 1. Clients first, WHILE THE NFS SERVER IS STILL ALIVE, so the hard NFS
    #    mount unmounts cleanly instead of hanging.
    echo "  deleting client Deployments first (so NFS unmounts while its server lives) ..."
    kcn delete deploy client-s3 client-nfs client-pvc client-hostpath \
      --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
    kcn wait --for=delete pod -l spike=spike-02 --timeout=120s >/dev/null 2>&1 || true

    # 2. Then the servers.
    echo "  deleting server Deployments ..."
    kcn delete deploy s3-server nfs-provisioner \
      --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

    # 3. Then the namespace.
    echo "  deleting namespace '${NAMESPACE}' ..."
    kc delete namespace "${NAMESPACE}" --wait=true --timeout=180s || true

    # 4. Bounded force path: if anything is still Terminating, the cause is
    #    almost always a surviving hard NFS mount in the node. Clear it with a
    #    lazy+force umount, which is the only thing that releases a hard mount
    #    whose server has gone, then force-delete whatever Pod held it.
    if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      echo "  namespace still Terminating — clearing stranded NFS mounts in ${WORKER_NODE} ..."
      docker exec "${WORKER_NODE}" sh -c \
        'mount | grep "type nfs" | awk "{print \$3}" | while read -r m; do umount -f -l "$m" || true; done' \
        2>/dev/null || true
      kcn delete pod --all --force --grace-period=0 >/dev/null 2>&1 || true
      i=1
      while [ "${i}" -le 40 ]; do
        kc get namespace "${NAMESPACE}" >/dev/null 2>&1 || break
        sleep 3
        i=$((i + 1))
      done
    fi
  else
    echo "  namespace '${NAMESPACE}' already absent."
  fi
  # The hostPath payload lives OUTSIDE the namespace, on the node's bind mount,
  # so deleting the namespace does not remove it (threat T-01-11: never leave
  # bytes behind on the host filesystem). Remove it through the node container,
  # confined to the declared mount and nothing above it.
  if docker exec "${WORKER_NODE}" sh -c "test -d '${HOSTPATH_NODE}'" >/dev/null 2>&1; then
    docker exec "${WORKER_NODE}" sh -c "rm -f '${HOSTPATH_NODE}'/payload-*.bin" || true
    echo "  host payloads removed from ${HOSTPATH_NODE} (host side: ${HOSTPATH_HOST})."
  fi
  # Released PVs from the dynamic NFS StorageClass outlive their namespace, and
  # they carry the PROVISIONER's labels, not this harness's — so they are found
  # by their claimRef namespace rather than by label. Once the provisioner is
  # gone nothing will ever reclaim them, so they are deleted explicitly.
  #
  # The finalizer patch comes FIRST. With the delete first, each released PV
  # blocked for the full --timeout=60s before the patch freed it, so a teardown
  # with several PVs stalled for minutes for no reason.
  local rc=0
  for pv in $(kc get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace=='${NAMESPACE}')]}{.metadata.name} {end}" 2>/dev/null); do
    kc patch pv "${pv}" -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    kc delete pv "${pv}" --ignore-not-found --timeout=60s >/dev/null 2>&1 || rc=1
    echo "  released PV ${pv} removed."
  done

  # nfs.yaml creates THREE cluster-scoped objects that no namespace delete can
  # reach. Leaving them behind is the same class of defect as leaving bytes on
  # the host filesystem (threat T-01-11), and the StorageClass is the harmful
  # one: spike02-nfs names provisioner spike02.lab/nfs, which no longer exists
  # once this harness is down, so any later PVC naming that class sits Pending
  # forever with no provisioner to answer it.
  echo "==> Removing the cluster-scoped objects nfs.yaml creates"
  kc delete storageclass spike02-nfs --ignore-not-found >/dev/null 2>&1 || rc=1
  kc delete clusterrolebinding spike02-nfs-provisioner --ignore-not-found >/dev/null 2>&1 || rc=1
  kc delete clusterrole spike02-nfs-provisioner-runner --ignore-not-found >/dev/null 2>&1 || rc=1

  # Assert it, rather than announce it.
  local leftover=""
  kc get storageclass spike02-nfs >/dev/null 2>&1 && leftover="${leftover} storageclass/spike02-nfs"
  kc get clusterrolebinding spike02-nfs-provisioner >/dev/null 2>&1 && leftover="${leftover} clusterrolebinding/spike02-nfs-provisioner"
  kc get clusterrole spike02-nfs-provisioner-runner >/dev/null 2>&1 && leftover="${leftover} clusterrole/spike02-nfs-provisioner-runner"
  kc get namespace "${NAMESPACE}" >/dev/null 2>&1 && leftover="${leftover} namespace/${NAMESPACE}"
  if [ -n "${leftover}" ]; then
    echo "FAIL: teardown left these objects behind:${leftover}" >&2
    rc=1
  fi
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: four-path teardown did not complete. A surviving StorageClass" >&2
    echo "      spike02-nfs will leave every later PVC naming it Pending." >&2
    echo "      Re-run 'bash run.sh teardown', or inspect:" >&2
    echo "      kubectl get storageclass,clusterrole,clusterrolebinding | grep spike02" >&2
    exit 1
  fi
  echo "OK: four-path harness torn down."
}

if [ "${1:-}" = "teardown" ]; then cmd_teardown; exit 0; fi
if [ "${1:-}" != "" ]; then
  echo "usage: bash run.sh [teardown]" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
kc cluster-info >/dev/null 2>&1 \
  || fail "context '${CONTEXT}' does not answer. Create the cluster first: bash labs/clusters/spike-core/create.sh"

kc get node "${WORKER_NODE}" >/dev/null 2>&1 \
  || fail "worker node '${WORKER_NODE}' not found; the hostpath path needs the node that carries the extraMount."

docker exec "${WORKER_NODE}" sh -c "test -d '${HOSTPATH_NODE}'" >/dev/null 2>&1 \
  || fail "'${HOSTPATH_NODE}' is not present inside ${WORKER_NODE}. extraMounts is CREATE-TIME-ONLY — add it to labs/clusters/spike-core/create.sh and recreate the cluster: bash labs/clusters/spike-core/teardown.sh && bash labs/clusters/spike-core/create.sh"

# A namespace that is still Terminating accepts `kubectl apply` without error
# and then silently refuses to create any Pod — `apply` prints only
# "Warning: Detected changes to resource spike-02 which is currently being
# deleted" and every rollout wait times out. Measured live: that is exactly how
# invocation 2 of this spike failed the first time
# (planning/lab-tests/raw/spike-02/run-2/measure-run-2-attempt-1.log). So the
# harness waits for the namespace to actually be gone, and fails with the
# reason rather than producing an empty run.
if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  NS_PHASE="$(kc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${NS_PHASE}" = "Terminating" ]; then
    echo "namespace '${NAMESPACE}' is Terminating — waiting for it to finish before applying anything ..."
    i=1
    while [ "${i}" -le 60 ]; do
      kc get namespace "${NAMESPACE}" >/dev/null 2>&1 || break
      sleep 3
      i=$((i + 1))
    done
    if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      fail "namespace '${NAMESPACE}' is stuck Terminating after 180s. Applying into it would create no Pods at all. Clear it first: bash ${BASH_SOURCE[0]} teardown"
    fi
    echo "  namespace '${NAMESPACE}' is gone; proceeding."
  fi
fi

mkdir -p "${RESULTS_DIR}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

echo "four-path storage harness"
echo "  paths:      ${PATHS}"
echo "  payload:    ${SIZE_MB} MiB per path per repetition"
echo "  reps:       ${RUNS} per path"
echo "  namespace:  ${NAMESPACE} (context ${CONTEXT})"
echo "  run id:     ${RUN_ID}"
echo

# -----------------------------------------------------------------------------
# the probe — ONE measurement implementation, shipped to every client Pod
# -----------------------------------------------------------------------------
PROBE_PY="$(mktemp -t spike02probe)"
cat > "${PROBE_PY}" <<'PROBE_EOF'
#!/usr/bin/env python3
"""spike-02 four-path storage probe.

ONE implementation measures all four paths. Invoked inside a client Pod as:

    python3 /probe/probe.py fs   <target-dir> <size-mb> <tag>
    python3 /probe/probe.py s3   <endpoint>   <size-mb> <tag> <bucket>

Emits exactly one JSON object on stdout. Every duration is time.monotonic
(a monotonic clock, immune to NTP steps mid-measurement); every throughput is
bytes actually transferred divided by the measured elapsed time, never a
nominal size divided by a time.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

MIB = 1024 * 1024
CHUNK = 8 * MIB
# The payload source. Deliberately a tmpfs (emptyDir medium: Memory) file, so
# that reading the source during a timed write costs RAM speed and the write
# figure is dominated by the TARGET path, not by the source.
SRC = "/payload/payload.bin"

# A constant byte buffer, which is 304's `head -c N /dev/zero | tr '\0' 'x'`
# payload pattern expressed in-process: identical generation cost for every
# path, and never random data (a random generator's cost would land inside the
# comparison and would differ run to run).
FILLER = b"x" * CHUNK


def ensure_source(size_mb):
    """Generate the payload once per probe invocation, OUTSIDE every timed
    region, and report how long it took so the cost is visible rather than
    merely excluded."""
    want = size_mb * MIB
    t0 = time.monotonic()
    os.makedirs(os.path.dirname(SRC), exist_ok=True)
    if os.path.exists(SRC) and os.path.getsize(SRC) == want:
        return {"generated": False, "seconds": 0.0, "bytes": want}
    with open(SRC, "wb") as f:
        left = want
        while left > 0:
            n = CHUNK if left > CHUNK else left
            f.write(FILLER[:n])
            left -= n
        f.flush()
        os.fsync(f.fileno())
    return {"generated": True, "seconds": time.monotonic() - t0, "bytes": want}


def evict(path):
    """Drop this file's clean page-cache pages.

    POSIX_FADV_DONTNEED needs no privilege, unlike /proc/sys/vm/drop_caches
    which is not writable from inside a Pod. It is advisory: the kernel drops
    clean pages it can, which after an fsync is all of them. Returns the
    mechanism name, or the reason it was unavailable — never silently nothing.
    """
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as exc:
        return "unavailable: open failed: %s" % exc
    try:
        os.fsync(fd)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        return "posix_fadvise(POSIX_FADV_DONTNEED) after fsync"
    except (AttributeError, OSError) as exc:
        return "unavailable: %s" % exc
    finally:
        os.close(fd)


def measure_fs(target_dir, size_mb, tag):
    dst = os.path.join(target_dir, "payload-%s.bin" % tag)
    out = {"target": dst}

    # --- sequential write, fsync INSIDE the timed region ---------------------
    wrote = 0
    t0 = time.monotonic()
    with open(SRC, "rb") as fin, open(dst, "wb") as fout:
        while True:
            buf = fin.read(CHUNK)
            if not buf:
                break
            fout.write(buf)
            wrote += len(buf)
        fout.flush()
        os.fsync(fout.fileno())
    out["write_seconds"] = time.monotonic() - t0
    out["write_bytes"] = wrote

    # --- first-byte latency: open(2) + the first read, on a cold file --------
    out["evict_mechanism"] = evict(dst)
    t0 = time.monotonic()
    fd = os.open(dst, os.O_RDONLY)
    got = os.read(fd, 1)
    out["first_byte_seconds"] = time.monotonic() - t0
    os.close(fd)
    out["first_byte_bytes"] = len(got)

    # --- sequential read, from a cold file again -----------------------------
    evict(dst)
    read = 0
    t0 = time.monotonic()
    with open(dst, "rb") as f:
        while True:
            buf = f.read(CHUNK)
            if not buf:
                break
            read += len(buf)
    out["read_seconds"] = time.monotonic() - t0
    out["read_bytes"] = read

    os.remove(dst)
    return out


class _CountingReader(object):
    """Pass-through file wrapper that counts the bytes actually read out of it.

    urllib streams a file-like `data` by calling read(); wrapping it is the
    only way to learn how many bytes really went to the socket, as opposed to
    how many were intended to.
    """

    def __init__(self, f):
        self.f = f
        self.n = 0

    def read(self, k=-1):
        b = self.f.read(k)
        self.n += len(b)
        return b


def _put(url, body, length):
    req = urllib.request.Request(url, method="PUT", data=body)
    req.add_header("Content-Length", str(length))
    req.add_header("Content-Type", "application/octet-stream")
    return urllib.request.urlopen(req, timeout=900)


def measure_s3(endpoint, size_mb, tag, bucket):
    key = "payload-%s.bin" % tag
    obj = "%s/%s/%s" % (endpoint.rstrip("/"), bucket, key)
    out = {"target": obj}

    # Bucket create, UNTIMED and retried: a one-off control-plane call, not
    # part of the data path being compared. Retried because `weed server -s3`
    # opens its S3 port before its filer and volume server have registered
    # with the master, so the TCP readiness probe can go green a second or two
    # before the first object write would actually succeed. Waiting here keeps
    # that startup race out of the measured write.
    deadline = time.monotonic() + 120.0
    out["bucket_note"] = "not created"
    while time.monotonic() < deadline:
        try:
            _put("%s/%s" % (endpoint.rstrip("/"), bucket), b"", 0).read()
            out["bucket_note"] = "created or already present"
            break
        except urllib.error.HTTPError as exc:
            # 409 only: urlopen raises HTTPError for status >= 400, so a 200
            # could never be seen here (IN-04).
            if exc.code in (409,):
                out["bucket_note"] = "already present (HTTP %s)" % exc.code
                break
            out["bucket_note"] = "PUT bucket -> HTTP %s" % exc.code
            time.sleep(2)
        except Exception as exc:                   # noqa: BLE001 - retried, then reported
            out["bucket_note"] = "PUT bucket -> %s" % exc
            time.sleep(2)

    nbytes = size_mb * MIB

    # --- sequential write: one streaming PUT, timed to the response ---------
    # write_bytes is COUNTED, not assumed. The docstring above promises "every
    # throughput is bytes actually transferred divided by the measured elapsed
    # time, never a nominal size divided by a time", and the fs paths keep that
    # promise by accumulating len(buf). This path used to set
    # write_bytes = size_mb * MIB — exactly the nominal figure the docstring
    # forbids — so a 2xx short write would have published full-size
    # throughput. CountingReader wraps the file object urlopen streams from, so
    # the number reported is the number of bytes handed to the socket.
    with open(SRC, "rb") as raw:
        body = _CountingReader(raw)
        t0 = time.monotonic()
        resp = _put(obj, body, nbytes)
        resp.read()
        out["write_seconds"] = time.monotonic() - t0
        out["write_status"] = resp.status
        out["write_bytes"] = body.n
    # write_status was captured and never asserted. A non-2xx here is not a
    # measurement, it is a failure, and urlopen only raises for >= 400 — so a
    # 3xx would otherwise have been reported as a successful write.
    if resp.status // 100 != 2:
        raise RuntimeError("PUT %s returned HTTP %s" % (obj, resp.status))
    if out["write_bytes"] != nbytes:
        raise RuntimeError(
            "short write to %s: sent %d bytes, expected %d"
            % (obj, out["write_bytes"], nbytes))

    # --- first-byte latency: TCP connect + request + first body byte --------
    # Not evictable from here: the object store's own page cache lives in
    # another Pod. Stated in harness-config.md rather than papered over.
    out["evict_mechanism"] = "not available to the client (server-side cache)"
    t0 = time.monotonic()
    resp = urllib.request.urlopen(obj, timeout=900)
    got = resp.read(1)
    out["first_byte_seconds"] = time.monotonic() - t0
    resp.close()
    out["first_byte_bytes"] = len(got)

    # --- sequential read: one GET drained to EOF ----------------------------
    t0 = time.monotonic()
    resp = urllib.request.urlopen(obj, timeout=900)
    read = 0
    while True:
        buf = resp.read(CHUNK)
        if not buf:
            break
        read += len(buf)
    out["read_seconds"] = time.monotonic() - t0
    out["read_bytes"] = read
    resp.close()

    try:
        urllib.request.urlopen(
            urllib.request.Request(obj, method="DELETE"), timeout=120).read()
    except urllib.error.HTTPError:
        pass
    return out


def main():
    kind = sys.argv[1]
    target = sys.argv[2]
    size_mb = int(sys.argv[3])
    tag = sys.argv[4]
    result = {"kind": kind, "size_mb": size_mb, "tag": tag,
              "chunk_bytes": CHUNK, "clock": "time.monotonic"}
    try:
        result["payload"] = ensure_source(size_mb)
        if kind == "fs":
            result.update(measure_fs(target, size_mb, tag))
        elif kind == "s3":
            result.update(measure_s3(target, size_mb, tag, sys.argv[5]))
        else:
            raise SystemExit("unknown probe kind: %s" % kind)
        result["ok"] = True
    except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
        result["ok"] = False
        result["error"] = "%s: %s" % (type(exc).__name__, exc)
    finally:
        # Free the 256 MiB tmpfs payload immediately: it is charged to the
        # Pod's memory cgroup, and only one client should ever hold one.
        try:
            os.remove(SRC)
        except OSError:
            pass
    print(json.dumps(result))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
PROBE_EOF

# -----------------------------------------------------------------------------
# apply
# -----------------------------------------------------------------------------
echo "==> namespace and probe ConfigMap"
kc create namespace "${NAMESPACE}" --dry-run=client -o yaml | kc apply -f - >/dev/null
kcn create configmap spike-02-probe --from-file=probe.py="${PROBE_PY}" \
  --dry-run=client -o yaml | kcn apply -f - >/dev/null
rm -f "${PROBE_PY}"

# path id -> manifest file. `s3` reads minio.yaml: the file keeps the name the
# four-path design gave it, and its header records why the image inside it is
# not MinIO.
manifest_for() {
  case "$1" in
    s3)       echo "${HARNESS_DIR}/minio.yaml" ;;
    nfs)      echo "${HARNESS_DIR}/nfs.yaml" ;;
    pvc)      echo "${HARNESS_DIR}/pvc.yaml" ;;
    hostpath) echo "${HARNESS_DIR}/hostpath.yaml" ;;
    *)        echo "" ;;
  esac
}

# Deployment whose Pod runs the probe for each path.
client_for() {
  case "$1" in
    s3)       echo "client-s3" ;;
    nfs)      echo "client-nfs" ;;
    pvc)      echo "client-pvc" ;;
    hostpath) echo "client-hostpath" ;;
    *)        echo "" ;;
  esac
}

# Intentional IFS word-splitting of the space-separated path list.
for p in ${PATHS}; do
  m="$(manifest_for "${p}")"
  [ -n "${m}" ] || fail "unknown path '${p}'. Valid: s3 nfs pvc hostpath"
  [ -s "${m}" ] || fail "manifest ${m} missing or empty"
  echo "==> applying ${p} (${m##*/})"
  sed -e "s|__CLIENT_IMAGE__|${CLIENT_IMAGE}|g" \
      -e "s|__S3_IMAGE__|${S3_IMAGE}|g" \
      -e "s|__NFS_IMAGE__|${NFS_IMAGE}|g" \
      -e "s|__HOSTPATH_NODE__|${HOSTPATH_NODE}|g" \
      -e "s|__WORKER_NODE__|${WORKER_NODE}|g" \
      -e "s|__PAYLOAD_LIMIT__|$((SIZE_MB + 64))Mi|g" \
      -e "s|__CLIENT_MEM_LIMIT__|$((SIZE_MB * 3 + 256))Mi|g" \
      -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      "${m}" | kcn apply -f - >/dev/null
done

echo
echo "==> waiting for rollouts (first run pulls images; this is the slow part)"
for p in ${PATHS}; do
  case "${p}" in
    s3)  kcn rollout status deploy/s3-server --timeout=420s || fail "s3-server did not roll out" ;;
    nfs) kcn rollout status deploy/nfs-provisioner --timeout=420s || true ;;
  esac
done
for p in ${PATHS}; do
  c="$(client_for "${p}")"
  if ! kcn rollout status "deploy/${c}" --timeout=420s; then
    echo "WARN: ${c} did not roll out; the '${p}' path will be recorded unmeasured with its reason."
  fi
done

# -----------------------------------------------------------------------------
# measure — strictly one path at a time, one rep at a time
# -----------------------------------------------------------------------------
RAW_JSON="${RESULTS_DIR}/results-${RUN_ID}.jsonl"
: > "${RAW_JSON}"

probe_pod() {
  kcn get pod -l "app=$1" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' \
    2>/dev/null | awk '{print $1}'
}

echo
echo "==> measuring"
rep=1
while [ "${rep}" -le "${RUNS}" ]; do
  for p in ${PATHS}; do
    c="$(client_for "${p}")"
    tag="${RUN_ID}-${p}-r${rep}"
    pod="$(probe_pod "${c}")"
    if [ -z "${pod}" ]; then
      printf '{"path":"%s","rep":%s,"ok":false,"error":"no Running Pod for %s"}\n' \
        "${p}" "${rep}" "${c}" >> "${RAW_JSON}"
      echo "  ${p} rep ${rep}: unmeasured — no Running Pod for ${c}"
      continue
    fi
    if [ "${p}" = "s3" ]; then
      args="s3 http://s3:8333 ${SIZE_MB} ${tag} spike02"
    else
      args="fs /target ${SIZE_MB} ${tag}"
    fi
    echo "  ${p} rep ${rep}: probing in ${pod} ..."
    # Intentional word-splitting of ${args}.
    # `|| true` and no `if`: the old form assigned `out` in the success branch
    # and then re-assigned `out="${out:-}"` in the failure branch, which was a
    # no-op because the command substitution had already set it (IN-05).
    out="$(kcn exec "${pod}" -- python3 /probe/probe.py ${args} 2>/dev/null || true)"
    if [ -z "${out}" ]; then
      printf '{"path":"%s","rep":%s,"ok":false,"error":"probe produced no output in %s"}\n' \
        "${p}" "${rep}" "${pod}" >> "${RAW_JSON}"
      echo "    unmeasured — probe produced no output"
      continue
    fi
    # The `unmeasured` discipline has to hold on the PARSE boundary too.
    #
    # An empty `out` was handled above, but a NON-EMPTY unparseable `out` — a
    # pod killed mid-write leaving truncated JSON, or any stdout noise from
    # `kubectl exec` — made json.loads raise, python3 exit 1, pipefail
    # propagate and set -e abort the whole run. The remaining reps were lost
    # and execution never reached the result table or harness-config.md, so a
    # run that had produced real data for three paths published nothing at
    # all. A single bad line must cost one rep, not the run.
    if ! printf '%s\n' "${out}" \
      | python3 -c 'import json,sys
d = json.loads(sys.stdin.read())
d["path"] = sys.argv[1]
d["rep"] = int(sys.argv[2])
d["pod"] = sys.argv[3]
print(json.dumps(d))' "${p}" "${rep}" "${pod}" 2>/dev/null >> "${RAW_JSON}"; then
      printf '{"path":"%s","rep":%s,"ok":false,"error":"probe output was not valid JSON in %s"}\n' \
        "${p}" "${rep}" "${pod}" >> "${RAW_JSON}"
      echo "    unmeasured — probe output was not valid JSON"
      continue
    fi
    # Same protection on the human-readable line, plus guards on the three
    # divisions: a 0.0 in any *_seconds field raised ZeroDivisionError and
    # aborted the run for what is itself a measurement result.
    printf '%s\n' "${out}" | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("    unmeasured — probe output was not valid JSON")
    sys.exit(0)
if not d.get("ok"):
    print("    unmeasured — %s" % d.get("error"))
else:
    mib = 1024.0*1024.0
    def rate(b, s):
        return (b / mib / s) if s else float("nan")
    print("    write %7.1f MiB/s | read %7.1f MiB/s | first byte %7.2f ms"
          % (rate(d.get("write_bytes", 0), d.get("write_seconds", 0)),
             rate(d.get("read_bytes", 0), d.get("read_seconds", 0)),
             (d.get("first_byte_seconds") or 0.0) * 1000.0))' || true
  done
  rep=$((rep + 1))
done

# -----------------------------------------------------------------------------
# render the result table
# -----------------------------------------------------------------------------
RENDER_PY='import json, sys

mib = 1024.0 * 1024.0
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        rows.append(json.loads(line))

CONDITIONS = {
    "s3":       "S3 HTTP PUT/GET to a SeaweedFS Pod backed by a PVC on `standard`; "
                "server-side cache not evictable from the client",
    "nfs":      "RWX PVC from the in-cluster userspace-Ganesha NFS server, itself "
                "backed by a PVC on `standard`; NFS protocol over the Pod network",
    "pvc":      "PVC on kind default `standard` (rancher.io/local-path) -> node "
                "container overlay2 -> /dev/vda1 ext4",
    "hostpath": "hostPath Pod volume onto the node extraMounts bind mount -> "
                "/dev/vda1 ext4 directly; no CSI, no overlay",
}

print("| path | rep | write (MiB/s) | read (MiB/s) | first byte (ms) | conditions |")
print("|---|---|---|---|---|---|")
# Sorted by path name ascending, then rep, so two runs diff cleanly.
for r in sorted(rows, key=lambda r: (r.get("path", ""), r.get("rep", 0))):
    p = r.get("path", "?")
    cond = CONDITIONS.get(p, "-")
    if not r.get("ok"):
        print("| %s | %s | unmeasured | unmeasured | unmeasured | **unmeasured — %s** |"
              % (p, r.get("rep", "?"), r.get("error", "no reason recorded")))
        continue
    print("| %s | %s | %.1f | %.1f | %.2f | %s |"
          % (p, r["rep"],
             r["write_bytes"] / mib / r["write_seconds"],
             r["read_bytes"] / mib / r["read_seconds"],
             r["first_byte_seconds"] * 1000.0,
             cond))

print("")
print("Per-path summary (mean of the repetitions above):")
print("")
print("| path | write (MiB/s) | read (MiB/s) | first byte (ms) | reps |")
print("|---|---|---|---|---|")
by = {}
for r in rows:
    if r.get("ok"):
        by.setdefault(r["path"], []).append(r)
for p in sorted(by):
    rs = by[p]
    n = len(rs)
    w = sum(x["write_bytes"] / mib / x["write_seconds"] for x in rs) / n
    rd = sum(x["read_bytes"] / mib / x["read_seconds"] for x in rs) / n
    fb = sum(x["first_byte_seconds"] * 1000.0 for x in rs) / n
    print("| %s | %.1f | %.1f | %.2f | %d |" % (p, w, rd, fb, n))
missing = sorted(set(r.get("path", "?") for r in rows) - set(by))
for p in missing:
    print("| %s | unmeasured | unmeasured | unmeasured | 0 |" % p)
'
TABLE="$(python3 -c "${RENDER_PY}" "${RAW_JSON}")"
echo
echo "==> results"
echo
printf '%s\n' "${TABLE}"
printf '%s\n' "${TABLE}" > "${RESULTS_DIR}/table-${RUN_ID}.md"

# -----------------------------------------------------------------------------
# harness-config.md — WRITTEN BY THE RUN, never hand-maintained
# -----------------------------------------------------------------------------
# Phase 6 SC4 requires the harness configuration published beside the figure.
# Generating it here is what makes that impossible to violate: the config file
# cannot drift from the figures, because the same invocation produces both.
echo
echo "==> publishing harness configuration -> ${CONFIG_OUT}"

SC_LINE="$(kc get storageclass standard -o jsonpath='{.metadata.name} / provisioner={.provisioner} / binding={.volumeBindingMode} / reclaim={.reclaimPolicy}' 2>/dev/null || echo unreadable)"
NODE_IMAGE="$(kc get node "${WORKER_NODE}" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null || true)"
NODE_PINNED="$(docker inspect "${WORKER_NODE}" --format '{{.Config.Image}}' 2>/dev/null || echo unreadable)"
NODE_MOUNTS="$(docker inspect "${WORKER_NODE}" \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}' 2>/dev/null \
  | sed 's/^/    /' || true)"
FS_TARGETS="$(docker exec "${WORKER_NODE}" sh -c \
  "df -T '${HOSTPATH_NODE}' / /var/lib/kubelet 2>&1" 2>/dev/null | sed 's/^/    /' || true)"
KUBELET_VERSION="$(kc get node "${WORKER_NODE}" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo unreadable)"
VM_FS="$(rdctl shell sh -c 'df -T / /tmp /var/lib /var/lib/docker 2>&1' 2>/dev/null | sed 's/^/    /' || echo "    (rdctl unavailable)")"
NFS_MODULE="$(rdctl shell sh -c 'lsmod | grep -E "^(nfs|sunrpc) " || echo "nfs kernel module NOT loaded"' 2>/dev/null | sed 's/^/    /' || echo "    (rdctl unavailable)")"

cat > "${CONFIG_OUT}" <<CONFIG_EOF
# four-path storage harness — published configuration

**Generated by \`labs/storage/four-path/run.sh\` on every run.** Never hand-edited: a
hand-maintained config drifts from the figures it is supposed to explain, and a storage figure
without its harness configuration is not a measurement. Regenerate it by re-running the harness.

Run id: \`${RUN_ID}\`

## Effective knobs

| Knob | Effective value | What it controls |
|---|---|---|
| \`SIZE_MB\` | ${SIZE_MB} | Payload size per path per repetition, in MiB |
| \`RUNS\` | ${RUNS} | Repetitions per path within this invocation |
| \`PATHS\` | \`${PATHS}\` | Which paths this invocation measured |
| \`NAMESPACE\` | \`${NAMESPACE}\` | Namespace every object was created in |
| \`CONTEXT\` | \`${CONTEXT}\` | kubectl context (isolated \`KUBECONFIG=${KUBECONFIG}\`) |
| \`HOSTPATH_NODE\` | \`${HOSTPATH_NODE}\` | The node-side bind mount the hostpath path writes to |
| \`HOSTPATH_HOST\` | \`${HOSTPATH_HOST}\` | Its host side, declared via \`extraMounts\` at cluster create |
| \`WORKER_NODE\` | \`${WORKER_NODE}\` | The node every client Pod runs on |

## Images — every one pinned by \`@sha256\` index digest

| Role | Pin |
|---|---|
| Kubernetes node | \`${NODE_PINNED}\` |
| S3 object store (\`s3\` path) | \`${S3_IMAGE}\` |
| NFS server (\`nfs\` path) | \`${NFS_IMAGE}\` |
| Measurement client (all paths) | \`${CLIENT_IMAGE}\` |

Node OS image: \`${NODE_IMAGE}\` · kubelet \`${KUBELET_VERSION}\`

### The S3 path does not run MinIO, and the reason is not cosmetic

The four-path design named **MinIO** as the S3 stand-in. On 2026-10-05 the MinIO community
container image could not be pulled anonymously from any registry tried:

- \`docker.io/minio/minio\` — Docker Hub's API returns \`{"message":"object not found"}\` for the
  repository itself, and a pull returns \`insufficient_scope: authorization failed\`
- \`quay.io/minio/minio\` — \`401 Unauthorized\` / \`Requires authentication\` for anonymous access
- \`ghcr.io/minio/minio\` — \`403 Forbidden\` on the anonymous token request

Evidence: \`planning/lab-tests/raw/spike-02/probe-minio-image-availability.log\`.

A lab whose image cannot be pulled is a broken lab, so the S3 path runs **SeaweedFS** instead and
is labelled \`s3\`, not \`minio\` — calling a SeaweedFS figure a MinIO figure is exactly the class
of claim the Lab Truth Contract forbids. The manifest keeps the filename \`minio.yaml\` so the
harness's file set still matches its design, and its header carries the same explanation.
**This is a stack-pin finding that needs founder sign-off, not a silent substitution.**

## What is actually under each path

| Path | Data path, outermost to innermost |
|---|---|
| \`s3\` | client Pod -> HTTP/1.1 over the Pod network -> SeaweedFS S3 gateway -> filer+volume store -> PVC on \`standard\` -> node overlay2 -> \`/dev/vda1\` ext4 |
| \`nfs\` | client Pod -> NFS (kernel client in the node) over the Pod network -> userspace Ganesha server Pod -> its PVC on \`standard\` -> node overlay2 -> \`/dev/vda1\` ext4 |
| \`pvc\` | client Pod -> PVC on \`standard\` -> \`rancher.io/local-path\` bind -> node overlay2 -> \`/dev/vda1\` ext4 |
| \`hostpath\` | client Pod -> hostPath volume -> node \`extraMounts\` bind -> \`/dev/vda1\` ext4 |

StorageClass behind the \`pvc\` path (and behind the \`s3\` and \`nfs\` servers' own backing volumes):

    ${SC_LINE}

Node container mount set (this is part of the configuration, because the hostpath figure is a
property of this mount):

${NODE_MOUNTS}

Filesystem types inside the node, measured not assumed:

${FS_TARGETS}

VM filesystem layout:

${VM_FS}

NFS client kernel module state in the VM (the Ganesha server is userspace and needs no \`nfsd\`,
but the NFS **client** mount performed by kubelet needs the \`nfs\` module in the VM kernel; the
pinned \`kindest/node\` image does ship \`/sbin/mount.nfs\`, the userspace helper):

${NFS_MODULE}

## Cache-bypass mechanism — the single most likely way a harness like this lies

A number that is really a page-cache hit is the most likely failure mode of any storage harness, so
the mechanism is named rather than assumed:

1. **Writes are timed including \`os.fsync()\`.** Without it the figure measures the rate of
   dirtying page-cache pages — RAM speed — and not a durable write.
2. **Reads are preceded by \`posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)\`** on that exact file,
   after an \`fsync\`, which asks the kernel to drop the file's clean page-cache pages. \`fadvise\`
   is used rather than \`/proc/sys/vm/drop_caches\` because the latter is not writable from inside
   a Pod. The probe reports the mechanism string it actually achieved per measurement, so an
   \`unavailable:\` fallback would appear in the raw capture instead of silently producing a warm
   number.
3. **Every repetition writes a distinctly named payload** (\`payload-<run-id>-<path>-r<rep>.bin\`),
   so no path and no repetition can read another's cached bytes.
4. **First-byte latency and sequential read are two separate cold reads**, each preceded by its own
   eviction.

**Where this does not reach:** the \`s3\` path's server-side page cache lives in the SeaweedFS Pod,
and a client cannot evict pages in another Pod. The \`s3\` read figure may therefore include a
server-side cache hit, and is the one figure in this harness that is not cache-cold by
construction. It is reported as measured, with this limit stated.

**Payload source:** a tmpfs \`emptyDir\` (\`medium: Memory\`) file, generated once per probe
invocation outside every timed region, so that the source read inside a timed write costs RAM speed
and the write figure is dominated by the target path. The generator is a constant byte buffer —
304's \`head -c N /dev/zero | tr '\\0' 'x'\` pattern expressed in-process — so generation cost is
identical for every path and never random.

**Ordering:** paths are measured strictly sequentially, never concurrently. All four resolve to the
same backing disk, so two paths measured at once would measure contention with each other.

## The shared-disk caveat — read this before comparing the four numbers

**All four paths resolve to the same backing disk inside the same Rancher Desktop VM:
\`/dev/vda1\`, ext4.** The S3 server, the NFS server, the \`standard\` StorageClass and the
\`extraMounts\` bind mount are four different routes onto one physical device, and the CPU, page
cache and I/O queue they contend for are shared.

So these four figures compare **path overhead on one disk** — the cost of an S3 round trip, of the
NFS protocol, of the local-path provisioner's bind plus the container overlay, and of a bare bind
mount — and they are **not** four storage technologies measured on their own hardware. A real
object store sits on its own disks across a network; a real NFS filer has its own spindles, its own
cache and its own network. Nothing here measures that, and no figure from this harness may be
presented as if it did.

Every number is also **laptop-local**: it describes this VM, on this disk, on this host, and says
nothing about what a learner's machine will produce. Whether M6.3 frames its claim as a
four-technology comparison or a four-path-overhead comparison is Phase 6's authoring decision, not
this harness's.
CONFIG_EOF

echo
echo "OK: four-path harness completed — ${PATHS} measured at ${SIZE_MB} MiB x ${RUNS} rep(s)."
echo "  results table: ${RESULTS_DIR}/table-${RUN_ID}.md"
echo "  raw json:      ${RAW_JSON}"
echo "  config:        ${CONFIG_OUT}"

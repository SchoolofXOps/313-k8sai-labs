#!/usr/bin/env bash
# checkpoint-storm.sh — several writers on ONE shared ReadWriteMany claim at once, then one alone.
#
# WHAT IT DOES. A gang of training workers writes its checkpoints at the same moment, into the same
# shared volume. This script reproduces that burst at laptop size on the four-path harness's `nfs`
# path: it starts WRITERS client Pods (default 3), each mounting the harness's own RWX claim
# `spike02-nfs-rwx`, and runs the harness's OWN generated probe (`probe.py`, from the ConfigMap
# `spike-02-probe`) in three phases: once in each writer alone, in turn (the warm-up), then in all of
# them at once (concurrent), then once more in one writer alone (single). Every write is timed by the
# probe's own clock and includes its fsync, exactly as in the four-path table.
#
# WHY THE WARM-UP. The lab measures it (D-32): the first `nfs` write after the NFS server starts can
# wait up to 90 s. The server (NFS-Ganesha, `Grace_Period = 90`) holds back every new open for its grace
# period after each start or restart, so that first write is a wait, not slow writing
# (planning/lab-tests/m6.md § Cold first write: cause). The storage layer is usually applied just before
# this script runs, so without a warm-up the concurrent writes would also be the first writes after the
# server started, and the comparison would mix concurrency with that wait (deep-dive run 1, plan
# 06-18). Each writer therefore writes once on its own first. Its rows are recorded as `warm-up`, never
# dropped, and are not part of the comparison: the `concurrent` and `single` rows both run on a volume
# every writer has already written to, so they differ in one thing only, how many writers write at
# once.
#
# ONE PROBE, NEVER A SECOND ONE. A storm timed by a different program would be timing its own
# implementation. So nothing here measures anything itself: it reads the probe out of the ConfigMap
# the harness created, copies it beside the results, and runs it unchanged.
#
# WHAT IT WRITES, under the directory it is run from (the clone root):
#   grid-platform/dataplane-storage/measurements/checkpoint-storm-<run-id>/
#     results.jsonl    one probe result per writer and mode, with the mode and writer added
#     probe.py         the exact probe that produced them, read from the ConfigMap
#     storm-record.md  the knobs, the declared environment, and one table:
#                      | Mode | Writer | Write (MiB/s) |: WRITERS `warm-up` rows, WRITERS `concurrent`
#                      rows and one `single` row
#
# WHAT IT ASSERTS ABOUT A FIGURE: NOTHING. The figures are recorded beside their configuration and
# never compared to a threshold. The same three scope fences as the four-path table bind them: they
# are laptop-local, they are not disk performance (the host's page cache sits under the VM's disk),
# and they come from one machine and one run.
#
# CLIENTS FIRST. The writers are NFS clients. Their `hard` mount blocks forever if the NFS server
# goes first, so the script deletes its own writer Pods before it exits, on success and on failure,
# while the server is still running. It never touches the server or the claim.
#
# PRECONDITIONS, each checked before anything is created:
#   - grid-core is up and the storage layer is applied: namespace spike-02, the Bound claim
#     spike02-nfs-rwx and the ConfigMap spike-02-probe exist;
#   - the script runs from the clone root (grid-platform/ is in the current directory);
#   - OTHER_CONTAINERS is set, because the VM's memory and disk are shared with the other containers
#     on this machine and the record must say so. `count` makes the script count them itself, with
#     `docker ps`, when the storm starts and again when it ends, leaving out this cluster's own node
#     containers and recording no names; any other value (a description, or `none`) is recorded as
#     given. A description typed in advance can go stale while the storm runs (deep-dive run 1: a
#     container from another project stopped mid-run), so the page uses `count`.
#
# THE IMAGE IS READ, NOT RETYPED. The writers run the harness's own client image, read from
# CLIENT_IMAGE's default in storage/four-path/run.sh, and the script refuses to run unless that is an
# @sha256 index digest. m6/PINS.md says why.
#
# Usage (from the clone root):
#   OTHER_CONTAINERS=count bash m6/checkpoint-storm.sh
#   WRITERS=3 SIZE_MB=128 OTHER_CONTAINERS=count bash m6/checkpoint-storm.sh
#
# Memory: each writer's limit is SIZE_MB * 3 + 256 MiB, the harness's own formula (640 MiB at the
# default 128), so three writers fit the 8 GB profile's budget beside the idle harness clients.
#
# bash 3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

CONTEXT="${CONTEXT:-kind-grid-core}"
NAMESPACE="${NAMESPACE:-spike-02}"
CLAIM="${CLAIM:-spike02-nfs-rwx}"
PROBE_CM="${PROBE_CM:-spike-02-probe}"
WORKER_NODE="${WORKER_NODE:-grid-core-worker}"
WRITERS="${WRITERS:-3}"
SIZE_MB="${SIZE_MB:-128}"
MEASUREMENTS="${MEASUREMENTS:-grid-platform/dataplane-storage/measurements}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../storage/four-path/run.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- preconditions --------------------------------------------------------------------------------
case "${WRITERS}" in ''|*[!0-9]*) fail "WRITERS must be a whole number, got '${WRITERS}'" ;; esac
case "${SIZE_MB}" in ''|*[!0-9]*) fail "SIZE_MB must be a whole number, got '${SIZE_MB}'" ;; esac
[ "${WRITERS}" -ge 2 ] || fail "WRITERS must be at least 2: one writer alone is not a storm"
[ -n "${OTHER_CONTAINERS:-}" ] \
  || fail "set OTHER_CONTAINERS to count (the script counts the other containers on this machine), to a description of them, or to none: the record declares them"
CLUSTER="${CONTEXT#kind-}"
# Containers on this machine's engine that are not this cluster's own nodes. Names are never recorded.
others() { docker ps --format '{{.Names}}' | grep -cv "^${CLUSTER}-" || true; }
if [ "${OTHER_CONTAINERS}" = "count" ]; then
  command -v docker >/dev/null 2>&1 || fail "OTHER_CONTAINERS=count needs the docker CLI on PATH, which kind itself uses"
  OTHERS_AT_START="$(others)"
  case "${OTHERS_AT_START}" in ''|*[!0-9]*) fail "could not count the containers on this machine (read: '${OTHERS_AT_START}')" ;; esac
fi
[ -d grid-platform ] || fail "run this from the root of your clone: grid-platform/ is not in $(pwd)"
[ -f "${HARNESS}" ] || fail "the four-path harness is not at ${HARNESS}"

CLIENT_IMAGE="$(sed -n 's/^CLIENT_IMAGE="\${CLIENT_IMAGE:-\(.*\)}"$/\1/p' "${HARNESS}" | head -1)"
[[ "${CLIENT_IMAGE}" =~ @sha256:[0-9a-f]{64}$ ]] \
  || fail "could not read a digest-pinned CLIENT_IMAGE from ${HARNESS} (read: '${CLIENT_IMAGE}')"

kc get namespace "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "namespace ${NAMESPACE} does not exist. Apply the storage layer first: bash clusters/grid-core/addons/dataplane/create.sh"
CLAIM_PHASE="$(kcn get pvc "${CLAIM}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[ "${CLAIM_PHASE}" = "Bound" ] || fail "claim ${CLAIM} is not Bound (read: '${CLAIM_PHASE:-absent}'). Apply the storage layer first."
CLAIM_MODE="$(kcn get pvc "${CLAIM}" -o jsonpath='{.spec.accessModes[0]}')"
CLAIM_CLASS="$(kcn get pvc "${CLAIM}" -o jsonpath='{.spec.storageClassName}')"
[ "${CLAIM_MODE}" = "ReadWriteMany" ] || fail "claim ${CLAIM} is ${CLAIM_MODE}, not ReadWriteMany: concurrent writers need a shared claim"
kcn get configmap "${PROBE_CM}" >/dev/null 2>&1 \
  || fail "ConfigMap ${PROBE_CM} is absent: the harness's probe is what times every write here"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${MEASUREMENTS}/checkpoint-storm-${RUN_ID}"
mkdir -p "${OUT}"
LIMIT_MI=$((SIZE_MB * 3 + 256))
PAYLOAD_MI=$((SIZE_MB + 64))

cleanup() {
  # Clients first: only this script's writer Pods, never the server or the claim.
  kcn delete pod -l app=storm-writer --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "checkpoint storm"
echo "  writers:   ${WRITERS} warm-up writes one at a time, then ${WRITERS} concurrent, then 1 alone"
echo "  payload:   ${SIZE_MB} MiB per writer"
echo "  claim:     ${CLAIM} (${CLAIM_CLASS}, ${CLAIM_MODE}) in ${NAMESPACE}"
echo "  run id:    ${RUN_ID}"
if [ "${OTHER_CONTAINERS}" = "count" ]; then
  echo "  others:    ${OTHERS_AT_START} other container(s) on this machine at the start, counted with docker ps"
fi
echo

kcn get configmap "${PROBE_CM}" -o jsonpath='{.data.probe\.py}' > "${OUT}/probe.py"
[ -s "${OUT}/probe.py" ] || fail "the probe read from ConfigMap ${PROBE_CM} is empty"

# --- the writers ----------------------------------------------------------------------------------
echo "==> creating ${WRITERS} writer Pods on the shared claim"
i=0
while [ "${i}" -lt "${WRITERS}" ]; do
  kcn apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: storm-writer-${i}
  labels:
    app: storm-writer
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${WORKER_NODE}
  containers:
  - name: writer
    image: ${CLIENT_IMAGE}
    command: ["sleep", "infinity"]
    volumeMounts:
    - { name: probe, mountPath: /probe }
    - { name: payload, mountPath: /payload }
    - { name: target, mountPath: /target }
    resources:
      requests: { cpu: 100m, memory: 64Mi }
      limits: { memory: ${LIMIT_MI}Mi }
  volumes:
  - name: probe
    configMap: { name: ${PROBE_CM} }
  - name: payload
    emptyDir: { medium: Memory, sizeLimit: ${PAYLOAD_MI}Mi }
  - name: target
    persistentVolumeClaim: { claimName: ${CLAIM} }
EOF
  i=$((i + 1))
done
# Existence read after the apply: a namespace that is Terminating accepts an apply and creates nothing.
CREATED="$(kcn get pod -l app=storm-writer -o name | wc -l | tr -d ' ')"
[ "${CREATED}" = "${WRITERS}" ] || fail "${CREATED} of ${WRITERS} writer Pods exist after the apply"
kcn wait --for=condition=Ready pod -l app=storm-writer --timeout=300s >/dev/null \
  || fail "the writer Pods did not become Ready; read: kubectl --context ${CONTEXT} -n ${NAMESPACE} describe pod -l app=storm-writer"
echo "  ${WRITERS} writer Pods Ready on ${WORKER_NODE}"

# One probe run -> one results line. A probe that printed nothing or not JSON is recorded
# unmeasured with its reason, never dropped: a lost writer is itself a result.
record() { # mode writer raw-file
  if [ -s "$3" ] && jq -e . "$3" >/dev/null 2>&1; then
    jq -c --arg m "$1" --arg w "$2" '. + {mode: $m, writer: $w}' "$3" >> "${OUT}/results.jsonl"
  else
    jq -cn --arg m "$1" --arg w "$2" --arg e "$(head -c 300 "$3.err" 2>/dev/null | tr '\n' ' ')" \
      '{mode: $m, writer: $w, ok: false, error: ("probe produced no JSON: " + $e)}' >> "${OUT}/results.jsonl"
  fi
  rm -f "$3" "$3.err"
}

: > "${OUT}/results.jsonl"

# --- warm-up: each writer once, alone, in turn -------------------------------------------------------
# The volume's first writes happen here, so they are not inside the comparison below. Recorded, never
# dropped: the warm-up rows are part of the record and say what the cold first write cost this run.
echo "==> warm-up: each writer once, alone, in turn"
i=0
while [ "${i}" -lt "${WRITERS}" ]; do
  kcn exec "storm-writer-${i}" -- python3 /probe/probe.py fs /target "${SIZE_MB}" "storm-${RUN_ID}-w${i}" \
    > "${OUT}/raw-w${i}.json" 2> "${OUT}/raw-w${i}.json.err" || true
  record warm-up "storm-writer-${i}" "${OUT}/raw-w${i}.json"
  i=$((i + 1))
done

# --- concurrent: every writer at once --------------------------------------------------------------
echo "==> ${WRITERS} writers at once"
PIDS=""
i=0
while [ "${i}" -lt "${WRITERS}" ]; do
  kcn exec "storm-writer-${i}" -- python3 /probe/probe.py fs /target "${SIZE_MB}" "storm-${RUN_ID}-c${i}" \
    > "${OUT}/raw-c${i}.json" 2> "${OUT}/raw-c${i}.json.err" &
  PIDS="${PIDS} $!"
  i=$((i + 1))
done
for p in ${PIDS}; do wait "${p}" || true; done
i=0
while [ "${i}" -lt "${WRITERS}" ]; do
  record concurrent "storm-writer-${i}" "${OUT}/raw-c${i}.json"
  i=$((i + 1))
done

# --- single: one writer alone, on the same claim, after the burst has finished ----------------------
echo "==> 1 writer alone"
kcn exec storm-writer-0 -- python3 /probe/probe.py fs /target "${SIZE_MB}" "storm-${RUN_ID}-s0" \
  > "${OUT}/raw-s0.json" 2> "${OUT}/raw-s0.json.err" || true
record single storm-writer-0 "${OUT}/raw-s0.json"

# --- the record -----------------------------------------------------------------------------------
if [ "${OTHER_CONTAINERS}" = "count" ]; then
  OTHERS_AT_END="$(others)"
  OTHERS_LINE="${OTHERS_AT_START} when the storm started and ${OTHERS_AT_END} when it ended, counted by this script with docker ps (this cluster's own node containers left out, no names recorded)"
else
  OTHERS_LINE="${OTHER_CONTAINERS}"
fi
NODE_JSON="$(kc get node "${WORKER_NODE}" -o json)"
VM_LINE="$(printf '%s' "${NODE_JSON}" | jq -r '.status.nodeInfo.kernelVersion + " kernel, " + .status.capacity.cpu + " cpu, " + .status.capacity.memory + " memory, as the kind node reports it"')"
K8S_LINE="$(printf '%s' "${NODE_JSON}" | jq -r '.status.nodeInfo.kubeletVersion')"
ROWS="$(jq -r 'def rate: if .ok == true and (.write_seconds // 0) > 0 then ((.write_bytes / 1048576 / .write_seconds * 10 | round) / 10 | tostring) else "unmeasured — " + (.error // "no reason recorded") end; "| " + .mode + " | " + .writer + " | " + rate + " |"' "${OUT}/results.jsonl")"

{
  echo "# Checkpoint storm — ${WRITERS} writers at once against 1 writer alone, on one shared claim"
  echo
  echo "Host: $(uname -srm)"
  echo "Container runtime VM: ${VM_LINE}"
  echo "Kubernetes: ${K8S_LINE}"
  echo "Other containers on the VM: ${OTHERS_LINE}"
  echo "Harness run id: none — this script, not run.sh"
  echo
  echo "## Knobs"
  echo
  echo "| Knob | Value |"
  echo "|---|---|"
  echo "| Storm run id | \`${RUN_ID}\` |"
  echo "| Writers | ${WRITERS}, each writing once alone in turn (warm-up), then all ${WRITERS} at once, then storm-writer-0 alone |"
  echo "| Payload per writer per run | ${SIZE_MB} MiB, written with fsync inside the timed region |"
  echo "| Claim | \`${CLAIM}\` (StorageClass \`${CLAIM_CLASS}\`, ${CLAIM_MODE}) in \`${NAMESPACE}\` |"
  echo "| Writer image | \`${CLIENT_IMAGE}\` |"
  echo "| Writer memory limit | ${LIMIT_MI}Mi (SIZE_MB * 3 + 256, the harness's formula) |"
  echo "| Probe | \`probe.py\` beside this file, read from ConfigMap \`${PROBE_CM}\` |"
  echo
  echo "## Results"
  echo
  echo "| Mode | Writer | Write (MiB/s) |"
  echo "|---|---|---|"
  printf '%s\n' "${ROWS}"
  echo
  echo "The warm-up rows are the volume's first writes from these writers. They are recorded and are"
  echo "not part of the comparison: the concurrent rows and the single row both ran after them, on a"
  echo "volume every writer had already written to."
  echo
  echo "Scope: every figure is for this machine, this VM and this run. None is disk performance: the"
  echo "host's page cache sits under the VM's disk where the guest cannot evict it. The figures are"
  echo "recorded beside their configuration and are never compared to a threshold."
} > "${OUT}/storm-record.md"

WARMUP="$(grep -c '^| warm-up |' "${OUT}/storm-record.md" || true)"
CONCURRENT="$(grep -c '^| concurrent |' "${OUT}/storm-record.md" || true)"
SINGLE="$(grep -c '^| single |' "${OUT}/storm-record.md" || true)"
echo
cat "${OUT}/storm-record.md"
cleanup
echo
echo "OK: checkpoint storm recorded — ${WARMUP} warm-up row(s), ${CONCURRENT} concurrent row(s) and ${SINGLE} single row(s) in ${OUT}/storm-record.md; writer Pods removed before exit."

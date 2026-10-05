#!/usr/bin/env bash
# spike-core profile — create
# kind cluster "spike-core": 1 control-plane + 1 worker, Kubernetes v1.37.0.
#
# Mechanism: everything this phase spikes needs a REAL kubelet (DRA device
# preparation, probes, actual Pod execution), so this is a real kind cluster,
# never KWOK. The node image is pinned by @sha256 DIGEST, never by tag: a tag
# is mutable, and Phase 3's PLAT-01 pins by digest, so no tag-pinned node image
# may appear anywhere on the lab surface.
#
# Three Kubernetes 1.37 feature gates this course teaches are beta-or-alpha and
# DEFAULT-OFF, and they are create-time-immutable — they cannot be turned on
# after the cluster exists. gates_enabled_on_cluster() detects a cluster that
# predates them and prints the one-time recreate instruction instead of
# failing: a learner who already has a cluster gets told what to do, not an
# error.
#
# Usage:
#   bash create.sh                    # create, or reuse an existing cluster
#   KIND_IMAGE=... bash create.sh     # override the digest-pinned node image
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/spike-core.kubeconfig   # isolated; never touch other clusters
#
# ONE CLUSTER PROFILE AT A TIME (ROADMAP § Standing Constraints #1): tear down
# any other profile first. The declared 8 GB VM has no room for two.
#
# Idempotent: re-running reuses an existing cluster and exits 0.
# bash-3.2 compatible (macOS default shell).
# Pinned: kind v0.33.0 — the only kind release carrying 1.37 node images.
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Installing the pinned kind is not enough: on this build host a STALE copy
# resolves FIRST from a login shell, because /usr/local/bin and ~/.rd/bin both
# precede the brew prefix in PATH.
#   kind  /usr/local/bin/kind     v0.32.0  (stale)  shadows
#         /opt/homebrew/bin/kind  v0.33.0  (pinned)
# A kind v0.32.0 has no 1.37 node image at all, so a cluster created through
# the stale copy is the wrong cluster. This script therefore resolves the
# pinned binary ITSELF rather than trusting the caller's PATH — an
# `export PATH` only lives as long as the shell that ran it, and it is not
# something a learner on a clean machine has. Override with LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

# The kind pin that used to be inline here now lives in labs/tools/pinned-bin.sh
# so verify.sh, the kwok installer and the sim-router installer assert the same
# thing instead of each trusting the PATH prepend (WR-01). kubectl is asserted
# too: nothing asserted it anywhere before, although the course pins 1.37.x.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)/pinned-bin.sh"
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="spike-core"
# Kubernetes v1.37.0 node image, manifest-list (multi-arch) digest resolved by
# spike 0 with `docker buildx imagetools inspect`. The index digest is used
# rather than a per-arch digest so the same pin works on linux/arm64 (this
# host) and linux/amd64 (plan 01-05's CI arm). Per-arch digests are recorded in
# planning/lab-tests/spike-00-preflight.md.
KIND_IMAGE="${KIND_IMAGE:-kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
CONTEXT="${CONTEXT:-kind-spike-core}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"
export KUBECONFIG="${KUBECONFIG:-/tmp/spike-core.kubeconfig}"

# The three create-time-immutable gates this profile exists to carry.
# Space-separated so bash-3.2 can iterate it without arrays.
#   GenericWorkload            beta,  default-OFF in 1.37
#   DRAWorkloadResourceClaims  beta,  default-OFF in 1.37
#   NodeLifecycleConditions    alpha, default-OFF in 1.37
FEATURE_GATES="${FEATURE_GATES:-GenericWorkload DRAWorkloadResourceClaims NodeLifecycleConditions}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# Read-only probe: non-zero when ANY gate in FEATURE_GATES is not enabled on
# the live cluster. Two independent signals, because a gate is registered with
# different components:
#   1. the API server's own kubernetes_feature_enabled{name="<gate>"} gauge == 1
#   2. the rendered kube-apiserver static-pod command line carrying <gate>=true
gates_enabled_on_cluster() {
  local gate metrics cmdline
  metrics="$(kc get --raw /metrics 2>/dev/null || true)"
  cmdline="$(kc -n kube-system get pod \
               "kube-apiserver-${CLUSTER_NAME}-control-plane" \
               -o jsonpath='{.spec.containers[0].command}' 2>/dev/null || true)"
  [ -n "${metrics}${cmdline}" ] || return 1
  # Intentional IFS word-splitting of the space-separated gate list (bash).
  for gate in ${FEATURE_GATES}; do
    if printf '%s\n' "${metrics}" \
         | grep -E "^kubernetes_feature_enabled\{name=\"${gate}\"" \
         | grep -q ' 1$'; then
      continue
    fi
    case "${cmdline}" in
      *"${gate}=true"*) continue ;;
    esac
    return 1
  done
  return 0
}

# Idempotent existence gate. grep -qx (exact whole line), never grep -q:
# 'spike-core' must not match a future 'spike-core-dra'.
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kc cluster-info >/dev/null
  if ! gates_enabled_on_cluster; then
    echo "NOTE: this cluster was created WITHOUT the three Kubernetes 1.37 feature"
    echo "      gates this profile carries (${FEATURE_GATES// /, })."
    echo "      Feature gates are immutable after create — recreate once to enable them:"
    echo "        bash ${PROFILE_DIR}/teardown.sh && bash ${PROFILE_DIR}/create.sh"
  fi
  exit 0
fi

echo "Creating kind cluster '${CLUSTER_NAME}' (image: ${KIND_IMAGE}) ..."
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" \
  --wait 120s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# A feature gate is NOT enough on its own. GenericWorkload makes the SCHEDULER
# start a PodGroup informer against scheduling.k8s.io/v1beta1, but that is a
# BETA api group and Kubernetes disables beta groups by default. With the gate
# on and the group off, the scheduler logs
#   failed to list *v1beta1.PodGroup: the server could not find the requested resource
# forever, never finishes syncing its caches, and never reports Ready. Nothing
# then gets scheduled at all — kindnet and kube-proxy stay Pending, so no CNI
# is installed, so every node stays NotReady. The cluster looks "created" and
# is in fact dead. Measured live on this host; see
# planning/lab-tests/spike-00-preflight.md.
#
# So the api group has to be turned on too, which needs an apiserver flag,
# which needs a kubeadm patch:
#
# kubeadm dialect note: kind v0.33 + Kubernetes 1.37 render kubeadm **v1beta4**,
# where ClusterConfiguration extraArgs is a name/value LIST — not the v1beta3
# MAP that 304-kubeadv's profiles use. A verbatim port of a 304
# kubeadmConfigPatches block does not render here; the list form below is the
# 1.37 dialect.
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        # v1beta4 list form: name/value, NOT a map.
        - name: runtime-config
          value: "scheduling.k8s.io/v1beta1=true"
#
# All three gates are CREATE-TIME-IMMUTABLE: they cannot be enabled on a
# cluster that already exists. Each is DEFAULT-OFF in Kubernetes 1.37, so none
# of them is on in anyone else's cluster — the course must say so rather than
# presenting them as available.
featureGates:
  # beta, default-OFF in 1.37. The SINGLE gate carrying core Workload/PodGroup
  # at scheduling.k8s.io/v1beta1, gang scheduling and workload-aware
  # preemption. The two older gate names were REMOVED in 1.37 and collapsed
  # into this one; naming them dates the course to a 1.36-era draft.
  GenericWorkload: true
  # beta, default-OFF in 1.37. One ResourceClaim per PodGroup. With the gate
  # off, the ResourceClaim controller deliberately will not create a per-Pod
  # claim for a PodGroup member — a silent-pending failure mode.
  DRAWorkloadResourceClaims: true
  # ALPHA, default-OFF in 1.37. The MaintenancePlanned /
  # MaintenanceInProgress / DrainInProgress / Drained /
  # GracefulNodeShutdownInProgress Node conditions. Alpha: teach as direction
  # of travel, never as a runbook dependency.
  NodeLifecycleConditions: true
nodes:
  - role: control-plane
  - role: worker
    # extraMounts is CREATE-TIME-ONLY. Adding this block to a running cluster
    # silently does nothing — the bind mount is an argument to `docker run` for
    # the node container, so it only exists if it was present when the node was
    # created. Anything needing a host directory inside a node must be declared
    # here, before create.
    #
    # Why one exists at all: SPIKE-02's four-path storage harness needs one path
    # with NO CSI layer and NO container-overlay layer between the Pod and the
    # disk. kind's default `standard` StorageClass (local-path-provisioner)
    # resolves to /var/local-path-provisioner INSIDE the node container, i.e.
    # onto docker's overlay2 filesystem. A hostPath Pod volume pointed at this
    # mount instead lands directly on the bind-mounted host directory, so the
    # pvc-vs-hostpath delta is the overlay+provisioner cost rather than two
    # different disks.
    #
    # The host path is DELIBERATELY under /var/lib and not /tmp: on the Rancher
    # Desktop VM, `/` is tmpfs (RAM) while /var/lib, /var/lib/docker, /mnt/data
    # and /tmp are all /dev/vda1 ext4 — measured in
    # planning/lab-tests/raw/spike-02/env-declared.log. A path that silently
    # landed on tmpfs would report RAM speed as disk speed, which is the single
    # most dishonest number this harness could produce.
    #
    # dockerd creates the host directory if it is absent, so no pre-step is
    # required. The mount set of this node is part of the published harness
    # configuration (labs/storage/four-path/harness-config.md).
    extraMounts:
      - hostPath: /var/lib/313-spike-02-hostpath
        containerPath: /mnt/spike-02-hostpath
EOF

kubectl config use-context "${CONTEXT}" >/dev/null
echo
echo "spike-core profile ready: 1 control-plane + 1 worker."
echo "  node image: ${KIND_IMAGE}"
echo "  kubeconfig: ${KUBECONFIG} (isolated), context: ${CONTEXT}"
if gates_enabled_on_cluster; then
  echo "  feature gates: ENABLED — ${FEATURE_GATES// /, }"
else
  echo "  feature gates: off — this cluster carries none of ${FEATURE_GATES// /, }"
fi
echo "  labs dir:   ${LABS_DIR}"
echo "next: bash ${PROFILE_DIR}/verify.sh"

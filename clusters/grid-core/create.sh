#!/usr/bin/env bash
# grid-core profile — create
# kind cluster "grid-core": 1 control-plane + N workers, Kubernetes v1.37.0,
# where N comes from the requested SIZE and nothing else.
#
# This is the BASE profile. Every later module's cluster is this one plus an
# addon layer applied onto it, never a cluster of its own — the 8 GB budget
# cannot hold two clusters, so a module-named profile exists only where a
# CREATE-TIME-IMMUTABLE decision forces it.
#
# Mechanism: everything this course runs on the core path needs a REAL kubelet
# (DRA device preparation, probes, actual Pod execution), so this is a real kind
# cluster, never KWOK. The node image is pinned by @sha256 DIGEST, never by tag:
# a tag is mutable, and PLAT-01 pins by digest, so no tag-pinned node image may
# appear anywhere on the lab surface.
#
# Three Kubernetes 1.37 feature gates this course teaches are beta-or-alpha and
# DEFAULT-OFF, and they are create-time-immutable — they cannot be turned on
# after the cluster exists. gates_enabled_on_cluster() detects a cluster that
# predates them and prints the one-time recreate instruction instead of
# failing: a learner who already has a cluster gets told what to do, not an
# error.
#
# WHY SIZE IS A CREATE-TIME AXIS, not a convenience: `kind create` has exactly
# one subcommand (`cluster`). There is no `kind create node` and no node-add
# path, so NODE COUNT IS CREATE-TIME-IMMUTABLE. grid-core at SIZE=8 and
# grid-core at SIZE=16 are genuinely two different clusters, which is why the
# worker count is composed into the config below rather than patched afterwards.
#
# Usage:
#   bash create.sh                    # create at the default SIZE, or reuse
#   SIZE=16 bash create.sh            # 1 control-plane + 2 workers
#   KIND_IMAGE=... bash create.sh     # override the digest-pinned node image
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export SIZE=8                           # or 16. Accepted: 8, 16. Default: 8.
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # isolated; never touch other clusters
#
# EXPORT SIZE, do not pass it per command. The profile triple is three separate
# scripts, and a learner who creates at SIZE=16 must verify and tear down at the
# same size. An exported variable carries across all three; an argument has to
# be repeated and will be forgotten.
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
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

# labs/tools/pinned-bin.sh is the SINGLE place a tool pin is asserted. This
# script sources it and re-implements no version check: a second copy of a
# version comparison is a second thing that can be right while the first one is
# wrong. labs/tools/size-gate.sh is the single place SIZE is validated and the
# single place the skip token is emitted, for the same reason.
#
# WHICH ASSERTIONS THIS SCRIPT CALLS, AND WHY NOT ALL THREE. pinned-bin.sh
# defines three — kind, kubectl and helm — and this script calls two. That is
# deliberate and not an omission: creating the cluster does not invoke helm, so
# asserting helm here would refuse to build a cluster over a tool the build
# does not use. assert_helm_version is called by the three addon layers that
# DO invoke helm (addons/dra, addons/ops, addons/kueue-kwok), each immediately
# before it pulls or renders a chart.
#
# Stated explicitly because the sentence above is easy to over-read: "the
# single place a tool pin is ASSERTED" is a claim about where the assertions
# LIVE, not a claim that every script runs all of them. Until 2026-10-21 that
# distinction hid a real gap — helm's pin was asserted in no script anywhere,
# and this comment read as though it were covered. See
# planning/lab-tests/03-setup-learner-qa.md § "Finding 4's gap".
LABS_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)"
. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-core"
# Kubernetes v1.37.0 node image, manifest-list (multi-arch) digest resolved by
# spike 0 with `docker buildx imagetools inspect`. The index digest is used
# rather than a per-arch digest so the same pin works on linux/arm64 (this
# host) and linux/amd64 (the CI arm). Per-arch digests are recorded in
# planning/lab-tests/spike-00-preflight.md.
KIND_IMAGE="${KIND_IMAGE:-kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
CONTEXT="${CONTEXT:-kind-grid-core}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"
# The kubeconfig path moves with the cluster name IN THE SAME COMMIT as the
# cluster name and the context. Moving one without the others leaves a stale
# kubeconfig behind for a cluster that no longer exists, and `kubectl` reads a
# stale kubeconfig perfectly happily — it answers for a cluster that is gone
# rather than reporting that it is gone.
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

# The worker count for the requested SIZE, read from course.config.json's
# lab.sizes block. Not a literal here: the prose in that config and the code in
# this script must not be able to disagree.
WORKER_NODES="$(size_value worker_nodes)"

# THE BUDGET TRAVELS WITH THE SIZE.
#
# labs/tools/measure.sh defaults BUDGET_MB to 4500 and documents that as *the
# 8 GB-profile lab budget*. A SIZE=16 reading adjudicated against 4500 would
# mark every 16 GB profile "over" for no reason at all. measure.sh's own default
# is deliberately NOT changed — 4500 is correct for the unqualified case and is
# what every existing spike record was measured against, so moving it would
# retro-invalidate those records.
#
# WHAT THE EXPORT DOES AND DOES NOT REACH, stated because the obvious reading is
# wrong. An export reaches a CHILD process, so a measure.sh invoked from inside
# this script or from a lab script that ran after it inherits the right budget.
# It does NOT reach `measure.sh run grid-core -- bash create.sh`, because there
# measure.sh is the PARENT and reads BUDGET_MB at its own startup, before this
# script exists. So the export is necessary and not sufficient, and the closing
# output below prints the exact invocation with the budget already filled in —
# a number the operator has to remember is a number that gets forgotten.
BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

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

# --- which clusters exist, read ONCE ------------------------------------------
# Captured into a variable and matched with `case`, deliberately, rather than
# asserted through `kind get clusters | grep -qx`. Under `set -o pipefail` a
# pipeline whose reader exits on the first match returns 141 — SIGPIPE — on a
# SUCCESSFUL match, and that false negative produced a near-miss wrong verdict
# in Phase 1. The newline fencing below is what makes the match EXACT: an
# unfenced substring test would let 'grid-core' match 'grid-core-dra', and with
# grid-sandbox also in play a prefix match has stopped being hypothetical.
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"

kind_cluster_exists() {
  case "
${KIND_CLUSTERS}
" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# --- one profile at a time, enforced by REFUSING rather than racing -----------
# The standing constraint is one cluster profile at a time: the declared 8 GB VM
# reports 7.74 GiB and has no room for two. So when a cluster exists whose name
# is one of THIS COURSE'S lab profiles and is not this one, create refuses and
# names the exact teardown command for the conflicting profile.
#
# IT REFUSES, IT DOES NOT AUTO-TEAR-DOWN. Deleting a cluster a learner may be
# mid-lab on is not a decision a create script gets to take — the cost of being
# wrong is somebody's unsaved work, and the cost of refusing is one command they
# then run deliberately.
#
# THE LIST IS THIS COURSE'S PROFILES ONLY, and that boundary is the point. A
# cluster from another course, another project or a learner's own experiment is
# not this script's business to refuse; refusing on any unknown cluster name
# would make the profile unusable on a machine that does anything else. Such a
# cluster still competes for the same memory, so it earns a NOTE rather than a
# refusal — information, not a veto.
#
# THE LIST IS THE ALLOWED PROFILE SET AND NOTHING ELSE, trimmed in plan 03-04
# from a six-name draft that still carried grid-dataplane, grid-serving,
# grid-ops and grid-capstone. Those four never passed the admission test and
# became addon layers under addons/, so refusing on them was refusing on
# clusters that cannot exist — harmless at runtime, but it left four
# module-named profiles written down as if they were legitimate, which is the
# stale second copy of a decision that STANDARDS.md section profile-set now
# fixes in one place. `course.config.json`'s lab.profiles.allowed is the
# machine-readable source; this literal is a shell copy of it, and
# scripts/standards/profile-set.mjs is what goes red if a module-named profile
# reappears on the tree.
LAB_PROFILES="${LAB_PROFILES:-grid-core grid-sandbox}"

for _profile in ${LAB_PROFILES}; do
  if [ "${_profile}" = "${CLUSTER_NAME}" ]; then continue; fi
  if kind_cluster_exists "${_profile}"; then
    echo "FAIL: the lab profile '${_profile}' is already running, and this course runs ONE profile at a time." >&2
    echo "      The declared 8 GB VM reports 7.74 GiB; it has no room for two clusters." >&2
    echo "      Tear that profile down first, then re-run this:" >&2
    echo "        bash ${LABS_DIR}/clusters/${_profile}/teardown.sh" >&2
    echo "        bash ${PROFILE_DIR}/create.sh" >&2
    echo "      This script refuses rather than deleting '${_profile}' for you: you may be mid-lab on it," >&2
    echo "      and that is not a decision a create script gets to take." >&2
    exit 1
  fi
done

# A foreign cluster is reported, never refused. See the note above.
for _other in ${KIND_CLUSTERS}; do
  _known=0
  for _profile in ${LAB_PROFILES}; do
    if [ "${_other}" = "${_profile}" ]; then _known=1; fi
  done
  if [ "${_known}" -eq 0 ]; then
    echo "NOTE: a kind cluster '${_other}' is running and is not one of this course's lab profiles."
    echo "      It is left alone, but it competes for the same VM memory. If this profile runs"
    echo "      short of memory, or if you are about to take an RSS measurement, delete it first:"
    echo "        kind delete cluster --name ${_other}"
  fi
done

# Idempotent existence gate.
if kind_cluster_exists "${CLUSTER_NAME}"; then
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

# --- the config, COMPOSED rather than read from a committed file --------------
# The static half is a quoted heredoc; the worker entries are appended below,
# because their COUNT is the one thing that varies with SIZE and the count is
# create-time-immutable. Composing it here is what makes that decision visible
# at the moment it is taken, rather than hidden in one of two committed config
# files that can drift apart.
#
# It is composed into a TEMP FILE rather than a shell variable, and that is a
# bash-3.2 constraint rather than a preference: bash 3.2 — the macOS default,
# and the floor this course targets — cannot parse a heredoc inside a command
# substitution. `VAR="$(cat <<'EOF' ... EOF)"` is a syntax error there, reported
# as `unexpected EOF while looking for matching ')'` at a line nowhere near the
# real cause. Measured on this host, bash 3.2.57.
#
# `mktemp` is given a full template ending in Xs rather than `mktemp -t name`:
# GNU mktemp rejects a template with too few Xs, so the short form works on
# macOS and fails on the Linux CI runner.
KIND_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/grid-core-kind-config.XXXXXX")"
# Removed on every exit path, including a failed create — a leftover config is
# the kind of stale artifact a later run reads without noticing.
trap 'rm -f "${KIND_CONFIG_FILE}"' EXIT

cat > "${KIND_CONFIG_FILE}" <<'EOF'
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
# where ClusterConfiguration extraArgs is a name/value LIST — not the MAP that
# 304-kubeadv's profiles use. A verbatim port of a 304 kubeadmConfigPatches
# block does not render here; the list form below is the 1.37 dialect.
#
# THE PATCH DELIBERATELY DECLARES NO apiVersion, and that is the portable form
# rather than an omission. kind's patch matcher requires the `kind` to match and
# IGNORES the apiVersion when the patch does not specify one, so a patch written
# this way matches whatever dialect kind renders. A patch naming the superseded
# dialect matches nothing and is DROPPED IN SILENCE — the function that would
# report an unused patch is not implemented — so `kind create cluster` exits 0,
# the cluster comes up, and the flag is simply absent. STANDARDS.md section C16
# is the rule, and scripts/standards/kubeadm-dialect.mjs is the gate that stops
# it re-entering.
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        # v1beta4 list form: name/value, NOT a map. kind already emits a
        # runtime-config entry here, so this UPDATES it rather than adding one;
        # a profile needing two values must put both in one comma-separated
        # value, because a second entry with the same name overwrites the first.
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
EOF

# One worker entry per lab.sizes.<SIZE>.worker_nodes.
#
# extraMounts is CREATE-TIME-ONLY. Adding this block to a running cluster
# silently does nothing — the bind mount is an argument to `docker run` for the
# node container, so it only exists if it was present when the node was created.
# Anything needing a host directory inside a node must be declared here, before
# create.
#
# Why one exists at all: SPIKE-02's four-path storage harness needs one path
# with NO CSI layer and NO container-overlay layer between the Pod and the disk.
# kind's default `standard` StorageClass (local-path-provisioner) resolves to
# /var/local-path-provisioner INSIDE the node container, i.e. onto docker's
# overlay2 filesystem. A hostPath Pod volume pointed at this mount instead lands
# directly on the bind-mounted host directory.
#
# The host path is DELIBERATELY under /var/lib and not /tmp: on the Rancher
# Desktop VM, `/` is tmpfs (RAM) while /var/lib, /var/lib/docker, /mnt/data and
# /tmp are all /dev/vda1 ext4 — measured in
# planning/lab-tests/raw/spike-02/env-declared.log. A path that silently landed
# on tmpfs would report RAM speed as disk speed, which is the single most
# dishonest number this harness could produce.
#
# THE HOST PATH KEEPS ITS SPIKE-ERA NAME, deliberately. It is invisible to a
# learner, it already exists on the VM, and renaming it would touch the
# published harness documentation (labs/storage/four-path/run.sh and
# harness-config.md) for no gain. The thing that had to move with the profile
# rename is the cluster name, the context and the kubeconfig — not a directory
# nobody reads.
#
# EVERY worker gets the mount, not just the first. At SIZE=16 the harness may
# land on either worker, and a mount present on one node and absent on the other
# is a harness that works until the scheduler picks differently.
#
# dockerd creates the host directory if it is absent, so no pre-step is required.
_w=0
while [ "${_w}" -lt "${WORKER_NODES}" ]; do
  cat >> "${KIND_CONFIG_FILE}" <<'WORKER_ENTRY'
  - role: worker
    extraMounts:
      - hostPath: /var/lib/313-spike-02-hostpath
        containerPath: /mnt/spike-02-hostpath
WORKER_ENTRY
  _w=$((_w + 1))
done

echo "Creating kind cluster '${CLUSTER_NAME}' at SIZE=${SIZE} (image: ${KIND_IMAGE}) ..."
echo "  1 control-plane + ${WORKER_NODES} worker(s) — node count is create-time-immutable."
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" \
  --wait 120s --config "${KIND_CONFIG_FILE}"

kubectl config use-context "${CONTEXT}" >/dev/null
echo
echo "grid-core profile ready at SIZE=${SIZE}: 1 control-plane + ${WORKER_NODES} worker(s)."
echo "  node image: ${KIND_IMAGE}"
echo "  kubeconfig: ${KUBECONFIG} (isolated), context: ${CONTEXT}"
if gates_enabled_on_cluster; then
  echo "  feature gates: ENABLED — ${FEATURE_GATES// /, }"
else
  echo "  feature gates: off — this cluster carries none of ${FEATURE_GATES// /, }"
fi
echo "  labs dir:   ${LABS_DIR}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: SIZE=${SIZE} bash ${PROFILE_DIR}/verify.sh"
# The measurement invocation, printed with the budget and the filter already
# filled in. BUDGET_MB is restated on the command line and not left to the
# export, because measure.sh is the PARENT in this invocation and cannot inherit
# it. FILTER and the profile LABEL are different things: the label is what a
# record publishes under, the filter is what names the running containers, and
# conflating them is what produced zero-byte baseline files earlier in this
# project.
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-size${SIZE}-gates-on FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_DIR}/tools/measure.sh read grid-core-size${SIZE}"
echo "              (read it BEFORE teardown — kind delete removes the cgroups the figure comes from)"

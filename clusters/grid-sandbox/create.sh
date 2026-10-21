#!/usr/bin/env bash
# grid-sandbox profile — create
# kind cluster "grid-sandbox": 1 control-plane + N workers, Kubernetes v1.37.0,
# built from a LOCALLY BUILT node image whose containerd already knows the
# sandbox runtime handler. N comes from the requested SIZE and nothing else.
#
# WHY THIS IS A PROFILE AND NOT AN ADDON LAYER — the one admission test, and
# the only profile in this course that passes it.
#
# Every other module-specific need in this phase became an addon layer applied
# onto a running grid-core: labs/clusters/grid-core/addons/{dra,kueue-kwok,
# dataplane,serving,ops}. The test a dedicated profile has to pass is a
# CREATE-TIME-IMMUTABLE decision — a kind feature gate, a node-image swap, a
# custom node image, or a kubelet/containerd setting that cannot change after
# the cluster exists. Convenience is not a reason.
#
# This profile passes it, and the mechanism is exact. A RuntimeClass is only a
# NAME. What resolves that name is a runtime handler registered in the node's
# /etc/containerd/config.toml, and containerd reads that file ONCE, at start.
# labs/sandbox/runsc-node/Dockerfile writes the handler into the config at
# IMAGE BUILD TIME, and the image is the --image argument `kind create cluster`
# consumes. There is no path from a running cluster to a node whose containerd
# knows a handler it did not start with, so this cannot be a layer. The image
# and the profile are one decision.
#
# The four candidates that did NOT pass — grid-dataplane, grid-serving,
# grid-ops, grid-capstone — and the reasons each failed are written in
# STANDARDS.md § profile-set, together with the promotion path a later phase
# must follow to add a fifth. scripts/standards/profile-set.mjs is the gate
# that goes red if one reappears without it.
#
# THREE DIFFERENCES FROM THE BASE PROFILE, each deliberate.
#
#   1. --image is the LOCALLY BUILT node image, BY TAG. That is the one
#      enumerated exemption from the digest-pin rule (PLAT-01), and the reason
#      is specific rather than a pattern hole: the image is built on the
#      learner's own machine by labs/sandbox/runsc-node/build.sh, never pulled
#      from a registry and never published, so there is no registry round-trip
#      for a digest to protect. Its own BASE is still pinned by index digest
#      inside that Dockerfile, which is where the pin belongs.
#
#      The image's PRESENCE is asserted here rather than left to `kind create`
#      to discover. A kind create against an absent local image attempts a
#      REGISTRY PULL of a name that exists in no registry, and the failure
#      arrives as a pull error that names docker.io rather than the build
#      script the learner actually needs to run. Worse, the tag was renamed in
#      plan 03-04 and the spike-era name may still be resident in a
#      developer's store, so an assert-then-name is the difference between
#      "run build.sh" and a cluster quietly coming up on a stale image.
#
#   2. NO FEATURE GATES, and that is a measured decision rather than an
#      omission. The base profile's three default-off 1.37 gates
#      (GenericWorkload, DRAWorkloadResourceClaims, NodeLifecycleConditions)
#      cost ~427 MiB measured and are irrelevant to every question this
#      profile exists to answer — the sandbox path is a containerd runtime
#      handler and a node.k8s.io/v1 RuntimeClass, neither of which is gated.
#      RuntimeClass has been stable since Kubernetes 1.20.
#
#      gates_enabled_on_cluster() is kept below anyway, in the base profile's
#      shape, because the next person who does need a gate here will need the
#      detector and reinventing it is how five scripts drift apart. With no
#      gates declared it reports `none-declared` rather than success — a
#      detector that returns "all present" over an empty list is the vacuous
#      pass this phase keeps finding, and it is closed here by construction.
#
#   3. NO STORAGE BIND MOUNT. grid-core carries an extraMounts hostPath for
#      M6's four-path storage comparison. This profile runs M11's sandbox lab
#      and never reads that path, and extraMounts is create-time-only, so
#      carrying it would be a permanent cost for a path nothing here uses.
#
# DOES THE NODE COUNT VARY WITH SIZE? YES — by the same axis as the base
# profile, 1 control-plane + lab.sizes.<SIZE>.worker_nodes, read from
# course.config.json. It is stated rather than left to be inferred because the
# alternative shape (a fixed single-node cluster, which is what the CI arm
# uses) was a live option: `kind create` has no node-add path, so node count is
# create-time-immutable and a profile that fixed it at one would be a THIRD
# create-time axis nobody declared. Varying with SIZE keeps one axis.
#
# ONE PROFILE AT A TIME, AND THIS SCRIPT'S HANDLING IS THE INVERSE OF THE BASE
# PROFILE'S. State it plainly, because the two scripts do opposite things:
#
#   grid-core/create.sh REFUSES when a conflicting profile is up. Deleting a
#   cluster a learner may be mid-lab on is not a create script's decision.
#
#   THIS SCRIPT TEARS grid-core DOWN. A dedicated profile has to replace the
#   base to exist at all — the declared 8 GB VM reports 7.74 GiB and has no
#   room for two clusters — so refusing would mean the profile could never be
#   created by the one command that creates it. It says what it is about to
#   delete and names the command that restores it BEFORE it proceeds, and
#   grid-sandbox/teardown.sh restores the base automatically, so the deletion
#   is a loan rather than a loss. Nothing in grid-core survives the delete:
#   continuity lives in the labs/grid-platform Git repository, never in a
#   running cluster.
#
# Usage:
#   bash create.sh                    # create at the default SIZE, or reuse
#   SIZE=16 bash create.sh            # 1 control-plane + 2 workers
#   KIND_IMAGE=... bash create.sh     # override the locally built node image
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export SIZE=8                           # or 16. Accepted: 8, 16. Default: 8.
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/grid-sandbox.kubeconfig   # isolated; never touch other clusters
#
# EXPORT SIZE, do not pass it per command — the profile triple is three
# separate scripts and a learner who creates at 16 must verify at 16.
#
# Idempotent: an existing grid-sandbox cluster is REUSED and this exits 0.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# A prepend is not a resolution guarantee: on this host /usr/local/bin/kind is
# a stale v0.32.0 that has no 1.37 node image at all, and it resolves FIRST
# from a login shell. Both asserts are SOURCED from the one place that owns
# them. Override with LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

LABS_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)"
. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-sandbox"
# THE DIGEST-PIN EXEMPTION, by tag, enumerated and reasoned above and in
# STANDARDS.md § profile-set. Built by labs/sandbox/runsc-node/build.sh.
KIND_IMAGE="${KIND_IMAGE:-313-grid-sandbox-node:v1.37.x-runsc}"
CONTEXT="${CONTEXT:-kind-grid-sandbox}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../../" && pwd)"
BASE_PROFILE="grid-core"
BASE_PROFILE_DIR="${LABS_DIR}/clusters/${BASE_PROFILE}"
# The base profile's OWN kubeconfig, never this one. An inherited KUBECONFIG is
# how a teardown-and-recreate writes grid-core's context into the sandbox's
# file and leaves the learner's next `kubectl` pointing at a cluster that is
# gone.
BASE_KUBECONFIG="${BASE_KUBECONFIG:-/tmp/grid-core.kubeconfig}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-sandbox.kubeconfig}"

WORKER_NODES="$(size_value worker_nodes)"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

# Deliberately EMPTY. See difference 2 in the header. Set it to enable gates
# here, and add them to the kind config below in the same edit — a gate named
# in this variable and absent from the config would make the detector report a
# cluster that is correctly configured as broken.
FEATURE_GATES="${FEATURE_GATES:-}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# Kept in the base profile's shape. Three return states, not two:
#   0  every declared gate is on
#   1  at least one declared gate is off, or the API surface was unreadable
#   2  NO GATE IS DECLARED — this profile's case
# The third exists because a for-loop over an empty list falls through to
# `return 0`, so a two-state version of this function would report "all gates
# enabled" on a cluster carrying none. That is a vacuous pass, and the caller
# below prints the honest line instead.
gates_enabled_on_cluster() {
  local gate metrics cmdline gauge
  [ -n "${FEATURE_GATES}" ] || return 2
  metrics="$(kc get --raw /metrics 2>/dev/null || true)"
  cmdline="$(kc -n kube-system get pod \
               "kube-apiserver-${CLUSTER_NAME}-control-plane" \
               -o jsonpath='{.spec.containers[0].command}' 2>/dev/null || true)"
  [ -n "${metrics}${cmdline}" ] || return 1
  for gate in ${FEATURE_GATES}; do
    # Captured into a variable and matched with `case`, never
    # `cmd | grep -q PATTERN`: under `set -o pipefail` a SUCCESSFUL grep match
    # returns 141, because grep exits the instant it matches and the writer
    # takes SIGPIPE. That nearly produced a false architecture verdict in
    # Phase 1. `sed -n '1,1p'` reads to EOF, so it cannot reproduce the hazard
    # the way `head` would.
    gauge="$(printf '%s\n' "${metrics}" \
             | sed -n "/^kubernetes_feature_enabled{name=\"${gate}\"/p" \
             | sed -n '1,1p')"
    case "${gauge}" in
      *" 1") continue ;;
    esac
    case "${cmdline}" in
      *"${gate}=true"*) continue ;;
    esac
    return 1
  done
  return 0
}

KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"

# Whole-line match, never a substring: 'grid-core' must not match
# 'grid-core-dra', and with grid-sandbox in play a prefix match has stopped
# being hypothetical. `case` on a newline-delimited haystack rather than
# `grep -qx` through a pipe, for the SIGPIPE reason above.
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

if kind_cluster_exists "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists — reusing it."
  kc cluster-info >/dev/null
  echo "  node image is create-time-immutable; this script did not re-apply it."
  echo "next: SIZE=${SIZE} bash ${PROFILE_DIR}/verify.sh"
  exit 0
fi

# --- the node image must be in the LOCAL store, and it is asserted here -------
# Never `kind load`: that side-loads an image into an already-running cluster,
# and this image's whole purpose is to BE the node. A node whose containerd
# configuration was fixed at image build cannot be given a new handler by
# loading a second image beside it.
if ! docker image inspect "${KIND_IMAGE}" >/dev/null 2>&1; then
  echo "FAIL: the node image '${KIND_IMAGE}' is not in the local image store." >&2
  echo "      This profile is created FROM that image — the sandbox runtime handler is" >&2
  echo "      written into its containerd configuration at IMAGE BUILD TIME and cannot be" >&2
  echo "      added to a running cluster. Build it first:" >&2
  echo "        bash ${LABS_DIR}/sandbox/runsc-node/build.sh" >&2
  echo "        bash ${PROFILE_DIR}/create.sh" >&2
  echo "      The image is never published, so there is no registry to pull it from; without" >&2
  echo "      this assert 'kind create' would attempt a pull of a name that exists nowhere." >&2
  echo "      If you have an image from before plan 03-04's rename, it carries the spike-era" >&2
  echo "      name and is NOT used by tag: rebuild rather than retag, so the artefact and the" >&2
  echo "      Dockerfile that is checked by the standards gate stay the same thing." >&2
  exit 1
fi

# --- one profile at a time: the base is torn down, with its restore named -----
if kind_cluster_exists "${BASE_PROFILE}"; then
  echo "NOTE: the base profile '${BASE_PROFILE}' is running, and this course runs ONE"
  echo "      cluster profile at a time — the declared 8 GB VM reports 7.74 GiB and has"
  echo "      no room for two. This script will DELETE it now."
  echo
  echo "      Everything running on '${BASE_PROFILE}' goes with it. Continuity for this"
  echo "      course lives in the ${LABS_DIR}/grid-platform Git repository, never in a"
  echo "      running cluster, so nothing you are meant to keep is in there."
  echo
  echo "      It comes back automatically: ${PROFILE_DIR}/teardown.sh deletes this"
  echo "      sandbox profile AND recreates '${BASE_PROFILE}'. To restore it by hand:"
  echo "        SIZE=${SIZE} bash ${BASE_PROFILE_DIR}/create.sh"
  echo
  echo "      (The base profile's create.sh does the opposite and REFUSES when a"
  echo "       conflicting profile is up. A dedicated profile has to replace the base to"
  echo "       exist at all, which is why this one deletes instead of refusing.)"
  echo
  env KUBECONFIG="${BASE_KUBECONFIG}" bash "${BASE_PROFILE_DIR}/teardown.sh"
  KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
fi

LAB_PROFILES="${LAB_PROFILES:-grid-core grid-sandbox}"

for _other in ${KIND_CLUSTERS}; do
  _known=0
  for _profile in ${LAB_PROFILES}; do
    if [ "${_other}" = "${_profile}" ]; then _known=1; fi
  done
  if [ "${_known}" -eq 0 ]; then
    echo "NOTE: a kind cluster '${_other}' is running and is not one of this course's lab profiles."
    echo "      It is left alone — it is not this course's to delete — but it competes for the"
    echo "      same VM memory. If this profile runs short of memory, or if you are about to"
    echo "      take an RSS measurement, delete it first:"
    echo "        kind delete cluster --name ${_other}"
  fi
done

KIND_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/grid-sandbox-kind-config.XXXXXX")"
trap 'rm -f "${KIND_CONFIG_FILE}"' EXIT

# No featureGates block and no extraMounts — see differences 2 and 3. No
# kubeadm patch either: this profile needs no API group the server does not
# serve by default, so there is no patch to get the dialect wrong in.
cat > "${KIND_CONFIG_FILE}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

_w=0
while [ "${_w}" -lt "${WORKER_NODES}" ]; do
  printf '%s\n' '  - role: worker' >> "${KIND_CONFIG_FILE}"
  _w=$((_w + 1))
done

echo "Creating kind cluster '${CLUSTER_NAME}' at SIZE=${SIZE} (image: ${KIND_IMAGE}) ..."
echo "  1 control-plane + ${WORKER_NODES} worker(s) — node count is create-time-immutable."
echo "  the node image carries the sandbox runtime handler in its containerd config,"
echo "  written at image build — which is the create-time-immutable decision that makes"
echo "  this a profile rather than an addon layer."
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}" \
  --wait 120s --config "${KIND_CONFIG_FILE}"

kubectl config use-context "${CONTEXT}" >/dev/null
echo
echo "grid-sandbox profile ready at SIZE=${SIZE}: 1 control-plane + ${WORKER_NODES} worker(s)."
echo "  node image: ${KIND_IMAGE} (locally built — the enumerated digest-pin exemption)"
echo "  kubeconfig: ${KUBECONFIG} (isolated), context: ${CONTEXT}"
gates_enabled_on_cluster && _gates_rc=0 || _gates_rc=$?
case "${_gates_rc}" in
  0) echo "  feature gates: ENABLED — ${FEATURE_GATES// /, }" ;;
  2) echo "  feature gates: none declared by this profile, and none asserted. The sandbox"
     echo "                 path is a containerd runtime handler plus a node.k8s.io/v1"
     echo "                 RuntimeClass, stable since Kubernetes 1.20 and not gated." ;;
  *) echo "  feature gates: declared (${FEATURE_GATES// /, }) but NOT all enabled on this cluster" ;;
esac
echo "  labs dir:   ${LABS_DIR}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: SIZE=${SIZE} bash ${PROFILE_DIR}/verify.sh"
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-sandbox-size${SIZE}-runsc FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_DIR}/tools/measure.sh read grid-sandbox-size${SIZE}"
echo "              (read it BEFORE teardown — kind delete removes the cgroups the figure comes from)"
echo "  teardown:   bash ${PROFILE_DIR}/teardown.sh"
echo "              (deletes this profile AND recreates '${BASE_PROFILE}' — you are never left with no cluster)"

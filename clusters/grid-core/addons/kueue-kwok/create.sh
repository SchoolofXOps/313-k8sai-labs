#!/usr/bin/env bash
# addon-kueue-kwok — apply the QUEUEING + SIMULATED-FLEET layer onto a running
# grid-core.
#
# THIS IS A LAYER, NOT A PROFILE. It creates no cluster. It applies onto the
# cluster labs/clusters/grid-core/create.sh already made, and its teardown.sh
# removes the layer and LEAVES THAT CLUSTER RUNNING.
#
# Two installs in one layer, in this order:
#   1. Kueue v0.20.0 from the OCI chart, rendered from a digest-VERIFIED local
#      archive with the committed kueue-values.yaml, its controller image
#      digest-pinned into the rendered output;
#   2. the kwok ATTACH-MODE simulated fleet, driven through
#      labs/kwok/attach/setup.sh rather than duplicated here;
#   3. this layer's own quota + Topology-Aware Scheduling object set
#      (tas-gangs-v1beta2.yaml), so the layer's verify has Workloads to read
#      admission decisions off rather than an empty cluster to pass over.
#
# ---------------------------------------------------------------------------
# WHY ATTACH MODE, AND WHY `kwokctl` IS NOT AN OPTION HERE
# ---------------------------------------------------------------------------
# ATTACH MODE IS FORCED, NOT PREFERRED. Two independent blockers, either one
# sufficient:
#
#   1. kwok v0.8.0's `registry.k8s.io/kwok/cluster` images STOP AT
#      `v0.8.0-k8s.v1.36.1`. There is no Kubernetes 1.37 cluster image and there
#      is no newer kwok release. This course pins 1.37, so the tool cannot build
#      the cluster this course teaches on at all.
#   2. v0.8.0's optional components (Kueue, JobSet, LWS, descheduler,
#      scheduler-plugins) are scoped to its own container-runtime backends —
#      i.e. to a fake control plane of its own — so they are not reachable from
#      a real kind cluster either.
#
# CLAUDE.md's stack table says v0.8.0's optional components collapse M5's and
# M7's setup from multi-step Helm installs to a single flagged cluster-create
# invocation of that tool. FOR A 1.37 COURSE THAT IS WRONG, and this sentence
# exists so nobody re-reaches for it: the path does not exist at the pinned
# Kubernetes version.
#
# The claim is DESCRIBED rather than quoted, so a mechanical scan for the
# forbidden invocation cannot hit the explanation of why it is forbidden — the
# same self-reference resolution this project's standards fixed for the
# superseded API group.
#
# And the reason that matters beyond tooling: a separate fake control plane would
# make every command below exit 0 while proving nothing. A fake scheduler
# deciding about fake nodes is not a scheduling result.
#
# WHO DECIDES WHAT — three owners, one order, and conflating them is what makes a
# fake result look like a real one:
#   Kueue              reserves the quota and narrows a gang to ONE topology
#                      domain by writing a nodeSelector, then unsuspends the Job;
#   the REAL kube-scheduler on grid-core picks the node inside that domain and
#                      performs the binding;
#   the kwok controller fakes the kubelet, AFTER a binding it had no part in.
#
# ---------------------------------------------------------------------------
# THE ONE KNOB THAT CHANGES WHAT THE LAB MEASURES
# ---------------------------------------------------------------------------
# `FAKE_NODES` separates two different labs that share this layer, and a fleet of
# the wrong size does not break an experiment — it SILENTLY INVERTS WHICH
# CONSTRAINT BINDS, which is worse:
#
#   FLEET=collision  (default)  lab.sizes.<SIZE>.kwok_collision_nodes
#                               The three-tenant quota collision. Deliberately
#                               small and deliberately NOT grown with the machine:
#                               a collision is an accounting event bounded by
#                               arithmetic, not by RSS.
#   FLEET=scale                 lab.sizes.<SIZE>.kwok_scale_nodes
#                               The inventory / topology-at-scale lab. At 500
#                               nodes the free fleet capacity is roughly 3950 cpu,
#                               so any quota a reader can hold in their head is
#                               orders of magnitude below capacity and a topology
#                               REFUSAL stops being showable at all — every gang
#                               fits somewhere.
#
# Both numbers come from course.config.json; neither is a literal in this file.
# An explicit `FAKE_NODES=<n>` overrides the profile and is what plan 03-03's
# measured collision run uses.
#
# ---------------------------------------------------------------------------
# ORDERING — the one constraint in this phase that is NOT free
# ---------------------------------------------------------------------------
# The Kueue `Configuration` in kueue-values.yaml maps device classes BY NAME, so
# the DRA layer's DeviceClass must exist BEFORE this layer's Configuration can
# account for it:
#
#   bash labs/clusters/grid-core/addons/dra/create.sh
#   bash labs/clusters/grid-core/addons/kueue-kwok/create.sh
#
# This script PREFLIGHTS that rather than assuming it, and the full reasoning —
# including what a mapping naming an absent DeviceClass does (nothing, silently)
# — is in kueue-values.yaml's own header.
#
# ---------------------------------------------------------------------------
# HOW THE OBJECT SET IS PINNED
# ---------------------------------------------------------------------------
# The chart is pulled at an exact `--version`, its OCI manifest digest is
# compared against the pin below, and the render then runs FROM THE VERIFIED
# LOCAL ARCHIVE — never from a floating version range. The chart ships its
# controller image by TAG (`templates/manager/manager.yaml:60` renders
# `repository:tag`, so `image.tag` cannot carry a digest), so the manifest-list
# INDEX digest is resolved at install time and substituted into the rendered
# output, which is then committed as kueue-rendered-pinned.yaml.
#
# A sum or a digest fetched from the same endpoint as the artefact does not defend
# against a compromised endpoint. It does defend against truncation, corruption
# and a silently reissued artefact, which is strictly more than no gate — and the
# running pod's own imageID is read back and compared, so a substitution that
# silently missed an occurrence cannot look like one that worked.
#
# Usage:
#   bash create.sh                                  # collision fleet (default)
#   FLEET=scale bash create.sh                      # scale fleet
#   FAKE_NODES=9 RACKS_PER_BLOCK=3 bash create.sh   # explicit fleet shape
#   TAS_GANGS=none bash create.sh                   # no gang set; see below
#
# TAS_GANGS=none exists for ONE purpose and it is not convenience: the
# three-tenant collision experiment needs a fleet with no other admitted
# workloads on it, because this layer's gang set reserves 24 cpu and that moves
# the capacity figure the collision's arithmetic is compared against. Stated here
# because an undocumented knob is a knob nobody can reason about.
#
# Env:
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   export SIZE=8                                  # or 16
#
# Regenerate kueue-rendered-pinned.yaml:
#   bash labs/clusters/grid-core/addons/kueue-kwok/create.sh
#   (it is rewritten on every run; a clean `git status` afterwards is the evidence
#    that the committed copy matches the chart at the pinned version)
#
# Reporting contract (same as the base profile): every hard assert prints
# `FAIL: <what> <remedy>` to stderr and exits 1; on success exactly one line
# beginning `OK:` is printed.
#
# Idempotent: re-running re-renders and re-applies the same objects, exits 0, and
# leaves the simulated node count unchanged.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Identical to labs/clusters/grid-core/*.sh. A prepend is not a resolution
# guarantee — the preflight below runs `kind get clusters`, and the stale v0.32.0
# on this host would answer for a different cluster — so the version assert is
# sourced rather than re-implemented.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
DRA_ADDON_DIR="${PROFILE_DIR}/addons/dra"
KWOK_ATTACH_DIR="${LABS_DIR}/kwok/attach"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version
# This layer `helm pull`s the Kueue chart from registry.k8s.io and verifies its
# manifest digest, so the helm floor is asserted BEFORE the pull. The
# `for _tool in helm jq ...` presence gate further down is not a second copy of
# this check: that one asserts the tools EXIST and names what this layer uses
# each for, this one asserts helm's VERSION can do oci:// at all.
assert_helm_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-kueue-system}"
RELEASE="${RELEASE:-kueue}"
DEPLOYMENT="${RELEASE}-controller-manager"

# The chart, pinned by exact version, and its OCI manifest digest pinned here.
# Resolved in SPIKE-00, re-verified at install time in SPIKE-04, and re-verified
# again by this script on every run.
CHART_REF="${CHART_REF:-oci://registry.k8s.io/kueue/charts/kueue}"
CHART_VERSION="${CHART_VERSION:-0.20.0}"
CHART_DIGEST="${CHART_DIGEST:-sha256:61857945f1109da052dcc01baf79ea912a6c2a5ffeb087f3dfe270c9ea198c9c}"

# The controller image's manifest-list (INDEX) digest. The index, not a per-arch
# digest, so one pin serves linux/arm64 (this host) and linux/amd64 (plan 03-08's
# CI arm) — the same reason the node image is pinned by index.
#
# This pin is NEW IN PLAN 03-03: SPIKE-04 recorded only the chart digest and the
# image TAG (`registry.k8s.io/kueue/kueue:v0.20.0`), so nothing in this project
# had resolved it before. Resolved with
#   docker buildx imagetools inspect registry.k8s.io/kueue/kueue:v0.20.0
# and recorded in planning/lab-tests/03-addon-kueue-kwok.md.
KUEUE_IMAGE_REPO="registry.k8s.io/kueue/kueue"
KUEUE_IMAGE_DIGEST="${KUEUE_IMAGE_DIGEST:-sha256:7c57f630b2987058cc543710aa4829cfd8119b7f7c23431cbc242b82cf4bce57}"
KUEUE_IMAGE="${KUEUE_IMAGE_REPO}@${KUEUE_IMAGE_DIGEST}"

VALUES_FILE="${ADDON_DIR}/kueue-values.yaml"
RENDERED="${ADDON_DIR}/kueue-rendered-pinned.yaml"
GANGS_FILE="${ADDON_DIR}/tas-gangs-v1beta2.yaml"
DRA_VALUES_FILE="${DRA_ADDON_DIR}/values.yaml"

WORKDIR="${WORKDIR:-/tmp/313-addon-kueue-kwok}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
ADMISSION_TIMEOUT="${ADMISSION_TIMEOUT:-180}"

# --- the fleet shape ----------------------------------------------------------
# FLEET selects WHICH declared number is the default. FAKE_NODES overrides it.
# Neither number is a literal here; see the header.
FLEET="${FLEET:-collision}"
case "${FLEET}" in
  collision) FLEET_KEY="kwok_collision_nodes" ;;
  scale)     FLEET_KEY="kwok_scale_nodes" ;;
  *)
    echo "FAIL: FLEET is '${FLEET}'; accepted values are 'collision' and 'scale'." >&2
    echo "      FLEET selects which declared node count in course.config.json" >&2
    echo "      lab.sizes.${SIZE} is the default, and it is NEVER guessed: the two" >&2
    echo "      fleets are different labs, and running one with the other's size" >&2
    echo "      inverts which constraint binds without failing." >&2
    exit 1
    ;;
esac
FLEET_DECLARED="$(size_value "${FLEET_KEY}")"
# Where the number came from is recorded BEFORE the default is applied, and it is
# printed in the OK: line. Without this, an explicit `FAKE_NODES=1000` produced a
# line reading `FLEET=collision -> 1000 node(s)` — the count overridden and the
# label not — which is a published claim that misdescribes the fleet it measured.
# Comparing FAKE_NODES against FLEET_DECLARED afterwards cannot recover this: an
# explicit value that happens to equal the declared one is indistinguishable.
if [ -n "${FAKE_NODES:-}" ]; then
  FLEET_SOURCE="explicit FAKE_NODES override"
else
  FLEET_SOURCE="declared lab.sizes.${SIZE}.${FLEET_KEY}"
fi
FAKE_NODES="${FAKE_NODES:-${FLEET_DECLARED}}"

# One node per rack, three racks per block. REQUIRED by tas-gangs-v1beta2.yaml's
# arithmetic (a rack domain is one node, a block domain is three) and by
# three-tenant-v1beta2.yaml's. Declared here, asserted in that file's own
# precondition block, and warned about by setup.sh at the point the fleet is made.
RACKS_PER_BLOCK="${RACKS_PER_BLOCK:-3}"
NODE_CPU="${NODE_CPU:-8}"

TAS_GANGS="${TAS_GANGS:-apply}"
case "${TAS_GANGS}" in
  apply|none) : ;;
  *)
    echo "FAIL: TAS_GANGS is '${TAS_GANGS}'; accepted values are 'apply' and 'none'." >&2
    exit 1
    ;;
esac

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- the DeviceClass name, read rather than repeated --------------------------
# The quota resource name's mapping subject comes from the DRA layer's own values
# file, so the two layers cannot drift apart. A second copy of the name would be
# a second authority.
if [ ! -f "${VALUES_FILE}" ]; then
  echo "FAIL: chart values not found at ${VALUES_FILE}." >&2
  exit 1
fi
if [ ! -f "${GANGS_FILE}" ]; then
  echo "FAIL: this layer's quota/TAS object set not found at ${GANGS_FILE}." >&2
  exit 1
fi
if [ ! -f "${DRA_VALUES_FILE}" ]; then
  echo "FAIL: the DRA layer's values file is not in the tree at ${DRA_VALUES_FILE}." >&2
  echo "      The device-class mapping in ${VALUES_FILE} names a DeviceClass by" >&2
  echo "      name, and that name is READ from the DRA layer's values rather than" >&2
  echo "      repeated here, so a missing file is not a reason to fall back to a" >&2
  echo "      literal." >&2
  exit 1
fi
DEVICE_CLASS_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${DRA_VALUES_FILE}" | head -1)"
if [ -z "${DEVICE_CLASS_NAME}" ]; then
  echo "FAIL: could not read driverName out of ${DRA_VALUES_FILE}." >&2
  exit 1
fi

# The mapping in the committed values MUST name that same DeviceClass. If the DRA
# layer is ever renamed and this file is not, the Configuration would map a name
# nothing creates — and Kueue accepts that without complaint, so nothing would
# ever say so.
if ! /usr/bin/grep -q -- "- ${DEVICE_CLASS_NAME}\$" "${VALUES_FILE}"; then
  echo "FAIL: ${VALUES_FILE} does not list '${DEVICE_CLASS_NAME}' under deviceClassMappings[].deviceClassNames." >&2
  echo "      That name is the DeviceClass the DRA layer creates (read from" >&2
  echo "      ${DRA_VALUES_FILE}). A Configuration that maps a DeviceClass name" >&2
  echo "      nothing creates is accepted silently and accounts nothing, so the" >&2
  echo "      two files are compared here instead." >&2
  exit 1
fi
QUOTA_RESOURCE_NAME="$(sed -n 's/^[[:space:]]*- name:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | tail -1)"

# --- preflight ----------------------------------------------------------------
# The cluster check comes FIRST and before anything expensive. A layer that
# silently installs nothing because the cluster is absent is the fail-open this
# preflight exists to close.
#
# Captured into a variable and matched with `case`, never a pipe into a quiet
# grep: under `set -o pipefail` a successful quiet-grep match returns 141,
# because grep exits the instant it matches and the writer takes SIGPIPE. That
# nearly produced a false architecture verdict in Phase 1.
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer applies ONTO a running cluster and creates none." >&2
    echo "      Run the base profile first:" >&2
    echo "        bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh" >&2
    echo "      then re-run:  bash ${ADDON_DIR}/create.sh" >&2
    exit 1
    ;;
esac

if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer on context '${CONTEXT}'." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  echo "      Then:    bash ${PROFILE_DIR}/verify.sh" >&2
  exit 1
fi

if ! kc wait --for=condition=Ready node -l '!type' --all --timeout=180s >/dev/null 2>&1; then
  echo "FAIL: not every REAL node on '${CLUSTER_NAME}' reached Ready within 180s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

for _tool in helm jq curl shasum docker; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required by this layer and is not on PATH." >&2
    echo "      helm renders the chart; jq folds across the fleet and the Workloads;" >&2
    echo "      curl and shasum fetch and content-verify the kwok release assets;" >&2
    echo "      docker resolves the controller image's index digest." >&2
    echo "      Install it and re-run; nothing has been applied to '${CLUSTER_NAME}' yet." >&2
    exit 1
  fi
done

# THE ORDERING PRECONDITION, asserted rather than assumed. See the header and
# kueue-values.yaml for why a mapping naming an absent DeviceClass is a SILENT
# failure and therefore has to be caught here.
if ! kc get deviceclasses.resource.k8s.io "${DEVICE_CLASS_NAME}" >/dev/null 2>&1; then
  echo "FAIL: no DeviceClass named '${DEVICE_CLASS_NAME}' on '${CLUSTER_NAME}'." >&2
  echo "      This layer's Kueue Configuration maps device classes BY NAME, and a" >&2
  echo "      mapping naming a DeviceClass that does not exist is accepted without" >&2
  echo "      complaint — the quota resource simply never accounts anything, and a" >&2
  echo "      ClusterQueue quota for it looks satisfied because it was never used." >&2
  echo "      Apply the DRA layer first:" >&2
  echo "        bash ${DRA_ADDON_DIR}/create.sh" >&2
  echo "      then re-run:  bash ${ADDON_DIR}/create.sh" >&2
  exit 1
fi

# --- 1. pull the chart and VERIFY its digest ----------------------------------
mkdir -p "${WORKDIR}"
CHART_ARCHIVE="${WORKDIR}/kueue-${CHART_VERSION}.tgz"
PULL_LOG="${WORKDIR}/helm-pull.log"

# Removed before the pull so the digest line is always freshly printed: helm
# skips re-downloading an archive it already has, and a cached file would leave
# the gate below with nothing to read — which is a gate that passes by being
# unreachable.
rm -f "${CHART_ARCHIVE}"
echo "==> pulling ${CHART_REF} --version ${CHART_VERSION}" >&2
if ! helm pull "${CHART_REF}" --version "${CHART_VERSION}" -d "${WORKDIR}" > "${PULL_LOG}" 2>&1; then
  echo "FAIL: could not pull the Kueue chart at version ${CHART_VERSION}." >&2
  sed 's/^/      /' "${PULL_LOG}" >&2
  echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
  exit 1
fi

PULLED_DIGEST="$(sed -n 's/^Digest:[[:space:]]*\(sha256:[0-9a-f]\{1,\}\).*$/\1/p' "${PULL_LOG}" | head -1)"
if [ -z "${PULLED_DIGEST}" ]; then
  echo "FAIL: helm pull printed no 'Digest:' line, so the chart digest could not be verified." >&2
  sed 's/^/      /' "${PULL_LOG}" >&2
  echo "      This gate is a security gate (T-03-13): the chart carries CRDs, a" >&2
  echo "      ClusterRole and a ClusterRoleBinding applied at cluster-admin" >&2
  echo "      privilege. It refuses rather than installing an unverified chart." >&2
  exit 1
fi
if [ "${PULLED_DIGEST}" != "${CHART_DIGEST}" ]; then
  echo "FAIL: the Kueue chart's OCI manifest digest changed." >&2
  echo "      pulled now: ${PULLED_DIGEST}" >&2
  echo "      expected:   ${CHART_DIGEST}" >&2
  echo "      Re-verify upstream before installing: this chart carries CRDs, a" >&2
  echo "      ClusterRole and a ClusterRoleBinding, applied at cluster-admin" >&2
  echo "      privilege. Nothing has been applied to '${CLUSTER_NAME}'." >&2
  exit 1
fi
if [ ! -s "${CHART_ARCHIVE}" ]; then
  echo "FAIL: the verified chart archive is missing at ${CHART_ARCHIVE}." >&2
  exit 1
fi
echo "    digest verified: ${PULLED_DIGEST}" >&2
echo "    rendering from the VERIFIED LOCAL ARCHIVE, not from a floating version range" >&2

# --- 2. render, then pin the controller image --------------------------------
RENDER_TMP="$(mktemp "${TMPDIR:-/tmp}/addon-kueue-rendered.XXXXXX")"
trap 'rm -f "${RENDER_TMP}" "${RENDER_TMP}.sub"' EXIT

if ! helm template "${RELEASE}" "${CHART_ARCHIVE}" \
       --namespace "${NAMESPACE}" \
       --values "${VALUES_FILE}" > "${RENDER_TMP}"; then
  echo "FAIL: 'helm template' failed against the verified chart archive." >&2
  echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
  exit 1
fi

# The rendered Configuration must carry BOTH the config group AND a non-empty
# mapping. Asserting the group alone is the easy half and would pass on a stock
# chart install that carries no mapping at all.
if ! /usr/bin/grep -q "apiVersion: config.kueue.x-k8s.io/v1beta2" "${RENDER_TMP}"; then
  echo "FAIL: the rendered kueue-manager-config carries no Configuration in group" >&2
  echo "      config.kueue.x-k8s.io/v1beta2." >&2
  echo "      managerConfig.controllerManagerConfigYaml is a STRING that helm" >&2
  echo "      REPLACES rather than merges into, so a values file that dropped the" >&2
  echo "      apiVersion line would render a Configuration with no group at all." >&2
  exit 1
fi
if ! /usr/bin/grep -q "deviceClassMappings:" "${RENDER_TMP}"; then
  echo "FAIL: the rendered kueue-manager-config carries no deviceClassMappings." >&2
  echo "      That mapping is the whole reason ${VALUES_FILE} exists: without it," >&2
  echo "      DRA devices are admitted UNCOUNTED." >&2
  exit 1
fi

# Resolve the index digest at install time and compare it with the pin. The
# resolution is a read against the registry; the PIN is what is applied, so a
# registry that answered differently is reported rather than followed.
echo "==> resolving ${KUEUE_IMAGE_REPO}:v${CHART_VERSION}'s manifest-list index digest" >&2
RESOLVED_DIGEST="$(docker buildx imagetools inspect "${KUEUE_IMAGE_REPO}:v${CHART_VERSION}" 2>/dev/null \
                     | sed -n 's/^Digest:[[:space:]]*\(sha256:[0-9a-f]\{1,\}\).*$/\1/p' | head -1 || true)"
if [ -z "${RESOLVED_DIGEST}" ]; then
  echo "NOTE: could not resolve the controller image's index digest from the registry" >&2
  echo "      (offline, or the registry did not answer). Using the recorded pin" >&2
  echo "      ${KUEUE_IMAGE_DIGEST} — which is what gets applied in either case." >&2
elif [ "${RESOLVED_DIGEST}" != "${KUEUE_IMAGE_DIGEST}" ]; then
  echo "FAIL: ${KUEUE_IMAGE_REPO}:v${CHART_VERSION} now resolves to a different index digest." >&2
  echo "      resolved now: ${RESOLVED_DIGEST}" >&2
  echo "      recorded pin: ${KUEUE_IMAGE_DIGEST}" >&2
  echo "      A release TAG is mutable and a digest is not; this is the case the pin" >&2
  echo "      exists to catch. Re-verify upstream, then update KUEUE_IMAGE_DIGEST and" >&2
  echo "      planning/lab-tests/03-addon-kueue-kwok.md together." >&2
  exit 1
else
  echo "    resolved digest matches the recorded pin: ${RESOLVED_DIGEST}" >&2
fi

sed "s|${KUEUE_IMAGE_REPO}:[A-Za-z0-9._-]\{1,\}|${KUEUE_IMAGE}|g" \
  "${RENDER_TMP}" > "${RENDER_TMP}.sub"

# THE ASSERT THAT MAKES THE SUBSTITUTION EVIDENCE RATHER THAN AN INTENTION.
# Two halves, because they catch different failures:
#   1. no tag-form reference to the controller image survives anywhere;
#   2. every NON-EMPTY `image:` value in the file carries an @sha256 digest,
#      which also catches an image a later chart release grows.
#
# Non-empty is the operative word: this chart renders eleven CRDs, and the Workload
# CRD's own OpenAPI schema contains `image:` property KEYS with no value. Those
# are schema, not references, and a check that counted them would be measuring
# the CRD rather than the deployment.
IMAGE_LINES="$(sed -n 's|^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]][^"[:space:]]*\)"\{0,1\}[[:space:]]*$|\1|p' "${RENDER_TMP}.sub")"
if [ -z "${IMAGE_LINES}" ]; then
  echo "FAIL: the rendered chart carries no 'image:' reference at all, which cannot be right." >&2
  exit 1
fi
UNPINNED=""
for _img in ${IMAGE_LINES}; do
  case "${_img}" in
    *"@sha256:"*) : ;;
    *) UNPINNED="${UNPINNED} ${_img}" ;;
  esac
done
if [ -n "${UNPINNED}" ]; then
  echo "FAIL: a tag-form image reference survived the digest substitution:${UNPINNED}" >&2
  echo "      PLAT-01 pins every lab image by @sha256 digest. Nothing has been applied." >&2
  echo "      Resolve the index digest and extend the substitution in this script:" >&2
  echo "        docker buildx imagetools inspect <repo>:<tag>" >&2
  exit 1
fi
echo "digest-pin: every controller image reference is digest-pinned (pre-apply assert passed)" >&2

# --- 3. commit the rendered object set into the tree --------------------------
{
  echo "# GENERATED FILE — do not edit by hand."
  echo "#"
  echo "# The Kueue object set addon-kueue-kwok applies, rendered with"
  echo "#   helm template kueue <verified local archive> --values kueue-values.yaml"
  echo "# from ${CHART_REF} version ${CHART_VERSION},"
  echo "# whose OCI manifest digest was verified as ${CHART_DIGEST}"
  echo "# BEFORE the render, and with the controller image reference replaced by the"
  echo "# resolved manifest-list index digest ${KUEUE_IMAGE_DIGEST}."
  echo "#"
  echo "# Regenerate with:"
  echo "#   bash labs/clusters/grid-core/addons/kueue-kwok/create.sh"
  echo "#"
  echo "# It is committed so the applied object set is reviewable in the tree and so"
  echo "# the digest-pin gate has a real subject. A clean \`git status\` after a create"
  echo "# run is the evidence that this copy matches the chart at the pinned version."
  echo "#"
  echo "# Every Kueue custom resource this object set defines is served on the"
  echo "# v1beta2 group; v0.20.0 serves no earlier one. The Configuration in the"
  echo "# kueue-manager-config ConfigMap is in group config.kueue.x-k8s.io/v1beta2"
  echo "# and carries the deviceClassMappings entry from kueue-values.yaml."
  cat "${RENDER_TMP}.sub"
} > "${RENDERED}"

# --- 4. apply Kueue ----------------------------------------------------------
# NEVER apply into a Terminating namespace. It exits 0 and creates nothing (a
# Phase-1 finding), so the namespace's phase is read and waited on rather than
# trusting the apply's exit code.
NS_PHASE="$(kc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "${NS_PHASE}" = "Terminating" ]; then
  echo "==> namespace '${NAMESPACE}' is Terminating; waiting for it to go away before applying" >&2
  _waited=0
  while [ "${_waited}" -lt 120 ]; do
    if ! kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then break; fi
    sleep 2
    _waited=$((_waited + 2))
  done
  if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "FAIL: namespace '${NAMESPACE}' is still Terminating after ${_waited}s." >&2
    echo "      kubectl apply into a Terminating namespace exits 0 and creates nothing," >&2
    echo "      so this refuses rather than reporting a successful install of nothing." >&2
    exit 1
  fi
  NS_PHASE=""
fi
if [ -z "${NS_PHASE}" ]; then
  kc create namespace "${NAMESPACE}" >/dev/null
  echo "==> namespace/${NAMESPACE} created" >&2
else
  echo "==> namespace/${NAMESPACE} already present (phase ${NS_PHASE}) — reusing it" >&2
fi

# --server-side: the eleven CRDs this chart ships are large enough that a
# client-side apply exceeds the last-applied-configuration annotation's size
# limit on at least one of them.
kc apply --server-side --force-conflicts -f "${RENDERED}" >/dev/null

if ! kc -n "${NAMESPACE}" rollout status "deploy/${DEPLOYMENT}" --timeout="${ROLLOUT_TIMEOUT}s"; then
  echo "FAIL: Deployment ${DEPLOYMENT} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
  echo "      A Configuration the controller cannot parse shows up HERE, as a" >&2
  echo "      CrashLoopBackOff, because the ConfigMap itself applies cleanly" >&2
  echo "      whatever it contains." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/${DEPLOYMENT}" >&2
  exit 1
fi

# --- 5. the live Configuration -----------------------------------------------
# The committed values file is the checkable artifact; THIS is the live object.
# Both halves are asserted — the group AND a non-empty mapping naming the DRA
# layer's DeviceClass — because SC2 names both and the group alone is the easy
# half.
LIVE_CONFIG_FILE="${WORKDIR}/live-manager-config.yaml"
if ! kc -n "${NAMESPACE}" get cm kueue-manager-config \
       -o jsonpath='{.data.controller_manager_config\.yaml}' > "${LIVE_CONFIG_FILE}" 2>/dev/null \
   || [ ! -s "${LIVE_CONFIG_FILE}" ]; then
  echo "FAIL: ConfigMap ${NAMESPACE}/kueue-manager-config carries no controller_manager_config.yaml." >&2
  exit 1
fi

# PARSED, not grepped. kueue-config-probe.mjs resolves the document and reads the
# fields, which is the only way to get both of these right:
#   - the mapping COUNT: a line-counter counts the nested deviceClassNames item
#     too and publishes a number that is off by one;
#   - the DeviceClass NAME: a substring test is satisfied by the name appearing
#     in a comment, so a Configuration that mentioned the right DeviceClass and
#     mapped nothing would pass.
# The probe prints nothing on stdout when the document does not parse, so this
# fails closed.
CONFIG_PROBE="$(node "${ADDON_DIR}/kueue-config-probe.mjs" "${LIVE_CONFIG_FILE}" "${DEVICE_CLASS_NAME}" 2>&1 || true)"
case "${CONFIG_PROBE}" in
  "config_group=config.kueue.x-k8s.io/v1beta2 "*" maps_deviceclass=yes "*) : ;;
  *)
    echo "FAIL: the live Kueue Configuration did not satisfy both halves of SC2." >&2
    echo "      probe: ${CONFIG_PROBE}" >&2
    echo "      Required: config_group=config.kueue.x-k8s.io/v1beta2 AND" >&2
    echo "                maps_deviceclass=yes for '${DEVICE_CLASS_NAME}'." >&2
    echo "      The group alone is the easy half — a stock chart install has the right" >&2
    echo "      group and NO mapping at all, and without the mapping DRA devices are" >&2
    echo "      admitted UNCOUNTED." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get cm kueue-manager-config -o yaml" >&2
    exit 1
    ;;
esac
LIVE_MAPPED="$(printf '%s' "${CONFIG_PROBE}" | sed -n 's/.*mappings=\([0-9]\{1,\}\).*/\1/p')"
if [ "${LIVE_MAPPED:-0}" -lt 1 ]; then
  echo "FAIL: the live Configuration's deviceClassMappings is empty (probe: ${CONFIG_PROBE})." >&2
  echo "      An empty list satisfies a presence test and accounts nothing." >&2
  exit 1
fi

# The pin is only honoured if EVERY thing that is RUNNING carries it. A rendered
# manifest proves what was asked for; imageID is what the kubelet resolved.
# Folded across every Running pod rather than read off `.items[0]`: after a
# re-apply `.items[0]` can be the OLD controller pod still Terminating, carrying
# the previous digest. The Running field-selector is what excludes it.
RUNNING_IMAGE_IDS="$(kc -n "${NAMESPACE}" get pod -l control-plane=controller-manager \
                       --field-selector status.phase=Running -o json 2>/dev/null \
                     | jq -r '[.items[].status.containerStatuses[]?.imageID] | join(" ")' 2>/dev/null || true)"
PODS_SEEN=0
PODS_PINNED=0
for _id in ${RUNNING_IMAGE_IDS}; do
  PODS_SEEN=$((PODS_SEEN + 1))
  case "${_id}" in
    *"${KUEUE_IMAGE_DIGEST}"*) PODS_PINNED=$((PODS_PINNED + 1)) ;;
  esac
done
if [ "${PODS_SEEN}" -lt 1 ] || [ "${PODS_PINNED}" -ne "${PODS_SEEN}" ]; then
  echo "FAIL: ${PODS_PINNED}/${PODS_SEEN} running Kueue controller container(s) carry the pinned digest ${KUEUE_IMAGE_DIGEST}." >&2
  echo "      The manifest asked for the pin and the node resolved something else," >&2
  echo "      which is exactly the case a written-only pin would not catch — and zero" >&2
  echo "      running containers is a rollout that did not happen, not a clean read." >&2
  echo "      Running imageIDs: ${RUNNING_IMAGE_IDS:-<none>}" >&2
  exit 1
fi

# --- 6. the simulated fleet ---------------------------------------------------
# DRIVEN, not duplicated: setup.sh owns fetch_verified and both release-asset
# content pins, the stage-fast install (KWOK v0.8.0 removed the built-in default
# stage, so a fleet without it never reports Ready), the mandatory
# `kwok.x-k8s.io/node: fake` adoption annotation, the NoSchedule taint that keeps
# real pods off kubelet-less nodes, and the normalised ARCH_LABEL.
if [ ! -f "${KWOK_ATTACH_DIR}/setup.sh" ]; then
  echo "FAIL: ${KWOK_ATTACH_DIR}/setup.sh is missing; this layer drives it rather than duplicating it." >&2
  exit 1
fi
echo "==> simulated fleet: ${FAKE_NODES} node(s) — FLEET=${FLEET}, count from ${FLEET_SOURCE} (declared ${FLEET_DECLARED} at SIZE=${SIZE}), ${RACKS_PER_BLOCK} rack(s)/block" >&2
FAKE_NODES="${FAKE_NODES}" RACKS_PER_BLOCK="${RACKS_PER_BLOCK}" NODE_CPU="${NODE_CPU}" \
  CONTEXT="${CONTEXT}" CLUSTER_NAME="${CLUSTER_NAME}" \
  bash "${KWOK_ATTACH_DIR}/setup.sh" deploy

# --- 7. this layer's quota and TAS object set --------------------------------
if [ "${TAS_GANGS}" = "apply" ]; then
  kc apply -f "${GANGS_FILE}" >/dev/null

  # An apply into a Terminating namespace exits 0 and creates nothing, so the
  # objects are read back rather than the exit code trusted.
  for _ns in kueue-kwok-tas kueue-kwok-tas-block; do
    if ! kc get namespace "${_ns}" >/dev/null 2>&1; then
      echo "FAIL: namespace '${_ns}' does not exist after the apply." >&2
      exit 1
    fi
  done

  # Wait for the ADMISSION DECISION, not for a Pod phase. The negative control
  # has no pod at all to have a phase.
  echo "==> waiting for Kueue to decide on the gangs (admission, not Pod phase)" >&2
  _waited=0
  ADMITTED=0
  while [ "${_waited}" -lt "${ADMISSION_TIMEOUT}" ]; do
    ADMITTED="$(kc get workloads.kueue.x-k8s.io -A -o json 2>/dev/null \
                  | jq '[.items[] | select(.status.admission != null)] | length' 2>/dev/null || echo 0)"
    if [ "${ADMITTED:-0}" -ge 2 ]; then break; fi
    sleep 3
    _waited=$((_waited + 3))
  done
  if [ "${ADMITTED:-0}" -lt 2 ]; then
    echo "FAIL: ${ADMITTED:-0} of the 2 admissible gangs reached a non-null .status.admission after ${_waited}s." >&2
    echo "      Inspect the DECISION, never the Pod phase:" >&2
    echo "        kubectl --context ${CONTEXT} get workloads.kueue.x-k8s.io -A -o yaml" >&2
    echo "      Note the fully-qualified resource: on a GenericWorkload cluster a bare" >&2
    echo "      'kubectl get workloads' resolves to the core scheduling group and returns" >&2
    echo "      nothing while Kueue Workloads exist." >&2
    exit 1
  fi
fi

WL_COUNT="$(kc get workloads.kueue.x-k8s.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
FLEET_READY="$(kc get nodes -l type=kwok -o json 2>/dev/null \
                 | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')"

echo
echo "OK: addon-kueue-kwok applied onto '${CLUSTER_NAME}' — Kueue ${CHART_VERSION} Available, Configuration in config.kueue.x-k8s.io/v1beta2 with ${LIVE_MAPPED} deviceClassMapping(s) naming '${DEVICE_CLASS_NAME}', ${FLEET_READY}/${FAKE_NODES} simulated nodes Ready, ${WL_COUNT} Kueue Workload(s)."
echo "  the fleet is SIMULATED — those nodes are not machines, they carry no kubelet, and nothing on them is a GPU"
echo "  attach mode:   FORCED, not preferred — kwokctl ships no Kubernetes 1.37 cluster image (its images stop at v0.8.0-k8s.v1.36.1)"
echo "  decided by:    Kueue admits and writes the nodeSelector; the real kube-scheduler binds; kwok fakes the kubelet afterwards"
echo "  fleet:         ${FAKE_NODES} node(s), ${RACKS_PER_BLOCK} rack(s)/block, ${NODE_CPU} cpu each — FLEET=${FLEET}, count from ${FLEET_SOURCE}"
echo "  quota name:    ${QUOTA_RESOURCE_NAME} (what ClusterQueue.nominalQuota counts for the mapped DeviceClass)"
echo "  chart:         ${CHART_REF} ${CHART_VERSION} @ ${CHART_DIGEST}"
echo "  image:         ${KUEUE_IMAGE}"
echo "  applied:       ${RENDERED}"
echo "  gang set:      ${GANGS_FILE} (TAS_GANGS=${TAS_GANGS})"
echo "  lab budget:    ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: bash ${ADDON_DIR}/verify.sh"
echo "  measure:       BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-kueue-kwok-${FLEET}-size${SIZE} FILTER=${CLUSTER_NAME} \\"
echo "                   bash ${LABS_TOOLS}/measure.sh read grid-core-kueue-kwok-${FLEET}"
echo "                 (read it BEFORE any teardown — kind delete removes the cgroups the figure comes from)"

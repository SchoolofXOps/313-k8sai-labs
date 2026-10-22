#!/usr/bin/env bash
# addon-dra — apply the SYNTHETIC-DEVICE layer onto a running grid-core.
#
# THIS IS A LAYER, NOT A PROFILE. It creates no cluster. It applies onto the
# cluster `labs/clusters/grid-core/create.sh` already made, and its teardown.sh
# removes the layer and leaves that cluster running. Everything the DRA kubelet
# plugin does is installable onto a live cluster — a DaemonSet, a DeviceClass,
# RBAC and a validating admission policy — which is exactly why this is a layer
# and why grid-core stays the only base cluster in the 7.74 GiB VM.
#
# WHAT IT ADVERTISES: eight SYNTHETIC devices per worker node. There is no
# accelerator in this VM and nothing here measures one. The driver is upstream's
# own example driver, and it names its synthetic devices with a device-vendor
# word in output this course did not write — the model string and the 80Gi
# `memory` capacity it reports are Go constants, not readings. STANDARDS.md C15
# requires a caption wherever that text reaches a page; the six device facts the
# platform cannot produce are recorded with upstream line citations in
# planning/lab-tests/03-addon-dra.md.
#
# WHAT THIS LAYER RENAMES, and it is one value. values.yaml sets
# `driverName: sim-accelerator.example.com`, and the chart's own helper puts that
# single string on the registered driver, on the DeviceClass's name and inside
# the DeviceClass's CEL selector. So a reader of `kubectl get resourceslices -o
# yaml` sees a driver that cannot be mistaken for a real fleet.
#
# ORDERING — the one constraint that is NOT free. Every other layer in this
# phase can be applied in any order relative to this one. This one cannot:
# Kueue's Configuration maps device classes BY NAME
# (`resources.deviceClassMappings[].deviceClassNames`), so THIS LAYER'S
# DeviceClass must exist before the queueing layer's Configuration can account
# for it. Apply addon-dra first. The backward half of this reference lives in
# the queueing layer's own values file.
#
# HOW THE OBJECT SET IS PINNED. The chart is fetched by GIT TAG v0.5.0, not by
# chart version: the in-tree chart is `version: 0.0.0-dev` and its
# `_helpers.tpl:82-83` renders `repository:tag`, so `image.tag` cannot carry a
# digest and the digest has to be substituted into the rendered output instead.
# The rendered, digest-substituted object set is written to rendered-pinned.yaml
# beside this script and committed, so the thing that gets applied is reviewable
# in the tree rather than regenerated differently on each machine.
#
# A sum or a tag fetched from the same endpoint as the artefact does not defend
# against a compromised endpoint. It does defend against truncation, corruption
# and a silently reissued artefact, which is strictly more than no gate — and
# the running pod's own imageID is read back and compared, so a substitution
# that silently missed an occurrence cannot look like one that worked.
#
# Usage:
#   bash create.sh                 # apply the layer onto a running grid-core
#   bash create.sh && bash verify.sh
#
# Regenerate rendered-pinned.yaml:
#   bash labs/clusters/grid-core/addons/dra/create.sh
#   (it is rewritten on every run from the chart at ${CHART_TAG}; a clean
#    `git status` after a run is the evidence that the committed copy matches)
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale v0.32.0 shim
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract (same as the base profile): every hard assert prints
# `FAIL: <what> <remedy>` to stderr and exits 1; on success exactly one line
# beginning `OK:` is printed.
#
# Idempotent: re-running re-renders and re-applies the same objects and exits 0.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Identical to labs/clusters/grid-core/*.sh. A prepend is not a resolution
# guarantee — the preflight below runs `kind get clusters`, and the stale
# v0.32.0 on this host would answer for a different cluster — so the version
# assert is sourced rather than re-implemented.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
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
# This layer renders its chart with `helm template`, so the helm floor is
# asserted BEFORE anything is fetched or applied. The `for _tool in git helm`
# presence gate further down is not a second copy of this check: that one
# asserts the tool EXISTS and names what this layer uses it for, this one
# asserts the VERSION is capable of the oci:// pulls the course depends on.
assert_helm_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-dra-example-driver}"
RELEASE="${RELEASE:-dra-example-driver}"
DAEMONSET="${RELEASE}-kubeletplugin"

# The chart, pinned by GIT TAG. See the header for why not by chart version.
CHART_REPO="${CHART_REPO:-https://github.com/kubernetes-sigs/dra-example-driver.git}"
CHART_TAG="${CHART_TAG:-v0.5.0}"
CHART_SUBDIR="deployments/helm/dra-example-driver"
WORKDIR="${WORKDIR:-/tmp/313-addon-dra}"

# The manifest-list (index) digest, resolved in SPIKE-00 with
# `docker buildx imagetools inspect` and re-verified in 03-RESEARCH.md. The index
# digest, not a per-arch one, so the same pin works on linux/arm64 (this host)
# and linux/amd64 (plan 03-08's CI arm).
DRIVER_IMAGE_REPO="registry.k8s.io/dra-example-driver/dra-example-driver"
DRIVER_IMAGE_DIGEST="${DRIVER_IMAGE_DIGEST:-sha256:c1488eb51e086bd6b885a667c7d059382844e54e5917a71bcf734c04edfbb62f}"
DRIVER_IMAGE="${DRIVER_IMAGE_REPO}@${DRIVER_IMAGE_DIGEST}"

VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
SLICE_TIMEOUT="${SLICE_TIMEOUT:-180}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# Both read OUT of values.yaml rather than repeated here, so the file that
# configures the driver is the same file that supplies the expected values. A
# second copy of either number is a second authority.
if [ ! -f "${VALUES_FILE}" ]; then
  echo "FAIL: chart values not found at ${VALUES_FILE}." >&2
  exit 1
fi
DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
EXPECTED_DEVICES="$(sed -n 's/^[[:space:]]\{1,\}numDevices:[[:space:]]*\([0-9]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
if [ -z "${DRIVER_NAME}" ] || [ -z "${EXPECTED_DEVICES}" ]; then
  echo "FAIL: could not read driverName and kubeletPlugin.numDevices out of ${VALUES_FILE}." >&2
  echo "      Both are read from that file rather than hardcoded here, so a missing" >&2
  echo "      key is a values defect and not a reason to fall back to a literal." >&2
  exit 1
fi

# --- preflight ----------------------------------------------------------------
# The cluster check comes FIRST and before anything expensive. A layer that
# silently installs nothing because the cluster is absent is the fail-open this
# preflight exists to close.
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

if ! kc wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' reached Ready within 180s." >&2
  echo "      The kubelet plugin runs as a DaemonSet, so a NotReady node is a node with no devices." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

for _tool in git helm jq; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required — the chart is fetched by git tag and rendered with helm," >&2
    echo "      and jq folds the pin read-back across every running driver pod." >&2
    echo "      Install it (brew install ${_tool}) and re-run; nothing has been applied to" >&2
    echo "      '${CLUSTER_NAME}' yet." >&2
    exit 1
  fi
done

# Worker count read FROM the cluster, not from SIZE. One cluster name serves both
# sizes, and the number of ResourceSlices this layer produces equals the number
# of nodes that actually run a driver pod. The control plane carries kind's
# NoSchedule taint and the DaemonSet tolerates nothing, so that is the worker
# count.
#
# SIMULATED NODES ARE EXCLUDED, and this is a correction measured in plan 03-03
# rather than a precaution. The kueue-kwok layer attaches a fleet of kwok Node
# objects carrying `type: kwok`, and they are not control-plane nodes — so the
# selector that reads "every non-control-plane node" counted all nine of them and
# this layer then demanded one ResourceSlice per "worker" and failed at 1 of 10.
# The DaemonSet had behaved correctly throughout: a simulated node has no kubelet
# and repels it with a NoSchedule taint it does not tolerate, so desired was 1 and
# ready was 1. ONE slice was the right answer and the EXPECTATION was wrong.
#
# `type!=kwok` rather than `!type`: a label selector's `!=` also matches a node
# with no such label at all, so this keeps every real node and drops only the
# simulated fleet — and it says which fleet it is dropping.
WORKERS="$(kc get nodes -l '!node-role.kubernetes.io/control-plane,type!=kwok' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${WORKERS}" -lt 1 ]; then
  echo "FAIL: '${CLUSTER_NAME}' reports no worker node, so this layer would advertise no devices." >&2
  echo "      Recreate the base profile: bash ${PROFILE_DIR}/create.sh" >&2
  exit 1
fi

# --- resolve the chart at the git tag ----------------------------------------
mkdir -p "${WORKDIR}"
CHART_CLONE="${WORKDIR}/dra-example-driver"
if [ ! -d "${CHART_CLONE}/.git" ]; then
  echo "==> cloning ${CHART_REPO} at ${CHART_TAG}" >&2
  if ! git clone --quiet --depth 1 --branch "${CHART_TAG}" "${CHART_REPO}" "${CHART_CLONE}"; then
    echo "FAIL: could not clone ${CHART_REPO} at tag ${CHART_TAG}." >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
    rm -rf "${CHART_CLONE}"
    exit 1
  fi
fi

# Assert the working copy really is AT the pinned tag. A cached clone from an
# earlier run could be at anything, and a chart rendered from the wrong revision
# would apply cleanly and be wrong. `git tag --points-at HEAD` is used rather
# than `git describe`, because this repository carries a second tag on the same
# commit (`chart/0.5.0`) and describe answers with whichever it prefers — a
# substring test against that answer would also accept the wrong one.
CHART_TAGS_AT_HEAD="$(git -C "${CHART_CLONE}" tag --points-at HEAD 2>/dev/null || true)"
CHART_COMMIT="$(git -C "${CHART_CLONE}" rev-parse HEAD 2>/dev/null || true)"
case "
${CHART_TAGS_AT_HEAD}
" in
  *"
${CHART_TAG}
"*) : ;;
  *)
    echo "FAIL: the chart clone at ${CHART_CLONE} is at commit ${CHART_COMMIT:-<unknown>}," >&2
    echo "      whose tags are '$(printf '%s' "${CHART_TAGS_AT_HEAD}" | tr '\n' ' ')' — ${CHART_TAG} is not among them." >&2
    echo "      Remove it and re-run so it is fetched at the pinned tag:" >&2
    echo "        rm -rf ${CHART_CLONE} && bash ${ADDON_DIR}/create.sh" >&2
    exit 1
    ;;
esac

if [ ! -f "${CHART_CLONE}/${CHART_SUBDIR}/Chart.yaml" ]; then
  echo "FAIL: no chart at ${CHART_CLONE}/${CHART_SUBDIR}." >&2
  exit 1
fi

# --- render -------------------------------------------------------------------
# --api-versions is passed EXPLICITLY. The chart picks its DeviceClass
# apiVersion from `.Capabilities.APIVersions.Has "resource.k8s.io/v1"`
# (_helpers.tpl:115); under `helm template` that set comes from helm's own
# built-in default list, which differs between helm majors. Naming the group
# here means the rendered apiVersion does not depend on which helm the learner
# installed — and the assert below fails rather than applying a DeviceClass with
# an empty apiVersion.
RENDER_TMP="$(mktemp "${TMPDIR:-/tmp}/addon-dra-rendered.XXXXXX")"
trap 'rm -f "${RENDER_TMP}" "${RENDER_TMP}.sub"' EXIT

if ! helm template "${RELEASE}" "${CHART_CLONE}/${CHART_SUBDIR}" \
       --namespace "${NAMESPACE}" \
       --api-versions resource.k8s.io/v1 \
       --values "${VALUES_FILE}" > "${RENDER_TMP}"; then
  echo "FAIL: 'helm template' failed against the chart at ${CHART_TAG}." >&2
  echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
  exit 1
fi

# --- substitute the digest ----------------------------------------------------
# Every rendered reference to the driver image becomes the resolved index digest.
sed "s|${DRIVER_IMAGE_REPO}:[A-Za-z0-9._-]\{1,\}|${DRIVER_IMAGE}|g" \
  "${RENDER_TMP}" > "${RENDER_TMP}.sub"

# THE ASSERT THAT MAKES THE SUBSTITUTION EVIDENCE RATHER THAN AN INTENTION.
# Two halves, because they catch different failures:
#   1. no tag-form reference to the driver image survives anywhere;
#   2. every `image:` line in the file carries an @sha256 digest — which also
#      catches an image this chart grew in a later release that the substitution
#      above does not know about.
IMAGE_LINES="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(.*\)$/\1/p' "${RENDER_TMP}.sub")"
if [ -z "${IMAGE_LINES}" ]; then
  echo "FAIL: the rendered chart carries no 'image:' line at all, which cannot be right." >&2
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
echo "digest-pin: every driver image reference is digest-pinned (pre-apply assert passed)"

# The DeviceClass apiVersion must have rendered. An empty one applies as an
# object with no apiVersion and kubectl refuses it with a message about the
# manifest rather than about the chart.
DC_APIVERSION="$(awk '/^kind: DeviceClass$/{print prev} {prev=$0}' "${RENDER_TMP}.sub")"
case "${DC_APIVERSION}" in
  "apiVersion: resource.k8s.io/v1") : ;;
  *)
    echo "FAIL: the rendered DeviceClass carries '${DC_APIVERSION:-<nothing>}', not 'apiVersion: resource.k8s.io/v1'." >&2
    echo "      The chart selects it from .Capabilities.APIVersions; --api-versions is passed" >&2
    echo "      explicitly above, so this means the chart at ${CHART_TAG} changed shape." >&2
    exit 1
    ;;
esac

# --- commit the rendered object set into the tree -----------------------------
{
  echo "# GENERATED FILE — do not edit by hand."
  echo "#"
  echo "# The object set addon-dra applies, rendered from the IN-TREE chart"
  echo "# ${CHART_SUBDIR} of ${CHART_REPO}"
  echo "# at git tag ${CHART_TAG} (commit ${CHART_COMMIT}), with the committed values.yaml,"
  echo "# and with every driver image reference replaced by the resolved"
  echo "# manifest-list index digest."
  echo "#"
  echo "# Regenerate with:"
  echo "#   bash labs/clusters/grid-core/addons/dra/create.sh"
  echo "#"
  echo "# It is committed so the applied object set is reviewable in the tree and"
  echo "# so the digest-pin gate has a real subject. A clean \`git status\` after a"
  echo "# create run is the evidence that this copy matches the chart at the tag."
  echo "#"
  echo "# The devices this object set advertises are SYNTHETIC. The driver's own"
  echo "# device names, its model string and its 80Gi \`memory\` capacity are Go"
  echo "# constants, not readings — see planning/lab-tests/03-addon-dra.md."
  cat "${RENDER_TMP}.sub"
} > "${RENDERED}"

# --- apply --------------------------------------------------------------------
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
    echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${NAMESPACE} -o yaml" >&2
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

kc apply -f "${RENDERED}" >/dev/null

if ! kc -n "${NAMESPACE}" rollout status "ds/${DAEMONSET}" --timeout="${ROLLOUT_TIMEOUT}s"; then
  echo "FAIL: DaemonSet ${DAEMONSET} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} describe ds/${DAEMONSET}" >&2
  echo "               kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l app.kubernetes.io/component=kubeletplugin" >&2
  exit 1
fi

# --- read back ----------------------------------------------------------------
# The pin is only honoured if EVERY thing that is RUNNING carries it. A rendered
# manifest proves what was asked for; imageID is what each kubelet resolved.
# Folded across every Running pod rather than read off `.items[0]`: at SIZE=16
# the DaemonSet has two pods and the first in API order says nothing about the
# second, and on a re-apply `.items[0]` can be the OLD pod still Terminating,
# carrying the previous digest. The Running field-selector is what excludes it.
RUNNING_IMAGE_IDS="$(kc -n "${NAMESPACE}" get pod -l app.kubernetes.io/component=kubeletplugin \
                       --field-selector status.phase=Running -o json 2>/dev/null \
                     | jq -r '[.items[].status.containerStatuses[]?.imageID] | join(" ")' 2>/dev/null || true)"
PODS_SEEN=0
PODS_PINNED=0
for _id in ${RUNNING_IMAGE_IDS}; do
  PODS_SEEN=$((PODS_SEEN + 1))
  case "${_id}" in
    *"${DRIVER_IMAGE_DIGEST}"*) PODS_PINNED=$((PODS_PINNED + 1)) ;;
  esac
done
if [ "${PODS_SEEN}" -lt 1 ] || [ "${PODS_PINNED}" -ne "${PODS_SEEN}" ]; then
  echo "FAIL: ${PODS_PINNED}/${PODS_SEEN} running driver container(s) carry the pinned digest ${DRIVER_IMAGE_DIGEST}." >&2
  echo "      The manifest asked for the pin and a node resolved something else," >&2
  echo "      which is exactly the case a written-only pin would not catch — and zero" >&2
  echo "      running containers is a rollout that did not happen, not a clean read." >&2
  echo "      Running imageIDs: ${RUNNING_IMAGE_IDS:-<none>}" >&2
  exit 1
fi

# ResourceSlices are published by the plugin shortly after it registers, so this
# polls for them rather than reading once and concluding the layer advertises
# nothing.
_waited=0
SLICES=0
while [ "${_waited}" -lt "${SLICE_TIMEOUT}" ]; do
  SLICES="$(kc get resourceslices --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${SLICES}" -ge "${WORKERS}" ]; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if [ "${SLICES}" -lt "${WORKERS}" ]; then
  echo "FAIL: ${SLICES} ResourceSlice(s) published after ${_waited}s; expected one per worker (${WORKERS})." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l app.kubernetes.io/component=kubeletplugin" >&2
  exit 1
fi

DEVICE_CLASS="$(kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ "${DEVICE_CLASS}" != "${DRIVER_NAME}" ]; then
  echo "FAIL: no DeviceClass named '${DRIVER_NAME}' exists after the apply." >&2
  echo "      The chart derives the DeviceClass name from the driverName value, so this" >&2
  echo "      means values.yaml was not the file that was rendered." >&2
  exit 1
fi

echo
echo "OK: addon-dra applied onto '${CLUSTER_NAME}' — driver '${DRIVER_NAME}', DeviceClass '${DEVICE_CLASS}', ${EXPECTED_DEVICES} synthetic devices on each of ${WORKERS} worker(s), across ${SLICES} ResourceSlice(s)."
echo "  the devices are SIMULATED — there is no accelerator in this VM and nothing here measures one"
echo "  chart:      ${CHART_SUBDIR} at ${CHART_TAG} (commit ${CHART_COMMIT})"
echo "  image:      ${DRIVER_IMAGE}"
echo "  applied:    ${RENDERED}"
echo "  namespace:  ${NAMESPACE}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: bash ${ADDON_DIR}/verify.sh"
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-addon-dra-size${SIZE}-gates-on FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_DIR}/tools/measure.sh read grid-core-addon-dra"
echo "              (read it BEFORE any teardown — kind delete removes the cgroups the figure comes from)"

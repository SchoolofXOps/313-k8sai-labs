#!/usr/bin/env bash
# addon-dra-nic — apply the SYNTHETIC-NIC layer onto a running grid-core that
# already carries addon-dra.
#
# THIS IS A LAYER, NOT A PROFILE. It creates no cluster. It applies onto the
# cluster `labs/clusters/grid-core/create.sh` already made, on top of the
# synthetic-device layer `addons/dra`, and its teardown.sh removes only what
# this script applied and leaves both of them running.
#
# WHAT IT ADVERTISES: four SYNTHETIC NICs per worker node, from a SECOND release
# of the same upstream example driver addon-dra runs, on the driver's `net`
# device profile. There is no network card behind any of them and nothing here
# sends a packet. The driver names them `nic-N`, reports the model
# `LATEST-NET-MODEL` and a `100G` bandwidth capacity, and all three are Go
# constants in its source, not readings (values.yaml beside this file cites the
# lines). STANDARDS.md C15 Group 3 requires a caption wherever that text reaches
# a page. A synthetic NIC is never called a NIC on hardware.
#
# WHY IT EXISTS: Module 6's co-allocation lab (Phase 6 CONTEXT D-28, D-50). One
# ResourceClaim asks for a synthetic device from addon-dra's driver AND a
# synthetic NIC from this one, with `matchAttribute:
# resource.kubernetes.io/pcieRoot`, and the scheduler has to find a pair that
# sits under one PCIe root. Both drivers publish that attribute from the same
# round-robin helper, so the pair exists, and both drivers really PREPARE what
# the scheduler allocated — which is what makes this a real allocate-and-prepare
# rather than a hand-written ResourceSlice nobody serves.
#
# THE SAME DRIVER BUILD AS addon-dra, READ FROM IT RATHER THAN RETYPED. The chart
# repository, git tag, the commit that tag names, the image repository and the
# image's manifest-list index digest are all read out of ../dra/create.sh's own
# defaults below. A second copy of any of them would be a second authority that
# could be right while the first is wrong. At authoring (2026-11-18) they read
# tag v0.5.0, commit 93ff610f3c3bfd603c592d1c281a236c1463edb9 and index digest
# sha256:c1488eb5…; PINS.md beside this file records them in full, and
# rendered-pinned.yaml's header records the commit it was rendered from.
#
# ORDERING — this layer needs addon-dra applied FIRST, and refuses otherwise.
# A synthetic NIC that shares a PCIe root with nothing teaches nothing, so the
# preflight reads addon-dra's DeviceClass and its ResourceSlices and requires
# every one of its devices to publish `resource.kubernetes.io/pcieRoot`.
# Teardown therefore unwinds in reverse: this layer first, addon-dra second.
#
# ONE INTERACTION TO KNOW ABOUT. addons/dra/verify.sh asserts that EVERY
# ResourceSlice on the cluster is its driver's, and that there is exactly one
# slice per worker. With this layer applied that is no longer true — there are
# two drivers and two slices per worker — so addons/dra/verify.sh reports FAIL
# while this layer is up. That is addon-dra's verify being exact about its own
# layer, not a broken cluster. Verify addon-dra BEFORE applying this layer, and
# again after this layer's teardown (teardown.sh does the second one for you).
#
# HOW THE OBJECT SET IS PINNED, exactly as addon-dra does it: the in-tree chart
# renders `repository:tag`, so the digest is substituted into the rendered
# output, the result is committed beside this script as rendered-pinned.yaml,
# and every run renders the chart again and REFUSES if that render differs from
# the committed copy by one byte. What gets applied is always the reviewed file.
#
# Usage:
#   bash ../dra/create.sh && bash ../dra/verify.sh   # first, if not already applied
#   bash create.sh && bash verify.sh
#
# Regenerate rendered-pinned.yaml (a deliberate, reviewed change only):
#   REGENERATE=1 bash labs/clusters/grid-core/addons/dra-nic/create.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#
# Reporting contract (same as every layer): every hard assert prints
# `FAIL: <what> <remedy>` to stderr and exits 1; on success exactly one line
# beginning `OK:` is printed.
#
# Idempotent: re-running re-renders and re-applies the same objects and exits 0.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
DRA_DIR="${PROFILE_DIR}/addons/dra"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version
assert_helm_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

# Release and namespace are both `dra-example-driver-nic` (D-50). The release
# name is what the chart's `fullname` derives every cluster-scoped object name
# from — the ClusterRole, its binding and the ValidatingAdmissionPolicy — so a
# second release with a different name cannot overwrite addon-dra's.
NAMESPACE="dra-example-driver-nic"
RELEASE="dra-example-driver-nic"
DAEMONSET="${RELEASE}-kubeletplugin"
POD_SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=kubeletplugin"

WORKDIR="${WORKDIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/313-k8sai/addon-dra-nic}"

VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"
DRA_CREATE="${DRA_DIR}/create.sh"
DRA_VALUES="${DRA_DIR}/values.yaml"

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
SLICE_TIMEOUT="${SLICE_TIMEOUT:-180}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- the pins, read out of addon-dra -----------------------------------------
# `VAR="${VAR:-<default>}"` is the form addon-dra writes every pin in; this reads
# the <default> half. An env override of addon-dra's pins does not reach this
# layer, on purpose: the committed default is the reviewed value.
dra_default() {
  sed -n "s|^${1}=\"\\\${${1}:-\\([^}]\\{1,\\}\\)}\"\$|\\1|p" "${DRA_CREATE}" | head -1
}
dra_literal() {
  sed -n "s|^${1}=\"\\([^\"\$]\\{1,\\}\\)\"\$|\\1|p" "${DRA_CREATE}" | head -1
}
for _f in "${DRA_CREATE}" "${DRA_VALUES}" "${VALUES_FILE}"; do
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} not found." >&2
    echo "      This layer reads its chart and image pins out of the addon-dra layer beside it," >&2
    echo "      so both layers' files must be present in the tree." >&2
    exit 1
  fi
done
CHART_REPO="$(dra_default CHART_REPO)"
CHART_TAG="$(dra_default CHART_TAG)"
CHART_COMMIT_EXPECTED="$(dra_default CHART_COMMIT_EXPECTED)"
CHART_SUBDIR="$(dra_literal CHART_SUBDIR)"
DRIVER_IMAGE_REPO="$(dra_literal DRIVER_IMAGE_REPO)"
DRIVER_IMAGE_DIGEST="$(dra_default DRIVER_IMAGE_DIGEST)"
for _pair in "CHART_REPO=${CHART_REPO}" "CHART_TAG=${CHART_TAG}" \
             "CHART_COMMIT_EXPECTED=${CHART_COMMIT_EXPECTED}" "CHART_SUBDIR=${CHART_SUBDIR}" \
             "DRIVER_IMAGE_REPO=${DRIVER_IMAGE_REPO}" "DRIVER_IMAGE_DIGEST=${DRIVER_IMAGE_DIGEST}"; do
  case "${_pair}" in
    *=) echo "FAIL: could not read ${_pair%=} out of ${DRA_CREATE}." >&2
        echo "      This layer pins exactly what addon-dra pins, read from that file; a pin" >&2
        echo "      it cannot read is a reason to stop, never to fall back to a literal." >&2
        exit 1 ;;
  esac
done
case "${DRIVER_IMAGE_DIGEST}" in
  sha256:[0-9a-f]*) : ;;
  *) echo "FAIL: the image digest read out of ${DRA_CREATE} is '${DRIVER_IMAGE_DIGEST}', not a sha256 digest." >&2; exit 1 ;;
esac
DRIVER_IMAGE="${DRIVER_IMAGE_REPO}@${DRIVER_IMAGE_DIGEST}"

# This layer's driver name and device count, read out of its own values.yaml;
# addon-dra's driver name out of addon-dra's. Never repeated as literals here.
DRIVER_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
EXPECTED_DEVICES="$(sed -n 's/^[[:space:]]\{1,\}numDevices:[[:space:]]*\([0-9]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | head -1)"
DRA_DRIVER="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${DRA_VALUES}" | head -1)"
if [ -z "${DRIVER_NAME}" ] || [ -z "${EXPECTED_DEVICES}" ] || [ -z "${DRA_DRIVER}" ]; then
  echo "FAIL: could not read driverName and kubeletPlugin.numDevices out of ${VALUES_FILE}," >&2
  echo "      or addon-dra's driverName out of ${DRA_VALUES}." >&2
  exit 1
fi
if [ "${DRIVER_NAME}" = "${DRA_DRIVER}" ]; then
  echo "FAIL: this layer's driverName '${DRIVER_NAME}' is addon-dra's own." >&2
  echo "      Two releases with one driver name share a CDI vendor, a plugin socket directory" >&2
  echo "      and a DeviceClass, and the second apply would take over the first's devices." >&2
  exit 1
fi

# --- preflight: the cluster ---------------------------------------------------
# Captured into a variable and matched with `case`, never a pipe into a quiet
# grep under pipefail (a successful match can return 141).
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
  echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer applies ONTO a running cluster and creates none." >&2
  echo "      Run the base profile and the synthetic-device layer first:" >&2
  echo "        bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh" >&2
  echo "        bash ${DRA_DIR}/create.sh && bash ${DRA_DIR}/verify.sh" >&2
  echo "      then re-run:  bash ${ADDON_DIR}/create.sh" >&2
  exit 1
  ;;
esac

if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer on context '${CONTEXT}'." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
  exit 1
fi

if ! kc wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' reached Ready within 180s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

for _tool in git helm jq; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required — the chart is fetched by git tag and rendered with helm," >&2
    echo "      and jq folds the ResourceSlice reads. Install it and re-run; nothing has been applied." >&2
    exit 1
  fi
done

# Simulated (kwok) nodes excluded, for the reason addons/dra/create.sh records:
# they carry no kubelet, so no driver pod and no slice.
WORKERS="$(kc get nodes -l '!node-role.kubernetes.io/control-plane,type!=kwok' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${WORKERS}" -lt 1 ]; then
  echo "FAIL: '${CLUSTER_NAME}' reports no worker node, so this layer would advertise no synthetic NICs." >&2
  echo "      Recreate the base profile: bash ${PROFILE_DIR}/create.sh" >&2
  exit 1
fi

# --- preflight: ORDERING — addon-dra is applied and publishes pcieRoot -------
DRA_DC="$(kc get deviceclasses.resource.k8s.io "${DRA_DRIVER}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ "${DRA_DC}" != "${DRA_DRIVER}" ]; then
  echo "FAIL: ORDERING — addon-dra is not applied: no DeviceClass '${DRA_DRIVER}' on '${CLUSTER_NAME}'." >&2
  echo "      This layer's synthetic NICs exist to share a PCIe root with addon-dra's synthetic" >&2
  echo "      devices, so it refuses to apply without them. Nothing has been applied." >&2
  echo "      Apply it first:  bash ${DRA_DIR}/create.sh && bash ${DRA_DIR}/verify.sh" >&2
  exit 1
fi
DRA_ROOTS_LINE="$(kc get resourceslices -o json 2>/dev/null | jq -r --arg d "${DRA_DRIVER}" --arg k resource.kubernetes.io/pcieRoot '
  [ .items[] | select(.spec.driver == $d) | .spec.devices[] ] as $devs
  | "devices=\($devs | length) with_root=\([ $devs[] | .attributes[$k].string | select(. != null and . != "") ] | length)"' 2>/dev/null || true)"
DRA_DEVICES="$(printf '%s' "${DRA_ROOTS_LINE}" | sed -n 's/^devices=\([0-9]\{1,\}\) .*$/\1/p')"
DRA_WITH_ROOT="$(printf '%s' "${DRA_ROOTS_LINE}" | sed -n 's/^.* with_root=\([0-9]\{1,\}\)$/\1/p')"
if [ -z "${DRA_DEVICES}" ] || [ "${DRA_DEVICES}" -lt 1 ] || [ "${DRA_WITH_ROOT}" != "${DRA_DEVICES}" ]; then
  echo "FAIL: ORDERING — addon-dra's ResourceSlices carry ${DRA_WITH_ROOT:-0} of ${DRA_DEVICES:-0} devices with a" >&2
  echo "      non-empty resource.kubernetes.io/pcieRoot. Every one must publish it, and there must be" >&2
  echo "      at least one, or no claim can match a synthetic NIC to a synthetic device under one root." >&2
  echo "      Inspect:  kubectl --context ${CONTEXT} get resourceslices -o yaml" >&2
  echo "      Re-apply: bash ${DRA_DIR}/create.sh && bash ${DRA_DIR}/verify.sh" >&2
  exit 1
fi

# --- resolve the chart at the git tag ----------------------------------------
mkdir -p "${WORKDIR}"
CHART_CLONE="${WORKDIR}/dra-example-driver"
if [ ! -d "${CHART_CLONE}/.git" ]; then
  echo "==> cloning ${CHART_REPO} at ${CHART_TAG}" >&2
  if ! git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${CHART_TAG}" "${CHART_REPO}" "${CHART_CLONE}"; then
    echo "FAIL: could not clone ${CHART_REPO} at tag ${CHART_TAG}." >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
    rm -rf "${CHART_CLONE}"
    exit 1
  fi
fi

# The commit is the check that matters; the tag is a name the clone's own .git
# answers for. Both are asserted, as addon-dra asserts them.
CHART_TAGS_AT_HEAD="$(git -C "${CHART_CLONE}" tag --points-at HEAD 2>/dev/null || true)"
CHART_COMMIT="$(git -C "${CHART_CLONE}" rev-parse HEAD 2>/dev/null || true)"
case "
${CHART_TAGS_AT_HEAD}
" in
  *"
${CHART_TAG}
"*) : ;;
  *)
    echo "FAIL: the chart clone at ${CHART_CLONE} is at commit ${CHART_COMMIT:-<unknown>}, which ${CHART_TAG} does not name." >&2
    echo "      Remove it and re-run:  rm -rf ${CHART_CLONE} && bash ${ADDON_DIR}/create.sh" >&2
    exit 1
    ;;
esac
if [ "${CHART_COMMIT}" != "${CHART_COMMIT_EXPECTED}" ]; then
  echo "FAIL: the chart clone at ${CHART_CLONE} is at commit ${CHART_COMMIT:-<unknown>}," >&2
  echo "      not ${CHART_COMMIT_EXPECTED}, the commit addon-dra pins for ${CHART_TAG}. Nothing has been applied." >&2
  echo "      Remove it and re-run:  rm -rf ${CHART_CLONE} && bash ${ADDON_DIR}/create.sh" >&2
  exit 1
fi
if [ ! -f "${CHART_CLONE}/${CHART_SUBDIR}/Chart.yaml" ]; then
  echo "FAIL: no chart at ${CHART_CLONE}/${CHART_SUBDIR}." >&2
  exit 1
fi

# --- render -------------------------------------------------------------------
# --api-versions passed explicitly, for addon-dra's reason: the chart picks its
# DeviceClass apiVersion from .Capabilities, which differs between helm majors.
RENDER_TMP="$(mktemp "${TMPDIR:-/tmp}/addon-dra-nic-rendered.XXXXXX")"
trap 'rm -f "${RENDER_TMP}" "${RENDER_TMP}.sub" "${RENDER_TMP}.candidate"' EXIT

if ! helm template "${RELEASE}" "${CHART_CLONE}/${CHART_SUBDIR}" \
       --namespace "${NAMESPACE}" \
       --api-versions resource.k8s.io/v1 \
       --values "${VALUES_FILE}" > "${RENDER_TMP}"; then
  echo "FAIL: 'helm template' failed against the chart at ${CHART_TAG}. Nothing has been applied." >&2
  exit 1
fi

# helm 3 and helm 4 differ only by blank lines before some `---` separators;
# dropping those makes the committed copy the same bytes whichever helm wrote
# it. The same function addon-dra uses (scripts/addon-dra-render.test.mjs).
normalize_render() {
  awk '/^[[:space:]]*$/ { held = held $0 "\n"; next }
       /^---$/          { held = "" }
                        { printf "%s", held; held = ""; print }
       END              { printf "%s", held }'
}

# --- substitute the digest, and prove it ------------------------------------
sed "s|${DRIVER_IMAGE_REPO}:[A-Za-z0-9._-]\{1,\}|${DRIVER_IMAGE}|g" \
  "${RENDER_TMP}" > "${RENDER_TMP}.sub"

IMAGE_LINES="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(.*\)$/\1/p' "${RENDER_TMP}.sub")"
if [ -z "${IMAGE_LINES}" ]; then
  echo "FAIL: the rendered chart carries no 'image:' line at all, which cannot be right." >&2
  exit 1
fi
UNPINNED=""
OTHER=""
for _img in ${IMAGE_LINES}; do
  case "${_img}" in
    "${DRIVER_IMAGE}"|"\"${DRIVER_IMAGE}\"") : ;;
    *"@sha256:"*) OTHER="${OTHER} ${_img}" ;;
    *) UNPINNED="${UNPINNED} ${_img}" ;;
  esac
done
if [ -n "${UNPINNED}" ]; then
  echo "FAIL: a tag-form image reference survived the digest substitution:${UNPINNED}" >&2
  echo "      PLAT-01 pins every lab image by @sha256 digest. Nothing has been applied." >&2
  exit 1
fi
if [ -n "${OTHER}" ]; then
  echo "FAIL: the render names an image that is not addon-dra's pinned driver image:${OTHER}" >&2
  echo "      This layer applies exactly one image, ${DRIVER_IMAGE}. Nothing has been applied." >&2
  exit 1
fi
echo "digest-pin: every driver image reference is digest-pinned to addon-dra's index digest (pre-apply assert passed)"

DC_APIVERSION="$(awk '/^kind: DeviceClass$/{print prev} {prev=$0}' "${RENDER_TMP}.sub")"
case "${DC_APIVERSION}" in
  "apiVersion: resource.k8s.io/v1") : ;;
  *)
    echo "FAIL: the rendered DeviceClass carries '${DC_APIVERSION:-<nothing>}', not 'apiVersion: resource.k8s.io/v1'." >&2
    exit 1
    ;;
esac

# --- compare the render with the committed object set -------------------------
{
  echo "# GENERATED FILE — do not edit by hand."
  echo "#"
  echo "# The object set addon-dra-nic applies: a SECOND release (${RELEASE}) of the"
  echo "# IN-TREE chart ${CHART_SUBDIR} of ${CHART_REPO}"
  echo "# at git tag ${CHART_TAG} (commit ${CHART_COMMIT}) — the tag, commit and image"
  echo "# index digest addon-dra pins, read from labs/clusters/grid-core/addons/dra/create.sh —"
  echo "# with this layer's committed values.yaml (deviceProfile net), and with every"
  echo "# driver image reference replaced by that digest."
  echo "#"
  echo "# Regenerate with (a reviewed change only):"
  echo "#   REGENERATE=1 bash labs/clusters/grid-core/addons/dra-nic/create.sh"
  echo "#"
  echo "# create.sh applies THIS file, and only after a fresh render at the pinned"
  echo "# commit matches it byte for byte."
  echo "#"
  echo "# The devices this object set advertises are SYNTHETIC NICs. The driver's own"
  echo "# device names, its model string and its bandwidth capacity are Go constants,"
  echo "# not readings — see values.yaml and planning/lab-tests/06-addon-dra-nic.md."
  normalize_render < "${RENDER_TMP}.sub"
} > "${RENDER_TMP}.candidate"

if [ "${REGENERATE:-0}" = "1" ]; then
  cp "${RENDER_TMP}.candidate" "${RENDERED}"
  echo "==> REGENERATE=1: wrote ${RENDERED} from the render at ${CHART_TAG}; review its diff before committing" >&2
elif [ ! -f "${RENDERED}" ] || ! cmp -s "${RENDER_TMP}.candidate" "${RENDERED}"; then
  echo "FAIL: the committed rendered-pinned.yaml differs from a fresh render of the chart at ${CHART_TAG}" >&2
  echo "      (commit ${CHART_COMMIT}): ${RENDERED}" >&2
  echo "      Nothing has been applied, and the committed file was not changed." >&2
  echo "      To see the difference: REGENERATE=1 bash ${ADDON_DIR}/create.sh, then 'git diff' that file;" >&2
  echo "      keep it only as a deliberate, reviewed change." >&2
  exit 1
fi

# --- apply --------------------------------------------------------------------
# Never into a Terminating namespace: that apply exits 0 and creates nothing.
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
if [ "$(kc get namespace "${NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)" != "${NAMESPACE}" ]; then
  echo "FAIL: namespace '${NAMESPACE}' does not exist after it was created." >&2
  exit 1
fi

kc apply -f "${RENDERED}" >/dev/null

# THE EXISTENCE ASSERTION AFTER THE APPLY. An apply's exit code says the API
# server accepted the request; it does not say every object is there. So every
# object the committed file names is read back by kind and name, and the count
# read back must equal the count of documents in the file.
WANT_OBJECTS="$(/usr/bin/grep -c '^kind:' "${RENDERED}" || true)"
GOT_OBJECTS="$(kc get -f "${RENDERED}" -o name 2>/dev/null | /usr/bin/grep -c . || true)"
if [ "${WANT_OBJECTS:-0}" -lt 1 ] || [ "${GOT_OBJECTS:-0}" -ne "${WANT_OBJECTS}" ]; then
  echo "FAIL: ${GOT_OBJECTS:-0} of the ${WANT_OBJECTS:-0} objects in ${RENDERED} exist after the apply." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get -f ${RENDERED}" >&2
  exit 1
fi

if ! kc -n "${NAMESPACE}" rollout status "ds/${DAEMONSET}" --timeout="${ROLLOUT_TIMEOUT}s"; then
  echo "FAIL: DaemonSet ${DAEMONSET} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} describe ds/${DAEMONSET}" >&2
  echo "               kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l ${POD_SELECTOR}" >&2
  exit 1
fi

# --- read back ----------------------------------------------------------------
# What RAN, not only what was asked for: every Running plugin container's
# imageID must carry addon-dra's index digest.
RUNNING_IMAGE_IDS="$(kc -n "${NAMESPACE}" get pod -l "${POD_SELECTOR}" \
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
  echo "FAIL: ${PODS_PINNED}/${PODS_SEEN} running synthetic-NIC plugin container(s) carry the pinned digest ${DRIVER_IMAGE_DIGEST}." >&2
  echo "      Running imageIDs: ${RUNNING_IMAGE_IDS:-<none>}" >&2
  exit 1
fi

# The plugin publishes its slices shortly after it registers, so this polls —
# counting ONLY this driver's slices, because addon-dra's are on the same nodes.
_waited=0
SLICES=0
while [ "${_waited}" -lt "${SLICE_TIMEOUT}" ]; do
  SLICES="$(kc get resourceslices -o json 2>/dev/null | jq -r --arg d "${DRIVER_NAME}" '[.items[] | select(.spec.driver == $d)] | length' 2>/dev/null || true)"
  SLICES="${SLICES:-0}"
  if [ "${SLICES}" -ge "${WORKERS}" ]; then break; fi
  sleep 3
  _waited=$((_waited + 3))
done
if [ "${SLICES}" -lt "${WORKERS}" ]; then
  echo "FAIL: ${SLICES} ResourceSlice(s) for driver '${DRIVER_NAME}' after ${_waited}s; expected one per worker (${WORKERS})." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l ${POD_SELECTOR}" >&2
  exit 1
fi

DEVICE_CLASS="$(kc get deviceclasses.resource.k8s.io "${DRIVER_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ "${DEVICE_CLASS}" != "${DRIVER_NAME}" ]; then
  echo "FAIL: no DeviceClass named '${DRIVER_NAME}' exists after the apply." >&2
  exit 1
fi

echo
echo "OK: addon-dra-nic applied onto '${CLUSTER_NAME}' — driver '${DRIVER_NAME}', DeviceClass '${DEVICE_CLASS}', ${EXPECTED_DEVICES} synthetic NICs on each of ${WORKERS} worker(s), across ${SLICES} ResourceSlice(s), beside addon-dra's '${DRA_DRIVER}'."
echo "  the NICs are SYNTHETIC — no network card is behind any of them, and the driver's own names, model and bandwidth figure are constants in its source"
echo "  chart:      ${CHART_SUBDIR} at ${CHART_TAG} (commit ${CHART_COMMIT}), release ${RELEASE}"
echo "  image:      ${DRIVER_IMAGE} (addon-dra's pin)"
echo "  applied:    ${RENDERED}"
echo "  namespace:  ${NAMESPACE}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "  note:       addons/dra/verify.sh does not pass while this layer is up — it asserts every slice is its own driver's; verify addon-dra before this layer and after its teardown"
echo "next: bash ${ADDON_DIR}/verify.sh"

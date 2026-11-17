#!/usr/bin/env bash
# addon-nvml-mock — apply the MOCK-DEVICE layer onto a running grid-core: NVIDIA's
# mock NVML library (Mokka nvml-mock 0.7.0) and, by default, the two consumers
# SPIKE-09 proved on it — the unmodified vendor device plugin and dcgm-exporter.
#
# THIS IS A LAYER, NOT A PROFILE. It creates no cluster. It applies onto the
# cluster `labs/clusters/grid-core/create.sh` already made, and its teardown.sh
# removes the layer and leaves that cluster running. Nothing here needed a
# create-time change: the kind v0.33.0 node already ships containerd with NRI
# and CDI enabled, and SPIKE-09 ran the base profile unmodified on three arms
# (planning/lab-tests/spike-09-mokka.md § "Node changes the consumers needed").
#
# WHAT THE DEVICES ARE. Four MOCK DEVICES on one worker, served by a mock NVML
# library from the `t4` profile in values.yaml. There is no accelerator in this
# VM and nothing here measures one. Every consumer that asks the mock who it is
# gets the profile's answer, so captures print vendor product names, a driver
# version, device UUIDs and memory sizes that this course did not write and
# that describe no hardware here. STANDARDS.md C15 requires a caption wherever
# that text reaches a page. Mokka's own README says what its simulation depth
# does not reach — CUDA execution, NCCL, GPUDirect and RDMA data paths, any
# throughput or thermal measurement, driver and firmware lifecycle, physically
# faithful fault timing, MIG partition lifecycle — and PINS.md § 4 repeats it.
#
# WHAT THE MOCK CHANGES ON THE WORKER, read on three arms by SPIKE-09 and not a
# guess. Its node agent rewrites the worker's containerd: a drop-in under
# /etc/containerd/conf.d, an imports line, two CDI specs, the DEFAULT RUNTIME
# HANDLER moved from runc to the vendor container runtime the mock's image
# installs, and a containerd restart. Upstream says the node agent reverts that
# when its Pod stops; teardown.sh reads the worker back and reports what it
# finds. Recreating grid-core is always the way back to a worker that never
# had the mock: `bash ../../teardown.sh && bash ../../create.sh`.
#
# ONE INTERACTION THAT IS NOT FREE — the extended-resource bridge. With the
# device plugin advertising its resource on a worker, a DeviceClass that maps
# the SAME resource name through DRA took no part in scheduling, either for a
# one-device request or to make up a shortfall (SPIKE-09 configuration B, all
# three arms). The two paths do not compose. So with the consumers on, this
# script REFUSES to apply while any DeviceClass carries an extendedResourceName
# ending in `/gpu`; delete that DeviceClass first, or apply mock-only.
#
# THE KNOB. NVML_MOCK_CONSUMERS selects what goes on top of the mock:
#   device-plugin,dcgm-exporter   the default: both consumers, as SPIKE-09 ran them
#   none                          mock only. The optional scheduler lab needs this,
#                                 because its own device plugin advertises the
#                                 same resource name (spike-10-hami.md § "If GO",
#                                 item 2). Applying `none` over an applied default
#                                 REMOVES the consumers.
# The mode is written onto the layer's namespace as an annotation, so verify.sh
# reads the mode the layer was applied with instead of being told it again.
#
# HOW THE OBJECT SETS ARE PINNED. PINS.md is the register: this script reads the
# chart digest and all three image digests out of it. The chart is pulled by
# version from its OCI coordinate and REFUSED if its manifest digest is not the
# registered one; it is rendered with values.yaml (which carries the mock's
# image digest natively), every image line is asserted to be the registered
# pin, and the render must equal the committed rendered-pinned.yaml byte for
# byte — the COMMITTED file is what is applied. The consumers have no chart in
# the configuration SPIKE-09 ran, so consumers-pinned.yaml is the reviewed
# object set itself; its image lines are asserted against the register too.
# After every rollout the running containers' imageIDs are read back and
# compared, so a node that resolved something else cannot pass.
#
# Usage:
#   bash create.sh                                  # mock + both consumers
#   NVML_MOCK_CONSUMERS=none bash create.sh         # mock only
#   bash create.sh && bash verify.sh
#
# Regenerate rendered-pinned.yaml (a deliberate, reviewed change only):
#   REGENERATE=1 bash labs/clusters/grid-core/addons/nvml-mock/create.sh
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig     # set by the base profile
#   SIZE               8 or 16 (default 8) — validated by labs/tools/size-gate.sh
#   ROLLOUT_TIMEOUT    seconds per DaemonSet rollout (default 900; a cold pull of
#                      the mock's image measured 38 s on the authoring host)
#   SERVE_TIMEOUT      seconds to wait for the resource and the exporter's first
#                      device series (default 300)
#
# Reporting contract (same as the base profile): every hard assert prints
# `FAIL: <what> <remedy>` to stderr and exits 1; on success exactly one line
# beginning `OK:` is printed.
#
# Idempotent: re-running re-renders, re-applies the same objects and exits 0.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Identical to labs/clusters/grid-core/*.sh: the version asserts are sourced
# rather than re-implemented, because a PATH prepend is not a resolution
# guarantee on a host carrying a stale kind elsewhere on PATH.
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
# The chart is pulled from an OCI registry, so the helm floor is asserted
# BEFORE the pull.
assert_helm_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

# The mock's namespace is SPIKE-09's. The mock's NRI plugin never injects its
# own release namespace or kube-system, which is why the exporter has its own.
NS_MOCK="mokka"
NS_EXPORTER="dcgm-exporter"
NS_PLUGIN="kube-system"
DS_MOCK="nvml-mock"
DS_PLUGIN="nvidia-device-plugin-mock"
DS_EXPORTER="dcgm-exporter"
RELEASE="nvml-mock"
# Exactly one node carries the mock, at both sizes: grid-core-worker exists at
# SIZE=8 and SIZE=16 (grid-core/verify.sh asserts it).
WORKER="${CLUSTER_NAME}-worker"
NODE_LABEL_KEY="mokka.nvidia.com/type"
NODE_LABEL_VALUE="sgpu"
MODE_ANNOTATION="addon-nvml-mock.example.com/consumers"

CHART_REF="oci://ghcr.io/nvidia/k8s-test-infra/chart/nvml-mock"
CHART_VERSION="0.7.0"

PINS="${ADDON_DIR}/PINS.md"
VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"
CONSUMERS="${ADDON_DIR}/consumers-pinned.yaml"
# A per-user cache, not a fixed shared /tmp path another local user could
# create first (review IN-09, phase 3).
WORKDIR="${WORKDIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/313-k8sai/addon-nvml-mock}"

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-900}"
SERVE_TIMEOUT="${SERVE_TIMEOUT:-300}"

COSIGN_IDENTITY="https://github.com/NVIDIA/k8s-test-infra/.github/workflows/nvml-mock-publish.yaml@refs/tags/v0.7.0"
COSIGN_ISSUER="https://token.actions.githubusercontent.com"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- the knob -----------------------------------------------------------------
CONSUMERS_MODE="${NVML_MOCK_CONSUMERS:-device-plugin,dcgm-exporter}"
case "${CONSUMERS_MODE}" in
  device-plugin,dcgm-exporter|none) : ;;
  *)
    echo "FAIL: NVML_MOCK_CONSUMERS='${CONSUMERS_MODE}' is not a mode this layer has." >&2
    echo "      Use 'device-plugin,dcgm-exporter' (the default: both consumers SPIKE-09 proved)" >&2
    echo "      or 'none' (the mock only, for the optional scheduler lab). Nothing has been applied." >&2
    exit 1
    ;;
esac

# --- the register -------------------------------------------------------------
# Read out of PINS.md rather than restated here: a second copy of a digest is a
# second authority that can be right while the first one is wrong.
for _f in "${PINS}" "${VALUES_FILE}" "${RENDERED}" "${CONSUMERS}"; do
  # REGENERATE=1 is the one run that may find the render absent: it writes it.
  if [ "${_f}" = "${RENDERED}" ] && [ "${REGENERATE:-0}" = "1" ]; then continue; fi
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} is missing — the layer's own committed artifacts are incomplete." >&2
    exit 1
  fi
done
pin_of() {
  # pin_of <repository> -> the full `<repository>@sha256:<hex>` row of § 2
  sed -n "s#^| \`\\($1@sha256:[0-9a-f]\\{64\\}\\)\`.*\$#\\1#p" "${PINS}" | sed -n '1p'
}
MOCK_IMAGE="$(pin_of 'ghcr.io/nvidia/nvml-mock')"
PLUGIN_IMAGE="$(pin_of 'nvcr.io/nvidia/k8s-device-plugin')"
EXPORTER_IMAGE="$(pin_of 'nvcr.io/nvidia/k8s/dcgm-exporter')"
CHART_DIGEST="$(sed -n 's#^| Mokka nvml-mock | `oci://[^`]*` | `[^`]*` | `\(sha256:[0-9a-f]\{64\}\)`.*$#\1#p' "${PINS}" | sed -n '1p')"
if [ -z "${MOCK_IMAGE}" ] || [ -z "${PLUGIN_IMAGE}" ] || [ -z "${EXPORTER_IMAGE}" ] || [ -z "${CHART_DIGEST}" ]; then
  echo "FAIL: could not read the chart digest and all three image pins out of ${PINS}." >&2
  echo "      read: chart='${CHART_DIGEST}' mock='${MOCK_IMAGE}' plugin='${PLUGIN_IMAGE}' exporter='${EXPORTER_IMAGE}'" >&2
  echo "      The register is the authority; a table edit that breaks its rows breaks the install here." >&2
  exit 1
fi
VALUES_DIGEST="$(sed -n 's/^[[:space:]]*digest:[[:space:]]*\(sha256:[0-9a-f]\{64\}\).*$/\1/p' "${VALUES_FILE}" | sed -n '1p')"
if [ "${MOCK_IMAGE##*@}" != "${VALUES_DIGEST}" ]; then
  echo "FAIL: values.yaml pins the mock's image at '${VALUES_DIGEST:-<none>}', PINS.md at '${MOCK_IMAGE##*@}'." >&2
  echo "      One of the two was edited without the other. Nothing has been applied." >&2
  exit 1
fi

# image_lines <file> -> every applied `image:` value, quotes stripped, one per line
image_lines() {
  sed -n 's/^[[:space:]-]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]\{1,\}\)"\{0,1\}[[:space:]]*$/\1/p' "$1"
}

# --- preflight ----------------------------------------------------------------
# The cluster check comes FIRST and before anything expensive. Captured into a
# variable and matched with `case`, never a pipe into a quiet matcher: under
# `pipefail` a successful quiet match returns 141 (SIGPIPE).
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
  echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz; then bash ${PROFILE_DIR}/verify.sh" >&2
  exit 1
fi

if ! kc wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1; then
  echo "FAIL: not every node on '${CLUSTER_NAME}' reached Ready within 180s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes" >&2
  exit 1
fi

for _tool in helm jq; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required — the chart is pulled and rendered with helm, and jq reads" >&2
    echo "      the pins back off every running container. Install it and re-run; nothing has" >&2
    echo "      been applied to '${CLUSTER_NAME}' yet." >&2
    exit 1
  fi
done

if ! kc get node "${WORKER}" >/dev/null 2>&1; then
  echo "FAIL: node '${WORKER}' not found — the mock goes on exactly that node." >&2
  echo "      Recreate the base profile: bash ${PROFILE_DIR}/create.sh" >&2
  exit 1
fi

if [ "${CONSUMERS_MODE}" != "none" ]; then
  # The two paths that do not compose (SPIKE-09 configuration B), refused
  # rather than left for a learner to discover as a Pod that silently ignores
  # the bridge. Selected by the `/gpu` suffix, the same way verify.sh selects
  # the device plugin's resource.
  BRIDGES="$(kc get deviceclasses.resource.k8s.io -o json 2>/dev/null \
             | jq -r '[.items[] | select((.spec.extendedResourceName // "") | endswith("/gpu")) | .metadata.name] | join(" ")' 2>/dev/null || true)"
  if [ -n "${BRIDGES}" ]; then
    echo "FAIL: DeviceClass(es) '${BRIDGES}' map a '/gpu' extended resource name through DRA." >&2
    echo "      With the device plugin advertising that name on the same worker, the bridge took" >&2
    echo "      no part in scheduling on any arm SPIKE-09 ran: the two paths do not compose." >&2
    echo "      Delete the bridge first:  kubectl --context ${CONTEXT} delete deviceclass ${BRIDGES}" >&2
    echo "      or apply the mock alone:  NVML_MOCK_CONSUMERS=none bash ${ADDON_DIR}/create.sh" >&2
    exit 1
  fi
fi

# --- the image pins in the two committed object sets --------------------------
# Every image line of each file must be a registered pin, and the set must not
# be empty. A tag survives nowhere; an image the register does not record is a
# reviewed change that has not been reviewed.
check_images() {
  # check_images <file> <allowed pins, space-separated>
  _file="$1"; _allowed=" $2 "; _n=0; _bad=""
  for _img in $(image_lines "${_file}"); do
    _n=$((_n + 1))
    case "${_allowed}" in *" ${_img} "*) : ;; *) _bad="${_bad} ${_img}" ;; esac
  done
  if [ "${_n}" -lt 1 ]; then
    echo "FAIL: ${_file} carries no image line at all, which cannot be right. Nothing has been applied." >&2
    exit 1
  fi
  if [ -n "${_bad}" ]; then
    echo "FAIL: ${_file} names image(s) that are not a pin registered in PINS.md:${_bad}" >&2
    echo "      PLAT-01 pins every lab image by index digest, and a new image is a reviewed change:" >&2
    echo "      resolve it with \`docker buildx imagetools inspect <repo>:<tag>\` and register it first." >&2
    exit 1
  fi
}
check_images "${CONSUMERS}" "${PLUGIN_IMAGE} ${EXPORTER_IMAGE}"

# --- the mock image's signature -----------------------------------------------
# Where cosign is installed the signature is verified and a failure refuses the
# install. Where it is not, the absence is SAID, every run, because a pin with
# an unchecked signature is a weaker claim and the reader is owed which one.
if command -v cosign >/dev/null 2>&1; then
  if ! COSIGN_OUT="$(cosign verify "${MOCK_IMAGE}" \
        --certificate-identity "${COSIGN_IDENTITY}" \
        --certificate-oidc-issuer "${COSIGN_ISSUER}" 2>&1 >/dev/null)"; then
    echo "FAIL: cosign could not verify the mock's image ${MOCK_IMAGE}" >&2
    echo "      against identity ${COSIGN_IDENTITY}." >&2
    printf '%s\n' "${COSIGN_OUT}" | sed -n '1,8p' | sed 's/^/      cosign: /' >&2
    echo "      Nothing has been applied." >&2
    exit 1
  fi
  SIGNATURE_NOTE="cosign verified the mock's image signature (identity: the v0.7.0 publish workflow)"
else
  SIGNATURE_NOTE="cosign is NOT installed on this host, so the mock's image signature was NOT verified; the index-digest pin is the only gate"
fi
echo "==> ${SIGNATURE_NOTE}" >&2

# --- the chart, pulled by version and refused on a digest mismatch ------------
mkdir -p "${WORKDIR}"
PULL_DIR="$(mktemp -d "${WORKDIR}/pull.XXXXXX")"
RENDER_TMP="$(mktemp "${TMPDIR:-/tmp}/addon-nvml-mock-rendered.XXXXXX")"
trap 'rm -rf "${PULL_DIR}"; rm -f "${RENDER_TMP}" "${RENDER_TMP}.candidate"' EXIT

if ! PULL_OUT="$(helm pull "${CHART_REF}" --version "${CHART_VERSION}" --destination "${PULL_DIR}" 2>&1)"; then
  echo "FAIL: could not pull ${CHART_REF} at ${CHART_VERSION}:" >&2
  printf '%s\n' "${PULL_OUT}" | sed 's/^/      /' >&2
  echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
  exit 1
fi
PULLED_DIGEST="$(printf '%s\n' "${PULL_OUT}" | sed -n 's/^Digest:[[:space:]]*\(sha256:[0-9a-f]\{64\}\).*$/\1/p' | sed -n '1p')"
if [ "${PULLED_DIGEST}" != "${CHART_DIGEST}" ]; then
  echo "FAIL: the chart pulled as ${CHART_REF}:${CHART_VERSION} has manifest digest '${PULLED_DIGEST:-<none printed>}'," >&2
  echo "      not the registered ${CHART_DIGEST} (PINS.md § 1). A reissued chart under the same" >&2
  echo "      version is exactly what this refuses. Nothing has been applied." >&2
  exit 1
fi
if ! tar -xzf "${PULL_DIR}/nvml-mock-${CHART_VERSION}.tgz" -C "${PULL_DIR}"; then
  echo "FAIL: could not unpack the pulled chart. Nothing has been applied." >&2
  exit 1
fi

# --- render -------------------------------------------------------------------
# This chart writes no namespace into its objects whatever --namespace says
# (SPIKE-09 superseded run 1, which put the mock in `default`), so the render is
# applied with `-n` below and the committed file carries no namespace either.
if ! helm template "${RELEASE}" "${PULL_DIR}/nvml-mock" \
       --namespace "${NS_MOCK}" \
       --values "${VALUES_FILE}" > "${RENDER_TMP}"; then
  echo "FAIL: 'helm template' failed against the chart at ${CHART_VERSION}. Nothing has been applied." >&2
  exit 1
fi

# helm 3 and helm 4 differ in blank lines before document separators (measured
# on addon-dra's chart, plan 05-28); a blank line there carries nothing in YAML,
# so it is dropped and the committed copy is the same bytes whichever helm wrote it.
normalize_render() {
  awk '/^[[:space:]]*$/ { held = held $0 "\n"; next }
       /^---$/          { held = "" }
                        { printf "%s", held; held = ""; print }
       END              { printf "%s", held }'
}

{
  echo "# GENERATED FILE — do not edit by hand."
  echo "#"
  echo "# The object set addon-nvml-mock applies for the MOCK, rendered from the chart"
  echo "# ${CHART_REF} at ${CHART_VERSION} (manifest digest ${CHART_DIGEST})"
  echo "# with the committed values.yaml, which pins the image by index digest natively."
  echo "#"
  echo "# Regenerate with (a reviewed change only):"
  echo "#   REGENERATE=1 bash labs/clusters/grid-core/addons/nvml-mock/create.sh"
  echo "#"
  echo "# create.sh applies THIS file, with -n ${NS_MOCK}, and only after a fresh render at the"
  echo "# registered chart digest matches it byte for byte. Every comment below this header is"
  echo "# the chart's own text, kept verbatim so the render stays byte-comparable. The devices"
  echo "# it stages are mock devices; the product name and figures in its profile ConfigMap are"
  echo "# values in a profile file, not readings of any hardware (PINS.md § 4)."
  normalize_render < "${RENDER_TMP}"
} > "${RENDER_TMP}.candidate"

check_images "${RENDER_TMP}.candidate" "${MOCK_IMAGE}"
echo "digest-pin: every image line in the mock render and the consumers file is a registered pin (pre-apply assert passed)" >&2

if [ "${REGENERATE:-0}" = "1" ]; then
  cp "${RENDER_TMP}.candidate" "${RENDERED}"
  echo "==> REGENERATE=1: wrote ${RENDERED}; review its diff before committing" >&2
elif ! cmp -s "${RENDER_TMP}.candidate" "${RENDERED}"; then
  echo "FAIL: the committed rendered-pinned.yaml differs from a fresh render of the chart at ${CHART_VERSION}:" >&2
  echo "      ${RENDERED}" >&2
  echo "      Nothing has been applied, and the committed file was not changed. To see the" >&2
  echo "      difference, re-run with REGENERATE=1 and read 'git diff' on that file; keep it only" >&2
  echo "      as a deliberate, reviewed change." >&2
  exit 1
fi

# --- namespace helper ---------------------------------------------------------
# NEVER apply into a Terminating namespace: it exits 0 and creates nothing (a
# Phase-1 finding), so the phase is read and waited on.
# ensure_namespace <ns> [wait-only]: wait out a Terminating namespace, then create it
# unless `wait-only` — the exporter's namespace is an object in consumers-pinned.yaml,
# so the apply creates it and a prior `create` would only earn kubectl's
# missing-last-applied-configuration warning.
ensure_namespace() {
  _ns="$1"
  _phase="$(kc get namespace "${_ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${_phase}" = "Terminating" ]; then
    echo "==> namespace '${_ns}' is Terminating; waiting for it to go away before applying" >&2
    _w=0
    while [ "${_w}" -lt 180 ] && kc get namespace "${_ns}" >/dev/null 2>&1; do sleep 3; _w=$((_w + 3)); done
    if kc get namespace "${_ns}" >/dev/null 2>&1; then
      echo "FAIL: namespace '${_ns}' is still Terminating after ${_w}s; an apply into it would create nothing." >&2
      echo "      Inspect: kubectl --context ${CONTEXT} get namespace ${_ns} -o yaml" >&2
      exit 1
    fi
    _phase=""
  fi
  if [ -z "${_phase}" ] && [ "${2:-}" != "wait-only" ]; then
    kc create namespace "${_ns}" >/dev/null
  fi
}

# must_exist <namespace> <kind/name> : the existence assertion after an apply (D-43)
must_exist() {
  if ! kc -n "$1" get "$2" >/dev/null 2>&1; then
    echo "FAIL: ${2} is not in namespace '${1}' after the apply, although the apply exited 0." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${1} get all" >&2
    exit 1
  fi
}

# pinned_running <namespace> <selector> <digest> <what> : every Running container on the pin
pinned_running() {
  _ids="$(kc -n "$1" get pod -l "$2" --field-selector status.phase=Running -o json 2>/dev/null \
          | jq -r '[.items[].status | (.initContainerStatuses // []) + (.containerStatuses // []) | .[].imageID] | join(" ")' 2>/dev/null || true)"
  _seen=0; _ok=0
  for _id in ${_ids}; do
    _seen=$((_seen + 1))
    case "${_id}" in *"$3"*) _ok=$((_ok + 1)) ;; esac
  done
  if [ "${_seen}" -lt 1 ] || [ "${_ok}" -ne "${_seen}" ]; then
    echo "FAIL: ${_ok}/${_seen} running $4 container(s) carry the registered digest $3." >&2
    echo "      The manifest asked for the pin and a node resolved something else, or nothing is" >&2
    echo "      running — either way a written-only pin would not have caught it." >&2
    echo "      Running imageIDs: ${_ids:-<none>}" >&2
    exit 1
  fi
}

# --- apply: the mock ----------------------------------------------------------
kc label node "${WORKER}" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite >/dev/null
ensure_namespace "${NS_MOCK}"
kc annotate namespace "${NS_MOCK}" "${MODE_ANNOTATION}=${CONSUMERS_MODE}" --overwrite >/dev/null
kc -n "${NS_MOCK}" apply -f "${RENDERED}" >/dev/null
must_exist "${NS_MOCK}" "ds/${DS_MOCK}"

if ! kc -n "${NS_MOCK}" rollout status "ds/${DS_MOCK}" --timeout="${ROLLOUT_TIMEOUT}s" >&2; then
  echo "FAIL: DaemonSet ${DS_MOCK} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} describe ds/${DS_MOCK}" >&2
  echo "               kubectl --context ${CONTEXT} -n ${NS_MOCK} logs -l app.kubernetes.io/name=nvml-mock -c node-agent" >&2
  exit 1
fi
if ! kc -n "${NS_MOCK}" wait --for=condition=Ready pod -l app.kubernetes.io/name=nvml-mock --timeout=300s >/dev/null; then
  echo "FAIL: the mock's Pod did not report Ready within 300s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} get pods -o wide" >&2
  exit 1
fi
pinned_running "${NS_MOCK}" "app.kubernetes.io/name=nvml-mock" "${MOCK_IMAGE##*@}" "mock"

# --- apply or remove: the consumers -------------------------------------------
RESOURCE_NAME=""
RESOURCE_COUNT=""
DEVICE_SERIES=0
if [ "${CONSUMERS_MODE}" = "none" ]; then
  if kc -n "${NS_PLUGIN}" get "ds/${DS_PLUGIN}" >/dev/null 2>&1 || kc get namespace "${NS_EXPORTER}" >/dev/null 2>&1; then
    echo "==> mock-only mode over an applied default: removing the two consumers" >&2
    kc delete -f "${CONSUMERS}" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  fi
  if kc -n "${NS_PLUGIN}" get "ds/${DS_PLUGIN}" >/dev/null 2>&1 || kc get namespace "${NS_EXPORTER}" >/dev/null 2>&1; then
    echo "FAIL: mock-only mode, but a consumer is still present after its removal." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_PLUGIN} get ds ${DS_PLUGIN}; kubectl --context ${CONTEXT} get ns ${NS_EXPORTER}" >&2
    exit 1
  fi
else
  ensure_namespace "${NS_EXPORTER}" wait-only
  kc apply -f "${CONSUMERS}" >/dev/null
  must_exist "${NS_PLUGIN}" "ds/${DS_PLUGIN}"
  must_exist "${NS_EXPORTER}" "ds/${DS_EXPORTER}"

  if ! kc -n "${NS_PLUGIN}" rollout status "ds/${DS_PLUGIN}" --timeout="${ROLLOUT_TIMEOUT}s" >&2; then
    echo "FAIL: DaemonSet ${DS_PLUGIN} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_PLUGIN} logs -l name=${DS_PLUGIN}" >&2
    exit 1
  fi
  pinned_running "${NS_PLUGIN}" "name=${DS_PLUGIN}" "${PLUGIN_IMAGE##*@}" "device plugin"

  # The resource is SELECTED BY ITS `/gpu` SUFFIX, never named, so neither this
  # script nor the checks file carries the vendor resource literal. Polled,
  # because the plugin registers with the kubelet after its Pod is Ready.
  _w=0
  while [ "${_w}" -lt "${SERVE_TIMEOUT}" ]; do
    RESOURCE="$(kc get node "${WORKER}" -o json 2>/dev/null \
                | jq -r '[.status.allocatable // {} | to_entries[] | select(.key | endswith("/gpu")) | "\(.key)=\(.value)"] | first // ""' 2>/dev/null || true)"
    RESOURCE_NAME="${RESOURCE%%=*}"
    RESOURCE_COUNT="${RESOURCE#*=}"
    if [ -n "${RESOURCE}" ] && [ "${RESOURCE_COUNT}" != "0" ]; then break; fi
    sleep 3
    _w=$((_w + 3))
  done
  if [ -z "${RESOURCE:-}" ] || [ "${RESOURCE_COUNT}" = "0" ]; then
    echo "FAIL: after ${_w}s node '${WORKER}' advertises no non-zero allocatable resource ending in '/gpu'." >&2
    echo "      The device plugin rolled out but registered nothing the kubelet counts." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_PLUGIN} logs -l name=${DS_PLUGIN}" >&2
    exit 1
  fi

  if ! kc -n "${NS_EXPORTER}" rollout status "ds/${DS_EXPORTER}" --timeout="${ROLLOUT_TIMEOUT}s" >&2; then
    echo "FAIL: DaemonSet ${DS_EXPORTER} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
    echo "      If its container restarts with exit 137, something put a memory limit back on it:" >&2
    echo "      a 256Mi limit OOM-killed it against the mock on every start (SPIKE-09 run 2)." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_EXPORTER} describe pods" >&2
    exit 1
  fi
  pinned_running "${NS_EXPORTER}" "app.kubernetes.io/name=dcgm-exporter" "${EXPORTER_IMAGE##*@}" "exporter"

  # The exporter is ready before it has collected anything, so its own metrics
  # endpoint is read, through the API server's Pod proxy (no port-forward), until
  # it serves per-device series. Only the NUMBER OF DEVICES with a series is
  # read; no value of any series is read or printed.
  EXPORTER_POD="$(kc -n "${NS_EXPORTER}" get pod -l app.kubernetes.io/name=dcgm-exporter \
                   --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  _w=0
  while [ "${_w}" -lt "${SERVE_TIMEOUT}" ]; do
    SCRAPE="$(kc get --raw "/api/v1/namespaces/${NS_EXPORTER}/pods/${EXPORTER_POD}:9400/proxy/metrics" 2>/dev/null || true)"
    DEVICE_SERIES="$(printf '%s\n' "${SCRAPE}" | sed -n 's/^DCGM_FI_DEV_[A-Z_]*.*[{,]gpu="\([0-9]\{1,\}\)".*$/\1/p' | sort -u | wc -l | tr -d ' ')"
    if [ "${DEVICE_SERIES:-0}" -ge 1 ]; then break; fi
    sleep 5
    _w=$((_w + 5))
  done
  if [ "${DEVICE_SERIES:-0}" -lt 1 ]; then
    echo "FAIL: after ${_w}s the exporter serves no per-device series for any mock device." >&2
    echo "      It started but its embedded host engine found nothing to read. Mokka's NRI plugin" >&2
    echo "      injects only Pods carrying the nvml-mock.nvidia.com/devices annotation outside the" >&2
    echo "      mock's namespace and kube-system, and only once the mock is Ready." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_EXPORTER} logs ${EXPORTER_POD:-<pod>}" >&2
    exit 1
  fi
fi

echo
if [ "${CONSUMERS_MODE}" = "none" ]; then
  echo "OK: addon-nvml-mock applied (none: mock only) onto '${CLUSTER_NAME}' — the mock's DaemonSet Ready on '${WORKER}' only, on the registered digest, with no device plugin and no exporter on the cluster."
else
  echo "OK: addon-nvml-mock applied (${CONSUMERS_MODE}) onto '${CLUSTER_NAME}' — the mock Ready on '${WORKER}' only, the device plugin registering '${RESOURCE_NAME}' (${RESOURCE_COUNT} allocatable on that node), and the exporter serving series for ${DEVICE_SERIES} mock device(s), every container on its registered digest."
fi
echo "  the devices are MOCK DEVICES served by a mock NVML library — the product name, driver version and memory figures they report are values in the '$(sed -n 's/^[[:space:]]*profile:[[:space:]]*\([a-z0-9-]\{1,\}\).*$/\1/p' "${VALUES_FILE}" | sed -n '1p')' profile file, not readings"
echo "  ${SIGNATURE_NOTE}"
echo "  the worker's containerd now runs the vendor container runtime as its default handler; teardown.sh reads back whether the node agent reverted it, and recreating grid-core always returns a worker that never had the mock"
echo "  chart:      ${CHART_REF}:${CHART_VERSION} (${CHART_DIGEST})"
echo "  applied:    ${RENDERED} (-n ${NS_MOCK})"
[ "${CONSUMERS_MODE}" = "none" ] || echo "              ${CONSUMERS}"
echo "  register:   ${PINS}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: bash ${ADDON_DIR}/verify.sh"
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-addon-nvml-mock-size${SIZE} FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_TOOLS}/measure.sh read grid-core-addon-nvml-mock"
echo "              (read it BEFORE any teardown — kind delete removes the cgroups the figure comes from)"

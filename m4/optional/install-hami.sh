#!/usr/bin/env bash
# install-hami.sh — put HAMi v2.11.0 onto grid-core for M4's OPTIONAL lab, on mock devices.
#
# THIS IS THE OPTIONAL TRACK, NEVER THE CORE PATH. HAMi brings a second scheduler path (its own
# kube-scheduler with a scheduler extender, a mutating webhook that routes Pods to it, and a device
# plugin). The course keeps a second scheduler out of the core path, so this script is called only
# by site/docs/m4-gpu-enabled-nodes/optional-lab.md, and the lab deletes the cluster afterwards.
#
# WHAT THE DEVICES ARE. The four devices HAMi registers are MOCK DEVICES served by Mokka's mock
# NVML library (labs/clusters/grid-core/addons/nvml-mock/, applied with NVML_MOCK_CONSUMERS=none
# first). Nothing here runs CUDA, so HAMi-core, the library that would hold a process to its memory
# and core share, is never exercised: this lab shows admission and placement by accounting only.
#
# HOW IT IS PINNED (SPIKE-10, planning/lab-tests/spike-10-hami.md § "If GO"):
#   - the chart is the v2.11.0 RELEASE ASSET, fetched by URL and refused on a sha256 mismatch;
#     never a branch build;
#   - values.yaml pins every image tag@index-digest through the chart's own tag fields, and is
#     asserted against PINS.md before anything renders;
#   - the render must equal the committed hami-rendered-pinned.yaml byte for byte, every image line
#     in it must be a registered pin, and the COMMITTED file is what is applied;
#   - after the apply, every HAMi container's running imageID is read back against the HAMi pin.
#
# WHY kubectl apply AND NOT helm install. The committed render is the reviewed object set, the same
# rule the course's other layers follow. The chart's two certificate Jobs are Helm hooks; applied
# as plain objects they run side by side, and the patch Job retries until the create Job's Secret
# exists. The script waits for both Jobs to complete.
#
# THE WEBHOOK FAILS OPEN. HAMi's MutatingWebhookConfiguration has failurePolicy: Ignore. Until the
# extender holds leadership and labels its own Pod, the webhook's Service has no endpoint, and a Pod
# created in that gap goes to the DEFAULT scheduler unmutated and stays Pending (SPIKE-10 superseded
# run 1). So this script does not finish until a server-side dry-run Pod comes back with
# schedulerName: hami-scheduler.
#
# Usage (from the root of the labs repository, with grid-core and the mock-only layer up):
#   bash m4/optional/install-hami.sh
#
# Regenerate hami-rendered-pinned.yaml (a deliberate, reviewed change only):
#   REGENERATE=1 bash m4/optional/install-hami.sh
#
# Reporting contract (same as the course's layers): every hard assert prints `FAIL: <what>` and a
# remedy to stderr and exits 1; on success exactly one line beginning `OK:` is printed.
# Idempotent: a re-run re-renders, re-applies the same objects and exits 0.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${HERE}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kubectl_version
assert_helm_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"
WORKER="${CLUSTER_NAME}-worker"
NS_HAMI="kube-system"          # HAMi Lab 5's namespace, and SPIKE-10's
NS_MOCK="mokka"
MODE_ANNOTATION="addon-nvml-mock.example.com/consumers"
RELEASE="hami"
KUBE_VERSION="v1.37.0"

PINS="${HERE}/PINS.md"
VALUES_FILE="${HERE}/values.yaml"
RENDERED="${HERE}/hami-rendered-pinned.yaml"
WORKDIR="${WORKDIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/313-k8sai/m4-optional-hami}"
TIMEOUT="${TIMEOUT:-600}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- the register ---------------------------------------------------------------------------------
for _f in "${PINS}" "${VALUES_FILE}" "${RENDERED}"; do
  if [ "${_f}" = "${RENDERED}" ] && [ "${REGENERATE:-0}" = "1" ]; then continue; fi
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} is missing — the optional lab's committed files are incomplete." >&2
    exit 1
  fi
done
CHART_URL="$(sed -n 's#^| HAMi chart | `\(https://[^`]*\)` |.*$#\1#p' "${PINS}" | sed -n '1p')"
CHART_SHA256="$(sed -n 's#^| HAMi chart | `[^`]*` | `[^`]*` | `\([0-9a-f]\{64\}\)` |.*$#\1#p' "${PINS}" | sed -n '1p')"
pin_of() { sed -n "s#^| \`\\($1:[^@\`]*@sha256:[0-9a-f]\\{64\\}\\)\`.*\$#\\1#p" "${PINS}" | sed -n '1p'; }
HAMI_IMAGE="$(pin_of 'docker.io/projecthami/hami')"
KSCHED_IMAGE="$(pin_of 'registry.k8s.io/kube-scheduler')"
CERTGEN_IMAGE="$(pin_of 'registry.k8s.io/ingress-nginx/kube-webhook-certgen')"
if [ -z "${CHART_URL}" ] || [ -z "${CHART_SHA256}" ] || [ -z "${HAMI_IMAGE}" ] || [ -z "${KSCHED_IMAGE}" ] || [ -z "${CERTGEN_IMAGE}" ]; then
  echo "FAIL: could not read the chart and all three image pins out of ${PINS}." >&2
  echo "      read: chart='${CHART_URL}' sha256='${CHART_SHA256}' hami='${HAMI_IMAGE}' scheduler='${KSCHED_IMAGE}' certgen='${CERTGEN_IMAGE}'" >&2
  exit 1
fi
# values.yaml carries the same pins as `tag: "<tag>@<digest>"`; a disagreement is refused.
for _img in "${HAMI_IMAGE}" "${KSCHED_IMAGE}"; do
  _tagdig="${_img#*:}"
  if ! grep -q "tag: \"${_tagdig}\"" "${VALUES_FILE}"; then
    echo "FAIL: values.yaml does not pin '${_tagdig}', which PINS.md registers for ${_img%%:*}." >&2
    echo "      One of the two was edited without the other. Nothing has been applied." >&2
    exit 1
  fi
done

image_lines() {
  sed -n 's/^[[:space:]-]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]\{1,\}\)"\{0,1\}[[:space:]]*$/\1/p' "$1"
}

# --- preflight ------------------------------------------------------------------------------------
# REGENERATE=1 only renders and writes the committed file; it needs no cluster and applies nothing.
if [ "${REGENERATE:-0}" != "1" ]; then
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this script installs onto a running cluster." >&2
    echo "      Create it first: bash grid-platform/clusters/grid-core/create.sh" >&2
    exit 1
    ;;
esac
if ! kc get --raw='/readyz' >/dev/null 2>&1; then
  echo "FAIL: API server /readyz did not answer on context '${CONTEXT}'." >&2
  exit 1
fi
for _tool in jq; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required. Install it and re-run; nothing has been applied." >&2
    exit 1
  fi
done
# The mock must be up, and up ALONE: a vendor device plugin beside HAMi's would advertise the same
# resource name on the same worker (SPIKE-10 § "If GO", item 2).
_mode="$(kc get namespace "${NS_MOCK}" -o jsonpath="{.metadata.annotations.addon-nvml-mock\.example\.com/consumers}" 2>/dev/null || true)"
if [ "${_mode}" != "none" ]; then
  echo "FAIL: the mock layer is not applied in mock-only mode (read '${_mode:-<absent>}' on namespace '${NS_MOCK}')." >&2
  echo "      Apply it first:  NVML_MOCK_CONSUMERS=none bash clusters/grid-core/addons/nvml-mock/create.sh" >&2
  exit 1
fi
if ! kc -n "${NS_MOCK}" wait --for=condition=Ready pod -l app.kubernetes.io/name=nvml-mock --timeout=120s >/dev/null 2>&1; then
  echo "FAIL: the mock's Pod is not Ready in namespace '${NS_MOCK}'." >&2
  exit 1
fi
fi

for _tool in helm curl tar; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required. Install it and re-run; nothing has been applied." >&2
    exit 1
  fi
done

# --- the chart: the release asset, refused on a sha256 mismatch -----------------------------------
mkdir -p "${WORKDIR}"
CHART_TGZ="${WORKDIR}/hami-2.11.0.tgz"
if [ ! -f "${CHART_TGZ}" ]; then
  echo "==> fetching the HAMi v2.11.0 chart (release asset)" >&2
  if ! curl -fsSLo "${CHART_TGZ}.part" "${CHART_URL}"; then
    rm -f "${CHART_TGZ}.part"
    echo "FAIL: could not fetch ${CHART_URL}. Nothing has been applied." >&2
    exit 1
  fi
  mv "${CHART_TGZ}.part" "${CHART_TGZ}"
fi
if command -v shasum >/dev/null 2>&1; then
  GOT_SHA="$(shasum -a 256 "${CHART_TGZ}" | awk '{print $1}')"
else
  GOT_SHA="$(sha256sum "${CHART_TGZ}" | awk '{print $1}')"
fi
if [ "${GOT_SHA}" != "${CHART_SHA256}" ]; then
  rm -f "${CHART_TGZ}"
  echo "FAIL: the chart's sha256 is ${GOT_SHA}, not the registered ${CHART_SHA256} (PINS.md § 1)." >&2
  echo "      The download was removed. Nothing has been applied." >&2
  exit 1
fi
UNPACK="$(mktemp -d "${WORKDIR}/chart.XXXXXX")"
RENDER_TMP="$(mktemp "${TMPDIR:-/tmp}/m4-optional-hami.XXXXXX")"
PROBE="$(mktemp "${TMPDIR:-/tmp}/m4-optional-probe.XXXXXX")"
trap 'rm -rf "${UNPACK}"; rm -f "${RENDER_TMP}" "${RENDER_TMP}.candidate" "${PROBE}"' EXIT
tar -xzf "${CHART_TGZ}" -C "${UNPACK}"

# --- render, and compare with the committed copy --------------------------------------------------
if ! helm template "${RELEASE}" "${UNPACK}/hami" --namespace "${NS_HAMI}" --kube-version "${KUBE_VERSION}" \
       --values "${VALUES_FILE}" > "${RENDER_TMP}"; then
  echo "FAIL: 'helm template' failed against the v2.11.0 chart. Nothing has been applied." >&2
  exit 1
fi
# helm 3 and helm 4 differ in blank lines before document separators (plan 05-28); a blank line
# there carries nothing in YAML, so it is dropped and the committed copy is the same bytes either way.
normalize_render() {
  awk '/^[[:space:]]*$/ { held = held $0 "\n"; next }
       /^---$/          { held = "" }
                        { printf "%s", held; held = ""; print }
       END              { printf "%s", held }'
}
{
  echo "# GENERATED FILE — do not edit by hand."
  echo "#"
  echo "# The object set M4's optional lab applies for HAMi v2.11.0, rendered from the release asset"
  echo "# ${CHART_URL}"
  echo "# (sha256 ${CHART_SHA256}) with the committed values.yaml, for Kubernetes ${KUBE_VERSION}."
  echo "#"
  echo "# Regenerate with (a reviewed change only):"
  echo "#   REGENERATE=1 bash m4/optional/install-hami.sh"
  echo "#"
  echo "# install-hami.sh applies THIS file, and only after a fresh render matches it byte for byte."
  echo "# Every comment below this header is the chart's own text. The devices HAMi registers on this"
  echo "# profile are mock devices; nothing here runs CUDA, so no HAMi cap is enforced (PINS.md § 3)."
  normalize_render < "${RENDER_TMP}"
} > "${RENDER_TMP}.candidate"

_bad=""
_seen=0
for _i in $(image_lines "${RENDER_TMP}.candidate"); do
  _seen=$((_seen + 1))
  case "${_i}" in
    "${HAMI_IMAGE}"|"${KSCHED_IMAGE}"|"${CERTGEN_IMAGE}") : ;;
    *) _bad="${_bad} ${_i}" ;;
  esac
done
if [ "${_seen}" -lt 1 ] || [ -n "${_bad}" ]; then
  echo "FAIL: the render carries an image line that is not a registered pin:${_bad:- <no image lines>}" >&2
  exit 1
fi
_crds="$(grep -c '^kind: CustomResourceDefinition' "${RENDER_TMP}.candidate" || true)"
if [ "${REGENERATE:-0}" = "1" ]; then
  cp "${RENDER_TMP}.candidate" "${RENDERED}"
  echo "==> REGENERATE=1: wrote ${RENDERED} (${_seen} image lines, ${_crds} CRDs); review its diff before committing. Nothing was applied." >&2
  exit 0
elif ! cmp -s "${RENDER_TMP}.candidate" "${RENDERED}"; then
  echo "FAIL: the committed hami-rendered-pinned.yaml differs from a fresh render of the v2.11.0 chart." >&2
  echo "      Nothing has been applied. Re-run with REGENERATE=1 and read 'git diff' on that file;" >&2
  echo "      keep it only as a deliberate, reviewed change." >&2
  exit 1
fi
echo "digest-pin: every image line in the render is a registered pin, and the render matches the committed file (${_seen} image lines, ${_crds} CRDs)" >&2

# --- apply ----------------------------------------------------------------------------------------
# HAMi's device plugin DaemonSet selects nodes labelled gpu=on (HAMi Lab 5). Only the mock's worker.
kc label node "${WORKER}" gpu=on --overwrite >/dev/null
kc apply -f "${RENDERED}" >/dev/null
for _o in deploy/hami-scheduler ds/hami-device-plugin job/hami-admission-create job/hami-admission-patch; do
  if ! kc -n "${NS_HAMI}" get "${_o}" >/dev/null 2>&1; then
    echo "FAIL: ${_o} is not in namespace '${NS_HAMI}' after the apply, although the apply exited 0." >&2
    exit 1
  fi
done
if ! kc get mutatingwebhookconfiguration hami-webhook >/dev/null 2>&1; then
  echo "FAIL: MutatingWebhookConfiguration hami-webhook is absent after the apply." >&2
  exit 1
fi
for _j in hami-admission-create hami-admission-patch; do
  if ! kc -n "${NS_HAMI}" wait --for=condition=complete "job/${_j}" --timeout="${TIMEOUT}s" >/dev/null; then
    echo "FAIL: Job ${_j} did not complete within ${TIMEOUT}s: the webhook has no certificate." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_HAMI} logs job/${_j}" >&2
    exit 1
  fi
done
if ! kc -n "${NS_HAMI}" rollout status deploy/hami-scheduler --timeout="${TIMEOUT}s" >&2; then
  echo "FAIL: deploy/hami-scheduler did not roll out within ${TIMEOUT}s." >&2
  exit 1
fi

# The device plugin's own container, not the DaemonSet's rollout: the vgpu-monitor sidecar can read
# not-ready for a few seconds on a fresh install (SPIKE-10 § "What HAMi registered").
_w=0
_dp=""
while [ "${_w}" -lt "${TIMEOUT}" ]; do
  _dp="$(kc -n "${NS_HAMI}" get pods -l app.kubernetes.io/component=hami-device-plugin \
          -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="device-plugin")]}{.ready}{end}' 2>/dev/null || true)"
  [ "${_dp}" = "true" ] && break
  sleep 5
  _w=$((_w + 5))
done
if [ "${_dp}" != "true" ]; then
  echo "FAIL: HAMi's device-plugin container is not ready after ${_w}s." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_HAMI} logs ds/hami-device-plugin -c device-plugin" >&2
  exit 1
fi

# Registration: a non-zero allocatable for the resource whose name ends in /gpu, and HAMi's
# per-device inventory annotation on the worker. Selected by suffix, as the course's checks do.
_w=0
RESOURCE=""
REGISTERED=""
while [ "${_w}" -lt 300 ]; do
  RESOURCE="$(kc get node "${WORKER}" -o json 2>/dev/null \
              | jq -r '[.status.allocatable // {} | to_entries[] | select(.key | endswith("/gpu")) | "\(.key)=\(.value)"] | first // ""' 2>/dev/null || true)"
  REGISTERED="$(kc get node "${WORKER}" -o json 2>/dev/null \
              | jq -r '[.metadata.annotations // {} | to_entries[] | select(.key | test("^hami\\.io/node-.*-register$")) | .value | fromjson | length] | first // 0' 2>/dev/null || echo 0)"
  if [ -n "${RESOURCE}" ] && [ "${RESOURCE#*=}" != "0" ] && [ "${REGISTERED:-0}" -gt 0 ]; then break; fi
  sleep 3
  _w=$((_w + 3))
done
if [ -z "${RESOURCE}" ] || [ "${RESOURCE#*=}" = "0" ] || [ "${REGISTERED:-0}" -lt 1 ]; then
  echo "FAIL: after ${_w}s node '${WORKER}' shows no device slots from HAMi (allocatable '${RESOURCE:-<none>}', registered devices ${REGISTERED:-0})." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_HAMI} logs ds/hami-device-plugin -c device-plugin" >&2
  exit 1
fi

# Every HAMi container is running the registered image. The kube-scheduler container is not read
# here: kind preloads that exact image under an `import-*` name, so containerd reports that name
# in its imageID (SPIKE-10 § "The kube-scheduler imageID"); its spec carries the pin.
_ids="$(kc -n "${NS_HAMI}" get pods -l app.kubernetes.io/name=hami --field-selector status.phase=Running -o json \
        | jq -r '[.items[].status.containerStatuses[] | select(.name != "kube-scheduler") | .imageID] | join(" ")')"
_n=0
_ok=0
for _id in ${_ids}; do
  _n=$((_n + 1))
  case "${_id}" in *"${HAMI_IMAGE##*@}") _ok=$((_ok + 1)) ;; esac
done
if [ "${_n}" -lt 3 ] || [ "${_ok}" -ne "${_n}" ]; then
  echo "FAIL: ${_ok}/${_n} running HAMi containers carry the registered digest ${HAMI_IMAGE##*@}." >&2
  echo "      Running imageIDs: ${_ids:-<none>}" >&2
  exit 1
fi
_ks="$(kc -n "${NS_HAMI}" get deploy hami-scheduler -o jsonpath='{.spec.template.spec.containers[?(@.name=="kube-scheduler")].image}')"
if [ "${_ks}" != "${KSCHED_IMAGE}" ]; then
  echo "FAIL: the kube-scheduler container asks for '${_ks}', not the registered ${KSCHED_IMAGE}." >&2
  exit 1
fi

# The fail-open webhook. No lab Pod may be created until a server-side dry run comes back rewritten
# to HAMi's scheduler (the webhook declares sideEffects: None, so a dry run reaches it).
cat > "${PROBE}" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: webhook-probe
  namespace: default
spec:
  containers:
    - name: probe
      image: docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
      resources:
        limits:
          nvidia.com/gpu: 1
          nvidia.com/gpumem: "1024"
YAML
_w=0
_sn=""
while [ "${_w}" -lt 300 ]; do
  _sn="$(kc create --dry-run=server -f "${PROBE}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null || true)"
  [ "${_sn}" = "hami-scheduler" ] && break
  sleep 5
  _w=$((_w + 5))
done
if [ "${_sn}" != "hami-scheduler" ]; then
  echo "FAIL: after ${_w}s a dry-run Pod still comes back with schedulerName '${_sn:-<none>}'." >&2
  echo "      The webhook fails open, so a Pod created now would go to the default scheduler and" >&2
  echo "      stay Pending. Inspect: kubectl --context ${CONTEXT} -n ${NS_HAMI} get pods -L hami.io/scheduler-role" >&2
  exit 1
fi

echo
echo "OK: HAMi v2.11.0 installed on '${CLUSTER_NAME}' — scheduler extender, webhook and device plugin running on the registered digests; the device plugin registered ${REGISTERED} mock devices and the worker advertises ${RESOURCE}; a dry-run Pod is routed to hami-scheduler."
echo "  the devices are MOCK DEVICES served by a mock NVML library; HAMi repeats the identity the mock's profile declares"
echo "  nothing here runs CUDA, so no memory or core cap is enforced: what you will read is admission and placement by accounting"
echo "  chart:      ${CHART_URL} (sha256 ${CHART_SHA256})"
echo "  applied:    ${RENDERED}"
echo "  register:   ${PINS}"
echo "  the way back: delete grid-core — the worker keeps the mock's runtime change and HAMi's library copy until it is recreated"

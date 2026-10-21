#!/usr/bin/env bash
# addon-ops — apply the OPERATIONS layer onto a running grid-core: a metrics
# collector, a dashboard surface and a cost tool.
#
# THIS IS A LAYER, NOT A PROFILE. It creates no cluster. It applies onto the
# cluster the base profile already made, verifies, and removes itself leaving
# that cluster running. It makes no create-time change: no node-container bind
# mount, no port mapping, no host port, no Ingress. Every endpoint is reached
# through a port forward the calling script starts and kills.
#
# ------------------------------------------------------------------------------
# PINS.md IS THE AUTHORITY, AND THIS SCRIPT READS IT RATHER THAN RESTATING IT.
#
# This is the one addon layer in the profile with no Phase-1 spike behind it:
# no component version was verified by prior research, no image digest was
# resolved, and the project's technology table names versions without digests.
# So the provenance that lives in a spike record for every other layer lives in
# PINS.md beside this script — per chart the coordinate, the exact version and
# the verified manifest digest; per image the index digest, the human version,
# the command that resolved it, the date and the platform list.
#
# This script READS the three chart digests and the four image digests out of
# that file. Two consequences, both deliberate:
#   * a chart whose pulled manifest digest disagrees with the register is
#     REFUSED, and nothing is applied;
#   * the register cannot silently rot, because an edit that breaks its tables
#     breaks the install on the next run rather than at recording time.
# ------------------------------------------------------------------------------
#
# WHAT IS NOT INSTALLED, and the reason is MEASURED rather than preferred.
# The bundled monitoring distribution is not installed. The declared-minimum
# lab budget is 4500 MiB and the base profile at rest with its three feature
# gates measures 1908 MiB, so the addon layers share roughly 2592 MiB. The
# bundled distribution carries an operator and its custom resource definitions,
# an alert manager, a node exporter per node, a kube-state-metrics deployment
# and a default rule set — several of which this course never reads at this
# layer. PINS.md section 3 carries the full arithmetic.
#
# NO COST FIGURE IS ASSERTED OR PUBLISHED BY THIS LAYER. The cost tool runs with
# no cloud integration and no real pricing, so every rate it uses is a default
# standing in for a price nobody paid. verify.sh asserts that the tool starts,
# finds the collector and answers its own readiness endpoint, and asserts
# nothing about any number it computes.
#
# NO DASHBOARD JSON IS AUTHORED HERE. The dashboards belong to the module that
# teaches them. What this layer ships is the surface and the pinned major, which
# is the schema contract those dashboards will be generated against.
#
# Usage:
#   bash create.sh
#
# Env:
#   export PATH="/opt/homebrew/bin:$PATH"          # /usr/local/bin/kind is a stale shim
#   export KUBECONFIG=/tmp/grid-core.kubeconfig    # set by the base profile
#   SIZE               8 or 16 (default 8) — validated by labs/tools/size-gate.sh
#   NAMESPACE          the layer's namespace (default grid-ops)
#   ROLLOUT_TIMEOUT    seconds to wait per Deployment (default 300)
#   TARGET_TIMEOUT     seconds to wait for a healthy scrape target (default 180)
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: re-applying re-applies the same objects and re-gates the rollouts.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
. "${ADDON_DIR}/ops-lib.sh"
assert_size
assert_kind_version
assert_kubectl_version
# This layer `helm pull`s three charts from OCI registries and verifies each
# one's manifest digest, so the helm floor is asserted BEFORE the first pull.
# The `for _tool in helm jq ...` presence gate further down is not a second
# copy of this check: that one asserts the tools EXIST and names what this
# layer uses each for, this one asserts helm's VERSION can do oci:// at all.
assert_helm_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-grid-ops}"
PINS="${ADDON_DIR}/PINS.md"
VALUES_FILE="${ADDON_DIR}/values.yaml"
RENDERED="${ADDON_DIR}/rendered-pinned.yaml"
WORKDIR="${WORKDIR:-/tmp/313-addon-ops}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
TARGET_TIMEOUT="${TARGET_TIMEOUT:-180}"
FWD_PROM_PORT="${FWD_PROM_PORT:-19090}"

# The three releases, in apply order. The collector is first because the cost
# tool blocks at startup until it can query the collector — not an ordering
# CONSTRAINT (a later apply converges either way, because the cost tool retries)
# but the order that costs the fewest restarts.
RELEASES="prometheus grafana opencost"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

# --- 1. the files this layer cannot run without -------------------------------
for _f in "${PINS}" "${VALUES_FILE}" "${ADDON_DIR}/ops-lib.sh"; do
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} is missing." >&2
    echo "      This layer reads its chart digests and its image digests OUT OF" >&2
    echo "      PINS.md and its chart values out of values.yaml. There is no" >&2
    echo "      fallback literal in this script, on purpose: a second copy of a" >&2
    echo "      digest is a second thing that can be right while the first one" >&2
    echo "      is wrong." >&2
    exit 1
  fi
done

for _tool in helm jq nc python3 awk sed; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    echo "FAIL: ${_tool} is required by this layer and is not on PATH." >&2
    echo "      helm pulls and renders the three charts; jq folds the applied" >&2
    echo "      object set; nc probes the port forward; python3 reads the" >&2
    echo "      collector's own target document; awk and sed read PINS.md and" >&2
    echo "      split values.yaml." >&2
    echo "      Install it and re-run; nothing has been applied to '${CLUSTER_NAME}'." >&2
    exit 1
  fi
done

# --- 2. the base cluster, before anything expensive ---------------------------
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
    echo "      then re-run:  ${APPLY}" >&2
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
  echo "FAIL: not every node on '${CLUSTER_NAME}' is Ready." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes; then ${BASE}" >&2
  exit 1
fi

# --- 3. read the register ------------------------------------------------------
# One chart row per release, matched on the release name in bold, and the four
# image references taken from the rows that carry an @sha256 reference in the
# first backticked cell. Both are read with a single pattern each, so a table
# somebody reshaped fails here rather than producing a partial read.
pins_chart_field() {
  # pins_chart_field <release> <field-number-within-the-row>
  awk -F'|' -v rel="$1" -v n="$2" '
    index($0, "oci://") == 0 { next }
    tolower($0) ~ ("[*][*]" rel "[*][*]") {
      v = $(n + 1)
      gsub(/[` *]/, "", v)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "${PINS}"
}

PIN_IMAGES="$(sed -n 's/^| `\([^`]*@sha256:[0-9a-f]\{1,\}\)`.*$/\1/p' "${PINS}")"
PIN_IMAGE_COUNT="$(printf '%s\n' "${PIN_IMAGES}" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "${PIN_IMAGE_COUNT}" -lt 1 ]; then
  echo "FAIL: PINS.md records no image reference carrying an @sha256 digest." >&2
  echo "      Every image this layer runs is pinned by manifest-list INDEX" >&2
  echo "      digest and the register is where those digests live. A register" >&2
  echo "      with no rows is not a reason to install from a tag." >&2
  exit 1
fi

# --- 4. per release: pull at an exact version, VERIFY the digest, render -------
mkdir -p "${WORKDIR}"
RENDER_TMP="$(mktemp "${TMPDIR:-/tmp}/addon-ops-rendered.XXXXXX")"
VALUES_TMP="$(mktemp "${TMPDIR:-/tmp}/addon-ops-values.XXXXXX")"
trap 'rm -f "${RENDER_TMP}" "${VALUES_TMP}"; fwd_stop; ops_probe_cleanup' EXIT

: > "${RENDER_TMP}"
CHART_SUMMARY=""

for _rel in ${RELEASES}; do
  _ref="$(pins_chart_field "${_rel}" 3)"
  _ver="$(pins_chart_field "${_rel}" 4)"
  _dig="$(pins_chart_field "${_rel}" 5)"
  if [ -z "${_ref}" ] || [ -z "${_ver}" ] || [ -z "${_dig}" ]; then
    echo "FAIL: PINS.md has no complete chart row for '${_rel}'." >&2
    echo "      read back: coordinate='${_ref}' version='${_ver}' digest='${_dig}'" >&2
    echo "      Section 1 of PINS.md must carry, per component, the chart" >&2
    echo "      coordinate, its exact version and its verified manifest digest." >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
    exit 1
  fi

  _archive="${WORKDIR}/${_rel}-${_ver}.tgz"
  _pulllog="${WORKDIR}/${_rel}-pull.log"
  rm -f "${_archive}"
  echo "==> pulling ${_ref} --version ${_ver}" >&2
  if ! helm pull "${_ref}" --version "${_ver}" -d "${WORKDIR}" > "${_pulllog}" 2>&1; then
    echo "FAIL: could not pull the ${_rel} chart at version ${_ver}." >&2
    sed 's/^/      /' "${_pulllog}" >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
    exit 1
  fi

  _pulled="$(sed -n 's/^Digest:[[:space:]]*\(sha256:[0-9a-f]\{1,\}\).*$/\1/p' "${_pulllog}" | sed -n '1,1p')"
  if [ -z "${_pulled}" ]; then
    echo "FAIL: helm pull printed no 'Digest:' line for ${_rel}, so the chart digest could not be verified." >&2
    sed 's/^/      /' "${_pulllog}" >&2
    echo "      This gate is a security gate (T-03-36): all three charts carry a" >&2
    echo "      ClusterRole and a ClusterRoleBinding applied at cluster-admin" >&2
    echo "      privilege, and NONE of them was pinned by any prior artifact in" >&2
    echo "      this project. It refuses rather than installing an unverified chart." >&2
    exit 1
  fi
  if [ "${_pulled}" != "${_dig}" ]; then
    echo "FAIL: the ${_rel} chart's OCI manifest digest changed." >&2
    echo "      pulled now: ${_pulled}" >&2
    echo "      PINS.md:    ${_dig}" >&2
    echo "      Re-verify upstream before installing. Nothing has been applied." >&2
    echo "      Then update PINS.md section 1 and values.yaml TOGETHER — this" >&2
    echo "      script reads the digest out of the register, so a half-update" >&2
    echo "      fails here instead of installing something nobody checked." >&2
    exit 1
  fi
  if [ ! -s "${_archive}" ]; then
    echo "FAIL: the verified ${_rel} chart archive is missing at ${_archive}." >&2
    exit 1
  fi
  echo "    digest verified: ${_pulled}" >&2
  echo "    rendering from the VERIFIED LOCAL ARCHIVE, not from a floating version range" >&2

  # The release's section of the committed values file. The extraction is
  # line-based on purpose: a learner cloning the public labs repository has no
  # node_modules, so no YAML library is reachable here. values.yaml's header
  # states the two rules that keep this correct.
  awk -v key="^${_rel}:\$" '
    $0 ~ key { inblk = 1; next }
    inblk && /^[A-Za-z]/ { inblk = 0 }
    inblk { print }
  ' "${VALUES_FILE}" | sed 's/^  //' > "${VALUES_TMP}"
  if [ ! -s "${VALUES_TMP}" ]; then
    echo "FAIL: values.yaml carries no '${_rel}:' section, or the section is empty." >&2
    echo "      Rendering without it would silently fall back to CHART DEFAULTS," >&2
    echo "      which would reinstate every tag PINS.md exists to replace and" >&2
    echo "      install the components this layer deliberately disables." >&2
    exit 1
  fi

  # No `---` is written here: `helm template` already prefixes every document
  # with one, and a `---` followed only by a comment is an EMPTY document that
  # `kubectl apply` rejects with a validation error naming no kind.
  echo "# ---- release: ${_rel} (${_ref} ${_ver} @ ${_dig}) ----" >> "${RENDER_TMP}"
  if ! helm template "${_rel}" "${_archive}" \
         --namespace "${NAMESPACE}" \
         --values "${VALUES_TMP}" >> "${RENDER_TMP}"; then
    echo "FAIL: 'helm template' failed for ${_rel} against the verified chart archive." >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
    exit 1
  fi

  CHART_SUMMARY="${CHART_SUMMARY}  ${_rel}: ${_ref} ${_ver} @ ${_dig}
"
done

# --- 5. the write-then-check pair ----------------------------------------------
# Counted as well as checked, for the reason this phase keeps re-learning: a
# render with zero image references would satisfy "no unpinned reference" and
# satisfy it vacuously. And the per-pin presence check below is the half that
# matters HERE more than anywhere else in the phase — these four digests were
# resolved for the first time in this plan, so a substitution that quietly
# missed one would reinstate exactly the tag the register exists to remove, and
# there is no earlier artifact that would have caught it.
PIN_REPORT="$(sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]][^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${RENDER_TMP}" \
  | awk 'BEGIN{n=0;bad=0}
         {n++; if (index($0,"@sha256:")==0) bad++}
         END{printf "image_refs=%d unpinned=%d\n", n, bad}')"
case "${PIN_REPORT}" in
  "image_refs=0 "*)
    echo "FAIL: the rendered object set carries no 'image:' reference at all, which cannot be right." >&2
    echo "      Report: ${PIN_REPORT}. Nothing has been applied." >&2
    exit 1
    ;;
  *"unpinned=0") : ;;
  *)
    echo "FAIL: a tag-form image reference survived the render: ${PIN_REPORT}" >&2
    echo "      PLAT-01 pins every lab image by @sha256 digest. Nothing has been applied." >&2
    echo "      Every image in this layer is expressible as a digest in its own" >&2
    echo "      chart's values — server.image.digest and" >&2
    echo "      configmapReload.prometheus.image.digest, image.sha, and the" >&2
    echo "      exporter's tag field — so an unpinned reference here means a" >&2
    echo "      values key was dropped, not that a chart cannot express it." >&2
    exit 1
    ;;
esac

MISSING_PINS=""
for _pin in ${PIN_IMAGES}; do
  _d="${_pin##*@}"
  if [ -z "$(sed -n "/${_d}/p" "${RENDER_TMP}" | sed -n '1,1p')" ]; then
    MISSING_PINS="${MISSING_PINS} ${_pin}"
  fi
done
if [ -n "${MISSING_PINS}" ]; then
  echo "FAIL: a digest PINS.md records does not appear in the rendered object set:${MISSING_PINS}" >&2
  echo "      The register and the render must agree in BOTH directions. A pin" >&2
  echo "      written in the register and absent from the manifest is a pin" >&2
  echo "      nobody applied." >&2
  exit 1
fi
echo "digest-pin: ${PIN_REPORT}, and all ${PIN_IMAGE_COUNT} digests PINS.md records are present (pre-apply assert passed)" >&2

{
  echo "# GENERATED FILE — do not edit by hand."
  echo "#"
  echo "# The object set addon-ops applies: a metrics collector, a dashboard"
  echo "# surface and a cost tool, rendered with"
  echo "#   helm template <release> <verified local archive> --values <section of values.yaml>"
  echo "# from the three charts below, each pulled at an exact version and each"
  echo "# verified against the manifest digest PINS.md records BEFORE the render:"
  echo "#"
  printf '%s' "${CHART_SUMMARY}" | sed 's/^/# /'
  echo "#"
  echo "# Regenerate with:"
  echo "#   bash labs/clusters/grid-core/addons/ops/create.sh"
  echo "#"
  echo "# It is committed so the applied object set is reviewable in the tree and"
  echo "# so the digest-pin gate has a real subject. A clean \`git status\` after a"
  echo "# create run is the evidence that this copy matches the charts at the"
  echo "# pinned versions. That property is why values.yaml sets the dashboard"
  echo "# admin password to a fixed non-secret literal: with it unset the chart"
  echo "# renders a random secret and this file would differ on every run."
  echo "#"
  echo "# Every image reference below is a manifest-list INDEX digest resolved in"
  echo "# plan 03-06 and recorded in PINS.md with the command that resolved it,"
  echo "# its date and the platform list the manifest reported. No bundled"
  echo "# monitoring distribution is installed and no dashboard JSON is shipped."
  cat "${RENDER_TMP}"
} > "${RENDERED}"

# --- 6. apply ------------------------------------------------------------------
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
    echo "      kubectl apply into a Terminating namespace exits 0 and creates" >&2
    echo "      nothing, so this refuses rather than reporting a successful" >&2
    echo "      install of nothing." >&2
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

kc apply --server-side --force-conflicts -f "${RENDERED}" >/dev/null

DEPLOYMENTS="prometheus-server grafana opencost"
for _d in ${DEPLOYMENTS}; do
  if ! kcn rollout status "deploy/${_d}" --timeout="${ROLLOUT_TIMEOUT}s"; then
    echo "FAIL: Deployment ${_d} did not roll out within ${ROLLOUT_TIMEOUT}s." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} describe deploy/${_d}" >&2
    echo "               kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/${_d}" >&2
    if [ "${_d}" = "grafana" ]; then
      echo "      For the dashboard specifically: this layer OVERRIDES its chart's" >&2
      echo "      own appVersion to pin the major the course's later dashboards are" >&2
      echo "      generated against, so the chart-and-image pairing is not one" >&2
      echo "      upstream tests. PINS.md section 4 records that and names what to" >&2
      echo "      do if the pairing stops working." >&2
    fi
    if [ "${_d}" = "opencost" ]; then
      echo "      For the cost tool specifically: it blocks at startup until it can" >&2
      echo "      query the collector, so a collector that is not serving shows up" >&2
      echo "      HERE rather than as its own failure." >&2
    fi
    exit 1
  fi
done

# --- 7. the pins, read back off the RUNNING containers -------------------------
# A manifest can ask for a digest and a node can resolve something else. This is
# the half a written-only pin never catches.
RUNNING_IDS="$(kcn get pods -o json 2>/dev/null \
  | jq -r '[.items[].status.containerStatuses[]?.imageID] | join(" ")')"
UNHONOURED=""
for _pin in ${PIN_IMAGES}; do
  _d="${_pin##*@}"
  case " ${RUNNING_IDS} " in
    *"${_d}"*) : ;;
    *) UNHONOURED="${UNHONOURED} ${_pin}" ;;
  esac
done
if [ -n "${UNHONOURED}" ]; then
  echo "FAIL: a pinned digest is not carried by any running container's imageID:${UNHONOURED}" >&2
  echo "      The manifest asked for the pin and the node resolved something" >&2
  echo "      else, which is exactly the case a written-only pin would not catch." >&2
  echo "      Running imageIDs: ${RUNNING_IDS}" >&2
  exit 1
fi
echo "digest-pin: all ${PIN_IMAGE_COUNT} pins honoured by a running container's imageID (post-rollout assert passed)" >&2

# --- 8. a HEALTHY SCRAPE TARGET, read from the collector's OWN state -----------
# Not the Pod's phase. A collector whose every target is down is Running, Ready
# and Available and collects nothing, so a phase assertion cannot tell a working
# install from one that measured nothing.
if ! fwd_start "${CONTEXT}" "${NAMESPACE}" "svc/prometheus-server" 80 "${FWD_PROM_PORT}"; then
  echo "FAIL: could not forward to the metrics collector's Service." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get svc prometheus-server -o yaml" >&2
  exit 1
fi

# POLLED TO A SETTLED STATE, not to the first healthy target. Breaking out at
# the first `up` was the first thing written here and it was wrong twice over:
# the reported count is then a snapshot taken mid-warmup — this run printed
# `3 of 4` for a layer whose four targets were all healthy seconds later — and
# a mid-warmup count is not comparable across two runs, which is exactly what
# the idempotency predicate compares. So the loop waits for every target to be
# healthy and only falls back to whatever it has when the timeout expires. The
# ASSERTION below is still `at least one`, so a genuinely unhealthy target
# costs this loop its full timeout and then reports honestly rather than
# failing the install.
TARGET_REPORT=""
TARGETS_UP=0
TARGETS_TOTAL=0
_waited=0
while [ "${_waited}" -lt "${TARGET_TIMEOUT}" ]; do
  TARGET_REPORT="$(ops_probe targets "http://127.0.0.1:${FWD_PORT}")"
  TARGETS_UP="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*targets_up=\([0-9]\{1,\}\).*/\1/p')"
  TARGETS_TOTAL="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*targets_total=\([0-9]\{1,\}\).*/\1/p')"
  if [ "${TARGETS_TOTAL:-0}" -ge 1 ] && [ "${TARGETS_UP:-0}" -ge "${TARGETS_TOTAL:-0}" ]; then break; fi
  sleep 5
  _waited=$((_waited + 5))
done
TARGET_NOT_UP="$(printf '%s' "${TARGET_REPORT}" | sed -n 's/.*not_up=\([^ ]*\).*/\1/p')"
fwd_stop
trap 'rm -f "${RENDER_TMP}" "${VALUES_TMP}"; ops_probe_cleanup' EXIT

if [ "${TARGETS_TOTAL:-0}" -lt 1 ]; then
  echo "FAIL: the collector reports ${TARGETS_TOTAL:-0} active scrape targets after ${_waited}s." >&2
  echo "      probe: ${TARGET_REPORT:-<no output>}" >&2
  echo "      A collector with no targets is Running, Ready and Available and" >&2
  echo "      collects nothing. Its scrape configuration comes from the" >&2
  echo "      serverFiles section of values.yaml, which REPLACES the chart's" >&2
  echo "      default rather than extending it, so a dropped key here means no" >&2
  echo "      jobs at all." >&2
  exit 1
fi
if [ "${TARGETS_UP:-0}" -lt 1 ]; then
  echo "FAIL: ${TARGETS_UP:-0} of ${TARGETS_TOTAL} scrape targets are healthy after ${_waited}s." >&2
  echo "      probe: ${TARGET_REPORT}" >&2
  echo "      Inspect the collector's own view, which is where this was read:" >&2
  echo "        kubectl --context ${CONTEXT} -n ${NAMESPACE} port-forward svc/prometheus-server 9090:80" >&2
  echo "        then open /api/v1/targets" >&2
  exit 1
fi

echo
NOT_UP_NOTE=""
if [ -n "${TARGET_NOT_UP:-}" ] && [ "${TARGET_NOT_UP}" != "-" ]; then
  NOT_UP_NOTE=" Still unhealthy after ${_waited}s: ${TARGET_NOT_UP}."
fi

echo "OK: addon-ops applied onto '${CLUSTER_NAME}' — Prometheus, Grafana and OpenCost all Available in namespace '${NAMESPACE}', with ${TARGETS_UP} of ${TARGETS_TOTAL} scrape targets reporting healthy from the collector's own target state.${NOT_UP_NOTE}"
echo "  no Pod phase was asserted: a collector whose every target is down is Running, Ready and Available and collects nothing"
echo "  NO COST FIGURE is asserted or published — the cost tool runs with no cloud integration and no real pricing, so any number would be arithmetic over a fabricated rate"
echo "  no bundled monitoring distribution: the declared-minimum budget is ${BUDGET_MB} MiB and the base profile at rest is 1908 MiB (PINS.md section 3)"
echo "  no dashboard JSON is shipped — the dashboards belong to the module that teaches them; what is pinned here is the schema contract they will be generated against"
echo "  images:     ${PIN_REPORT}, all ${PIN_IMAGE_COUNT} honoured by a running container"
printf '%s' "${CHART_SUMMARY}"
echo "  applied:    ${RENDERED}"
echo "  register:   ${PINS} (this script reads its chart and image digests from there, and refuses on a mismatch)"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: bash ${ADDON_DIR}/verify.sh"
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-addon-ops-size${SIZE} FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_TOOLS}/measure.sh read grid-core-addon-ops"
echo "              (read it BEFORE any teardown — kind delete removes the cgroups the figure comes from)"

#!/usr/bin/env bash
# addon-kueue-kwok — verify the queueing and simulated-fleet layer on a running
# grid-core.
#
# READ-ONLY. It changes nothing on the cluster and it asserts OBJECT STATE only:
# the live Configuration's group and its device-class mapping, the simulated node
# count and their Ready conditions, the Kueue Workload count, each gang's
# admission decision, and where the admitted gang's pods were actually bound.
# NO assertion anywhere in this file is about a Pod PHASE, and none is a
# performance number. A Running phase proves nothing about admission: Kueue can
# admit nothing at all while every pod on the cluster is Running.
#
# ---------------------------------------------------------------------------
# THE ORDER OF THE ASSERTIONS IS LOAD-BEARING
# ---------------------------------------------------------------------------
# The simulated-node count and the Workload count are each asserted NON-ZERO
# BEFORE anything is asserted about their contents, because:
#
#   "every simulated node is Ready" over ZERO nodes is VACUOUSLY TRUE, and
#   "each expected Workload carries its admission condition" over ZERO Workloads
#   is VACUOUSLY TRUE.
#
# The Kueue install and the fleet can BOTH roll out successfully while admitting
# nothing, so a verify that reports clean over an empty cluster is this phase's
# named failure mode (T-03-16). Those two guards are what make this file refuse.
#
# ---------------------------------------------------------------------------
# NEVER A BARE `kubectl get workloads`
# ---------------------------------------------------------------------------
# grid-core enables the GenericWorkload gate AND serves the core scheduling
# group, so TWO resources answer to the plural name `workloads` — Kueue's and the
# core scheduling API's — and THE BARE NAME RESOLVES TO THE CORE ONE. Measured in
# SPIKE-04's own gate run: `kubectl get workloads` returned nothing at all while
# three Kueue Workloads existed. That is a silent wrong answer that reads as a
# clean cluster, not an error. Every query below uses the fully-qualified
# `workloads.kueue.x-k8s.io`.
#
# Usage:
#   bash verify.sh                 # collision fleet (the create default)
#   FLEET=scale bash verify.sh     # scale fleet
#   FAKE_NODES=9 bash verify.sh    # explicit expected fleet size
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   export SIZE=8                                  # or 16
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: read-only.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
DRA_ADDON_DIR="${PROFILE_DIR}/addons/dra"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size
assert_kind_version
assert_kubectl_version

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-kueue-system}"
RELEASE="${RELEASE:-kueue}"
DEPLOYMENT="${RELEASE}-controller-manager"

VALUES_FILE="${ADDON_DIR}/kueue-values.yaml"
RENDERED="${ADDON_DIR}/kueue-rendered-pinned.yaml"
DRA_VALUES_FILE="${DRA_ADDON_DIR}/values.yaml"

TOPOLOGY_RACK="${TOPOLOGY_RACK:-cloud.provider.com/topology-rack}"
GANG_NS="${GANG_NS:-kueue-kwok-tas}"
GANG_OK="${GANG_OK:-gang-rack}"
GANG_REFUSED="${GANG_REFUSED:-gang-rack-oversized}"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

# The expected fleet size, resolved exactly as create.sh resolves it so the two
# cannot disagree. See create.sh's header for why FAKE_NODES is the one knob that
# changes what the lab measures.
FLEET="${FLEET:-collision}"
case "${FLEET}" in
  collision) FLEET_KEY="kwok_collision_nodes" ;;
  scale)     FLEET_KEY="kwok_scale_nodes" ;;
  *)
    echo "FAIL: FLEET is '${FLEET}'; accepted values are 'collision' and 'scale'." >&2
    exit 1
    ;;
esac
# Recorded BEFORE the default, for the reason create.sh states at the same place:
# an explicit FAKE_NODES with the FLEET label unchanged produced an OK: line that
# misdescribed the fleet it had just verified.
if [ -n "${FAKE_NODES:-}" ]; then
  FLEET_SOURCE="explicit FAKE_NODES override"
else
  FLEET_SOURCE="declared lab.sizes.${SIZE}.${FLEET_KEY}"
fi
EXPECTED_NODES="${FAKE_NODES:-$(size_value "${FLEET_KEY}")}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- 1. the base cluster ------------------------------------------------------
# Captured and matched with `case`, never a pipe into a quiet grep under pipefail.
KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer has no cluster to be on." >&2
    echo "      Run the base profile first:  ${BASE}" >&2
    echo "      then apply the layer:        ${APPLY}" >&2
    exit 1
    ;;
esac

# The REAL nodes only. A simulated node has no kubelet, and `node --all` would
# make this wait on the fleet rather than on the cluster.
if ! kc wait --for=condition=Ready node -l '!type' --all --timeout=120s >/dev/null 2>&1; then
  echo "FAIL: not every real node on '${CLUSTER_NAME}' is Ready." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} get nodes; then ${BASE}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required — the assertions below fold across every simulated node" >&2
  echo "      and every Workload, which jsonpath cannot do." >&2
  echo "      Install it (brew install jq) and re-run; this script changes nothing." >&2
  exit 1
fi

for _f in "${VALUES_FILE}" "${RENDERED}" "${DRA_VALUES_FILE}"; do
  if [ ! -f "${_f}" ]; then
    echo "FAIL: ${_f} not found — the layer's own artifacts are missing from the tree." >&2
    echo "      Apply the layer, which regenerates the rendered manifest: ${APPLY}" >&2
    exit 1
  fi
done

# Read from the committed artifacts, never repeated as literals here.
DEVICE_CLASS_NAME="$(sed -n 's/^driverName:[[:space:]]*\([^[:space:]#]\{1,\}\).*$/\1/p' "${DRA_VALUES_FILE}" | head -1)"
PINNED_IMAGE="$(sed -n 's|^[[:space:]]*image:[[:space:]]*"\{0,1\}\(registry.k8s.io/kueue/kueue@sha256:[0-9a-f]\{1,\}\)"\{0,1\}[[:space:]]*$|\1|p' "${RENDERED}" | head -1)"
PINNED_DIGEST="${PINNED_IMAGE##*@}"
if [ -z "${DEVICE_CLASS_NAME}" ] || [ -z "${PINNED_DIGEST}" ]; then
  echo "FAIL: could not read the DeviceClass name from ${DRA_VALUES_FILE}," >&2
  echo "      or a digest-pinned controller image from ${RENDERED}." >&2
  echo "      Both are read from the committed artifacts rather than hardcoded here." >&2
  exit 1
fi

# --- 2. the Kueue controller --------------------------------------------------
if ! kc -n "${NAMESPACE}" get "deploy/${DEPLOYMENT}" >/dev/null 2>&1; then
  echo "FAIL: Deployment ${NAMESPACE}/${DEPLOYMENT} not found — the layer is not applied to this cluster." >&2
  echo "      Apply it: ${APPLY}" >&2
  exit 1
fi
DEPLOY_AVAILABLE="$(kc -n "${NAMESPACE}" get "deploy/${DEPLOYMENT}" \
                      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
if [ "${DEPLOY_AVAILABLE}" != "True" ]; then
  echo "FAIL: ${DEPLOYMENT} reports Available='${DEPLOY_AVAILABLE:-<none>}'." >&2
  echo "      A Configuration the controller cannot parse shows up here as a crash loop," >&2
  echo "      because the ConfigMap applies cleanly whatever it contains." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/${DEPLOYMENT}" >&2
  exit 1
fi

# --- 3. the live Configuration — the group AND the mapping -------------------
LIVE_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/kueue-live-config.XXXXXX")"
trap 'rm -f "${LIVE_CONFIG_FILE}"' EXIT
if ! kc -n "${NAMESPACE}" get cm kueue-manager-config \
       -o jsonpath='{.data.controller_manager_config\.yaml}' > "${LIVE_CONFIG_FILE}" 2>/dev/null \
   || [ ! -s "${LIVE_CONFIG_FILE}" ]; then
  echo "FAIL: ConfigMap ${NAMESPACE}/kueue-manager-config carries no controller_manager_config.yaml." >&2
  echo "      Re-apply from the committed values: ${APPLY}" >&2
  exit 1
fi

# PARSED, not grepped — kueue-config-probe.mjs resolves the document and reads
# the fields. Its own header records what the two weaker forms got wrong: a line
# counter counts the nested deviceClassNames item and publishes a count that is
# off by one, and a substring test for the DeviceClass name is satisfied by the
# name appearing in a comment. The probe prints nothing on stdout when the
# document does not parse, so this fails closed.
CONFIG_PROBE="$(node "${ADDON_DIR}/kueue-config-probe.mjs" "${LIVE_CONFIG_FILE}" "${DEVICE_CLASS_NAME}" 2>&1 || true)"
CONFIG_GROUP="$(printf '%s' "${CONFIG_PROBE}" | sed -n 's/^config_group=\([^ ]*\).*/\1/p')"
MAPPING_COUNT="$(printf '%s' "${CONFIG_PROBE}" | sed -n 's/.*mappings=\([0-9]\{1,\}\).*/\1/p')"
MAPS_DEVICE_CLASS="$(printf '%s' "${CONFIG_PROBE}" | sed -n 's/.*maps_deviceclass=\([^ ]*\).*/\1/p')"
QUOTA_RESOURCE_NAME="$(printf '%s' "${CONFIG_PROBE}" | sed -n 's/.*quota_resources=\(.*\)$/\1/p')"
if [ "${CONFIG_GROUP}" != "config.kueue.x-k8s.io/v1beta2" ]; then
  echo "FAIL: the live Configuration's apiVersion is '${CONFIG_GROUP:-<none>}', not config.kueue.x-k8s.io/v1beta2." >&2
  echo "      probe: ${CONFIG_PROBE}" >&2
  exit 1
fi
if [ "${MAPPING_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: the live Configuration carries no deviceClassMappings entry (probe: ${CONFIG_PROBE})." >&2
  echo "      Without the mapping, DRA devices are admitted UNCOUNTED: a tenant can" >&2
  echo "      claim every synthetic device while its ClusterQueue reports its quota" >&2
  echo "      untouched. Re-apply from the committed values: ${APPLY}" >&2
  exit 1
fi
if [ "${MAPS_DEVICE_CLASS}" != "yes" ]; then
  echo "FAIL: no deviceClassMappings entry lists '${DEVICE_CLASS_NAME}' in its deviceClassNames." >&2
  echo "      probe: ${CONFIG_PROBE}" >&2
  echo "      That is the DeviceClass the DRA layer creates (read from ${DRA_VALUES_FILE})." >&2
  echo "      A mapping naming a DeviceClass that does not exist is accepted silently" >&2
  echo "      and accounts nothing, which is why the name is resolved and compared" >&2
  echo "      rather than looked for in the text." >&2
  exit 1
fi

# --- 4. THE FIRST EMPTY GUARD: a non-zero simulated-node count ---------------
FLEET_JSON="$(kc get nodes -l type=kwok -o json 2>/dev/null || true)"
if [ -z "${FLEET_JSON}" ]; then
  echo "FAIL: could not read the simulated fleet from the cluster." >&2
  exit 1
fi
FLEET_COUNT="$(printf '%s' "${FLEET_JSON}" | jq -r '.items | length')"
if [ "${FLEET_COUNT}" -lt 1 ]; then
  echo "FAIL: zero simulated nodes on '${CLUSTER_NAME}', so this layer has no fleet." >&2
  echo "      This is asserted BEFORE anything about the nodes' conditions, because" >&2
  echo "      'every simulated node is Ready' over zero nodes is vacuously true." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi
if [ "${FLEET_COUNT}" -ne "${EXPECTED_NODES}" ]; then
  echo "FAIL: ${FLEET_COUNT} simulated node(s) but ${EXPECTED_NODES} expected for FLEET=${FLEET} at SIZE=${SIZE}." >&2
  echo "      The expected count is read from course.config.json" >&2
  echo "      lab.sizes.${SIZE}.${FLEET_KEY}; override with FAKE_NODES=<n> if the fleet" >&2
  echo "      was created with an explicit size." >&2
  echo "      A fleet of the wrong size does not break an experiment, it INVERTS which" >&2
  echo "      constraint binds, which is why the count is asserted and not reported." >&2
  exit 1
fi
FLEET_READY="$(printf '%s' "${FLEET_JSON}" \
                 | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')"
if [ "${FLEET_READY}" -ne "${FLEET_COUNT}" ]; then
  echo "FAIL: ${FLEET_READY}/${FLEET_COUNT} simulated nodes report Ready." >&2
  echo "      The kwok controller adopts a Node only via its kwok.x-k8s.io/node" >&2
  echo "      annotation, and KWOK v0.8.0 removed the built-in default stage — a fleet" >&2
  echo "      without stage-fast.yaml never reports Ready at all." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n kube-system logs deploy/kwok-controller --tail=50" >&2
  exit 1
fi

# --- 5. THE SECOND EMPTY GUARD: a non-zero Workload count --------------------
# Fully-qualified resource. See the header for the measured consequence of the
# bare plural on a GenericWorkload cluster.
WL_JSON="$(kc get workloads.kueue.x-k8s.io -A -o json 2>/dev/null || true)"
if [ -z "${WL_JSON}" ]; then
  echo "FAIL: could not read Kueue Workloads from the cluster." >&2
  exit 1
fi
WL_COUNT="$(printf '%s' "${WL_JSON}" | jq -r '.items | length')"
if [ "${WL_COUNT}" -lt 1 ]; then
  echo "FAIL: zero Kueue Workloads on '${CLUSTER_NAME}', so no admission decision exists to read." >&2
  echo "      This is asserted BEFORE anything about the Workloads' conditions, because" >&2
  echo "      'each Workload carries its admission condition' over zero Workloads is" >&2
  echo "      vacuously true — and the Kueue install and the fleet can both roll out" >&2
  echo "      successfully while admitting nothing." >&2
  echo "      Apply the layer: ${APPLY}" >&2
  exit 1
fi

# --- 5b. which experiment object set is on the cluster ------------------------
# The layer runs in TWO configurations and both are legitimate:
#   TAS_GANGS=apply (the default)  the topology gang set, which sections 6-8 read
#   TAS_GANGS=none                 no gang set, because the three-tenant collision
#                                  needs a fleet with no other admitted workloads
#
# Sections 6-8 are specific to the gang set, so they are SKIPPED when it is
# absent — but the non-zero Workload guard above has already fired, and the
# generic admission assertion below replaces them, so the skip cannot become a
# pass over a cluster that admitted nothing. A documented knob whose state the
# verify cannot pass in would be a knob nobody can use.
GANG_SET=present
if ! kc get clusterqueue.kueue.x-k8s.io kueue-kwok-cq >/dev/null 2>&1; then
  GANG_SET=absent
fi

if [ "${GANG_SET}" = "absent" ]; then
  # The generic form of sections 6-8: SOMETHING was admitted and it reserved
  # quota. Asserted on the Workload's own status, never on a Pod phase.
  GENERIC_ADMITTED="$(printf '%s' "${WL_JSON}" | jq -r '
    [ .items[] | select(.status.admission != null) ] | length')"
  if [ "${GENERIC_ADMITTED}" -lt 1 ]; then
    echo "FAIL: ${WL_COUNT} Kueue Workload(s) exist and NONE has a non-null .status.admission." >&2
    echo "      The layer's own gang set is absent (TAS_GANGS=none), so the gang-specific" >&2
    echo "      assertions are skipped — but at least one Workload must still have been" >&2
    echo "      admitted, or this verify would be reporting clean over a cluster that" >&2
    echo "      queued everything and ran nothing." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get workloads.kueue.x-k8s.io -A -o yaml" >&2
    exit 1
  fi
  GENERIC_RESERVED="$(printf '%s' "${WL_JSON}" | jq -r '
    [ .items[] | select(.status.admission != null)
               | .status.admission.podSetAssignments[0].resourceUsage.cpu ] | first // "none" | tostring')"
  if [ "${GENERIC_RESERVED}" = "none" ]; then
    echo "FAIL: an admitted Workload reserved no cpu — an admission that accounted nothing." >&2
    exit 1
  fi

  echo "OK: addon-kueue-kwok verified on '${CLUSTER_NAME}' — ${FLEET_READY}/${FLEET_COUNT} simulated nodes Ready (FLEET=${FLEET}, count from ${FLEET_SOURCE}), ${WL_COUNT} Kueue Workload(s) of which ${GENERIC_ADMITTED} admitted (first reserving ${GENERIC_RESERVED} cpu), Configuration in ${CONFIG_GROUP} with ${MAPPING_COUNT} deviceClassMapping(s) naming '${DEVICE_CLASS_NAME}', and the running controller on the pinned digest."
  echo "  the fleet is SIMULATED — those nodes are not machines, they carry no kubelet, and nothing on them is a GPU"
  echo "  gang set:      ABSENT (applied with TAS_GANGS=none), so the rack/block topology assertions were skipped"
  echo "                 and the generic 'something was admitted and reserved quota' assertion ran instead"
  echo "                 re-apply with the gang set:  bash ${ADDON_DIR}/create.sh"
  echo "  nothing above asserts a Pod phase or a performance number"
  echo "  quota name:    ${QUOTA_RESOURCE_NAME} (what ClusterQueue.nominalQuota counts for the mapped DeviceClass)"
  echo "  image:         ${PINNED_IMAGE}"
  echo "  lab budget:    ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
  exit 0
fi

# --- 6. the positive gang: admitted, with its quota reserved ------------------
OK_ADMISSION="$(printf '%s' "${WL_JSON}" | jq -r --arg ns "${GANG_NS}" --arg job "${GANG_OK}" '
  [ .items[] | select(.metadata.namespace == $ns)
             | select(any(.metadata.ownerReferences[]?; .name == $job)) ] | first
  | if . == null then "absent"
    elif .status.admission == null then "null"
    else (.status.admission.clusterQueue // "unnamed") end')"
case "${OK_ADMISSION}" in
  absent)
    echo "FAIL: no Kueue Workload owned by Job '${GANG_OK}' in namespace '${GANG_NS}'." >&2
    echo "      Re-apply the layer: ${APPLY}" >&2
    exit 1
    ;;
  null)
    echo "FAIL: the Workload for '${GANG_OK}' has a null .status.admission — it was NOT admitted." >&2
    echo "      This gang is 3 pods x 2 cpu = 6 cpu required at rack level, and a rack" >&2
    echo "      is one simulated node with 7.9 cpu free, so it must fit." >&2
    echo "      Inspect the DECISION, never a Pod phase:" >&2
    echo "        kubectl --context ${CONTEXT} -n ${GANG_NS} get workloads.kueue.x-k8s.io -o yaml" >&2
    exit 1
    ;;
esac
RESERVED_CPU="$(printf '%s' "${WL_JSON}" | jq -r --arg ns "${GANG_NS}" --arg job "${GANG_OK}" '
  [ .items[] | select(.metadata.namespace == $ns)
             | select(any(.metadata.ownerReferences[]?; .name == $job)) ] | first
  | (.status.admission.podSetAssignments[0].resourceUsage.cpu // "none") | tostring')"
if [ "${RESERVED_CPU}" = "none" ]; then
  echo "FAIL: the admitted Workload for '${GANG_OK}' reserved no cpu." >&2
  echo "      An admission with no resourceUsage is an admission that accounted nothing." >&2
  exit 1
fi

# --- 7. the negative control: refused BY TOPOLOGY, and for that reason --------
# Asserted as the ABSENCE of .status.admission plus the refusal REASON, never as
# a Pod phase: the Job stays suspended and there is no pod to have one. And the
# reason matters as much as the refusal — a gang refused for quota would also
# have a null admission and would look identical.
REFUSED_STATE="$(printf '%s' "${WL_JSON}" | jq -r --arg ns "${GANG_NS}" --arg job "${GANG_REFUSED}" '
  [ .items[] | select(.metadata.namespace == $ns)
             | select(any(.metadata.ownerReferences[]?; .name == $job)) ] | first
  | if . == null then "absent"
    elif .status.admission != null then "admitted"
    else ([ .status.conditions[]? | select(.type == "QuotaReserved") | .reason ] | first // "noreason")
    end')"
case "${REFUSED_STATE}" in
  TopologyPlacementFailed) : ;;
  absent)
    echo "FAIL: no Kueue Workload owned by Job '${GANG_REFUSED}' in namespace '${GANG_NS}'." >&2
    exit 1
    ;;
  admitted)
    echo "FAIL: the negative control '${GANG_REFUSED}' WAS ADMITTED." >&2
    echo "      It is 3 pods x 6 cpu = 18 cpu required at rack level, and a rack is one" >&2
    echo "      simulated node with 7.9 cpu free, so no rack can hold it — while a single" >&2
    echo "      pod of 6 cpu fits a node and quota permits 18 of 48. Admitting it means" >&2
    echo "      the topology constraint did not bind, and a cooperative fake that merely" >&2
    echo "      rubber-stamped placements would look exactly like this." >&2
    exit 1
    ;;
  *)
    echo "FAIL: the negative control '${GANG_REFUSED}' is un-admitted with QuotaReserved" >&2
    echo "      reason '${REFUSED_STATE}', not TopologyPlacementFailed." >&2
    echo "      It must be refused BY TOPOLOGY. A refusal for quota has an identically" >&2
    echo "      null .status.admission and would pass a check that only asserted the" >&2
    echo "      refusal, which is how a fleet of the wrong size silently invalidates" >&2
    echo "      this experiment." >&2
    exit 1
    ;;
esac

# --- 8. where the admitted gang actually landed ------------------------------
# Read as .spec.nodeName resolved against the rack label ON THAT NODE — the
# binding and the topology, joined — never as a Pod phase. Rack label values are
# globally unique across the fleet, so "all three pods share one rack value"
# cannot pass by coincidence.
GANG_NODES="$(kc -n "${GANG_NS}" get pods -l "batch.kubernetes.io/job-name=${GANG_OK}" \
                -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
                | /usr/bin/grep -v '^$' || true)"
GANG_POD_COUNT="$(printf '%s\n' "${GANG_NODES}" | /usr/bin/grep -c . || true)"
GANG_POD_COUNT="${GANG_POD_COUNT:-0}"
if [ "${GANG_POD_COUNT}" -lt 1 ]; then
  echo "FAIL: the admitted gang '${GANG_OK}' has no pod carrying a .spec.nodeName." >&2
  echo "      Kueue admitted it (asserted above), so this means the real kube-scheduler" >&2
  echo "      has not bound the pods yet or could not." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${GANG_NS} get pods -o wide" >&2
  exit 1
fi
RACKS_USED=""
for _node in ${GANG_NODES}; do
  _rack="$(kc get node "${_node}" -o jsonpath="{.metadata.labels['${TOPOLOGY_RACK//./\\.}']}" 2>/dev/null || true)"
  if [ -z "${_rack}" ]; then
    echo "FAIL: node '${_node}' carries no '${TOPOLOGY_RACK}' label, so the placement" >&2
    echo "      cannot be read against the topology it was supposedly constrained to." >&2
    exit 1
  fi
  case " ${RACKS_USED} " in
    *" ${_rack} "*) : ;;
    *) RACKS_USED="${RACKS_USED} ${_rack}" ;;
  esac
done
RACKS_USED="$(printf '%s' "${RACKS_USED}" | sed 's/^ *//')"
RACK_COUNT="$(printf '%s\n' "${RACKS_USED}" | tr ' ' '\n' | /usr/bin/grep -c . || true)"
if [ "${RACK_COUNT}" -ne 1 ]; then
  echo "FAIL: the ${GANG_POD_COUNT} pods of '${GANG_OK}' are spread across ${RACK_COUNT} rack(s): ${RACKS_USED}." >&2
  echo "      It requested podset-required-topology at rack level, so one rack is the" >&2
  echo "      whole claim. Rack label values are globally unique across the fleet, so" >&2
  echo "      this comparison means what it says." >&2
  exit 1
fi

# --- 9. the digest the running controller resolved ---------------------------
RUNNING_IMAGE_ID="$(kc -n "${NAMESPACE}" get pod -l control-plane=controller-manager \
                      -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
case "${RUNNING_IMAGE_ID}" in
  *"${PINNED_DIGEST}"*) : ;;
  *)
    echo "FAIL: the running Kueue controller's imageID is '${RUNNING_IMAGE_ID:-<empty>}'," >&2
    echo "      which does not carry the digest pinned in ${RENDERED} (${PINNED_DIGEST})." >&2
    echo "      A written pin proves what was asked for; imageID is what the node resolved." >&2
    exit 1
    ;;
esac

echo "OK: addon-kueue-kwok verified on '${CLUSTER_NAME}' — ${FLEET_READY}/${FLEET_COUNT} simulated nodes Ready (FLEET=${FLEET}, count from ${FLEET_SOURCE}), ${WL_COUNT} Kueue Workload(s), Configuration in ${CONFIG_GROUP} with ${MAPPING_COUNT} deviceClassMapping(s) naming '${DEVICE_CLASS_NAME}', '${GANG_OK}' admitted to ClusterQueue '${OK_ADMISSION}' reserving ${RESERVED_CPU} cpu inside the single rack '${RACKS_USED}', and '${GANG_REFUSED}' refused with .status.admission null and reason ${REFUSED_STATE}."
echo "  the fleet is SIMULATED — those nodes are not machines, they carry no kubelet, and nothing on them is a GPU"
echo "  decided by:    Kueue admitted and wrote the nodeSelector; the real kube-scheduler bound the ${GANG_POD_COUNT} pods; kwok faked the kubelet afterwards"
echo "  nothing above asserts a Pod phase or a performance number"
echo "  quota name:    ${QUOTA_RESOURCE_NAME} (what ClusterQueue.nominalQuota counts for the mapped DeviceClass)"
echo "  image:         ${PINNED_IMAGE}"
echo "  lab budget:    ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"

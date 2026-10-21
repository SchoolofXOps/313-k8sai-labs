#!/usr/bin/env bash
# addon-serving — apply the INFERENCE SERVING layer onto a running grid-core.
#
# THIS IS A LAYER, NOT A PROFILE, AND IT MAKES NO CREATE-TIME CHANGE TO THE
# CLUSTER. It creates no cluster, it needs no node-container bind mount, it binds
# no host port and it maps no port: every endpoint is reached through a port
# forward the verifying script starts and kills. The harness this generalises
# says so in its own header — it does not create a cluster, and it runs entirely
# against whatever base profile is already up. That is the whole of why this is a
# layer: there is nothing here that could only be done before the node existed.
#
# ------------------------------------------------------------------------------
# THE SIZE BEHAVIOUR IS THE WHOLE SHAPE OF THIS LAYER, AND IT IS AN APPROVED
# DECISION RESTATED HERE RATHER THAN RE-LITIGATED.
#
# This configuration was MEASURED at 5227 MiB of summed container peak against
# the declared-minimum size's 4500 MiB lab budget — 727 MiB over. The founder
# approved the re-cut on 2026-10-05: this path is REAL at the larger size and a
# READ-ALONG at the minimum. The cheap reduction was tried and FALSIFIED on
# measurement — lowering the simulator replica count measured 5749 MiB, which is
# 522 MiB WORSE, because the dominant term is one image's resident footprint and
# not the replica count — so the fence is the decided outcome and not a
# placeholder for a reduction somebody should attempt.
#
# So at the minimum size this script sources labs/tools/size-gate.sh, prints the
# fixed skip token for the size the layer requires, prints the fence and the
# measured figure that justifies it, APPLIES NOTHING, and EXITS 0.
#
# EXITING 0 IS DELIBERATE AND IT NEEDS ITS OWN SENTENCE. The phase's success
# criterion requires this layer's triple to exit 0, and a refusal that exited
# non-zero would make a correctly-fenced layer indistinguishable from a broken
# one. The layer RAN, stated the fence, and changed nothing — that is a
# successful outcome, and the stdout is what distinguishes it from an install.
# verify.sh and teardown.sh branch the same way.
#
# THE FENCE IS NOT A CLAIM THAT THE LARGER SIZE IS PROVEN HERE. The authoring
# host is a 7.74 GiB VM and both CI runner classes are 8 GB, so the two-worker
# larger-size cluster WITH this layer on top cannot be exercised on any machine
# this project has. The phase success criterion's size qualifier attaches to the
# BASE PROFILE rather than to the addon list — which is what the sentence's own
# grammar says — and the larger-size half of this layer is the one part of the
# phase that is UNMEASURABLE in this environment set. It is recorded as
# unmeasurable with its reason in planning/lab-tests/03-addon-serving.md and
# routed to the pre-recording checklist, rather than claimed.
# ------------------------------------------------------------------------------
#
# SERVING_OVER_BUDGET=1 — AUTHOR-ONLY, AND NOT A LEARNER-REACHABLE
# CONFIGURATION. The fence above is correct for learners and stays the default.
# But as written it also fences the AUTHOR out of ever proving, on the ported
# profile, that the inference simulator and the router in Standalone Mode serve
# requests at all — and that requirement is not about the larger size. The
# evidence says it is reachable here: the Phase-1 records carry this exact
# configuration RUNNING on a single-worker cluster, 5227 MiB peak against a
# 7818 MiB summed VM high-water, 24 of 24 requests served. It exceeds the
# LEARNER BUDGET; it does not exceed the MACHINE.
#
# So with SERVING_OVER_BUDGET=1 this script installs at the minimum size instead
# of fencing, and says `SIZE-GATE: overridden` with the measured figure and the
# words that this is an author-only path. WITH THE VARIABLE UNSET THE BEHAVIOUR
# IS IDENTICAL TO THE FENCE — the override adds a path and alters none. The
# learner-facing setup page does not document how to set it, deliberately.
#
# WHAT STANDALONE MODE AVOIDS, which is why the course names this router. The
# router manages its OWN data plane beside the endpoint picker, so the routing
# loop needs:
#   NO gateway controller
#   NO service mesh
#   NO serverless layer
#   NO inference-pool custom resource
# That is what makes a routing lab possible on a laptop at all, and it is the
# reason this router is on the path rather than the upstream reference picker.
#
# THE UPSTREAM REFERENCE PICKER IS EXCLUDED BY NAME, with its measured reason.
# `lwepp` ships NO arm64 manifest at any published tag — measured 2026-10-04 —
# and the upstream v1.6.2 release notes claiming the arm64 fix landed are WRONG.
# It is therefore not on the core path at ANY size, and it is named here so
# nobody adds it back on the strength of those notes. It appears nowhere in this
# layer's executable body.
#
# THE CUDA-ONLY OFFICIAL MODEL-SERVER IMAGE APPEARS NOWHERE IN THIS LAYER. It
# will not start on this path. The one model-server image here is the CPU build,
# and it exists for exactly one reason — to give the simulator and the router a
# SHARED tokenizer, because precise prefix-cache routing correlates on token ids
# and the two sides must tokenize identically.
#
# Usage:
#   bash create.sh                                  # fence at the minimum size
#   SIZE=16 bash create.sh                          # install
#   SERVING_OVER_BUDGET=1 bash create.sh            # author-only install at the minimum size
#
# Env:
#   export PATH="/opt/homebrew/bin:$PATH"   # /usr/local/bin/kind is a stale shim
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   SIZE                  8 or 16 (default 8) — validated by labs/tools/size-gate.sh
#   SERVING_OVER_BUDGET   1 = author-only install at the minimum size (see above)
#   COURSE_IMAGE_CACHE    0 (default) = pull every image in this run, which is
#                         what a cold learner wall-clock measures. 1 = side-load
#                         from the host image store BY DIGEST.
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
#
# Idempotent: re-applying re-applies the same objects and re-gates the rollouts.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"
LABS_DIR="$(cd "${PROFILE_DIR}/../.." && pwd)"
LABS_TOOLS="${LABS_DIR}/tools"
HARNESS_DIR="${LABS_DIR}/serving/sim-router"

. "${LABS_TOOLS}/pinned-bin.sh"
. "${LABS_TOOLS}/size-gate.sh"
assert_size

CLUSTER_NAME="grid-core"
CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"
export CONTEXT

BUDGET_MB="$(size_value budget_mb)"
export BUDGET_MB

NAMESPACE="${NAMESPACE:-spike-03}"
export NAMESPACE

# The size this layer requires, and the measured figures the fence rests on.
# Every one is a copy of a measurement recorded in planning/lab-tests/, never a
# number invented here.
REQUIRED_SIZE=16
MEASURED_PEAK_MB=5227
MEASURED_OVER_MB=727
FALSIFIED_PEAK_MB=5749

SERVING_OVER_BUDGET="${SERVING_OVER_BUDGET:-0}"

APPLY="bash ${ADDON_DIR}/create.sh"
BASE="bash ${PROFILE_DIR}/create.sh && bash ${PROFILE_DIR}/verify.sh"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- 1. the size gate --------------------------------------------------------
# The skip token is emitted by labs/tools/size-gate.sh and NOWHERE else: its
# exact text is fixed in the written authority, and a literal composed here
# would make this file the authority on it by accident. So the gate is RUN with
# a no-op command and its output is printed verbatim — empty output means the
# required size was met and the no-op ran; a non-empty line is the token.
GATE_OUT="$(bash "${LABS_TOOLS}/size-gate.sh" "${REQUIRED_SIZE}" -- true)"

if [ -n "${GATE_OUT}" ] && [ "${SERVING_OVER_BUDGET}" != "1" ]; then
  printf '%s\n' "${GATE_OUT}"
  echo "FENCE: this layer is NOT installed at SIZE=${SIZE}, and nothing has been applied."
  echo "  Measured: ${MEASURED_PEAK_MB} MiB of summed container peak against this size's"
  echo "  ${BUDGET_MB} MiB lab budget — ${MEASURED_OVER_MB} MiB over. The founder approved the"
  echo "  re-cut on 2026-10-05: this path is REAL at SIZE=${REQUIRED_SIZE} and a READ-ALONG here."
  echo "  The cheap reduction was tried and FALSIFIED: fewer simulator replicas measured"
  echo "  ${FALSIFIED_PEAK_MB} MiB, which is $((FALSIFIED_PEAK_MB - MEASURED_PEAK_MB)) MiB WORSE, because the dominant term is one"
  echo "  image's resident footprint and not the replica count."
  echo "  The read-along is the three-policy walkthrough in this clone:"
  echo "    ${HARNESS_DIR}/policies.md"
  echo "  It names each policy's scorer, picker and distinguishing observable. The"
  echo "  measured captures behind it — the per-endpoint score inversion across a"
  echo "  forced eviction and the router's own index counters — are presented in the"
  echo "  module, not in this repository: they are course production records."
  echo
  echo "OK: addon-serving ran at SIZE=${SIZE}, declared its approved fence, and applied nothing — the cluster '${CLUSTER_NAME}' is unchanged."
  echo "  exiting 0 is deliberate: a refusal that exited non-zero would be indistinguishable from a broken layer"
  echo "  install it where it fits:  SIZE=${REQUIRED_SIZE} ${APPLY}"
  echo "next: bash ${ADDON_DIR}/verify.sh"
  exit 0
fi

OVERRIDE_ACTIVE=0
if [ -n "${GATE_OUT}" ] && [ "${SERVING_OVER_BUDGET}" = "1" ]; then
  OVERRIDE_ACTIVE=1
  echo "SIZE-GATE: overridden (requires SIZE=${REQUIRED_SIZE}, SIZE is ${SIZE}) — installing ${MEASURED_OVER_MB} MiB OVER this size's ${BUDGET_MB} MiB lab budget at a measured ${MEASURED_PEAK_MB} MiB peak."
  echo "  THIS IS AN AUTHOR-ONLY PATH AND NOT A LEARNER-REACHABLE CONFIGURATION."
  echo "  It exists so one affirmative measurement can be taken on the ported profile: that"
  echo "  the inference simulator and the router in Standalone Mode serve a real request"
  echo "  here. It exceeds the LEARNER BUDGET, not the MACHINE — the Phase-1 records carry"
  echo "  this configuration running on a single-worker cluster of this very shape."
  echo "  The learner-facing fence above is unchanged and remains the default."
fi

# --- 2. the base cluster, before anything expensive ---------------------------
assert_kind_version
assert_kubectl_version

KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
case "
${KIND_CLUSTERS}
" in
  *"
${CLUSTER_NAME}
"*) : ;;
  *)
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this layer applies ONTO a running cluster and creates none." >&2
    echo "      Run the base profile first:  ${BASE}" >&2
    echo "      then re-run:                 ${APPLY}" >&2
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

# --- 3. the excluded images, asserted over the layer's own object set ---------
# Two bans and one count, over the manifests this layer is about to apply.
# Counted as well as checked: a manifest set with zero image references would
# otherwise satisfy both bans and the pin assert at once.
MANIFESTS="${HARNESS_DIR}/render.yaml ${HARNESS_DIR}/sim.yaml ${HARNESS_DIR}/router.yaml ${HARNESS_DIR}/envoy.yaml"
PIN_REPORT="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(.*\)$/\1/p' ${MANIFESTS} \
  | awk 'BEGIN{n=0;bad=0;cuda=0;picker=0}
         {n++;
          if (index($0,"@sha256:")==0) bad++;
          if (index($0,"vllm/vllm-openai@")>0 || index($0,"vllm/vllm-openai:")>0) cuda++;
          if (index($0,"lwepp")>0) picker++ }
         END{printf "image_refs=%d unpinned=%d cuda_only_server=%d reference_picker=%d\n", n, bad, cuda, picker}')"
case "${PIN_REPORT}" in
  "image_refs=0 "*)
    echo "FAIL: the layer's manifests carry no image reference at all, which cannot be right." >&2
    echo "      Report: ${PIN_REPORT}. Nothing has been applied." >&2
    exit 1
    ;;
  *"unpinned=0 cuda_only_server=0 reference_picker=0") : ;;
  *)
    echo "FAIL: the layer's image set reports '${PIN_REPORT}'." >&2
    echo "      Every reference must be an @sha256 digest from the recorded resolved set;" >&2
    echo "      the CUDA-only official model-server image must not appear, because it will" >&2
    echo "      not start on this path; and the upstream reference picker must not appear," >&2
    echo "      because it ships no arm64 manifest at any published tag." >&2
    echo "      Nothing has been applied to '${CLUSTER_NAME}'." >&2
    exit 1
    ;;
esac
echo "digest-pin: ${PIN_REPORT} across the four layer manifests (pre-apply assert passed)"

# --- 4. install, by driving the harness rather than duplicating it ------------
# The harness owns the ordering that matters (the render service must be SERVING
# before a simulator starts, or every simulator exits on a refused tokenizer call
# and costs minutes of backoff), the digest consistency assert between its own
# knobs and the manifests, and the by-digest side-load branch. Driving it keeps
# one install sequence in one place.
#
# Its output is PREFIXED rather than passed through, so exactly one line in this
# script's stdout begins `OK:` — this layer's own.
if [ ! -f "${HARNESS_DIR}/setup.sh" ]; then
  echo "FAIL: ${HARNESS_DIR}/setup.sh not found — the layer drives the harness and does not reimplement it." >&2
  exit 1
fi

set +e
bash "${HARNESS_DIR}/setup.sh" up 2>&1 | sed 's/^/  harness| /'
HARNESS_RC="${PIPESTATUS[0]}"
set -e
if [ "${HARNESS_RC}" -ne 0 ]; then
  echo "FAIL: the serving harness's bring-up exited ${HARNESS_RC}; the layer is not installed." >&2
  echo "      Re-run with the harness's own output unprefixed for the full detail:" >&2
  echo "        bash ${HARNESS_DIR}/setup.sh up" >&2
  exit 1
fi

# --- 5. read the applied object set back --------------------------------------
WORKLOADS_READY=0
WORKLOADS_TOTAL=0
for _d in vllm-render sim sim-router-epp sim-router-envoy; do
  WORKLOADS_TOTAL=$((WORKLOADS_TOTAL + 1))
  _rep="$(kc -n "${NAMESPACE}" get "deploy/${_d}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [ "${_rep:-0}" -ge 1 ]; then WORKLOADS_READY=$((WORKLOADS_READY + 1)); fi
done
if [ "${WORKLOADS_READY}" -ne "${WORKLOADS_TOTAL}" ]; then
  echo "FAIL: after the install, ${WORKLOADS_READY}/${WORKLOADS_TOTAL} layer workloads report an available replica." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NAMESPACE} get deploy,pods -o wide" >&2
  echo "      Re-apply: ${APPLY}" >&2
  exit 1
fi

OVERRIDE_NOTE=""
if [ "${OVERRIDE_ACTIVE}" = "1" ]; then
  OVERRIDE_NOTE=" — installed under the AUTHOR-ONLY SERVING_OVER_BUDGET override, ${MEASURED_OVER_MB} MiB over this size's ${BUDGET_MB} MiB budget"
fi

echo
echo "OK: addon-serving applied onto '${CLUSTER_NAME}' — ${WORKLOADS_READY}/${WORKLOADS_TOTAL} layer workloads available in namespace '${NAMESPACE}'${OVERRIDE_NOTE}."
echo "  Standalone Mode: the router runs its own data plane beside the endpoint picker — NO gateway controller, NO service mesh, NO serverless layer, NO inference-pool custom resource"
echo "  no create-time change was made to the cluster: no bind mount, no port mapping, no host port — every endpoint is reached through a port forward"
echo "  the upstream reference picker is EXCLUDED: it ships no arm64 manifest at any published tag, and the release notes claiming otherwise are wrong"
echo "  images:     ${PIN_REPORT}"
echo "  lab budget: ${BUDGET_MB} MiB (lab.sizes.${SIZE}.budget_mb, exported as BUDGET_MB)"
echo "next: bash ${ADDON_DIR}/verify.sh"
echo "  measure:    BUDGET_MB=${BUDGET_MB} CONFIG=grid-core-addon-serving-size${SIZE} FILTER=${CLUSTER_NAME} \\"
echo "                bash ${LABS_TOOLS}/measure.sh read grid-core-addon-serving"
echo "              (read it BEFORE any teardown — kind delete removes the cgroups the figure comes from)"

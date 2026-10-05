#!/usr/bin/env bash
# kwok attach mode — install the kwok controller INTO the real spike-core cluster
#
# Purpose: give the real Kubernetes control plane a large, cheap, SIMULATED node
# fleet to make scheduling and admission decisions about, without a second
# control plane and without a second scheduler.
#
# Mechanism — and this is the whole point of SPIKE-04. This installs the
# upstream kwok controller as an ORDINARY in-cluster Deployment on the real
# `spike-core` kind cluster, then creates plain `Node` objects carrying the
# `kwok.x-k8s.io/node: fake` annotation. The controller adopts those Node
# objects and fakes a kubelet for them: it runs the node-initialize stage so
# they report Ready, keeps their Lease fresh, and transitions Pods that get
# BOUND to them into Running.
#
#   The real kube-scheduler on spike-core still makes every placement decision.
#   The real Kueue admission controller still reserves every unit of quota.
#   The kwok controller only fakes the kubelet, and only AFTER the binding.
#
# This is deliberately NOT the other kwok mode, which stands up a separate fake
# control plane of its own. That mode would make the commands below succeed
# while falsifying the claim: a fake scheduler deciding about fake nodes proves
# nothing about Kubernetes. If you find a reference to that tool in this file
# outside a comment, the spike has been lost.
#
# Real and simulated coexist:
#   - real pods schedule onto the real kind worker, because every fake node
#     carries a NoSchedule taint they do not tolerate;
#   - workloads that tolerate that taint (Kueue adds the toleration from the
#     ResourceFlavor) land on fake nodes, where kwok fakes the kubelet.
#
# A fake node is a SIMULATED node. It is not a machine, it has no kubelet, and
# nothing on it is a GPU.
#
# Usage:
#   bash setup.sh                     # install controller + stages + fake fleet
#   bash setup.sh teardown            # remove fake fleet + stages + controller
#   FAKE_NODES=12 bash setup.sh       # bigger simulated fleet. NOTE: valid for
#                                     # the SCALE profile, but kueue-v1beta2.yaml's
#                                     # quota and published arithmetic assume the
#                                     # default 6 nodes / 3 racks — see the
#                                     # FLEET PRECONDITION block in that file.
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export KUBECONFIG=/tmp/spike-core.kubeconfig   # isolated; set by the profile
#
# Prerequisite: the spike-core profile is up and verified —
#   bash labs/clusters/spike-core/create.sh && bash labs/clusters/spike-core/verify.sh
#
# Reporting contract (same as the cluster profile): every hard assert prints
# `FAIL: <what> <remedy>` to stderr and exits 1; on success exactly one line
# beginning `OK:` is printed.
#
# Idempotent: re-running re-applies the same objects and exits 0.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Kept identical to labs/clusters/spike-core/*.sh. Installing a pinned binary is
# not the same as it being the one that runs: on this build host
# /usr/local/bin/kind (v0.32.0) and ~/.rd/bin/kubectl resolve FIRST from a login
# shell. An `export PATH` only lives as long as the shell that ran it, so this
# script prepends the brew prefix itself rather than trusting the caller.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

# A prepend is not a resolution guarantee; preflight below runs `kind get
# clusters`, so the stale v0.32.0 would answer for a different cluster (WR-01).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)/pinned-bin.sh"
assert_kind_version
assert_kubectl_version

# kwok v0.8.0 — the release that added installable optional components and
# changed the default node CIDR from x.x.x.1/24 to x.x.x.0/24.
KWOK_VERSION="${KWOK_VERSION:-v0.8.0}"

# Digest-pinned controller image, resolved by Spike 0 with
# `docker buildx imagetools inspect` and recorded in
# planning/lab-tests/spike-00-preflight.md. The manifest-list (index) digest is
# used, not a per-arch digest, so the same pin works on linux/arm64 (this host)
# and linux/amd64 (plan 01-05's CI arm). A release tag is mutable; a digest is
# not, which is what makes T-01-07 mitigated rather than hoped about.
KWOK_IMAGE="${KWOK_IMAGE:-registry.k8s.io/kwok/kwok@sha256:6d25aa8fbdfe78845423160bf125b5513f9522e2770981f0945c2a250c2b26f0}"

# 6 simulated nodes: 2 topology blocks x 3 racks each (see RACKS_PER_BLOCK).
# Small enough to stay inside the declared 7.74 GiB VM, large enough for a
# Kueue Topology constraint to be satisfiable in one placement and
# unsatisfiable in another — which is what makes "TAS honoured" assertable
# instead of coincidental.
FAKE_NODES="${FAKE_NODES:-6}"
RACKS_PER_BLOCK="${RACKS_PER_BLOCK:-3}"

# Per-node simulated capacity. Deliberately MODEST (304 used 32 cpu / 256Gi):
# a rack has to be small enough that a gang can exceed one rack's aggregate
# capacity while every individual pod still fits on a single node. That
# asymmetry is the negative control.
NODE_CPU="${NODE_CPU:-8}"
NODE_MEMORY="${NODE_MEMORY:-32Gi}"
NODE_PODS="${NODE_PODS:-110}"

# The cluster this installs INTO — the real kind cluster created by
# labs/clusters/spike-core/create.sh.
CONTEXT="${CONTEXT:-kind-spike-core}"
CLUSTER_NAME="${CLUSTER_NAME:-spike-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/spike-core.kubeconfig}"

# Release-asset base, pinned to the exact tag, never `latest`.
#   kwok.yaml       CRDs + RBAC + the kwok-controller Deployment
#   stage-fast.yaml the lifecycle stages (node-initialize,
#                   node-heartbeat-with-lease, pod-ready/complete/delete)
# Spike 0 recorded both assets' byte size and sha256 content pin
# (planning/lab-tests/spike-00-preflight.md, raw/spike-00/digest-kwok-dra.log).
# Those pins are ENFORCED below by fetch_verified, not merely recorded: a
# GitHub release asset is mutable by any repo maintainer or anyone who
# compromises the account, and `kwok.yaml` carries CRDs, a ClusterRole and a
# ClusterRoleBinding that are applied at cluster-admin privilege. A pin that
# lives only in a comment protects nothing.
KWOK_REPO="kubernetes-sigs/kwok"
BASE="${BASE:-https://github.com/${KWOK_REPO}/releases/download/${KWOK_VERSION}}"
KWOK_MANIFEST_SHA256="${KWOK_MANIFEST_SHA256:-a4c16e6431e382dcb5c1903139344b7a68652f16a6460337fe17a678a426f405}"
STAGE_MANIFEST_SHA256="${STAGE_MANIFEST_SHA256:-2f28d95564ec43056c0873f7a25ac7d2a5bba4c8496c72f8b3ee73fd4f54ee24}"
WORKDIR="${WORKDIR:-/tmp/313-kwok-attach}"

# Kueue Topology-Aware Scheduling node-label keys. These are the exact
# `spec.levels[].nodeLabel` values the `Topology` object in kueue-v1beta2.yaml
# references; overriding one here rewrites it in the rendered Node objects too.
TOPOLOGY_BLOCK="${TOPOLOGY_BLOCK:-cloud.provider.com/topology-block}"
TOPOLOGY_RACK="${TOPOLOGY_RACK:-cloud.provider.com/topology-rack}"
TOPOLOGY_BLOCK_DEFAULT="cloud.provider.com/topology-block"
TOPOLOGY_RACK_DEFAULT="cloud.provider.com/topology-rack"

# Kubernetes arch LABEL, normalised. `uname -m` answers `arm64` on macOS but
# `x86_64` on an amd64 Linux runner, and `x86_64` is not a valid
# kubernetes.io/arch value — it must be `amd64`. 304 hardcoded `arm64`; plan
# 01-05 renders this same file on an amd64 CI runner, so it cannot be
# hardcoded and it cannot be passed through unnormalised.
ARCH_LABEL="${ARCH_LABEL:-$(uname -m)}"
case "${ARCH_LABEL}" in
  x86_64|amd64)   ARCH_LABEL="amd64" ;;
  aarch64|arm64)  ARCH_LABEL="arm64" ;;
esac

ATTACH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_TEMPLATE="${ATTACH_DIR}/fake-nodes.yaml"

kc() { kubectl --context "${CONTEXT}" "$@"; }

# Fetch a release asset to a local file and refuse to return it unless its
# bytes match the sha256 Spike 0 recorded. Mirrors
# labs/sandbox/agent-sandbox/install.sh:81-102, which already got this right.
# Progress goes to stderr so the only thing on stdout is the path (install.sh
# needs a `tail -n 1` because it mixes the two; this does not).
fetch_verified() {
  local url="$1" want="$2" name="$3" out got
  out="${WORKDIR}/${name}"
  mkdir -p "${WORKDIR}"
  if [ ! -s "${out}" ]; then
    echo "==> fetching ${name} (${KWOK_VERSION})" >&2
    if ! curl -fsSL --retry 3 -o "${out}" "${url}"; then
      echo "FAIL: could not fetch ${url}" >&2
      rm -f "${out}"
      exit 1
    fi
  fi
  got="$(shasum -a 256 "${out}" | awk '{print $1}')"
  if [ "${got}" != "${want}" ]; then
    echo "FAIL: ${url}" >&2
    echo "      sha256 ${got}" >&2
    echo "      expected ${want}" >&2
    echo "      The release asset's bytes changed since Spike 0 recorded them." >&2
    echo "      Re-verify upstream before installing: this manifest carries" >&2
    echo "      CRDs, a ClusterRole and a ClusterRoleBinding, and it is applied" >&2
    echo "      with cluster-admin privilege." >&2
    rm -f "${out}"
    exit 1
  fi
  printf '%s' "${out}"
}

# --- preflight ----------------------------------------------------------------
preflight() {
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "FAIL: kind cluster '${CLUSTER_NAME}' not found — this installs INTO the real cluster." >&2
    echo "      Run: bash labs/clusters/spike-core/create.sh && bash labs/clusters/spike-core/verify.sh" >&2
    exit 1
  fi
  if ! kc get --raw='/readyz' >/dev/null 2>&1; then
    echo "FAIL: API server /readyz did not answer on context '${CONTEXT}'." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get --raw=/readyz" >&2
    exit 1
  fi
  if [ ! -f "${NODE_TEMPLATE}" ]; then
    echo "FAIL: node template not found at ${NODE_TEMPLATE}." >&2
    exit 1
  fi
  # jq is used by assert_fleet and by the OK line, both of which run AFTER the
  # controller, the CRDs, the ClusterRole and six simulated nodes are already
  # installed. Absent, the pipeline returned 127 and `set -e` aborted with
  # `jq: command not found` and no FAIL: line, leaving a half-configured
  # cluster. Checked here instead, while the cluster is still untouched.
  if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq is required to assert the simulated fleet reached Ready." >&2
    echo "      Install it (brew install jq) and re-run; nothing has been" >&2
    echo "      installed into '${CLUSTER_NAME}' yet." >&2
    exit 1
  fi
}

# --- controller ---------------------------------------------------------------
deploy_controller() {
  local mf stage subst
  echo "==> Installing kwok ${KWOK_VERSION} IN-CLUSTER on the real '${CLUSTER_NAME}' cluster"
  echo "    (CRDs + RBAC + kwok-controller Deployment, from the pinned release tag)"
  mf="$(fetch_verified "${BASE}/kwok.yaml" "${KWOK_MANIFEST_SHA256}" "kwok-${KWOK_VERSION}.yaml")"
  # Belt and braces. `exit 1` inside fetch_verified exits the command
  # substitution's subshell, and the assignment then trips `set -e` — but only
  # when this file is run as `bash setup.sh`. This explicit check makes the
  # gate independent of that subtlety, because it is a security gate.
  [ -n "${mf}" ] && [ -s "${mf}" ] || {
    echo "FAIL: kwok.yaml did not pass the sha256 content gate." >&2; exit 1; }
  echo "    sha256 verified against the Spike 0 pin"

  # Substitute the digest BEFORE the apply, not after.
  #
  # The manifest references the MUTABLE tag registry.k8s.io/kwok/kwok:v0.8.0.
  # Applying it first and patching the Deployment afterwards left a window in
  # which the ReplicaSet created by the apply could already have pulled and
  # started the tag — so the digest pin only ever guaranteed the FINAL
  # generation, which is not what pinning is for (D-17). Rewriting the bytes
  # first means the tag is never admitted to the cluster at all.
  echo "==> Pinning the controller image to its resolved digest before apply"
  echo "    ${KWOK_IMAGE}"
  subst="${WORKDIR}/kwok-${KWOK_VERSION}.pinned.yaml"
  sed "s|image: registry.k8s.io/kwok/kwok:${KWOK_VERSION}|image: ${KWOK_IMAGE}|g" \
    "${mf}" > "${subst}"
  # The sha256 gate above guarantees the tag line is present, so a zero-match
  # here means the pin and the manifest have drifted apart — stop rather than
  # apply an unpinned image.
  if grep -q "image: registry.k8s.io/kwok/kwok:${KWOK_VERSION}" "${subst}"; then
    echo "FAIL: the image tag survived digest substitution in ${subst}." >&2
    echo "      KWOK_IMAGE and the manifest's image reference have drifted." >&2
    exit 1
  fi
  if ! grep -q "image: ${KWOK_IMAGE}" "${subst}"; then
    echo "FAIL: digest substitution produced no pinned image reference." >&2
    echo "      Expected 'image: ${KWOK_IMAGE}' in ${subst}." >&2
    exit 1
  fi
  kc apply -f "${subst}"

  echo "==> Installing kwok lifecycle stages (stage-fast: node-initialize,"
  echo "    node-heartbeat-with-lease, pod-ready/complete/delete)"
  stage="$(fetch_verified "${BASE}/stage-fast.yaml" "${STAGE_MANIFEST_SHA256}" "stage-fast-${KWOK_VERSION}.yaml")"
  [ -n "${stage}" ] && [ -s "${stage}" ] || {
    echo "FAIL: stage-fast.yaml did not pass the sha256 content gate." >&2; exit 1; }
  echo "    sha256 verified against the Spike 0 pin"
  kc apply -f "${stage}"

  echo "==> Waiting for kwok-controller to roll out"
  if ! kc -n kube-system rollout status deploy/kwok-controller --timeout=120s; then
    echo "FAIL: kwok-controller did not roll out within 120s." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} -n kube-system describe deploy/kwok-controller" >&2
    exit 1
  fi
}

# --- fake fleet ---------------------------------------------------------------
# Topology assignment. Rack label values are GLOBALLY unique rather than
# restarting at rack-0 inside each block: a reused rack name would let a gang
# that actually spread across two blocks still report a single distinct rack
# label, so the "did TAS confine this gang to one rack" assertion could pass by
# accident. Unique rack values make that assertion mean what it says.
block_for() { echo "block-$(( $1 / RACKS_PER_BLOCK ))"; }
rack_for()  { echo "rack-$1"; }

render_node() {
  local i="$1" block rack
  block="$(block_for "${i}")"
  rack="$(rack_for "${i}")"
  sed \
    -e "s|${TOPOLOGY_BLOCK_DEFAULT}|${TOPOLOGY_BLOCK}|g" \
    -e "s|${TOPOLOGY_RACK_DEFAULT}|${TOPOLOGY_RACK}|g" \
    -e "s|__NODE_NAME__|kwok-node-${i}|g" \
    -e "s|__ARCH__|${ARCH_LABEL}|g" \
    -e "s|__BLOCK__|${block}|g" \
    -e "s|__RACK__|${rack}|g" \
    -e "s|__CPU__|${NODE_CPU}|g" \
    -e "s|__MEMORY__|${NODE_MEMORY}|g" \
    -e "s|__PODS__|${NODE_PODS}|g" \
    "${NODE_TEMPLATE}"
}

deploy_nodes() {
  echo "==> Creating ${FAKE_NODES} SIMULATED node(s): ${NODE_CPU} cpu / ${NODE_MEMORY} each,"
  echo "    arch label ${ARCH_LABEL}, ${RACKS_PER_BLOCK} rack(s) per topology block,"
  echo "    adoption annotation kwok.x-k8s.io/node=fake, taint kwok.x-k8s.io/node=fake:NoSchedule"
  # kueue-v1beta2.yaml's nominalQuota (48 cpu / 192Gi) and its entire published
  # arithmetic are fixed for 6 nodes x 8 cpu with 3 racks per block. A
  # different fleet does not break that manifest, it INVALIDATES it: at
  # FAKE_NODES=12 the fleet is 96 cpu against a 48 cpu quota, so quota becomes
  # the binding constraint and the TAS negative control is refused by quota
  # rather than by topology — it still looks like it passes. Say so here, at
  # the point the fleet is created, rather than leaving it to be discovered.
  if [ "${FAKE_NODES}" != "6" ] || [ "${RACKS_PER_BLOCK}" != "3" ] \
     || [ "${NODE_CPU}" != "8" ]; then
    echo
    echo "    NOTE: this fleet is ${FAKE_NODES} node(s) x ${NODE_CPU} cpu, ${RACKS_PER_BLOCK} rack(s)/block." >&2
    echo "          kueue-v1beta2.yaml assumes 6 x 8 cpu / 3 racks per block, and its" >&2
    echo "          quota and arithmetic are fixed text. Do NOT apply it against this" >&2
    echo "          fleet without re-deriving both: the TAS negative control would be" >&2
    echo "          refused by QUOTA rather than by TOPOLOGY and would still appear to" >&2
    echo "          pass. See the FLEET PRECONDITION block in that file." >&2
    echo
  fi
  local i=0
  while [ "${i}" -lt "${FAKE_NODES}" ]; do
    render_node "${i}" | kc apply -f -
    i=$(( i + 1 ))
  done

  echo "==> Waiting for the simulated nodes to report Ready (kwok node-initialize stage)"
  local n=0
  while [ "${n}" -lt "${FAKE_NODES}" ]; do
    kc wait --for=condition=Ready "node/kwok-node-${n}" --timeout=90s >/dev/null 2>&1 || true
    n=$(( n + 1 ))
  done
}

# --- asserts ------------------------------------------------------------------
assert_fleet() {
  local ready blocks real_labelled
  ready="$(kc get nodes -l type=kwok -o json \
            | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')"
  if [ "${ready}" -ne "${FAKE_NODES}" ]; then
    echo "FAIL: ${ready}/${FAKE_NODES} simulated nodes reached Ready." >&2
    echo "      The controller adopts a Node only via the kwok.x-k8s.io/node annotation —" >&2
    echo "      inspect: kubectl --context ${CONTEXT} -n kube-system logs deploy/kwok-controller --tail=50" >&2
    exit 1
  fi

  blocks="$(kc get nodes -l type=kwok -o json \
             | jq -r --arg k "${TOPOLOGY_BLOCK}" \
                 '[.items[].metadata.labels[$k] | select(. != null)] | unique | length')"
  if [ "${blocks}" -lt 2 ]; then
    echo "FAIL: the simulated fleet spans ${blocks} topology block(s); at least 2 are needed" >&2
    echo "      for a Kueue Topology constraint to be shown to bind." >&2
    exit 1
  fi

  if ! kc get node "${CLUSTER_NAME}-worker" >/dev/null 2>&1; then
    echo "FAIL: the real worker '${CLUSTER_NAME}-worker' is gone — real pods have nowhere to run." >&2
    exit 1
  fi
  real_labelled="$(kc get node "${CLUSTER_NAME}-worker" \
                     -o jsonpath='{.metadata.labels.type}' 2>/dev/null || true)"
  if [ "${real_labelled}" = "kwok" ]; then
    echo "FAIL: the real worker is labelled type=kwok, so quota meant for the simulated" >&2
    echo "      fleet would land on a real node. Remove the label." >&2
    exit 1
  fi
}

# --- teardown -----------------------------------------------------------------
teardown() {
  echo "==> Removing simulated nodes (type=kwok) and anything bound to them"
  local fake nm node
  fake="$(kc get nodes -l type=kwok -o name 2>/dev/null || true)"
  if [ -n "${fake}" ]; then
    for node in ${fake}; do
      nm="${node#node/}"
      kc get pods -A --field-selector "spec.nodeName=${nm}" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | while read -r ns pod; do
            if [ -n "${pod:-}" ]; then
              kc -n "${ns}" delete pod "${pod}" --force --grace-period=0 >/dev/null 2>&1 || true
            fi
          done
      kc delete "${node}" --ignore-not-found >/dev/null 2>&1 || true
    done
  fi

  echo "==> Removing kwok lifecycle stages, controller, CRDs and RBAC"
  # Delete by NAME, not by refetching the release assets.
  #
  # This used to run `kc delete -f "${BASE}/stage-fast.yaml"` and
  # `kc delete -f "${BASE}/kwok.yaml"`, which re-downloaded both manifests over
  # the network. Offline, behind a proxy, or after an upstream asset is
  # renamed, both deletes failed, both failures were swallowed by `|| true`,
  # and the script still asserted that the controller, CRDs and ClusterRole
  # were gone AND that the real cluster was untouched — having checked
  # neither. A surviving kwok controller plus CRDs is budget a learner
  # believes they reclaimed on a 7.74 GiB VM.
  #
  # The object set is the one kwok.yaml and stage-fast.yaml create at v0.8.0
  # (enumerated from the sha256-verified bytes). Stages go first so the
  # controller stops acting on nodes; RBAC and CRDs last.
  local rc=0
  kc delete stages.kwok.x-k8s.io \
    node-initialize node-heartbeat-with-lease pod-ready pod-complete pod-delete \
    --ignore-not-found >/dev/null 2>&1 || rc=1
  kc -n kube-system delete deploy/kwok-controller svc/kwok-controller \
    cm/kwok sa/kwok-controller --ignore-not-found >/dev/null 2>&1 || rc=1
  kc delete flowschema.flowcontrol.apiserver.k8s.io kwok-controller \
    --ignore-not-found >/dev/null 2>&1 || rc=1
  kc delete clusterrolebinding kwok-controller --ignore-not-found >/dev/null 2>&1 || rc=1
  kc delete clusterrole kwok-controller --ignore-not-found >/dev/null 2>&1 || rc=1
  kc delete crd \
    attaches.kwok.x-k8s.io clusterattaches.kwok.x-k8s.io \
    clusterexecs.kwok.x-k8s.io clusterlogs.kwok.x-k8s.io \
    clusterportforwards.kwok.x-k8s.io clusterresourceusages.kwok.x-k8s.io \
    execs.kwok.x-k8s.io logs.kwok.x-k8s.io metrics.kwok.x-k8s.io \
    portforwards.kwok.x-k8s.io resourceusages.kwok.x-k8s.io \
    stages.kwok.x-k8s.io \
    --ignore-not-found >/dev/null 2>&1 || rc=1

  # The OK line has to be earned. Assert what it claims: kwok is gone, and the
  # real nodes are still here.
  local left real_left
  left="$(kc get nodes -l type=kwok -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${left}" != "0" ]; then
    echo "FAIL: ${left} simulated node(s) still present after teardown." >&2
    rc=1
  fi
  if kc get deploy/kwok-controller -n kube-system >/dev/null 2>&1; then
    echo "FAIL: kube-system/kwok-controller still present after teardown." >&2
    rc=1
  fi
  if kc get crd stages.kwok.x-k8s.io >/dev/null 2>&1; then
    echo "FAIL: the kwok CRDs are still present after teardown." >&2
    rc=1
  fi
  if kc get clusterrole kwok-controller >/dev/null 2>&1; then
    echo "FAIL: ClusterRole kwok-controller still present after teardown." >&2
    rc=1
  fi
  real_left="$(kc get node "${CLUSTER_NAME}-control-plane" -o name 2>/dev/null || true)"
  if [ -z "${real_left}" ]; then
    echo "FAIL: the real control-plane node is gone — teardown was not confined" >&2
    echo "      to kwok, so 'the real cluster is untouched' cannot be claimed." >&2
    rc=1
  fi

  echo "==> Remaining nodes (expect the 2 real kind nodes):"
  kc get nodes
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: kwok teardown left objects behind, or could not verify removal." >&2
    echo "      Re-run 'bash ${ATTACH_DIR}/setup.sh teardown', or inspect:" >&2
    echo "      kubectl --context ${CONTEXT} get crd | grep kwok" >&2
    echo "      kubectl --context ${CONTEXT} -n kube-system get all | grep kwok" >&2
    exit 1
  fi
  echo "OK: kwok attach mode removed from '${CLUSTER_NAME}'; the real cluster is untouched."
}

# --- dispatch -----------------------------------------------------------------
case "${1:-deploy}" in
  deploy)
    preflight
    deploy_controller
    deploy_nodes
    assert_fleet
    echo
    kc get nodes -L type -L "${TOPOLOGY_BLOCK}" -L "${TOPOLOGY_RACK}"
    echo
    echo "OK: kwok ${KWOK_VERSION} attached IN-CLUSTER to the real '${CLUSTER_NAME}' cluster — controller rolled out, ${FAKE_NODES}/${FAKE_NODES} simulated nodes Ready across $(kc get nodes -l type=kwok -o json | jq -r --arg k "${TOPOLOGY_BLOCK}" '[.items[].metadata.labels[$k]] | unique | length') topology blocks."
    echo "  context:        ${CONTEXT}"
    echo "  kubeconfig:     ${KUBECONFIG}"
    echo "  controller:     kube-system/kwok-controller @ ${KWOK_IMAGE}"
    echo "  simulated node: ${NODE_CPU} cpu / ${NODE_MEMORY} / ${NODE_PODS} pods, arch ${ARCH_LABEL}"
    echo "  taint:          kwok.x-k8s.io/node=fake:NoSchedule (real pods stay off)"
    echo "  topology:       ${TOPOLOGY_BLOCK} / ${TOPOLOGY_RACK}"
    echo "  decided by:     the real kube-scheduler on ${CLUSTER_NAME}; kwok only fakes the kubelet after the binding."
    echo "  teardown:       bash ${ATTACH_DIR}/setup.sh teardown"
    ;;
  teardown)
    preflight
    teardown
    ;;
  *)
    echo "usage: bash setup.sh [deploy|teardown]" >&2
    exit 2
    ;;
esac

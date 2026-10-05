#!/usr/bin/env bash
# labs/sandbox/agent-sandbox — install the Agent Sandbox controller and CRD
#
# Mechanism: Agent Sandbox is a controller plus ONE custom resource. The
# controller watches Sandbox objects and materialises each one as a Pod from
# the object's spec.podTemplate. Because that pod template is a real Kubernetes
# PodSpec, it carries runtimeClassName -- which is the whole reason this
# component sits next to labs/sandbox/runsc-node/ in this phase: a Sandbox can
# be placed under gVisor without the Sandbox API knowing gVisor exists.
#
# SCOPE -- controller and CRD only, deliberately.
# Upstream v1.0.5 publishes three release manifests:
#   sandbox.yaml                  controller + the Sandbox CRD      <- this one
#   extensions.yaml               SandboxClaim / SandboxTemplate /
#                                 SandboxWarmPool, on the separate
#                                 extensions.agents.x-k8s.io group
#   sandbox-with-extensions.yaml  both of the above
# Only the first is installed. Phase 5 SC5 makes the boundary between the
# sandbox RUNTIME and the agent tooling above it M11's actual content, and
# names the client libraries and framework integrations as course 314's scope.
# Installing those here would pre-empt a decision this spike does not own. The
# warm-pool path (an extensions resource) is M11's 16 GB option and is reached
# by installing extensions.yaml as a separate, explicit step -- not by this
# script.
#
# API group note (CLAUDE.md, Modules 10-12): the Sandbox CRD in v1.0.5 serves
# agents.x-k8s.io/v1beta1 and NOTHING ELSE. v1alpha1 and its conversion
# webhooks were removed at v1.0.0, so any manifest lifted from a 2025-era
# example is dead on arrival -- it will be rejected by the API server, not
# silently converted. Verified by reading the CRD in the pinned manifest:
# planning/lab-tests/raw/spike-01/arm64/05-agent-sandbox-manifest-inspect.log
#
# Usage:
#   bash install.sh            # install controller + CRD, wait for rollout
#   bash install.sh teardown   # remove everything this script created
#   CONTEXT=... bash install.sh
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"
#   export KUBECONFIG=/tmp/spike-core.kubeconfig   # isolated; never touch other clusters
#
# Idempotent: re-running re-applies the same pinned manifest and re-waits for
# the rollout; nothing is duplicated and no Sandbox object is touched.
# bash-3.2 compatible (macOS default shell).
# Pinned: Agent Sandbox v1.0.5 (release manifest, content-pinned by sha256).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Same hazard as the cluster profiles: a stale kubectl resolves first from a
# login shell on this host (~/.rd/bin/kubectl is a version-switching shim), and
# an `export PATH` does not survive the shell that set it.
# `${HOME}/.local/bin` is NOT prepended here, unlike an earlier version of this
# line. Eight sibling scripts use exactly `PATH="${LAB_BIN_PREFIX}:${PATH}"`,
# and putting a user-writable directory AHEAD of the pinned prefix
# reintroduced the shadowing this block exists to prevent. On the build host
# that was not hypothetical: ~/.local/bin/kubectl is v1.37.0 while
# /opt/homebrew/bin/kubectl is v1.36.2, so this script ran against a different
# client than verify.sh did.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

# No kind here, so only the client is asserted (WR-01).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)/pinned-bin.sh"
assert_kubectl_version

# --- knobs -------------------------------------------------------------------
# Pinned to v1.0.5 exactly. Upstream ships a release every week or so
# (v1.0.0 2026-08-28 ... v1.0.5 2026-10-01), and it removed a whole API version
# at v1.0.0, so "latest" is not a safe reference for course material: the
# version and the API group version must be pairable on screen.
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-1.0.5}"
# Upstream distributes release MANIFESTS, not a Helm chart -- there is no
# published chart for this project at this version, so there is nothing to
# `helm install`.
MANIFEST_URL="${MANIFEST_URL:-https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v${AGENT_SANDBOX_VERSION}/sandbox.yaml}"
# Content pin for the manifest above, verified by hand on 2026-10-05. A version
# tag on a GitHub release asset is mutable in principle; the bytes are not.
MANIFEST_SHA256="${MANIFEST_SHA256:-e89fd95c0aa57609fa24be4112bd52ce67fe8939ecf6f3c17edf2f1e8f1eb860}"
# The controller image the manifest references, recorded here for the spike
# record rather than substituted: index digest
# sha256:28a9cbdbfd6ac0a4e5c7e9261ace1aa30ee2da681cb640dccdfed98e8dd9d98b,
# multi-arch with linux/arm64 present
# (raw/spike-01/arm64/07-controller-image-platforms.log).
CONTEXT="${CONTEXT:-kind-spike-core}"
NAMESPACE="${NAMESPACE:-agent-sandbox-system}"
DEPLOYMENT="${DEPLOYMENT:-agent-sandbox-controller}"
WORKDIR="${WORKDIR:-/tmp/313-agent-sandbox}"

kc() { kubectl --context "${CONTEXT}" "$@"; }

fetch_manifest() {
  mkdir -p "${WORKDIR}"
  local f="${WORKDIR}/sandbox-v${AGENT_SANDBOX_VERSION}.yaml"
  if [ ! -s "${f}" ]; then
    echo "==> fetching Agent Sandbox v${AGENT_SANDBOX_VERSION} release manifest"
    curl -fsSL --retry 3 -o "${f}" "${MANIFEST_URL}"
  fi
  # Content gate. A release asset that no longer matches its recorded bytes is
  # a stop, not a warning: this manifest installs a cluster-scoped CRD and a
  # ClusterRole.
  local got
  got="$(shasum -a 256 "${f}" | awk '{print $1}')"
  if [ "${got}" != "${MANIFEST_SHA256}" ]; then
    echo "FAIL: ${MANIFEST_URL}" >&2
    echo "      sha256 ${got}" >&2
    echo "      expected ${MANIFEST_SHA256}" >&2
    echo "      The release asset's bytes changed. Re-verify upstream before installing;" >&2
    echo "      this manifest carries a cluster-scoped CRD and a ClusterRole." >&2
    exit 1
  fi
  echo "${f}"
}

if [ "${1:-install}" = "teardown" ]; then
  echo "==> removing Agent Sandbox v${AGENT_SANDBOX_VERSION}"
  MF="$(fetch_manifest 2>/dev/null | tail -n 1)" || MF=""
  # Every delete used to be `|| true`-swallowed and the OK line printed
  # unconditionally, so a teardown that removed nothing still reported
  # success. Failures are tracked now and the OK line is earned.
  RC=0
  # Sandbox objects first: the CRD going away with objects still present leaves
  # the controller no chance to clean up the Pods it created.
  kc delete sandboxes.agents.x-k8s.io --all --all-namespaces --ignore-not-found --timeout=90s || RC=1
  if [ -n "${MF}" ] && [ -s "${MF}" ]; then
    kc delete -f "${MF}" --ignore-not-found --timeout=120s || RC=1
  else
    # Fallback when the manifest is unavailable or failed its content gate:
    # delete by name. Without this the cluster-scoped CRD and the controller
    # namespace could both survive a "successful" teardown.
    kc delete crd sandboxes.agents.x-k8s.io --ignore-not-found || RC=1
    kc delete namespace "${NAMESPACE}" --ignore-not-found --timeout=120s || RC=1
  fi
  # Assert what the OK line claims, rather than asserting it.
  if kc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1; then
    echo "FAIL: CRD sandboxes.agents.x-k8s.io still present after teardown." >&2
    RC=1
  fi
  if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "FAIL: namespace ${NAMESPACE} still present after teardown." >&2
    RC=1
  fi
  if [ "${RC}" -ne 0 ]; then
    echo "FAIL: Agent Sandbox teardown left objects behind." >&2
    echo "      Inspect: kubectl --context ${CONTEXT} get crd | grep agents.x-k8s.io" >&2
    echo "               kubectl --context ${CONTEXT} get ns ${NAMESPACE}" >&2
    exit 1
  fi
  echo "OK: Agent Sandbox removed (Sandbox objects deleted first, then controller, RBAC and CRD)."
  exit 0
fi

if ! kc version --request-timeout=10s >/dev/null 2>&1; then
  echo "FAIL: cannot reach the cluster on context '${CONTEXT}'." >&2
  echo "      Bring the profile up first: bash labs/clusters/spike-core/create.sh" >&2
  exit 1
fi

MANIFEST="$(fetch_manifest | tail -n 1)"
echo "==> applying $(basename "${MANIFEST}") (sha256 verified)"
kc apply --server-side --force-conflicts -f "${MANIFEST}"

echo "==> waiting for the Sandbox CRD to be Established"
kc wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=120s

echo "==> waiting for the controller rollout"
if ! kc -n "${NAMESPACE}" rollout status "deploy/${DEPLOYMENT}" --timeout=180s; then
  echo "FAIL: the Agent Sandbox controller did not become available in ${NAMESPACE}." >&2
  echo "      Inspect it with:" >&2
  echo "        kubectl --context ${CONTEXT} -n ${NAMESPACE} describe deploy/${DEPLOYMENT}" >&2
  echo "        kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/${DEPLOYMENT} --tail=50" >&2
  exit 1
fi

# Hard assert the API group version this course puts on screen. If upstream
# ever serves a second version, the course must say which one it taught.
SERVED="$(kc get crd sandboxes.agents.x-k8s.io \
            -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}' | tr -s ' ')"
case "${SERVED}" in
  *v1beta1*) : ;;
  *) echo "FAIL: the Sandbox CRD does not serve v1beta1; it serves: ${SERVED}" >&2
     exit 1 ;;
esac

# Non-fatal capability probes, after the hard asserts.
echo
echo "  CRD versions served : ${SERVED}"
echo "  controller image    : $(kc -n "${NAMESPACE}" get "deploy/${DEPLOYMENT}" \
                                  -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "  extensions group    : $(kc get crd -o name 2>/dev/null \
                                  | grep -c 'extensions.agents.x-k8s.io' || true) CRD(s) present (0 expected -- out of scope here)"
echo "OK: Agent Sandbox v${AGENT_SANDBOX_VERSION} installed -- controller and the Sandbox CRD on agents.x-k8s.io/${SERVED% }, nothing else."
echo "next: kubectl --context ${CONTEXT} apply -f labs/sandbox/agent-sandbox/sandbox.yaml"

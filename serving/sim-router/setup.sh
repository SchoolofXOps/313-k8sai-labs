#!/usr/bin/env bash
# sim-router — llm-d-inference-sim + llm-d-router Standalone Mode, bring-up
#
# Purpose: stand up the prefix-cache-aware routing loop on the spike-core
# profile, switch between three routing policies, and replay a fixed request set
# through it so the three policies can be compared on identical input.
#
# Mechanism: four components, no gateway controller anywhere.
#   vllm-render  one vLLM CPU container serving ONLY the tokenizer endpoints.
#                Shared by the simulators AND the router, because precise
#                prefix-cache routing correlates on token ids and the two sides
#                must therefore tokenize identically (see render.yaml).
#   sim          3x llm-d-inference-sim with KV cache on, publishing BlockStored
#                / BlockRemoved over ZMQ. The simulators DIAL the router.
#   sim-router-epp  the llm-d Router endpoint picker. BINDS the ZMQ SUB socket,
#                indexes blocks per pod, answers Envoy's ext-proc call.
#   sim-router-envoy  a self-managed Envoy. ORIGINAL_DST on the header the EPP
#                sets, so every endpoint choice in the log is the router's.
#
# PREREQUISITE: the spike-core profile must be up and verified —
#   bash labs/clusters/spike-core/create.sh && bash labs/clusters/spike-core/verify.sh
# This script does NOT create a cluster. ONE CLUSTER PROFILE AT A TIME
# (ROADMAP § Standing Constraints #1).
#
# Usage:
#   bash setup.sh                     # bring everything up (cold by default)
#   bash setup.sh policy <name>       # switch policy: round-robin|load-aware|prefix-cache
#   bash setup.sh replay <name>       # switch to <name>, then replay the request set
#   bash setup.sh asymmetry           # the eviction-asymmetry experiment (SPIKE-03's proof)
#   bash setup.sh seeded              # three-policy comparison on SEEDED uneven residency
#   bash setup.sh teardown            # remove everything this script created
#
# Env:
#   COURSE_IMAGE_CACHE  0 (default) = pull every image now, inside this run.
#                       1 = side-load from the host docker cache and SKIP pulls.
#                       See the long note at image_cache_branch() — a wall-clock
#                       figure measured on branch 1 is invalid for D-20.
#   SIM_IMAGE ROUTER_IMAGE RENDER_IMAGE ENVOY_IMAGE
#                       digest-pinned overrides; defaults must match the
#                       manifests, which this script asserts.
#   REPLICAS            simulator replicas (default 3; fewer than 2 makes a
#                       prefix-cache scorer undemonstrable)
#   POLICIES            space-separated policy list for `replay all`
#   NAMESPACE           default spike-03
#   CONTEXT             default kind-spike-core
#
# Idempotent: re-running applies the same manifests and re-gates the rollouts.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Identical story to the cluster profiles: on this build host a stale kind and a
# stale kubectl resolve FIRST from a login shell, and an `export PATH` does not
# survive past the shell that ran it. Resolve here rather than trusting PATH.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_DIR="$(cd "${SCRIPT_DIR}/../../" && pwd)"

# `kind load` below must use the pinned kind, and a PATH prepend does not
# guarantee it resolves (WR-01).
. "${LABS_DIR}/tools/pinned-bin.sh"
assert_kind_version
assert_kubectl_version

NAMESPACE="${NAMESPACE:-spike-03}"
CONTEXT="${CONTEXT:-kind-spike-core}"
REPLICAS="${REPLICAS:-3}"
POLICIES="${POLICIES:-round-robin load-aware prefix-cache}"
COURSE_IMAGE_CACHE="${COURSE_IMAGE_CACHE:-0}"
export KUBECONFIG="${KUBECONFIG:-/tmp/spike-core.kubeconfig}"

# Digest-pinned image set. Defaults MUST equal the digests in the manifests;
# assert_manifest_pins() fails loudly if an edit ever moves one and not the
# other. Digests for the two llm-d images come from Spike 0
# (planning/lab-tests/spike-00-preflight.md); the render and envoy digests were
# resolved by plan 01-04 (planning/lab-tests/raw/spike-03/digests-extra.log).
# Every one is a multi-arch INDEX digest, so the same pin works on arm64 (this
# host) and amd64.
SIM_IMAGE="${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim@sha256:32144df791330a0006b747edfdf2b114a0fe728e023a9d1b3463eeb48d32abb9}"
ROUTER_IMAGE="${ROUTER_IMAGE:-ghcr.io/llm-d/llm-d-router-endpoint-picker@sha256:39257d24552d16d8f215d3de25cc734fd44af3b282b67032db01aff900c610cf}"
RENDER_IMAGE="${RENDER_IMAGE:-vllm/vllm-openai-cpu@sha256:fc78b363009faa519a0adb5f1a287a533a922970f4463e73c00053a4aa2136e8}"
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy@sha256:85500e28ed088ec39ff0adc1be3d358a8ad062926aaa62c36b28bde00919e4e8}"

# Local forward ports. Deliberately high and lab-specific: nothing binds a host
# port in the cluster (threat T-01-14), so the only host exposure is a
# port-forward this script starts and kills.
FWD_ENVOY_PORT="${FWD_ENVOY_PORT:-18081}"
FWD_POD_PORT="${FWD_POD_PORT:-18000}"

kc() { kubectl --context "${CONTEXT}" "$@"; }
kcn() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the image-cache escape hatch --------------------------------------------
# 304's labs/m9/setup.sh carries a COURSE_IMAGE_CACHE=1 branch whose purpose is
# to SKIP image pulls by side-loading from a local cache. The mechanism is worth
# porting — Phase 3 and the learner-facing labs want a fast re-run — but the
# DEFAULT here is 0, and the branch taken is printed on EVERY run.
#
# Why that matters more than convenience: D-20 judges SPIKE-03's 30-minute
# budget on COLD LEARNER WALL-CLOCK with an EMPTY IMAGE CACHE, and image pulls
# are expected to dominate that number. A measured run that silently took the
# cached branch publishes a figure no learner starting from scratch can reach.
# So the branch is announced, not inferred, and the spike record states which
# branch its measured run took.
image_cache_branch() {
  if [ "${COURSE_IMAGE_CACHE}" = "1" ]; then
    echo "image-cache branch: CACHED (COURSE_IMAGE_CACHE=1)"
    echo "  Images are side-loaded from the host docker cache; registry pulls are SKIPPED."
    echo "  A WALL-CLOCK FIGURE MEASURED ON THIS BRANCH IS INVALID for D-20."
  else
    echo "image-cache branch: NO-CACHE (COURSE_IMAGE_CACHE=0, the default)"
    echo "  Every image is pulled by the kubelet during this run, so pull time is"
    echo "  inside this run's wall clock — which is what D-20 measures."
  fi
}

side_load_images() {
  local img
  echo "Side-loading images into the kind cluster (COURSE_IMAGE_CACHE=1) ..."
  for img in "${SIM_IMAGE}" "${ROUTER_IMAGE}" "${RENDER_IMAGE}" "${ENVOY_IMAGE}"; do
    # Whether `kind load docker-image` can side-load a DIGEST reference such
    # that the kubelet then resolves it without a registry pull is the open
    # question this branch rests on, and it is NOT settled here:
    #   - the manifests reference every image by @sha256 digest (D-17), and
    #     they must keep doing so, so retagging to a local tag is not a fix
    #     unless the manifests are rewritten too;
    #   - containerd may resolve a digest reference from imported content, in
    #     which case no retag is needed at all.
    # SPIKE-03's measured run is cold by definition, so it never exercised
    # this path. WINDOWS #6 records it as a stub and Phase 3 owns validating
    # it against a real cluster.
    #
    # What IS fixed here: the failure is no longer swallowed. It used to be
    # printed as a `NOTE:` and the run continued, so the branch announced
    # "Side-loading images ..." and then pulled everything anyway — a knob
    # that lied about what it did. A side-load that did not happen is now a
    # hard stop, because the only reason to take this branch is to avoid the
    # pull, and a measured wall-clock figure from a run that silently pulled
    # is invalid for D-20 either way.
    echo "  ${img}"
    docker pull "${img}" >/dev/null \
      || fail "docker pull failed for ${img}; COURSE_IMAGE_CACHE=1 cannot side-load an image the host does not have."
    kind load docker-image "${img}" --name "${CONTEXT#kind-}" >/dev/null \
      || fail "kind load failed for ${img}; COURSE_IMAGE_CACHE=1 cannot be honoured. Re-run with COURSE_IMAGE_CACHE=0 (the default) to pull normally, and see WINDOWS #6 — Phase 3 owns validating this branch."
  done
  # Even a successful load does not prove the kubelet will resolve the digest
  # from local content rather than pulling. Say so, rather than implying it.
  echo "  NOTE: images are loaded into the node. Whether the kubelet resolves"
  echo "        the @sha256 references WITHOUT a registry pull is unvalidated"
  echo "        (WINDOWS #6); a wall-clock figure from this branch is not a"
  echo "        cold-cache figure and is invalid for D-20 regardless."
}

# Duplication between the knobs above and the manifests is deliberate — the
# manifests must be applyable on their own, and the cold-cache gate derives its
# image set from them — so the duplication is turned into a CHECKED invariant
# rather than a drift risk.
assert_manifest_pins() {
  local pair f img
  for pair in "sim.yaml:${SIM_IMAGE}" \
              "router.yaml:${ROUTER_IMAGE}" \
              "render.yaml:${RENDER_IMAGE}" \
              "envoy.yaml:${ENVOY_IMAGE}"; do
    f="${SCRIPT_DIR}/${pair%%:*}"
    img="${pair#*:}"
    grep -qF "${img}" "${f}" \
      || fail "${pair%%:*} does not pin ${img} — the script knob and the manifest have diverged. Fix both, or the cold-cache purge (which derives its set from the manifests) will miss an image this script runs."
  done
  echo "OK: all four image digests are consistent between setup.sh and the manifests."
}

cmd_up() {
  echo "=== sim-router bring-up ==="
  image_cache_branch
  echo
  assert_manifest_pins
  echo

  kc cluster-info >/dev/null 2>&1 \
    || fail "context '${CONTEXT}' is not reachable. Run labs/clusters/spike-core/create.sh first."

  # Idempotent namespace create.
  kc get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || kc create namespace "${NAMESPACE}" >/dev/null
  echo "OK: namespace ${NAMESPACE}"

  [ "${COURSE_IMAGE_CACHE}" = "1" ] && side_load_images

  # ORDER IS LOAD-BEARING: render must be SERVING before a simulator starts.
  #
  # The simulator tokenizes its response bank during startup, so with
  # --render-url set it calls /v1/completions/render before it can serve at all
  # and EXITS if that call is refused:
  #   failed to create inference simulator: dataset initialization error:
  #   failed to initialize random dataset: RenderRequest: post
  #   /v1/completions/render: dial tcp ...:8082: connect: connection refused
  # Kubernetes then restarts it, and CrashLoopBackOff's exponential backoff
  # costs minutes of the cold budget while the render container finishes its own
  # (much slower) start. Measured live: 3 restarts per simulator before this
  # ordering was introduced — see
  # planning/lab-tests/raw/spike-03/05-setup-attempt1.log.
  #
  # Applying render alone first does serialize its image pull ahead of the other
  # three, but those three are small (a Go binary, a Go binary and Envoy) next to
  # a vLLM CPU image, so the deterministic ordering costs far less than the
  # backoff it removes.
  echo "applying render.yaml ..."
  kcn apply -f "${SCRIPT_DIR}/render.yaml" >/dev/null
  echo "waiting for the render service to SERVE before any simulator starts ..."
  kcn rollout status deploy/vllm-render --timeout=900s

  for f in sim.yaml router.yaml envoy.yaml; do
    echo "applying ${f} ..."
    kcn apply -f "${SCRIPT_DIR}/${f}" >/dev/null
  done

  if [ "${REPLICAS}" != "3" ]; then
    [ "${REPLICAS}" -ge 2 ] \
      || fail "REPLICAS=${REPLICAS}: a prefix-cache scorer with fewer than two endpoints cannot demonstrate anything — every request goes to the only pod whether the scorer works or not."
    kcn scale deploy/sim --replicas="${REPLICAS}" >/dev/null
  fi

  echo
  echo "Waiting for the remaining rollouts ..."
  kcn rollout status deploy/sim --timeout=600s
  kcn rollout status deploy/sim-router-epp --timeout=300s
  kcn rollout status deploy/sim-router-envoy --timeout=300s

  echo
  echo "OK: sim-router up in namespace ${NAMESPACE}"
  kcn get deploy -o wide
  echo
  echo "  live policy: $(current_policy)"
  echo "  next: bash ${SCRIPT_DIR}/setup.sh replay prefix-cache"
}

current_policy() {
  kcn get deploy/sim-router-epp \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POLICY")].value}' 2>/dev/null
}

cmd_policy() {
  local p="$1" valid=0 known
  for known in round-robin load-aware prefix-cache; do
    [ "${p}" = "${known}" ] && valid=1
  done
  [ "${valid}" -eq 1 ] || fail "unknown policy '${p}' (expected one of: round-robin load-aware prefix-cache)"

  # Switching policy restarts ONLY the router. The simulator fleet, its pod IPs
  # and its warmed caches are untouched, which is what makes the three
  # measurements comparable: same endpoints, same input, different policy.
  kcn set env deploy/sim-router-epp "POLICY=${p}" >/dev/null
  kcn rollout status deploy/sim-router-epp --timeout=300s >/dev/null
  echo "OK: live policy is now '${p}' (router restarted; simulator fleet untouched)"
  # The router's block index is rebuilt from scratch on restart, so anything it
  # knew about cache residency is gone. State that rather than let a reader
  # assume continuity across a policy switch.
  if [ "${p}" = "prefix-cache" ]; then
    echo "  NOTE: the router's KV-block index starts EMPTY after a restart. It"
    echo "        learns residency only from events published while it is"
    echo "        subscribed, so a prefix must be (re)warmed after this switch."
  fi
}

# --- the request set ----------------------------------------------------------
# Fixed, reproducible, and identical across the three policies — that is the
# whole point: if the input is identical and the endpoint distribution differs,
# the policy is what differed.
#
# Each prompt is a long unique paragraph (~300 tokens) so that it occupies
# ~20 blocks of 16 tokens. Simulator cache is 64 blocks per pod, so four
# distinct prompts on one pod force eviction. Prompts are generated
# deterministically from a seed string, never randomly.
PY_DRIVER='
import json, sys, urllib.request, collections, time

base = sys.argv[1]
policy = sys.argv[2]
mode = sys.argv[3]
model = "Qwen/Qwen2.5-1.5B-Instruct"

def prompt(tag, words=60):
    # Deterministic long paragraph, unique per tag. Long enough to span many
    # blocks; identical every run so two runs are comparable.
    #
    # 60 words is bounded from above and below, and BOTH bounds were measured.
    #
    #   upper, hard: the simulator defaults to --max-model-len 1024 and rejects
    #     anything longer with HTTP 400 "This models maximum context length is
    #     1024 tokens. However, you requested 1449 tokens". 240 words rendered
    #     to 1449 real Qwen tokens, 120 words to 729, 60 words to 369.
    #     See planning/lab-tests/raw/spike-03/07-prompt-length-probe.log.
    #
    #   upper, practical — THE WORKING SET MUST FIT, and this is the subtle one:
    #     369 tokens / 16 tokens per block = ~23 blocks, against a 64-block
    #     per-pod cache. Six prefixes concentrated across three pods is ~2
    #     prefixes (~46 blocks) per pod, which FITS. A cache-blind policy spreads
    #     all six onto every pod (~138 blocks), which does NOT fit and thrashes.
    #     That contrast is the measurement.
    #
    #     The first version of this set used four 120-word prefixes (~46 blocks
    #     each). Aggregate demand was then ~184 blocks per pod against a 64-block
    #     cache, so residency thrashed under EVERY policy, every endpoint scored
    #     alike, and the prefix-cache policy was statistically indistinguishable
    #     from the random control — 50% mean per-prefix concentration versus the
    #     controls 54%. The mechanism was working perfectly the whole time; the
    #     REQUEST SET could not see it. That null result is kept at
    #     planning/lab-tests/raw/spike-03/15-policy-distribution-thrashing-set.log
    #     because it is the single most useful thing this lab learned about how
    #     to TEACH prefix-cache routing: a comparison whose working set exceeds
    #     the fleets aggregate cache measures eviction churn, not routing.
    #
    #   lower: the prompt must span many blocks for a PARTIAL eviction to be
    #     observable. 23 blocks is comfortably many, and 8 filler prompts
    #     (~184 blocks) still overflow a 64-block cache several times over, so
    #     the asymmetry experiments forced eviction is unaffected.
    body = " ".join("%s-%04d" % (tag, i) for i in range(words))
    return "Context block %s. %s End of context %s." % (tag, body, tag)

def post(tag, extra_headers=None, max_tokens=4):
    req = urllib.request.Request(
        base + "/v1/completions",
        data=json.dumps({"model": model, "prompt": prompt(tag),
                         "max_tokens": max_tokens, "temperature": 0}).encode(),
        headers={"Content-Type": "application/json",
                 "X-GSD-POLICY": policy, "X-GSD-TAG": tag},
        method="POST")
    if extra_headers:
        for k, v in extra_headers.items():
            req.add_header(k, v)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            payload = json.loads(r.read().decode())
        cached = (payload.get("usage", {})
                         .get("prompt_tokens_details", {})
                         .get("cached_tokens"))
        print("  POST tag=%-6s http=%s prompt_tokens=%s cached_tokens=%s dur=%.2fs"
              % (tag, r.status, payload.get("usage", {}).get("prompt_tokens"),
                 cached, time.time() - t0))
        return True
    except Exception as e:
        print("  POST tag=%-6s FAILED %s" % (tag, e))
        return False

if mode == "replay":
    # The comparison set: four recurring prefixes, six requests each, issued in
    # a fixed interleaved order. A cache-blind policy spreads these across
    # endpoints; a cache-aware one concentrates each prefix on whichever
    # endpoint already holds it.
    tags = ["A", "B", "C", "D", "E", "F"]
    order = [t for _ in range(4) for t in tags]
    print("replay: %d requests over %d prefixes, policy=%s" % (len(order), len(tags), policy))
    ok = sum(1 for t in order if post(t))
    print("replay: %d/%d requests succeeded" % (ok, len(order)))
    sys.exit(0 if ok == len(order) else 1)

if mode == "warm":
    # One request, used to seed a specific pod when posted DIRECTLY to it.
    sys.exit(0 if post(sys.argv[4]) else 1)

if mode == "flood":
    # Distinct prefixes posted DIRECTLY to one pod to force eviction there.
    n = int(sys.argv[4])
    ok = sum(1 for i in range(n) if post("F%02d" % i))
    print("flood: %d/%d requests succeeded" % (ok, n))
    sys.exit(0 if ok == n else 1)

if mode == "observe":
    # A single request through the router, to observe its endpoint choice.
    sys.exit(0 if post(sys.argv[4]) else 1)
'

# The router's own KV-block index counters, read from its Prometheus endpoint.
#
# THIS is the ground truth for "did the scorer consume the ZMQ events", and the
# only signal that cannot be produced by a router that is not consuming them:
#   kvcache_index_admissions_total      blocks admitted from BlockStored events
#   kvcache_index_evictions_total       blocks dropped from BlockRemoved events
#   kvcache_index_lookup_requests_total prefix lookups performed while routing
#   kvcache_index_lookup_hits_total     lookups that matched a resident block
#
# Read these rather than the EPP's logs: the per-pod subscriber's refused dials
# spam ERROR lines continuously while the bound socket ingests normally, so the
# logs suggest failure exactly when ingestion is working (see router.yaml).
index_counters() {
  local label="$1" out
  start_forward "svc/sim-router-epp" 19090 9090 >/dev/null 2>&1 || true
  out="$(curl -s --max-time 10 "http://127.0.0.1:${FWD_PORT}/metrics" 2>/dev/null \
         | grep -E '^kvcache_index_(admissions|evictions|lookup_requests|lookup_hits)_total' || true)"
  stop_forward
  if [ -z "${out}" ]; then
    echo "  index[${label}]: unreadable (no counters scraped from :9090)"
  else
    echo "  index[${label}]:"
    printf '%s\n' "${out}" | sed 's/^/    /'
  fi
}

# Start a port-forward and wait until it answers. Killed by the caller's trap.
#
# EVERY forward gets a FRESH local port, and FWD_PORT reports which one. That is
# not tidiness — it is correctness, and getting it wrong silently corrupted a
# measured run of this very experiment:
#
#   With a fixed local port, a `kill` of the previous forward returns before the
#   process has actually exited and released the socket. The next
#   `kubectl port-forward` then fails to bind, and the readiness check
#   (`nc -z 127.0.0.1 <port>`) SUCCEEDS anyway — against the dying PREVIOUS
#   forward. The script believes it is talking to pod Q while every request is
#   still reaching pod P.
#
#   That failure is invisible in the request log: the responses are all HTTP 200.
#   It showed up only as an impossible number — "warm prefix A on Q" reporting
#   cached_tokens=720 on a pod that had never seen prefix A. See
#   planning/lab-tests/raw/spike-03/08-asymmetry.log for the corrupted run.
#
# A monotonically increasing port cannot be confused with a previous forward, and
# the `wait` reaps the old process so a leak cannot accumulate.
FWD_PID=""
FWD_PORT=""
FWD_SEQ=0
start_forward() {
  local target="$1" base="$2" rport="$3" i
  # Walk forward to the first port nothing is listening on. The invariant that
  # matters is "this port is not already serving something else" — satisfied by
  # SKIPPING a busy port, not by refusing to run. A hard failure here was wrong:
  # a leaked forward from an earlier run (or any unrelated local listener) would
  # abort a measured sequence midway, which is a worse outcome than moving over
  # one port. The guard still holds, because the chosen port is verified free
  # before the forward starts.
  local tries=0
  FWD_SEQ=$((FWD_SEQ + 1))
  FWD_PORT=$((base + FWD_SEQ))
  while nc -z 127.0.0.1 "${FWD_PORT}" 2>/dev/null; do
    tries=$((tries + 1))
    [ "${tries}" -le 50 ] \
      || fail "could not find a free local port in ${base}+1..${base}+50 to forward ${target}; something is listening across the whole range."
    FWD_SEQ=$((FWD_SEQ + 1))
    FWD_PORT=$((base + FWD_SEQ))
  done
  kcn port-forward "${target}" "${FWD_PORT}:${rport}" >/dev/null 2>&1 &
  FWD_PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if nc -z 127.0.0.1 "${FWD_PORT}" 2>/dev/null; then
      echo "    (forward ${target} -> 127.0.0.1:${FWD_PORT})"
      return 0
    fi
    sleep 1
  done
  fail "port-forward to ${target} never came up on 127.0.0.1:${FWD_PORT}"
}
stop_forward() {
  if [ -n "${FWD_PID}" ]; then
    kill "${FWD_PID}" 2>/dev/null || true
    # Reap it. Without this the socket can outlive the kill and the NEXT
    # forward's readiness check can pass against this one.
    wait "${FWD_PID}" 2>/dev/null || true
  fi
  FWD_PID=""
}

cmd_replay() {
  local p="${1:-}"
  [ -n "${p}" ] || fail "usage: bash setup.sh replay <round-robin|load-aware|prefix-cache|all>"
  if [ "${p}" = "all" ]; then
    local one
    for one in ${POLICIES}; do
      echo
      echo "================ policy: ${one} ================"
      cmd_replay "${one}"
    done
    return 0
  fi
  cmd_policy "${p}"
  trap stop_forward EXIT
  start_forward "svc/sim-router-envoy" "${FWD_ENVOY_PORT}" 8081
  # Under the cache-aware policy the index is empty after the restart, so the
  # first pass over the four prefixes is what teaches it where they live and the
  # second pass is what can act on that. Both passes are issued for EVERY policy
  # so the input set stays identical across the three.
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" "${p}" replay
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" "${p}" replay
  stop_forward
  trap - EXIT
}

# --- the eviction asymmetry: SPIKE-03's actual proof -------------------------
# A router that is NOT consuming the ZMQ events cannot produce this sequence.
#
#   1. warm prefix A on pod P   — posted DIRECTLY to P, router not involved
#   2. ask the router for A     — expect P, the only holder
#   3. warm prefix A on pod Q   — posted DIRECTLY to Q; now P and Q both hold it
#   4. flood P directly         — forces BlockRemoved for A's blocks ON P ONLY
#   5. ask the router for A     — expect Q
#
# Every manipulation of cache state is performed DIRECTLY against a simulator,
# so the only way the router can learn about any of it is the event stream. The
# choice moving P -> Q for a byte-identical prompt under an unchanged policy is
# the asymmetry; two independent allocations could not produce it, because step
# 5's prompt is the same prompt as step 2's.
cmd_asymmetry() {
  cmd_policy prefix-cache
  local pods p q
  # Running-only: cmd_policy restarts the fleet, and `rollout status` returns
  # before the old Pods are gone, so an unfiltered list can name a Terminating
  # pod as P or Q (WR-18).
  pods="$(kcn get pods -l app=sim -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}')"
  p="$(echo "${pods}" | awk '{print $1}')"
  q="$(echo "${pods}" | awk '{print $2}')"
  [ -n "${p}" ] && [ -n "${q}" ] || fail "need at least two simulator pods; got '${pods}'"
  echo "asymmetry: P=${p}  Q=${q}"
  index_counters "baseline - router index after restart"

  trap stop_forward EXIT

  echo
  echo "--- STEP 1: warm prefix A directly on P (${p}) — the router is not in this path"
  start_forward "pod/${p}" "${FWD_POD_PORT}" 8000
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" prefix-cache warm A
  stop_forward
  sleep 3   # let the event batch reach the router
  index_counters "after step 1 - A stored on P"

  echo
  echo "--- STEP 2: ask the ROUTER for prefix A — expect it to choose P (${p})"
  start_forward "svc/sim-router-envoy" "${FWD_ENVOY_PORT}" 8081
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" prefix-cache observe A
  stop_forward
  index_counters "after step 2 - router looked A up"

  echo
  echo "--- STEP 3: warm prefix A directly on Q (${q}) — both pods now hold it"
  start_forward "pod/${q}" "${FWD_POD_PORT}" 8000
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" prefix-cache warm A
  stop_forward
  sleep 3
  index_counters "after step 3 - A stored on Q too"

  echo
  echo "--- STEP 4: flood P (${p}) directly with distinct prefixes — forces eviction ON P"
  start_forward "pod/${p}" "${FWD_POD_PORT}" 8000
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" prefix-cache flood 8
  stop_forward
  sleep 3
  index_counters "after step 4 - evictions on P"

  echo
  echo "--- STEP 5: ask the ROUTER for prefix A again — expect the choice to MOVE to Q (${q})"
  start_forward "svc/sim-router-envoy" "${FWD_ENVOY_PORT}" 8081
  python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" prefix-cache observe A
  stop_forward
  index_counters "after step 5 - router looked A up again"
  trap - EXIT

  echo
  echo "asymmetry: sequence complete. Read the endpoint choices from the Envoy"
  echo "access log (chosen=/scores=) and the events from the simulator and router logs."
  echo "  P = ${p}"
  echo "  Q = ${q}"
}

# --- the SEEDED comparison: the one that can actually tell the policies apart --
#
# Why the plain `replay` comparison cannot, which is the most important lab-design
# finding in this spike:
#
#   The prefix-cache scorer scores an endpoint on matchBlocks/totalBlocks. If
#   EVERY pod holds the prefix, every pod scores 1.0, the scores tie, and
#   max-score-picker breaks the tie arbitrarily — so the policy becomes
#   OBSERVATIONALLY IDENTICAL to the random control. A replay that sends a small
#   set of prefixes repeatedly at a small fleet drives exactly that state:
#   residency SATURATES within the first pass and the comparison then measures
#   tie-breaking, not routing. Measured twice, at two different prompt sizes:
#   planning/lab-tests/raw/spike-03/15-policy-distribution-thrashing-set.log and
#   17-policy-distribution.log, where prefix-cache scored 50% and 65% mean
#   per-prefix concentration against the control at 54% and 67%.
#
#   Prefix-cache routing only has anything to say while residency is UNEVEN —
#   which is the real production case, where the prefix population vastly exceeds
#   what any one pod can hold.
#
# So this comparison SEEDS uneven residency first, and does so DIRECTLY against
# individual pods with the router out of the path:
#   seed    prefix i is warmed on pod (i mod N) only, where N is the ACTUAL
#           number of simulator pods, so each prefix has exactly ONE holder.
#           At the default REPLICAS=3 each pod holds 2 of the 6 prefixes (~46
#           of its 64 blocks: fits).
#   measure each prefix is then sent twice THROUGH the router
#   score   what fraction of those picks landed on the prefix's seeded holder
#
# Expected ceiling and floor are both known in advance, which is what makes the
# result interpretable: a cache-aware policy should approach 100%, and any
# cache-blind policy should sit near 1/N — chance, for N endpoints. N is
# derived from the running fleet and printed with the result, so the
# interpretation cannot go stale when REPLICAS changes.
#
# Seeding happens AFTER the policy switch, always. The router's index is rebuilt
# from scratch when it restarts and it learns residency ONLY from events
# published while it is subscribed, so a seed laid down before the switch would
# be invisible to it — the policy would then be measured against an empty index
# and would score like chance for the wrong reason.
cmd_seeded() {
  local one pods arr n i tag ip baseline
  for one in ${POLICIES}; do
    echo
    echo "================ seeded comparison: ${one} ================"
    # Fresh simulators per policy: residency must start empty so the seed below
    # is the ONLY thing in the caches.
    kcn rollout restart deploy/sim >/dev/null
    kcn rollout status deploy/sim --timeout=300s >/dev/null
    sleep 5
    cmd_policy "${one}" >/dev/null
    pods="$(kcn get pods -l app=sim -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}')"
    # Derive the fleet size instead of assuming it.
    #
    # This used to `set -- ${pods}` and then index $1/$2/$3 from
    # `case $((i % 3))`. cmd_up explicitly accepts REPLICAS=2 (line 194 only
    # requires >= 2), at which the third prefix hit `$3` and the script died
    # with `$3: unbound variable` under `set -u` — AFTER the fleet had already
    # been rollout-restarted and the live policy switched, leaving the lab
    # half-reconfigured with no FAIL: line. At REPLICAS>=4 the converse was
    # silent: pods 4..n were never seeded, while the published interpretation
    # stayed hardcoded to three endpoints, so the measured concentration was
    # scored against the wrong chance baseline with nothing saying so.
    #
    # The `Running` phase filter is also load-bearing. `rollout status` returns
    # when the NEW ReplicaSet is available, NOT when the old Pods are gone, so
    # an unfiltered list taken four lines after `rollout restart` can contain
    # Terminating pods from the previous policy's fleet. The seed would then be
    # laid on a pod that is about to disappear and the measured per-prefix
    # concentration would be scored against a seed map that was never true,
    # with nothing in the output showing it. run.sh:619 already used this
    # pattern.
    #
    # `read -ra` rather than `set --`: it splits explicitly on IFS and does not
    # depend on unquoted-parameter word splitting.
    read -ra arr <<< "${pods}"
    n="${#arr[@]}"
    if [ "${n}" -lt 2 ]; then
      fail "need >= 2 simulator pods to seed uneven residency; got ${n}. A prefix-cache scorer cannot be distinguished from chance on one endpoint."
    fi
    baseline="$(python3 -c "print('%.3f' % (1.0/${n}))")"
    echo "fleet: ${n} simulator pod(s); chance baseline for a cache-blind policy = 1/${n} = ${baseline}"
    echo "seed map (prefix -> sole holder):"
    i=0
    trap stop_forward EXIT
    for tag in A B C D E F; do
      i=$((i + 1))
      # Round-robin over the ACTUAL fleet, so every pod is used and no index
      # can be out of range regardless of REPLICAS.
      ip="${arr[$(( (i - 1) % n ))]}"
      echo "  ${tag} -> ${ip}"
      start_forward "pod/${ip}" "${FWD_POD_PORT}" 8000 >/dev/null 2>&1
      python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" "${one}" warm "${tag}" >/dev/null
      stop_forward
      # The seeded pod must still be Running AFTER the warm POST, or the seed
      # map this comparison is scored against is already false.
      if [ "$(kcn get pod "${ip}" -o jsonpath='{.status.phase}' 2>/dev/null || true)" != "Running" ]; then
        fail "simulator pod ${ip} is no longer Running immediately after seeding prefix ${tag}; the seed map is unsafe and the concentration score would be meaningless."
      fi
    done
    sleep 4   # let the final event batch reach the router
    kcn get pods -l app=sim -o custom-columns='NAME:.metadata.name,IP:.status.podIP' --no-headers
    echo "measuring: each prefix twice through the router, policy=${one}"
    start_forward "svc/sim-router-envoy" "${FWD_ENVOY_PORT}" 8081
    for tag in A B C D E F A B C D E F; do
      python3 -c "${PY_DRIVER}" "http://127.0.0.1:${FWD_PORT}" "seeded-${one}" observe "${tag}"
    done
    stop_forward
    trap - EXIT
    # Print the baseline WITH the result, computed from the fleet that was
    # actually measured. A baseline carried in prose goes stale the moment
    # REPLICAS changes; this one cannot.
    echo "interpret: policy=${one}, ${n} endpoints — a cache-blind policy scores"
    echo "           about ${baseline} (1/${n}); a cache-aware policy approaches 1.000."
  done
}

cmd_teardown() {
  echo "Removing sim-router from namespace ${NAMESPACE} ..."
  # Namespace delete removes every object this script created. Deliberately NOT
  # `kubectl delete -f` per file: a partially-applied run would leave strays.
  if kc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    kc delete namespace "${NAMESPACE}" --wait=true --timeout=180s >/dev/null
    echo "OK: namespace ${NAMESPACE} deleted"
  else
    echo "OK: namespace ${NAMESPACE} already absent"
  fi
  # The cluster itself is NOT touched here: labs/clusters/spike-core/teardown.sh
  # owns that, so one profile's lifecycle stays in one place.
  echo "NOTE: the spike-core cluster is still up. Remove it with"
  echo "      bash ${LABS_DIR}/clusters/spike-core/teardown.sh"
}

case "${1:-up}" in
  up|"")      cmd_up ;;
  policy)     shift; cmd_policy "${1:-}" ;;
  replay)     shift; cmd_replay "${1:-}" ;;
  asymmetry)  cmd_asymmetry ;;
  seeded)     cmd_seeded ;;
  teardown)   cmd_teardown ;;
  *)          echo "usage: bash setup.sh [up|policy <n>|replay <n>|asymmetry|seeded|teardown]" >&2; exit 2 ;;
esac

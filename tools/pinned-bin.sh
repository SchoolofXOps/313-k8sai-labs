#!/usr/bin/env bash
# pinned-bin.sh — one place that asserts the lab's pinned client binaries.
#
# SOURCED, never executed:  . "${LABS_DIR}/tools/pinned-bin.sh"
#
# Why this file exists
# -------------------
# Every labs/ script prepends LAB_BIN_PREFIX (default /opt/homebrew/bin) to
# PATH, but a prepend is NOT a resolution guarantee. If the pinned copy is
# absent from that prefix — a Linux learner, or a Mac carrying kind only in
# /usr/local/bin — the prepend is a no-op and whatever is next on PATH runs
# instead. On the build host the shadowing copies are real:
#
#   /usr/local/bin/kind      v0.32.0   shadows /opt/homebrew/bin/kind v0.33.0
#   ~/.rd/bin/kubectl        a version-switching Rancher Desktop shim
#   ~/.local/bin/kubectl     v1.37.0   (while the brew prefix carries v1.36.2)
#
# create.sh caught this for kind with a hard assert; verify.sh, the kwok
# installer and the sim-router installer did not, and nothing asserted kubectl
# anywhere. This file is that assert, factored once so the five scripts that
# touch a cluster cannot drift apart.
#
# EACH TOOL IS ASSERTED ON THE PROPERTY THAT ACTUALLY MATTERS FOR IT, which is
# why the three assertions below have three different shapes rather than one
# copied shape. kind is EXACT, because exactly one release carries the node
# image. kubectl is a WINDOW, because the supported skew window is the real
# property and an exact pin would fail a correctly-configured host. helm is a
# FLOOR, because the thing the layers require of helm is a CAPABILITY — stable
# OCI registry support — and that capability has a first version rather than a
# single correct one. A fourth tool gets whichever of the three its own
# requirement actually is; it does not get one of these by analogy.
#
# bash-3.2 compatible (macOS default shell). No arrays, no `local -n`.

# kind is pinned EXACTLY. v0.33.0 is the only kind release carrying Kubernetes
# 1.37 node images, so an older kind does not produce a slightly different
# cluster — it cannot produce this cluster at all.
PINNED_KIND_VERSION="${PINNED_KIND_VERSION:-0.33.0}"

# The Kubernetes MINOR this course pins on the server side (node image
# v1.37.x). Used to bound the acceptable kubectl skew below.
PINNED_SERVER_MINOR="${PINNED_SERVER_MINOR:-37}"

# helm's FLOOR, expressed as major.minor. 3.8.0 is not a taste: it is the
# release where OCI registry support stopped being an experiment.
#
# Helm's own v3.8.0 release notes, read 2026-10-21 via the GitHub releases API:
#   "OCI registry support for charts is now generally available. It has
#    graduated out of being an experiment."
#   "Removing all the checks for oci experimental flag"
#
# Every chart this course installs is pulled from an OCI registry
# (`oci://registry.k8s.io/kueue/charts/kueue`,
# `oci://ghcr.io/prometheus-community/charts/prometheus`, and two more), so a
# helm below this floor does not render a slightly different object set — it
# cannot fetch the chart at all without an experimental environment variable
# that no lab script sets.
PINNED_HELM_MIN_MAJOR="${PINNED_HELM_MIN_MAJOR:-3}"
PINNED_HELM_MIN_MINOR="${PINNED_HELM_MIN_MINOR:-8}"

assert_kind_version() {
  local got
  got="$(kind --version 2>/dev/null | awk '{print $NF}' || true)"
  if [ "${got}" != "${PINNED_KIND_VERSION}" ]; then
    echo "FAIL: kind resolves to '${got:-<not found>}' but this course pins v${PINNED_KIND_VERSION}," >&2
    echo "      the only kind release carrying Kubernetes 1.37 node images." >&2
    echo "      Install it and make sure it resolves first:" >&2
    echo "        brew install kind     # then: LAB_BIN_PREFIX=\$(brew --prefix)/bin bash <script>" >&2
    echo "      Resolution order on this host: $(type -a kind 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
}

# kubectl is asserted against the SUPPORTED SKEW WINDOW, not an exact version.
#
# Kubernetes supports a client within +/-1 minor of the server, and that is the
# property that actually matters here: a v1.36 client against a v1.37 server is
# supported and works, so failing it would break a correctly-configured host
# for no benefit. The build host is exactly that case — the pinned brew prefix
# carries v1.36.2 against the v1.37.0 node image.
#
# What this DOES catch is the recorded hazard: a client two or more minors away
# (the Rancher Desktop shim has served v1.35.0), which is outside the supported
# window and fails in ways that look like cluster bugs.
assert_kubectl_version() {
  local raw minor lo hi
  raw="$(kubectl version --client 2>/dev/null | awk '/Client Version/{print $NF}' || true)"
  if [ -z "${raw}" ]; then
    echo "FAIL: kubectl not found, or 'kubectl version --client' produced nothing." >&2
    echo "      Resolution order on this host: $(type -a kubectl 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  # v1.36.2 -> 36 ; tolerates a pre-release suffix such as v1.37.0-rc.1
  minor="$(printf '%s' "${raw}" | sed -n 's|^v\{0,1\}1\.\([0-9]\{1,\}\)\..*$|\1|p')"
  if [ -z "${minor}" ]; then
    echo "FAIL: could not parse a Kubernetes minor from kubectl version '${raw}'." >&2
    exit 1
  fi
  lo=$(( PINNED_SERVER_MINOR - 1 ))
  hi=$(( PINNED_SERVER_MINOR + 1 ))
  if [ "${minor}" -lt "${lo}" ] || [ "${minor}" -gt "${hi}" ]; then
    echo "FAIL: kubectl resolves to ${raw}, which is outside the supported skew" >&2
    echo "      window for a v1.${PINNED_SERVER_MINOR} server (client 1.${lo}-1.${hi})." >&2
    echo "      This course pins kubectl 1.${PINNED_SERVER_MINOR}.x." >&2
    echo "      Resolution order on this host: $(type -a kubectl 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
}

# helm is asserted against a CAPABILITY FLOOR, not against a major and not
# against an exact version. Three things forced that shape, and all three are
# measurements rather than preferences.
#
# 1. THE MAJOR IS NOT THE RISK. Measured 2026-10-21 on this host, with the two
#    helm majors it actually carries — v3.22.0+g144ca65 (/usr/local/bin) and
#    v4.2.3+g43e8b7f (/opt/homebrew/bin). For all four charts this course
#    installs plus the DRA chart rendered from its pinned git tag, the two
#    majors produced:
#      - the SAME `helm pull` manifest digest, matching the registered pin in
#        every case (4/4); and
#      - a `helm template` render that is IDENTICAL once blank lines are
#        stripped (5/5 matching sha256 over the non-blank render).
#    The only difference either major produces is that helm 4 emits one
#    trailing blank line per rendered document. Nothing downstream reads that:
#    the committed rendered-pinned.yaml files are written by create.sh, and
#    every checker over them scans `image:` references and object kinds.
#    So a major pin would reject a known-good helm for a cosmetic difference.
#
# 2. REJECTING HELM 4 WOULD REJECT THE VERSION EVERYTHING WAS VERIFIED ON.
#    Every addon layer in this profile was measured under helm 4 — v4.2.3 in
#    planning/lab-tests/03-addon-{dra,ops,kueue-kwok}.md and in
#    labs/clusters/grid-core/addons/ops/PINS.md, v4.2.1 in the Phase-1 spikes.
#    Every chart digest the install gates enforce was resolved by helm 4.2.3.
#    Phase 1's D-03 adjudicated "helm 4 acceptable" and deferred the pin
#    itself to this phase; this is that pin.
#
# 3. WHAT IS GENUINELY REQUIRED IS OCI, AND OCI HAS A FIRST VERSION. See the
#    floor constants above and their citation.
#
# WHAT THIS DOES NOT CLAIM. Two majors were measured, not every version in
# them. A helm at or above the floor but outside the measured pair is
# UNTESTED HERE rather than known-good, and the failure path says so rather
# than implying this course has ruled on versions it never ran. The site's
# setup page names v3.19.0 as its install target; no layer in this course has
# ever been run under it, and it sits above this floor, so it is accepted here
# and flagged in planning/lab-tests/03-setup-learner-qa.md § "Finding 4" rather
# than silently blessed or silently rejected.
assert_helm_version() {
  local raw major minor
  raw="$(helm version --short 2>/dev/null | sed -n '1,1p' || true)"
  if [ -z "${raw}" ]; then
    echo "FAIL: helm not found, or 'helm version --short' produced nothing." >&2
    echo "      Every addon layer in this course pulls its chart from an OCI registry" >&2
    echo "      and renders it with 'helm template', so no layer can run without it." >&2
    echo "      Install helm ${PINNED_HELM_MIN_MAJOR}.${PINNED_HELM_MIN_MINOR} or newer:" >&2
    echo "        brew install helm     # then: LAB_BIN_PREFIX=\$(brew --prefix)/bin bash <script>" >&2
    echo "      Resolution order on this host: $(type -a helm 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  # v4.2.3+g43e8b7f -> major 4, minor 2 ; tolerates the +gSHA build suffix and
  # a pre-release suffix such as v3.19.0-rc.1
  major="$(printf '%s' "${raw}" | sed -n 's|^v\{0,1\}\([0-9]\{1,\}\)\..*$|\1|p')"
  minor="$(printf '%s' "${raw}" | sed -n 's|^v\{0,1\}[0-9]\{1,\}\.\([0-9]\{1,\}\).*$|\1|p')"
  if [ -z "${major}" ] || [ -z "${minor}" ]; then
    echo "FAIL: could not parse a major.minor from helm version '${raw}'." >&2
    echo "      Resolution order on this host: $(type -a helm 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  if [ "${major}" -lt "${PINNED_HELM_MIN_MAJOR}" ] ||
     { [ "${major}" -eq "${PINNED_HELM_MIN_MAJOR}" ] && [ "${minor}" -lt "${PINNED_HELM_MIN_MINOR}" ]; }; then
    echo "FAIL: helm resolves to ${raw}, below this course's floor of" >&2
    echo "      v${PINNED_HELM_MIN_MAJOR}.${PINNED_HELM_MIN_MINOR}.0." >&2
    echo "      The floor exists because OCI registry support for charts stopped being" >&2
    echo "      an experiment in helm v3.8.0 (helm's own v3.8.0 release notes), and" >&2
    echo "      every addon layer here pulls its chart from an oci:// coordinate — so a" >&2
    echo "      helm below that cannot fetch the chart at all." >&2
    echo "      Both helm 3 and helm 4 are accepted above the floor: v3.22.0 and v4.2.3" >&2
    echo "      were measured rendering every chart in this course identically." >&2
    echo "      Install helm ${PINNED_HELM_MIN_MAJOR}.${PINNED_HELM_MIN_MINOR} or newer:" >&2
    echo "        brew install helm     # then: LAB_BIN_PREFIX=\$(brew --prefix)/bin bash <script>" >&2
    echo "      Resolution order on this host: $(type -a helm 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
}

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
# bash-3.2 compatible (macOS default shell). No arrays, no `local -n`.

# kind is pinned EXACTLY. v0.33.0 is the only kind release carrying Kubernetes
# 1.37 node images, so an older kind does not produce a slightly different
# cluster — it cannot produce this cluster at all.
PINNED_KIND_VERSION="${PINNED_KIND_VERSION:-0.33.0}"

# The Kubernetes MINOR this course pins on the server side (node image
# v1.37.x). Used to bound the acceptable kubectl skew below.
PINNED_SERVER_MINOR="${PINNED_SERVER_MINOR:-37}"

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

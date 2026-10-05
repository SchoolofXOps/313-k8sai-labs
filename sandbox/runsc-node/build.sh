#!/usr/bin/env bash
# labs/sandbox/runsc-node — build the gVisor-enabled kind node image
#
# Mechanism: one Dockerfile serves both architectures because buildx passes
# TARGETARCH per --platform and the Dockerfile selects the matching gVisor
# artefact from it. This script therefore does TWO builds, deliberately:
#
#   1. a MULTI-ARCH build for ${PLATFORMS}, output to a local OCI layout.
#      This is what proves CONTEXT D-10's multi-arch claim -- both platforms
#      are really compiled, with their gVisor artefacts really downloaded and
#      really checksum-verified, rather than the claim resting on the fact
#      that the Dockerfile mentions two arch names.
#   2. a SINGLE-ARCH build for the host platform, --load into the local docker
#      image store. Only this form can be `kind load`ed, because the docker
#      image store holds one architecture per tag.
#
# Both builds read the same pins, so (1) is evidence for (2) rather than a
# different artefact.
#
# Nothing is published. The image stays local -- local OCI layout plus the
# docker image store -- for the whole of Phase 1 (threat T-01-17, Information
# Disclosure: a node image carrying a privileged runtime must not reach a
# public registry from a spike). Phase 3 owns the publishing decision, with its
# own review. There is deliberately no registry flag in this script.
#
# Usage:
#   bash build.sh                              # multi-arch check + load host arch
#   PLATFORMS=linux/arm64 bash build.sh        # one platform only (faster)
#   GVISOR_RELEASE=release-20260921.0 bash build.sh   # a different gVisor release
#   TAG=mine bash build.sh                     # a different local tag
#
# Env (match planning/lab-tests/spike-00-preflight.md on the build host):
#   export PATH="/opt/homebrew/bin:$PATH"
#   # docker buildx v0.34.1 present on the build host; no DOCKER_HOST override
#   # is needed with Rancher Desktop's Moby engine on the default socket.
#
# Idempotent: re-running rebuilds from cache and re-tags; no cluster is touched
# and no state outside the image store and ${OUT_DIR} is changed.
# bash-3.2 compatible (macOS default shell).
# Pinned: kindest/node v1.37.0 by index digest; gVisor release-20260928.0.
set -euo pipefail

# --- knobs -------------------------------------------------------------------
# Local image name. Not a registry path: this image is never published in
# Phase 1, so it deliberately carries no registry host.
IMAGE="${IMAGE:-313-runsc-node}"
# Tag names the Kubernetes version and what was added, so a `docker images`
# listing is self-describing. The node image this is built FROM is pinned by
# DIGEST in the Dockerfile; this tag names the local artefact only and is not a
# pin of anything.
TAG="${TAG:-v1.37.x-runsc}"
# Both architectures SPIKE-01 must cover: arm64 is the authoring host, amd64 is
# the Actions runner arm. gVisor publishes artefacts for exactly these two.
PLATFORMS="${PLATFORMS:-linux/arm64,linux/amd64}"
# Kubernetes v1.37.0 node image, manifest-list (index) digest resolved by
# spike 0. Passed through for the record; the Dockerfile's FROM carries the
# same digest literally, because a FROM cannot be a build arg without
# weakening the pin Phase 3 SC2 greps for.
BASE_DIGEST="${BASE_DIGEST:-sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
# gVisor release. Confirmed live against the google/gvisor releases API
# (published 2026-09-30). CLAUDE.md pins this exact release.
GVISOR_RELEASE="${GVISOR_RELEASE:-release-20260928.0}"

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/313-runsc-node-oci}"

# --- pinned-binary resolution -------------------------------------------------
# Same hazard as the cluster profiles: on this build host a stale copy of the
# toolchain resolves first from a login shell because /usr/local/bin and
# ~/.rd/bin both precede the brew prefix. An `export PATH` only lives as long
# as the shell that set it, so each script resolves its own binaries.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

if ! docker buildx version >/dev/null 2>&1; then
  echo "FAIL: 'docker buildx' is unavailable, so no multi-arch build is possible." >&2
  echo "      Install the buildx plugin, or enable it in Rancher Desktop." >&2
  exit 1
fi

# jq is REQUIRED, and it is checked here — before the build — rather than
# discovered after it.
#
# The OCI index read below is the ONLY evidence for this script's multi-arch
# claim: the whole point (header, lines 8-12) is that the claim rests on the
# index actually carrying two platform manifests, "rather than the claim
# resting on the fact that the Dockerfile mentions two arch names". Without jq
# that read used to degrade to `cat index.json` with PLATFORM_COUNT="unknown",
# which short-circuited the count guard — and the script still printed
# `OK: ... built for linux/arm64,linux/amd64`. The evidence path vanished while
# the verdict line stayed the same, which is the one outcome this file must not
# produce.
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to read the OCI index, which is the only evidence" >&2
  echo "      for this script's multi-arch claim. Install it (brew install jq)." >&2
  echo "      Checked before the build so a 10-minute build is not wasted." >&2
  exit 1
fi

HOST_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)"
if [ -z "${HOST_ARCH}" ]; then
  echo "FAIL: cannot reach the docker daemon to determine the host architecture." >&2
  echo "      Start Rancher Desktop (Moby/dockerd engine) and retry." >&2
  exit 1
fi
HOST_PLATFORM="linux/${HOST_ARCH}"

echo "==> runsc node image build"
echo "    image      : ${IMAGE}:${TAG}"
echo "    base       : kindest/node@${BASE_DIGEST}"
echo "    gVisor     : ${GVISOR_RELEASE}"
echo "    platforms  : ${PLATFORMS}"
echo "    host plat  : ${HOST_PLATFORM}"
echo "    oci layout : ${OUT_DIR}"
echo

# --- 1. multi-arch build, to a local OCI layout -------------------------------
# type=oci writes a real multi-platform image index to disk. It is the honest
# way to assert "this builds for both architectures" without a registry: every
# platform's layers are genuinely built and the resulting index can be
# inspected for its per-platform digests.
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
echo "==> [1/2] multi-arch build for ${PLATFORMS} -> local OCI layout"
docker buildx build \
  --platform "${PLATFORMS}" \
  --build-arg "GVISOR_RELEASE=${GVISOR_RELEASE}" \
  --progress plain \
  --output "type=oci,dest=${OUT_DIR}/image.tar" \
  -t "${IMAGE}:${TAG}" \
  "${PROFILE_DIR}"

if [ ! -s "${OUT_DIR}/image.tar" ]; then
  echo "FAIL: the multi-arch build produced no OCI artefact at ${OUT_DIR}/image.tar," >&2
  echo "      so D-10's both-architectures claim has no evidence behind it." >&2
  exit 1
fi

# Per-platform digests, read out of the OCI index the build just wrote. These
# are recorded in planning/lab-tests/spike-01-gvisor.md as the identity of what
# was built, the same way spike 0 recorded the base image's per-arch digests.
echo
echo "==> per-platform manifests in the OCI index:"
tar -xOf "${OUT_DIR}/image.tar" index.json > "${OUT_DIR}/index.json"
# jq is asserted present at the top of this script, so there is no longer a
# jq-less branch here. The previous `else` set PLATFORM_COUNT="unknown", which
# made the guard below short-circuit and let the OK line print unchanged.
{
  # A multi-platform build writes a top-level descriptor pointing at an image
  # INDEX, whose own manifests carry .platform. A single-platform build writes
  # the image MANIFEST straight into index.json, with no .platform on it at
  # all. Both are valid OCI layouts and both are reachable from this script
  # (PLATFORMS=linux/arm64 is documented usage), so the two shapes are handled
  # separately rather than one being assumed.
  TOP_MEDIA="$(jq -r '.manifests[0].mediaType // ""' "${OUT_DIR}/index.json")"
  case "${TOP_MEDIA}" in
    *image.index*)
      MANIFEST_DIGEST="$(jq -r '.manifests[0].digest' "${OUT_DIR}/index.json")"
      tar -xOf "${OUT_DIR}/image.tar" "blobs/sha256/${MANIFEST_DIGEST#sha256:}" \
        > "${OUT_DIR}/manifest-index.json"
      jq -r '.manifests[]
             | select(.platform.architecture != "unknown")
             | "    \(.platform.os)/\(.platform.architecture)  \(.digest)"' \
        "${OUT_DIR}/manifest-index.json"
      PLATFORM_COUNT="$(jq -r '[.manifests[] | select(.platform.architecture != "unknown")] | length' \
        "${OUT_DIR}/manifest-index.json")"
      ;;
    *)
      # Single platform: the architecture is only stated authoritatively in the
      # image CONFIG blob, so it is read from there rather than guessed from
      # the requested --platform value.
      MANIFEST_DIGEST="$(jq -r '.manifests[0].digest' "${OUT_DIR}/index.json")"
      tar -xOf "${OUT_DIR}/image.tar" "blobs/sha256/${MANIFEST_DIGEST#sha256:}" \
        > "${OUT_DIR}/manifest-index.json"
      CONFIG_DIGEST="$(jq -r '.config.digest' "${OUT_DIR}/manifest-index.json")"
      tar -xOf "${OUT_DIR}/image.tar" "blobs/sha256/${CONFIG_DIGEST#sha256:}" \
        > "${OUT_DIR}/image-config.json"
      jq -r '"    \(.os)/\(.architecture)"' "${OUT_DIR}/image-config.json"
      echo "    manifest ${MANIFEST_DIGEST}"
      PLATFORM_COUNT=1
      ;;
  esac
}

WANTED_COUNT="$(printf '%s' "${PLATFORMS}" | tr ',' '\n' | grep -c . || true)"
# No `!= "unknown"` escape hatch: PLATFORM_COUNT is always a number now.
if [ "${PLATFORM_COUNT}" -lt "${WANTED_COUNT}" ]; then
  echo "FAIL: the OCI index carries ${PLATFORM_COUNT} platform manifest(s) but ${WANTED_COUNT} were requested." >&2
  echo "      One architecture did not build; D-10's multi-arch claim is unproven." >&2
  exit 1
fi

# --- 2. host-arch build, loaded into the docker image store -------------------
# A multi-platform result cannot be loaded into the docker image store, so the
# host architecture is built again (fully cached) in loadable form. This is the
# image `kind load docker-image` consumes.
echo
echo "==> [2/2] host-arch build for ${HOST_PLATFORM} -> local docker image store"
docker buildx build \
  --platform "${HOST_PLATFORM}" \
  --build-arg "GVISOR_RELEASE=${GVISOR_RELEASE}" \
  --progress plain \
  --load \
  -t "${IMAGE}:${TAG}" \
  "${PROFILE_DIR}"

if ! docker image inspect "${IMAGE}:${TAG}" >/dev/null 2>&1; then
  echo "FAIL: ${IMAGE}:${TAG} is not in the local docker image store after --load." >&2
  exit 1
fi

# Hard assert the runtime really is in the image and really runs, from inside
# the built image rather than from the build log.
RUNSC_VERSION="$(docker run --rm --entrypoint runsc "${IMAGE}:${TAG}" --version 2>&1 | head -n 1 || true)"
case "${RUNSC_VERSION}" in
  *runsc*) : ;;
  *) echo "FAIL: 'runsc --version' inside ${IMAGE}:${TAG} did not identify runsc: ${RUNSC_VERSION}" >&2
     exit 1 ;;
esac

if ! docker run --rm --entrypoint grep "${IMAGE}:${TAG}" \
       -q 'containerd.runtimes.runsc\]' /etc/containerd/config.toml; then
  echo "FAIL: the runsc runtime handler is not registered in the node's containerd config." >&2
  echo "      Without it the RuntimeClass silently falls back to runc and a Pod still runs." >&2
  exit 1
fi

HANDLER="$(docker run --rm --entrypoint grep "${IMAGE}:${TAG}" \
             -o 'containerd\.runtimes\.[a-z0-9-]*\]' /etc/containerd/config.toml \
           | sed 's/containerd\.runtimes\.//; s/\]//' | tr '\n' ' ')"

echo
echo "    runsc        : ${RUNSC_VERSION}"
echo "    handlers     : ${HANDLER}"
echo "    oci index    : ${OUT_DIR}/image.tar (${PLATFORM_COUNT} platform manifests)"
echo "OK: ${IMAGE}:${TAG} built for ${PLATFORMS}, loaded for ${HOST_PLATFORM}, runsc present and the 'runsc' containerd handler registered. Nothing published."
echo "next: kind load docker-image ${IMAGE}:${TAG} --name spike-core"

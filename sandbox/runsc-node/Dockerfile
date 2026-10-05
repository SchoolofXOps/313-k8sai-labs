# syntax=docker/dockerfile:1
# labs/sandbox/runsc-node — kind node image with gVisor runsc baked in
#
# Mechanism: a RuntimeClass only resolves if the node's CONTAINERD knows a
# runtime handler by that name. containerd reads /etc/containerd/config.toml
# once, at start. So runsc cannot be added to a RUNNING kind node without
# restarting containerd inside it -- which is why CONTEXT D-10 settles M11's
# lab shape as "the learner consumes a published node image", never
# "docker exec into a running node". This Dockerfile is that image.
#
# CROSS-FILE DEPENDENCY (CONTEXT D-10, reversibility: costly). Three things
# downstream assume this image exists and is CONSUMED rather than installed at
# runtime:
#   1. M11's lab text (Phase 5)            -- its first step pulls this image
#   2. the grid-sandbox profile create.sh  -- Phase 3 PLAT-03, KIND_IMAGE=this
#   3. the labs-repo image build           -- Phase 3, publishes this image
# Switching to runtime installation changes all three.
#
# What this image adds to the pinned base, and where:
#   /usr/local/bin/runsc                      the gVisor runtime
#   /usr/local/bin/containerd-shim-runsc-v1   the containerd v2 shim
#   /usr/local/bin/gvisor-bin/                runsc's split helper binaries,
#                                             kept RELATIVE to runsc as shipped
#   /etc/containerd/runsc.toml                runsc_config (platform)
#   /etc/containerd/config.toml               APPENDED: the runsc handler
#
# The containerd runtime handler registered here is named exactly `runsc`, and
# labs/sandbox/runsc-node/runtimeclass.yaml sets `handler: runsc` to match. A
# mismatch between those two names is the silent failure mode of this pair:
# containerd falls back to the default runtime and the Pod still reaches
# Running, so it must be checked from INSIDE the Pod, never from outside.
#
# Build with the sibling build.sh -- it carries the knobs and the arch matrix.
#
# Idempotent: a pure image build; rebuilding produces the same content from the
# same pins. Nothing here is pushed to a registry in Phase 1 (threat T-01-17);
# Phase 3 owns the publishing decision.

# Kubernetes v1.37.0 node image, pinned by the manifest-list (index) DIGEST
# resolved by spike 0 -- never by tag. A tag is mutable; Phase 3's PLAT-01 pins
# by digest and Phase 3 SC2 greps the whole lab surface for the tag form, and
# this Dockerfile is inside that grep surface. The INDEX digest is used rather
# than a per-arch digest so one FROM line serves linux/arm64 (the authoring
# host) and linux/amd64 (the Actions arm): buildx resolves the index to the
# per-platform manifest for each --platform. Per-arch digests are recorded in
# planning/lab-tests/spike-00-preflight.md.
FROM kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5

# gVisor release. CLAUDE.md pins release-20260928.0 (published 2026-09-30,
# confirmed live against the google/gvisor releases API -- see
# planning/lab-tests/raw/spike-01/build/gvisor-release-list.log).
ARG GVISOR_RELEASE=release-20260928.0

# EXPECTED CONTENT DIGESTS, one per architecture, taken from the release's own
# published SHA256SUMS asset and re-verified by hand against the downloaded
# aarch64 tarball before being written here
# (raw/spike-01/build/gvisor-tarball-layout.log). These are the real pin: the
# verification below checks the downloaded bytes against THESE constants, not
# merely against a SHA256SUMS file fetched from the same endpoint over the same
# connection -- a file that moves with the artefact cannot attest to it
# (threat T-01-16, Tampering).
ARG GVISOR_SHA256_ARM64=fc23acbf56a98f9e95267eec431870cff9354dca7e0620da48749f881eed85b6
ARG GVISOR_SHA256_AMD64=1f2a732d12072eda6b8a64eccf9829fe9f4a1893d3292a7e8005a82089811d8d

# Supplied by buildx per --platform: `amd64` or `arm64`. One Dockerfile serves
# both architectures by selecting the matching gVisor artefact from it. gVisor
# names its artefacts with the UNAME spelling (x86_64 / aarch64), which is NOT
# the Go/OCI spelling TARGETARCH uses, so the two are mapped explicitly below
# rather than interpolated.
ARG TARGETARCH

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) GVISOR_ARCH=x86_64;  GVISOR_SHA256="${GVISOR_SHA256_AMD64}" ;; \
      arm64) GVISOR_ARCH=aarch64; GVISOR_SHA256="${GVISOR_SHA256_ARM64}" ;; \
      *) echo "FAIL: unsupported TARGETARCH '${TARGETARCH}' -- gVisor publishes x86_64 and aarch64 only" >&2; exit 1 ;; \
    esac; \
    TARBALL="gvisor-${GVISOR_ARCH}.tar.zstd"; \
    BASE="https://github.com/google/gvisor/releases/download/${GVISOR_RELEASE}"; \
    \
    # zstd is absent from the base image (Debian 13 trixie ships curl, tar and
    # sha256sum but no decompressor -- raw/spike-01/build/base-image-probe.log),
    # so it is installed from Debian's signed archive for the extraction and
    # removed again, leaving no apt state in the published layer.
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends zstd; \
    \
    cd /tmp; \
    # gVisor no longer serves individual per-arch binaries at the
    # storage.googleapis.com/gvisor/releases/release/<date>/<arch>/runsc path its
    # install docs describe -- every form of that URL returns 404 at this
    # release, including `latest` (raw/spike-01/build/gvisor-release-probe.log).
    # The release ships per-arch TARBALLS plus SHA256SUMS/SHA512SUMS as GitHub
    # release assets instead, so that is what is fetched and verified here.
    curl -fsSL --retry 3 -o "${TARBALL}" "${BASE}/${TARBALL}"; \
    curl -fsSL --retry 3 -o SHA256SUMS "${BASE}/SHA256SUMS"; \
    \
    # Gate 1 -- the downloaded bytes against the digest pinned IN THIS FILE.
    echo "${GVISOR_SHA256}  ${TARBALL}" > expected.sha256; \
    sha256sum -c expected.sha256; \
    # Gate 2 -- the same bytes against the release's own published SHA256SUMS,
    # so a drifted upstream asset is distinguishable from a stale pin here.
    awk -v f="${TARBALL}" '$2 == f { print }' SHA256SUMS > published.sha256; \
    test -s published.sha256; \
    sha256sum -c published.sha256; \
    \
    # Flat tarball: runsc, containerd-shim-runsc-v1, and a gvisor-bin/ directory
    # of split helpers (checkpointgofer, gvisor_sentry, runsc-metric-server,
    # ...) that runsc resolves RELATIVE to its own path. Extracting the whole
    # archive into one prefix preserves that layout; cherry-picking the two
    # top-level binaries would leave the sentry unfindable.
    tar --zstd -xf "${TARBALL}" -C /usr/local/bin; \
    chmod 0755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1; \
    \
    rm -rf /tmp/"${TARBALL}" /tmp/SHA256SUMS /tmp/expected.sha256 /tmp/published.sha256; \
    apt-get purge -y -qq zstd; \
    apt-get autoremove -y -qq; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # Prove the binaries actually execute on this platform at BUILD time, so a
    # wrong-architecture artefact fails the build rather than surfacing later as
    # a mysterious Pod that silently ran under runc.
    runsc --version; \
    containerd-shim-runsc-v1 -v || true

# runsc's own configuration, referenced by ConfigPath in the containerd stanza
# below. The platform is set EXPLICITLY rather than left to the default: it is
# the variable most likely to matter when runsc runs NESTED inside a kind node
# container, which is the whole subject of SPIKE-01. `systrap` needs no KVM
# device and no privileged host access beyond what the node container already
# has; `ptrace` is the slower fallback.
RUN set -eux; \
    printf '%s\n' \
      '[runsc_config]' \
      '  platform = "systrap"' \
      > /etc/containerd/runsc.toml; \
    cat /etc/containerd/runsc.toml

# Register the `runsc` runtime handler with the node's containerd.
#
# Dialect note: the base image's /etc/containerd/config.toml declares
# `version = 2` even though the containerd binary is v2.3.4
# (raw/spike-01/build/containerd-config-base.log). containerd 2.x still reads
# the v2 config format and the v2 `io.containerd.grpc.v1.cri` plugin path, so
# the stanza below is written in the SAME dialect as the base image's own runc
# and test-handler stanzas. Writing a v3 `io.containerd.cri.v1.runtime` stanza
# into a v2 document would be silently ignored, and a silently ignored handler
# means containerd falls back to runc while the Pod still reports Running.
#
# Appended rather than rewritten: kind's entrypoint rewrites the snapshotter
# line in this file at node start, so the base content must survive intact.
# Cgroup-driver note, corrected. An earlier version of this stanza carried
# `SystemdCgroup = true` under the runsc options, with a comment claiming it
# matched the runc handler's systemd cgroup driver. It did not:
# `runtime_type = "io.containerd.runsc.v1"` decodes its options as
# runtimeoptions.Options, whose only fields are TypeUrl, ConfigPath and
# ConfigBody. SystemdCgroup belongs to the runc **v2** options struct, so the
# key was at best inert here and at worst logged as an undecoded field — and
# the comment asserted a property this file did not actually have.
#
# The line is removed rather than relocated, because where it would need to go
# is not established: if a systemd cgroup path is genuinely required it has to
# be configured through runsc.toml or the CRI plugin's own `systemd_cgroup`,
# not through an option the shim does not read. SPIKE-01 passed with the inert
# key present, so this is a latent inconsistency and not a current outage, and
# nothing here should claim a driver match that was never measured.
#
# To settle it empirically, from inside the node, for a Pod under runsc:
#   crictl inspect <id> | jq '.info.runtimeSpec.linux.cgroupsPath'
#   systemd driver -> "kubepods-....slice:cri-containerd:<id>"
#   cgroupfs       -> "/kubepods/..."
RUN set -eux; \
    printf '\n' >> /etc/containerd/config.toml; \
    printf '%s\n' \
      '# --- gVisor, added by labs/sandbox/runsc-node/Dockerfile (SPIKE-01) ---' \
      '# Handler name `runsc` must match handler: in runtimeclass.yaml.' \
      '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]' \
      '  runtime_type = "io.containerd.runsc.v1"' \
      '  # Options for runtime_type io.containerd.runsc.v1 are' \
      '  # runtimeoptions.Options: TypeUrl, ConfigPath, ConfigBody only.' \
      '  # The cgroup driver is NOT configurable here.' \
      '  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]' \
      '    TypeUrl = "io.containerd.runsc.v1.options"' \
      '    ConfigPath = "/etc/containerd/runsc.toml"' \
      >> /etc/containerd/config.toml; \
    tail -n 12 /etc/containerd/config.toml

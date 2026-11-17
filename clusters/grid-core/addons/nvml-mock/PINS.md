# `addon-nvml-mock` — the pin register

**This file is the authority for the chart coordinate, the chart digest and every image digest the
mock-device layer applies.** `values.yaml` and the two committed object sets beside it carry copies.
`create.sh` reads the chart digest and the three image digests *out of this file*, refuses a chart
whose pulled manifest digest disagrees, and refuses an object set whose image lines are not exactly
these pins. The layer's checks file compares this register with both object sets in both directions.

Every pin below is **SPIKE-09's GO configuration, unchanged** — resolved on 2026-11-17 by plan 05-33
and recorded with its captures in `planning/lab-tests/spike-09-mokka.md` § "Pins, platform lists and
the signature". Plan 05-37 re-ran every resolving command below on 2026-11-17 on the authoring host
(Apple M1 Pro, `linux/arm64` through the Rancher Desktop VM, `docker` 29.5.2, `helm` v3.22.0), and
every digest and platform list read back identical.

The devices this layer stages are **mock devices**, served by a mock NVML library. The vendor names
in the coordinates below are the names of the projects that publish these artefacts. They say
nothing about the hardware of any machine this layer runs on.

---

## 1. The chart

| Component | Chart coordinate | Version | Chart manifest digest | App version |
|---|---|---|---|---|
| Mokka nvml-mock | `oci://ghcr.io/nvidia/k8s-test-infra/chart/nvml-mock` | `0.7.0` | `sha256:bdc18dc7071000d6b1531c107f277c1cf3569a16036c1868025f9d090e798b19` | `0.7.0` |

The chart digest equals the one in the v0.7.0 release notes. The resolving command, verbatim, and
the `Digest:` line it printed:

```
helm pull oci://ghcr.io/nvidia/k8s-test-infra/chart/nvml-mock --version 0.7.0 --destination .
  Pulled: ghcr.io/nvidia/k8s-test-infra/chart/nvml-mock:0.7.0
  Digest: sha256:bdc18dc7071000d6b1531c107f277c1cf3569a16036c1868025f9d090e798b19
```

---

## 2. Image pins — every one a manifest-list INDEX digest

Three images, which is every image the layer applies: the mock (in the chart render) and the two
consumers (in `consumers-pinned.yaml`). The **index** digest is recorded rather than a
per-architecture one, so one reference resolves on a `linux/arm64` host and on a `linux/amd64` CI
runner. `labs/tools/platform-check.sh` asserts both platforms on every one of them.

| Image reference (index digest) | Human version | Platforms the manifest list reported | Applied by |
|---|---|---|---|
| `ghcr.io/nvidia/nvml-mock@sha256:1730a101817c21a9745af75a7a1dce0b066370b24b80cd987b4fba3ae7df1042` | nvml-mock `0.7.0` | `linux/amd64` `linux/arm64` (plus an `unknown/unknown` attestation entry) | `rendered-pinned.yaml` |
| `nvcr.io/nvidia/k8s-device-plugin@sha256:b5788e29e7ae5272de8de863ebe386d6611e608421a6ecc5b4e7d5952aba637f` | device plugin `v0.18.2` | `linux/amd64` `linux/arm64` | `consumers-pinned.yaml` |
| `nvcr.io/nvidia/k8s/dcgm-exporter@sha256:60d3b00ac80b4ae77f94dae2f943685605585ad9e92fdccda3154d009ae317cc` | dcgm-exporter `4.5.3-4.8.2-distroless` | `linux/amd64` `linux/arm64` (plus an `unknown/unknown` attestation entry) | `consumers-pinned.yaml` |

**Why these versions.** The mock is the version CONTEXT D-59 names. The device plugin `v0.18.2` is
the version Mokka v0.7.0's device-plugin guide and `tests/e2e/VERSION-MATRIX.md` name.
dcgm-exporter `4.5.3-4.8.2` is the version Mokka v0.7.0's CI runs, as the GPU Operator v26.3.3
operand; the matrix lists the standalone `3.3.9-3.6.1` only as "not run", so it was not chosen.

### The resolving command, verbatim

```
docker buildx imagetools inspect ghcr.io/nvidia/nvml-mock:0.7.0
docker buildx imagetools inspect nvcr.io/nvidia/k8s-device-plugin:v0.18.2
docker buildx imagetools inspect nvcr.io/nvidia/k8s/dcgm-exporter:4.5.3-4.8.2-distroless
```

The `Digest:` line of each is the index digest, the one directly under the index media type and not
one of the per-architecture digests listed below it. The platform column is the `Platform:` lines of
the same output, read verbatim and de-duplicated.

---

## 3. The signature

The mock image is cosign-signed by its release workflow. `create.sh` verifies it **where `cosign` is
installed**, with the identity and issuer below, and refuses to apply on a failed verification. On a
host without `cosign` it prints that the signature was **not** verified and proceeds on the digest
pin alone. SPIKE-09's hosted CI arms had no `cosign`, and neither has a learner who did not install
it, so the absence is stated every time rather than implied.

| Field | Value |
|---|---|
| Certificate identity | `https://github.com/NVIDIA/k8s-test-infra/.github/workflows/nvml-mock-publish.yaml@refs/tags/v0.7.0` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |

Neither consumer image is signature-checked here. Their release notes name no signature this layer
could verify, so they rest on their index-digest pins.

---

## 4. What Mokka itself says it does not prove

Mokka's README at v0.7.0 says to use real hardware for "CUDA execution, NCCL, GPUDirect and RDMA data
paths, any throughput or thermal measurement, driver and firmware lifecycle, switch management
planes, physically faithful fault timing, MIG partition lifecycle, and Confidential Computing". This
layer adds none of those. Allocation on it is real Kubernetes accounting over mock devices; an Xid on
it is a value written to an override file and replayed through the mock's event set.

# `m1` — the pin register

**This file is the authority for every image the Module 1 lab pulls.** The manifests in this
directory carry copies. Each reference below is a manifest-list **index digest**, never a
per-architecture digest, so the same line resolves on `linux/arm64` and on `linux/amd64`.

**Resolution date for everything below: 2026-10-24.** Resolved on the authoring host (Apple M1 Pro,
`linux/arm64` through the Rancher Desktop VM). Raw captures are under
`planning/lab-tests/raw/m1/spike/` in the source repository.

## 1. The three images

| Role | Reference | Human version | Platforms | Where it appears |
|---|---|---|---|---|
| inference simulator, mounted as an `image` volume and never run as a container image | `ghcr.io/llm-d/llm-d-inference-sim@sha256:32144df791330a0006b747edfdf2b114a0fe728e023a9d1b3463eeb48d32abb9` | v0.11.2 | `linux/amd64` `linux/arm64` | `simulator.yaml`, `volumes[].image.reference` |
| CPU metrics for the HPA | `registry.k8s.io/metrics-server/metrics-server@sha256:d9862115e7c7881280d3d75ca26bda8ffc0fc213315979575bf23ce9826205c0` | v0.9.0 | `linux/amd64` `linux/arm/v7` `linux/arm64/v8` `linux/ppc64le` `linux/s390x` | `metrics-server.yaml` |
| the shell that starts the simulator and sends test traffic, plus the never-scheduled device Pod | `docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | 1.37.0 | `linux/386` `linux/amd64` `linux/arm/v5` `linux/arm/v6` `linux/arm/v7` `linux/arm64/v8` `linux/ppc64le` `linux/riscv64` `linux/s390x` | `simulator.yaml`, `client.yaml`, `device-request.yaml` |

## 2. The resolving commands, verbatim

The simulator digest was **not re-resolved**. It is reused from `labs/serving/sim-router/sim.yaml`
and inspected only to read its platform list.

```
docker buildx imagetools inspect registry.k8s.io/metrics-server/metrics-server:v0.9.0
docker buildx imagetools inspect busybox:1.37.0
docker buildx imagetools inspect ghcr.io/llm-d/llm-d-inference-sim@sha256:32144df791330a0006b747edfdf2b114a0fe728e023a9d1b3463eeb48d32abb9
```

The `Digest:` line of the first two is the value in the table. Attestation entries reading
`unknown/unknown` are omitted from the platform lists.

## 3. The edits made to the upstream metrics-server manifest

`metrics-server.yaml` is the upstream `components.yaml` release asset for v0.9.0
(`https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml`),
with exactly two changes:

1. The image, named by tag upstream (`registry.k8s.io/metrics-server/metrics-server:v0.9.0`), is
   replaced by the index digest in the table above.
2. `--kubelet-insecure-tls` is added to the container arguments, because kind's kubelet serves a
   self-signed certificate. This edit is **unproven until the live lab run**. If the run shows it is
   wrong or unnecessary, the run records that.

## 4. Why the simulator is a volume

The simulator image has no shell and runs as user `65532:65532`. Its binary is statically linked, so
it runs unchanged from any mount point. The `image` volume source is stable since Kubernetes 1.36 and
needs no feature gate on the 1.37 kubelet in `grid-core`.

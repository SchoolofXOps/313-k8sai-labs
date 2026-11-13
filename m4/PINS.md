# `m4` — the pin register

**This file is the authority for every image the Module 4 lab references.** The manifests in this
directory carry copies. Each reference below is a manifest-list **index digest**, never a
per-architecture digest, so the same line resolves on `linux/arm64` and on `linux/amd64`.

**Resolution date for everything below: 2026-11-11.** Resolved on the authoring host (Apple M1 Pro,
`linux/arm64` through the Rancher Desktop VM).

## 1. The images

| Role | Reference | Human version | Platforms | Where it appears |
|---|---|---|---|---|
| the shell for every Pod that prints its environment (`env`) | `docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | 1.37.0 | `linux/386` `linux/amd64` `linux/arm/v5` `linux/arm/v6` `linux/arm/v7` `linux/arm64/v8` `linux/ppc64le` `linux/riscv64` `linux/s390x` | `attr-pods.yaml`, `extended-resource-bridge.yaml`, `sharing-exclusive.yaml`, `sharing-shared-claim.yaml`, `dd-prepare.yaml`, and the deep dive's `kubectl debug` image |
| the holder for every Pod that needs no shell | `registry.k8s.io/pause@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a` | 3.10 | `linux/amd64` `linux/arm/v7` `linux/arm64` `linux/ppc64le` `linux/s390x` `windows/amd64` | `count-pods.yaml`, `lifecycle-holder.yaml`, `readiness-probe.yaml`, `attr-unsatisfiable.yaml`, `sharing-counter-*.yaml`, `sharing-capacity.yaml`, `health-watch.yaml`, `dd-status.yaml`, `dd-taint-victim.yaml` |
| the synthetic-device driver, as the `addon-dra` layer installs it | `registry.k8s.io/dra-example-driver/dra-example-driver@sha256:c1488eb51e086bd6b885a667c7d059382844e54e5917a71bcf734c04edfbb62f` | v0.5.0 | as recorded in `planning/lab-tests/03-addon-dra.md` | not in this directory; read from `clusters/grid-core/addons/dra/create.sh` (`DRIVER_IMAGE_DIGEST`) and never re-resolved here |
| the broken driver revision in part 2 | `registry.k8s.io/dra-example-driver/dra-example-driver@sha256:` followed by 63 zeros and a `1` | none | none — it resolves to nothing, on purpose | the `kubectl set image` step on the lab page |

The pause image is already present on a kind v1.37 node, so the Pods that use it pull nothing.

## 2. The resolving commands, verbatim

```
docker buildx imagetools inspect registry.k8s.io/pause:3.10
docker buildx imagetools inspect busybox:1.37.0
```

The `Digest:` line of each is the value in the table. The busybox digest is the one Module 1 pinned
(`m1/PINS.md`) and was not re-resolved; its platform list is copied from there. The pause digest
was re-read on 2026-11-11 and matches the one `planning/lab-tests/03-addon-dra.md` records.
Attestation entries reading `unknown/unknown` are omitted from the platform lists.

## 3. The broken revision is a digest on purpose

The part 2 failure needs an image that never pulls, so that no new code runs on the node. It is
written in digest form, `sha256:` and 64 hex characters, so the course's pin gate (STANDARDS.md
C17) has nothing to report and no tag can ever be published under it.

# `m5` — the pin register

**This file is the authority for every image the Module 5 lab references.** The manifests in this
directory carry copies. Each reference below is a manifest-list **index digest**, never a
per-architecture digest, so the same line resolves on `linux/arm64` and on `linux/amd64`.

**Nothing here was re-resolved for Module 5.** Every digest is copied from a register that already
recorded it: the pause digest from `m4/PINS.md` (resolved there on 2026-11-11), and the two
controller images from the layer scripts that install them. Copying instead of re-resolving keeps
one authority per pin.

## 1. The images

| Role | Reference | Human version | Platforms | Where it appears |
|---|---|---|---|---|
| the holder for every Pod in this module — every group, every Job, the deep dive's gangs | `registry.k8s.io/pause@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a` | 3.10 | `linux/amd64` `linux/arm/v7` `linux/arm64` `linux/ppc64le` `linux/s390x` `windows/amd64` (as `m4/PINS.md` records) | `collision-probe.yaml`, `webhook-probe.yaml`, `research-steady.yaml`, `gang-unqueued.yaml`, `gang-queued.yaml`, `research-batch.yaml`, `product-serve.yaml`, `ghost.yaml`, `devices-before.yaml`, `devices-over-quota.yaml`, `topology-gangs.yaml`, `block-gang-refused.yaml`, `scatter-gang.yaml`, `quota-incident.yaml`, `dd-core-gang.yaml`, `dd-oversized-gang.yaml`, `dd-kueue-same-gang.yaml`, `dd-precreated-claim.yaml` |
| the queueing controller, as the `addon-kueue-kwok` layer installs it | Kueue v0.20.6, `KUEUE_IMAGE_DIGEST` in `clusters/grid-core/addons/kueue-kwok/create.sh` | v0.20.6 | as recorded in `planning/lab-tests/06-kueue-v0206.md` | not in this directory; the lab reads the running Pod's own image into `grid-platform/clusters/addon-kueue-kwok/PROFILE.md` |
| the synthetic-device driver, as the `addon-dra` layer installs it | `DRIVER_IMAGE_DIGEST` in `clusters/grid-core/addons/dra/create.sh` | v0.5.0 | as recorded in `planning/lab-tests/03-addon-dra.md` | not in this directory, and never re-resolved here |

The pause image is already present on a kind v1.37 node, so the Pods that use it pull nothing, and
on the simulated fleet nothing is pulled at all: kwok fakes the kubelet, so no container runs there.

## 2. No other image

No Pod in this module prints its environment, so the busybox image Module 4 pins is not used here.
No file in this directory holds a Kueue `Configuration` (`config.kueue.x-k8s.io/v1beta2`): the lab
edits the running Configuration live, in a scratch directory outside the clone, and restores it.

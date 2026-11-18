# `m6` — the pin register

**This file is the authority for every image the Module 6 lab and deep dive reference.** The
manifests in this directory carry copies. Each reference below is a manifest-list **index digest**,
never a per-architecture digest, so the same line resolves on `linux/arm64` and on `linux/amd64`.

**Nothing here was re-resolved for Module 6.** Every digest is copied from a register that already
recorded it: busybox and pause from `m4/PINS.md` (resolved there on 2026-11-11), and the three
storage images from the four-path harness, `storage/four-path/run.sh`, whose defaults
`planning/lab-tests/spike-02-storage.md` resolved and recorded. Copying instead of re-resolving
keeps one authority per pin, and Phase 6 CONTEXT D-02 holds all of them: SPIKE-02 and plan 03-05
ran on these digests, and a bump would forfeit that evidence for no lab-visible gain.

## 1. The images

| Role | Reference | Human version | Platforms | Where it appears |
|---|---|---|---|---|
| the Pod that prints its environment, so the lab reads what both drivers injected | `docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | 1.37.0 | as `m4/PINS.md` records | `accel-and-nic-pod.yaml` |
| the holder for the Pod whose claim can never be allocated | `registry.k8s.io/pause@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a` | 3.10 | as `m4/PINS.md` records | `split-roots.yaml` |
| the `s3` path's server | `chrislusf/seaweedfs@sha256:d24be3bc1d6e8e305c095c446cb9a00d40e3afdac82fb2a1cc96f2d42c4a8e80` | 4.03 | `linux/amd64` `linux/arm64` (SPIKE-02 `digest-images.log`) | not in this directory: `S3_IMAGE` in `storage/four-path/run.sh` |
| the `nfs` path's server | `registry.k8s.io/sig-storage/nfs-provisioner@sha256:c825f3d5e28bde099bd7a3daace28772d412c9157ad47fa752a9ad0baafc118d` | v4.0.8 | `linux/amd64` `linux/arm64` (SPIKE-02 `digest-images.log`) | not in this directory: `NFS_IMAGE` in `storage/four-path/run.sh` |
| the probe client for every path, and the deep dive's checkpoint-storm writers | `python@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a` | 3.13-alpine | `linux/amd64` `linux/arm64` (SPIKE-02 `digest-images.log`) | `CLIENT_IMAGE` in `storage/four-path/run.sh`; `checkpoint-storm.sh` **reads it from there at run time** and never retypes it |
| both example-driver releases, the synthetic device's and the synthetic NIC's | `DRIVER_IMAGE_DIGEST` in `clusters/grid-core/addons/dra/create.sh` | v0.5.0 | as recorded in `planning/lab-tests/03-addon-dra.md` | not in this directory: `addons/dra-nic/` reads it out of `addons/dra/create.sh` (Phase 6 CONTEXT D-50) |

The busybox and pause images are pulled once onto the one real worker. The three storage images
are pulled when the storage layer is first applied, which is why the measuring invocation in the
lab, coming after the layer, pulls nothing.

## 2. Why the storm script reads its image instead of carrying it

`checkpoint-storm.sh` runs the harness's own generated probe in the harness's own client image, on
the harness's own RWX claim. If it carried a second copy of the client digest, a harness bump would
leave the storm writing with one image while the four-path table was taken with another, and the
two records side by side in the platform repository would no longer be comparable. So it reads
`CLIENT_IMAGE`'s default out of `storage/four-path/run.sh`, refuses to run if that value is not an
`@sha256` index digest, and writes the value it used into its own record.

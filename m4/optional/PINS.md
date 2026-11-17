# PINS — M4's optional lab (HAMi v2.11.0 on mock devices)

The register for `install-hami.sh`. Every row was measured in SPIKE-10
(`planning/lab-tests/spike-10-hami.md` § "Pins, platform lists, the chart and the values layout"):
each image index carries `linux/amd64` and `linux/arm64`, read with `docker buildx imagetools
inspect` on three arms. `install-hami.sh` reads these rows; a second copy of a digest elsewhere is a
second authority, so `values.yaml` is asserted against this file before anything renders.

## 1. The chart

| Component | Source | Version | sha256 |
|---|---|---|---|
| HAMi chart | `https://github.com/Project-HAMi/HAMi/releases/download/v2.11.0/hami-2.11.0.tgz` | `2.11.0` | `2530d25ba1a953a5ffa8070c308a373f756c6108c5bb39fce49943f614dd9315` |

The release asset of the tag, never a branch build. The sha256 equals the Releases API's asset
digest. HAMi's release body names no image signature, so the images below rest on their index
digests alone.

## 2. Images

| Image (index digest) | Used by |
|---|---|
| `docker.io/projecthami/hami:v2.11.0@sha256:caab978ed50e53163c31ed7c4650c4e6e5d8facf157f377c26e021ff5fa3e5ce` | scheduler extender, device plugin, vgpu-monitor |
| `registry.k8s.io/kube-scheduler:v1.37.0@sha256:a27622f132aa09cf2461ba077894a070c0186ec607366d14e805912d4804d11f` | the chart's kube-scheduler container, pinned to the cluster's own version |
| `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9@sha256:01038e7de14b78d702d2849c3aad72fd25903c4765af63cf16aa3398f5d5f2dd` | the chart's two webhook-certificate Jobs |
| `docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | the lab's Pods (the image M4 already uses) |

## 3. What the devices are

The devices HAMi registers on this profile are **mock devices**, served by Mokka's mock NVML library
(`labs/clusters/grid-core/addons/nvml-mock/`, applied with `NVML_MOCK_CONSUMERS=none`). Their
product name, memory size and UUIDs are values in the mock's `t4` profile file. HAMi reads them
through NVML and repeats them. **Nothing in this lab runs CUDA**, so HAMi-core, the library that
would hold a process to its memory and core share, is never exercised. Every Pod sets
`CUDA_DISABLE_CONTROL=true`, as HAMi's Lab 5 does, and at v2.11.0 that keeps HAMi-core out of the
container altogether. What this lab shows is admission and placement by accounting.

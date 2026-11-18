# `addon-dra-nic` — the pin register

**This layer pins nothing of its own.** It runs a second release of the same driver build
`addon-dra` runs, and `create.sh` reads every pin below out of `../dra/create.sh`'s own defaults at
run time. That file is the authority. This register records what those defaults read on the day the
layer was built, so a reviewer can see the pins without running anything, and it records the
resolving commands so anyone can check them.

The devices this layer stages are **synthetic NICs**, published by the upstream example driver's
`net` profile. There is no network card behind any of them. The names the driver gives them (`nic-N`),
its model string (`LATEST-NET-MODEL`) and its `100G` bandwidth capacity are constants in the driver's
source and describe no hardware on any machine this layer runs on.

Read and re-resolved on 2026-11-18 by plan 06-09 on the authoring host (Apple M1 Pro, `linux/arm64`
through the Rancher Desktop VM, `helm` v3.22.0). The captures are in
`planning/lab-tests/raw/06-addon-dra-nic/`, files `00-ls-remote.txt` and `00-imagetools-inspect.txt`.

---

## 1. The chart

| Field | Value | Read from |
|---|---|---|
| Repository | `https://github.com/kubernetes-sigs/dra-example-driver.git` | `../dra/create.sh` `CHART_REPO` |
| Git tag | `v0.5.0` | `../dra/create.sh` `CHART_TAG` |
| Commit the tag names | `93ff610f3c3bfd603c592d1c281a236c1463edb9` | `../dra/create.sh` `CHART_COMMIT_EXPECTED` |
| Chart directory | `deployments/helm/dra-example-driver` (in-tree, `version: 0.0.0-dev`) | `../dra/create.sh` `CHART_SUBDIR` |
| Release and namespace | `dra-example-driver-nic` | this layer's `create.sh` (Phase 6 CONTEXT D-50) |

The resolving command, verbatim, and what it printed. The tag is an annotated tag; the `^{}` line is
the commit it names:

```
git ls-remote https://github.com/kubernetes-sigs/dra-example-driver.git 'refs/tags/v0.5.0*'
  a5becae6747f276969dc88d2b23f826a9bb6728a	refs/tags/v0.5.0
  93ff610f3c3bfd603c592d1c281a236c1463edb9	refs/tags/v0.5.0^{}
```

---

## 2. The one image — a manifest-list INDEX digest

| Image reference (index digest) | Human version | Platforms the manifest list reported | Applied by |
|---|---|---|---|
| `registry.k8s.io/dra-example-driver/dra-example-driver@sha256:c1488eb51e086bd6b885a667c7d059382844e54e5917a71bcf734c04edfbb62f` | `v0.5.0` | `linux/amd64` `linux/arm64` `linux/ppc64le` | `rendered-pinned.yaml` (and `addon-dra`'s) |

The **index** digest is recorded, not a per-architecture one, so one reference resolves on a
`linux/arm64` host and on a `linux/amd64` CI runner. `labs/tools/platform-check.sh` asserts both
platforms on it. Because it is the same image `addon-dra` already pulled, applying this layer onto a
node that carries `addon-dra` pulls no new image bytes.

The resolving command, verbatim:

```
docker buildx imagetools inspect registry.k8s.io/dra-example-driver/dra-example-driver:v0.5.0
```

Its `Digest:` line, the one directly under the index media type, is the index digest above. The
platform column is its `Platform:` lines, read verbatim.

---

## 3. The values this layer sets

| Value | Setting | Why |
|---|---|---|
| `driverName` | `sim-nic.example.com` | the one name the layer controls; differs from `addon-dra`'s so the CDI vendor, socket directory and DeviceClass do not collide |
| `deviceProfile` | `net` | upstream's simulated network devices |
| `kubeletPlugin.numDevices` | `4` | four synthetic NICs per worker |
| `netPublishPCIeRoot` | `true` | publishes `resource.kubernetes.io/pcieRoot`; the chart default is `false` |

`values.yaml` carries the reasons in full, with the upstream line citations.

---

## 4. What this layer does not prove

Allocation on it is real Kubernetes accounting, and preparation is a real kubelet-plugin call that
writes a CDI spec and injects environment variables into the container. Nothing in it carries a
packet, measures a link, or models SR-IOV, RDMA or any network data path. The `100G` capacity is a
number the driver publishes, not a speed anything was measured at.

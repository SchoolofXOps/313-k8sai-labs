# 313 — Lab assets

Learner-facing lab tree for **Ultimate Kubernetes for AI Infrastructure & Platform Engineering**.

Course site: <https://schoolofxops.github.io/313-k8sai-site/>

Clone this repository and work from its root — every command on the course's setup page and in
every lab is relative to that root.

## What runs on what

Everything here is designed for a **CPU-only laptop**: no GPU, no cloud account, no Docker Desktop.
The declared environment for every measurement is a Rancher Desktop VM pinned to **8 GB / 5 CPU** on
Apple Silicon, Kubernetes **1.37.0** via kind **v0.33.0**.

Set `SIZE=8` or `SIZE=16` to match your machine. The scripts read it, and refuse rather than guess
if it is set to anything else.

## The cluster profiles

One profile runs at a time — the 8 GB budget does not fit two. Each profile ships the same three
scripts, so the signal you learn to look for on one works on all of them.

| Path | What it is |
|---|---|
| `clusters/grid-core/` | The base profile — the pinned kind cluster the course builds on. `create.sh`, `verify.sh`, `teardown.sh` |
| `clusters/grid-sandbox/` | A separate profile carrying the gVisor `runsc` runtime, for the sandboxed-workload labs. Its teardown rebuilds and re-verifies the base profile |

### The layers you apply onto the base cluster

Each layer is additive, applied on top of the base profile one at a time, and ships the same
`create.sh` / `verify.sh` / `teardown.sh` triple. A layer's `teardown.sh` removes the layer and
leaves the cluster standing; the base profile's `teardown.sh` deletes the cluster.

| Path | What it adds |
|---|---|
| `clusters/grid-core/addons/dra/` | Synthetic devices via the upstream DRA example driver, with the device-health path |
| `clusters/grid-core/addons/kueue-kwok/` | Kueue quota and gang admission (`kueue.x-k8s.io/v1beta2`), against a KWOK-simulated fleet joined to the real scheduler |
| `clusters/grid-core/addons/dataplane/` | The storage and data-path harness |
| `clusters/grid-core/addons/serving/` | The inference simulator and the prefix-cache-aware router. **Requires `SIZE=16`** — at `SIZE=8` it reports its fence and applies nothing, and points you at a read-along instead |
| `clusters/grid-core/addons/ops/` | The operations layer — metrics, dashboards and cost |

## Where your work accumulates

`grid-platform/` is the repository you grow by hand, one layer per module. It ships as **twelve
documented addresses and no lab artifacts** — each directory's `README.md` says what lands there,
which module writes it, and what does **not** land there. That is deliberate: a provided snapshot
would hand you the state the labs exist to make you produce.

## Shared helpers

| Path | What it is |
|---|---|
| `tools/pinned-bin.sh` | The single place a tool pin is asserted — `kind`, `kubectl` and the `helm` floor. Every script that touches a cluster sources it and re-implements no version check |
| `tools/size-gate.sh` | The single place `SIZE` is validated |
| `tools/lab-sizes.json` | The machine-readable size table the gate reads |
| `tools/platform-check.sh` | Asserts the pinned image references are multi-architecture |
| `tools/measure.sh` | Peak-RSS measurement via cgroup v2 `memory.peak` |

## Honesty rules these assets follow

The course has a **Truth Contract**, and these assets are written to it:

- **A synthetic device is never called a GPU.** The upstream DRA example driver names its devices
  `gpu-0` and advertises `model: LATEST-GPU-MODEL` with an 80Gi "memory" capacity. None of that is a
  GPU or memory on any device. Where the driver's own output appears, it is captioned as synthetic.
- **No measured number appears without the environment it was measured in.**
- **The simulator is a simulator.** Results from the serving layer are *modelled* or *demonstrated*,
  never *measured* as real model performance.

## Prerequisites

Rancher Desktop (Moby/dockerd engine), `kind` v0.33.0, `kubectl` on the v1.37 line, `helm` v3.8.0 or
newer — either major — and `git`.

Scripts resolve their own pinned binaries rather than trusting `PATH`: a stale `kind` earlier on
`PATH` than the pinned one is a real and silent failure mode, so `create.sh` hard-asserts its
version. Override the search prefix with `LAB_BIN_PREFIX` if your pinned binaries live elsewhere.

The course's setup page has the full install, with checksum-verified downloads.

## Start here

```bash
export SIZE=8
export KUBECONFIG=/tmp/grid-core.kubeconfig

bash clusters/grid-core/create.sh
bash clusters/grid-core/verify.sh
# ... run a lab ...
bash clusters/grid-core/teardown.sh
```

`verify.sh` prints one `OK:` line when the cluster is what it should be, and a `FAIL:` line naming
what is wrong when it is not. Run **one cluster profile at a time**.

## Licence and feedback

Issues and corrections welcome. Course content is authored in a private source repository; this
repository carries the runnable assets only.

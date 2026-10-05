# 313 — Lab assets

Learner-facing lab tree for **Ultimate Kubernetes for AI Infrastructure & Platform Engineering**.

Course site: <https://schoolofxops.github.io/313-k8sai-site/>

> **Status: pre-release.** These are the de-risking spike assets from Phase 1, not yet the
> curated per-module labs. They run, and every number the course quotes from them was measured
> on the environment declared in the course's lab-test records — but the per-module structure
> (`m1/`, `m2/`, …, with `checks.json` per module) lands in a later phase.

## What runs on what

Everything here is designed for a **CPU-only laptop**: no GPU, no cloud account, no Docker Desktop.
The declared environment for every measurement is a Rancher Desktop VM pinned to **8 GB / 5 CPU**
on Apple Silicon, Kubernetes **1.37.0** via kind **v0.33.0**.

| Path | What it is |
|---|---|
| `clusters/spike-core/` | The pinned kind cluster — `create.sh`, `verify.sh`, `teardown.sh` |
| `tools/measure.sh` | Peak-RSS measurement via cgroup v2 `memory.peak` |
| `kwok/attach/` | KWOK v0.8.0 joined in-cluster so the **real** scheduler decides |
| `storage/four-path/` | Four-path storage harness — s3 · NFS · PVC · hostPath |
| `serving/sim-router/` | Inference simulator + prefix-cache-aware router, Standalone Mode |
| `sandbox/runsc-node/` | Custom kind node image carrying gVisor `runsc` |
| `sandbox/agent-sandbox/` | Agent Sandbox `agents.x-k8s.io/v1beta1` |

## Honesty rules these assets follow

The course has a **Truth Contract**, and these assets are written to it:

- **A synthetic device is never called a GPU.** The upstream DRA example driver names its devices
  `gpu-0` and advertises `model: LATEST-GPU-MODEL` with an 80Gi "memory" capacity. None of that is
  a GPU or memory on any device. Where the driver's own output appears, it is captioned as synthetic.
- **No measured number appears without the environment it was measured in.**
- **The simulator is a simulator.** Results from `serving/sim-router/` are *modelled* or
  *demonstrated*, never *measured* as real model performance.

## Prerequisites

Rancher Desktop (Moby/dockerd engine), `kind` v0.33.0, `kubectl` 1.37.x, `helm` 3+ with OCI support.

Scripts resolve their own pinned binaries rather than trusting `PATH` — a stale `kind` earlier on
`PATH` than the pinned one is a real and silent failure mode, so `create.sh` hard-asserts its version.

## Start here

```bash
bash clusters/spike-core/create.sh
bash clusters/spike-core/verify.sh
# ... run a lab ...
bash clusters/spike-core/teardown.sh
```

Run **one cluster profile at a time** — the 8 GB budget does not fit two.

## Licence and feedback

Issues and corrections welcome. Course content is authored in a private source repo; this
repository carries the runnable assets only.

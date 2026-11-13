# `labs/m11/` — pins

Every image this module's lab and deep dive run is named by its **manifest-list index digest**
(STANDARDS C17), so the same manifest resolves on `linux/arm64` and `linux/amd64`. The one exception
is the controller image inside the upstream asset, which this course does not edit; it is pinned by
reading the running Pod, below.

## Images

| Role | Reference | Where it was resolved |
|---|---|---|
| busybox 1.37.0, for `probe-sandbox`, `latency-1`…`latency-5`, `probe-plain`, `mcp-client`, `reap-demo`, `ctb-reader` and the deep dive's node debug Pod | `docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | resolved live 2026-10-05 for SPIKE-01 (`labs/sandbox/agent-sandbox/sandbox.yaml`) and carried by `planning/plans/m11-plan.md` § 8 |
| python, standard library only, for `mcp-server` and `actor` | `docker.io/library/python@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a` | fixed by `planning/plans/m11-plan.md` § 8 (plan 05-05). The live run re-reads its platform list with `docker buildx imagetools inspect` and records it in `planning/lab-tests/m11.md` |
| the Agent Sandbox controller, as `sandbox.yaml` names it | `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.5`, index digest `sha256:28a9cbdbfd6ac0a4e5c7e9261ace1aa30ee2da681cb640dccdfed98e8dd9d98b` (`linux/amd64`, `linux/arm64`) | `planning/lab-tests/raw/spike-01/arm64/07-controller-image-platforms.log`. The asset names it **by tag** and its sha256 pins the manifest's text, not the image's bytes, so `checks.json` → `controller-image-digest-pinned` reads the running Pod's `imageID` against this digest |

## Upstream assets

| Asset | Pin | Used how |
|---|---|---|
| Agent Sandbox **v1.0.5** `sandbox.yaml` (released 2026-10-01) | sha256 `e89fd95c0aa57609fa24be4112bd52ce67fe8939ecf6f3c17edf2f1e8f1eb860`, re-verified 2026-11-11 | applied by `labs/sandbox/agent-sandbox/install.sh` with `CONTEXT=kind-grid-sandbox`, after its sha256 gate. One CRD, `sandboxes.agents.x-k8s.io`, serving `agents.x-k8s.io/v1beta1` only |
| Agent Sandbox v1.0.5 `extensions.yaml` | sha256 `071d4966a085cf0b70a7b4786ed4c48351a133c10beae1a01ad921515952d40d`, read 2026-11-11 | **never applied.** Its CRD schemas were read to write `warm-pool.yaml`'s fields. It sits outside this module's install fence (Phase 5 CONTEXT D-23) |
| gVisor | `release-20260928.0` | baked into the `grid-sandbox` node image by `labs/sandbox/runsc-node/build.sh` (per-arch tarball and `SHA256SUMS`) |
| Kubernetes node image base | `kindest/node` v1.37.0 by index digest | in `labs/sandbox/runsc-node/Dockerfile`; the built image `313-grid-sandbox-node:v1.37.x-runsc` is the one enumerated C17 exemption |

The latest Agent Sandbox release read on 2026-11-10 was v1.0.10. It is not taken (Phase 5 CONTEXT
D-25): every measurement this module rests on was taken at v1.0.5, and every object name in this
directory is 63 characters or shorter, so a later bump past v1.0.6's name-length validation cannot
break the lab.

## Files

| File | Applied by | Notes |
|---|---|---|
| `namespaces.yaml` | lab | `agent-probes`, `agent-mcp`, `agent-actor`, `agent-target`; only the last three are audited |
| `probe-sandbox.yaml`, `latency-sandbox.yaml`, `probe-plain.yaml` | lab | the sandboxed workload, the five timed creates, the comparison Pod |
| `probe-matrix.sh`, `probe-table.sh` | lab, through `kubectl exec -i … sh -s` and on the host | the fixed probe, and the join into the table |
| `egress-deny.yaml`, `egress-allow-443.yaml` | lab | the deny-then-allow pair |
| `mcp-server.py`, `mcp-server.yaml`, `mcp-rbac.yaml`, `mcp-client.yaml` | lab | the tool server, its identity, its caller |
| `actor.py`, `actor.yaml`, `actor-rbac.yaml`, `target-settings.yaml` | lab | the scripted actor and the setting it wants changed |
| `warm-pool.yaml` | **nobody** | read with `cat`; never applied, never committed to the learner's repository |
| `dd-reap-demo.yaml`, `dd-cluster-trust-bundle.yaml` | deep dive | idle reaping; an admin-published `ClusterTrustBundle` with no signer, and the Pod that reads it |
| `checks.json`, `deep-dive.checks.json` | the course's lab runner | object state only, `REAL` |

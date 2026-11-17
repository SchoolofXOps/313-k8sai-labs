# `labs/m11/` — pins

Every image this module's lab and deep dive run is named by its **manifest-list index digest**
(STANDARDS C17), so the same manifest resolves on `linux/arm64` and `linux/amd64`. The one exception
is the controller image inside the upstream asset, which this course does not edit; it is pinned by
reading the running Pod, below.

## Images

| Role | Reference | Where it was resolved |
|---|---|---|
| busybox 1.37.0, for `probe-sandbox`, `latency-1`…`latency-5`, `suspend-demo`, `probe-plain`, `mcp-client`, `reap-demo`, `ctb-reader` and the deep dive's node debug Pod | `docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | resolved live 2026-10-05 for SPIKE-01 (`labs/sandbox/agent-sandbox/sandbox.yaml`) and carried by `planning/plans/m11-plan.md` § 8 |
| python, standard library only, for `mcp-server` and `actor` | `docker.io/library/python@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a` | fixed by `planning/plans/m11-plan.md` § 8 (plan 05-05). The live run re-reads its platform list with `docker buildx imagetools inspect` and records it in `planning/lab-tests/m11.md` |
| the Agent Sandbox controller, as `sandbox.yaml` names it | `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.11`, index digest `sha256:73cb162407cddf73f4cd063b02bdee2dac86aa342bbc40bd99a9f023e69b31ed` (`linux/amd64`, `linux/arm64`) | resolved 2026-11-17 with `docker buildx imagetools inspect`, `planning/lab-tests/raw/05-addition/agent-sandbox-repin/04-controller-v1.0.11-imagetools.txt`. The asset names it **by tag** and its sha256 pins the manifest's text, not the image's bytes, so `checks.json` → `controller-image-digest-pinned` reads the running Pod's `imageID` against this digest |

## Upstream assets

| Asset | Pin | Used how |
|---|---|---|
| Agent Sandbox **v1.0.11** `sandbox.yaml` (released 2026-11-12) | sha256 `4c54dc1284e9d34e9a00b88de2cb0f098f2dbce4ade814616fd49d44cfd5d1c2`, 207211 bytes, read from the downloaded asset 2026-11-17 and equal to the releases API's asset digest | applied by `labs/sandbox/agent-sandbox/install.sh` with `CONTEXT=kind-grid-sandbox`, after its sha256 gate. CRD count: exactly 1, `sandboxes.agents.x-k8s.io`, group `agents.x-k8s.io`, serving `v1beta1` only (served and storage). Its schema carries `spec.operatingMode` (`Running` \| `Suspended`, default `Running`) and `spec.volumeClaimTemplates` (at most 128), the two fields the suspend/resume step uses. Seven objects: Namespace, ServiceAccount, ClusterRoleBinding, Service (`metrics`, 8080), Deployment, the CRD, ClusterRole (`planning/lab-tests/raw/05-addition/agent-sandbox-repin/03-v1.0.11-sandbox-yaml-census.txt`) |
| Agent Sandbox v1.0.11 `extensions.yaml` | sha256 `58623d40a12ab79944d219662d4e0d50daab909353bb98c6b897d43e91810886`, read 2026-11-17 | **never applied.** Its CRD schemas were read to confirm `warm-pool.yaml`'s fields, unchanged from v1.0.5. It sits outside this module's install fence (Phase 5 CONTEXT D-23) |
| gVisor | `release-20260928.0` | baked into the `grid-sandbox` node image by `labs/sandbox/runsc-node/build.sh` (per-arch tarball and `SHA256SUMS`) |
| Kubernetes node image base | `kindest/node` v1.37.0 by index digest | in `labs/sandbox/runsc-node/Dockerfile`; the built image `313-grid-sandbox-node:v1.37.x-runsc` is the one enumerated C17 exemption |

The pin moved from v1.0.5 to **v1.0.11** on 2026-11-17 (Phase 5 CONTEXT D-63, plan 05-34, which
supersedes D-25's decision to hold v1.0.5). v1.0.11 was the latest release on the releases API that
day. The suspend/resume step needs v1.0.9 or later: #2079 stops a suspended Sandbox reporting
`Finished=True`, and #1775 adds the suspend and resume metrics. Every object name in this directory,
and every `volumeClaimTemplates` name, is 63 characters or shorter, so v1.0.6's Sandbox name rule
(#1475) and v1.0.9's claim-template name rule (#1886) cannot reject them. The measurements this
module's pages show were taken at v1.0.5; the live re-run on v1.0.11 (plan 05-43) replaces them, and
until it lands `planning/lab-tests/m11.md` § "Re-pin" records which blocks are pending.

## Files

| File | Applied by | Notes |
|---|---|---|
| `namespaces.yaml` | lab | `agent-probes`, `agent-mcp`, `agent-actor`, `agent-target`; only the last three are audited |
| `probe-sandbox.yaml`, `latency-sandbox.yaml`, `probe-plain.yaml` | lab | the sandboxed workload, the five timed creates, the comparison Pod |
| `suspend-sandbox.yaml` | lab | the Sandbox that is suspended and resumed: `runsc`, one claim template `workspace` mounted at `/data` |
| `probe-matrix.sh`, `probe-table.sh` | lab, through `kubectl exec -i … sh -s` and on the host | the fixed probe, and the join into the table |
| `egress-deny.yaml`, `egress-allow-443.yaml` | lab | the deny-then-allow pair |
| `mcp-server.py`, `mcp-server.yaml`, `mcp-rbac.yaml`, `mcp-client.yaml` | lab | the tool server, its identity, its caller |
| `actor.py`, `actor.yaml`, `actor-rbac.yaml`, `target-settings.yaml` | lab | the scripted actor and the setting it wants changed |
| `warm-pool.yaml` | **nobody** | read with `cat`; never applied, never committed to the learner's repository |
| `dd-reap-demo.yaml`, `dd-cluster-trust-bundle.yaml` | deep dive | idle reaping; an admin-published `ClusterTrustBundle` with no signer, and the Pod that reads it |
| `checks.json`, `deep-dive.checks.json` | the course's lab runner | object state only, `REAL` |

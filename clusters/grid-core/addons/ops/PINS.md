# `addon-ops` — the pin register

**This file is the authority for every chart coordinate, chart digest and image digest the
operations layer installs.** `values.yaml` beside it carries copies; `create.sh` reads the chart
digests *out of this file* and refuses to install a chart whose pulled manifest digest disagrees.

## Why this file exists at all, when no other layer in this profile has one

Every other pin in this project traces back to a Phase-1 spike record that *shows* its resolution —
the command, the output, the date. **This layer had no Phase-1 spike.** Nothing measured its memory
cost, nothing resolved its image digests, and the project's own technology table names versions
without digests and flags OCI chart coordinates as unconfirmed on its own pre-recording checklist.

So the provenance that would live in a spike record lives here instead: per image, the resolving
command **verbatim**, the date it was run, and the platform list the manifest reported. A digest
with no record of how it was obtained is a number somebody has to trust.

**Resolution date for everything below: 2026-10-14.** Every command was run on the authoring host
(`MacBookPro18,3`, Apple M1 Pro, `linux/arm64` through the Rancher Desktop VM) against the public
registries, with `docker` 29.5.2 and `helm` v4.2.3.

---

## 1. Chart coordinates, versions and digests

The coordinate is the thing most likely to be wrong, because a chart can be published to a classic
HTTP repository, to an OCI registry, or to both under different paths. Each coordinate below was
**resolved by running it**, not read from a documentation page.

| Component | Role | Chart coordinate | Version | Chart manifest digest | App version |
|---|---|---|---|---|---|
| **Prometheus** | metrics collector | `oci://ghcr.io/prometheus-community/charts/prometheus` | `29.36.2` | `sha256:26503341a6fe4a4c929ca15e65698219fd4f545dc49d7d53b0c0c3131e236653` | `v3.15.0` |
| **Grafana** | dashboard surface | `oci://ghcr.io/grafana/helm-charts/grafana` | `10.5.15` | `sha256:3d75dc3173c3fb07eaa8853283f38558c7c27259f7ed00cf8c096173667426a1` | `12.3.1` (**overridden — see § 4**) |
| **OpenCost** | cost tool | `oci://ghcr.io/opencost/charts/opencost` | `2.5.32` | `sha256:8163f17a34033a5d8ea79477eb2262088610e4a7ba1583077b06883f1e01fc16` | `1.121.3` |

**The resolving command, verbatim** — one per chart, and the `Digest:` line it printed is the value
in the table:

```
helm pull oci://ghcr.io/prometheus-community/charts/prometheus --version 29.36.2 -d .
  Pulled: ghcr.io/prometheus-community/charts/prometheus:29.36.2
  Digest: sha256:26503341a6fe4a4c929ca15e65698219fd4f545dc49d7d53b0c0c3131e236653

helm pull oci://ghcr.io/grafana/helm-charts/grafana --version 10.5.15 -d .
  Pulled: ghcr.io/grafana/helm-charts/grafana:10.5.15
  Digest: sha256:3d75dc3173c3fb07eaa8853283f38558c7c27259f7ed00cf8c096173667426a1

helm pull oci://ghcr.io/opencost/charts/opencost --version 2.5.32 -d .
  Pulled: ghcr.io/opencost/charts/opencost:2.5.32
  Digest: sha256:8163f17a34033a5d8ea79477eb2262088610e4a7ba1583077b06883f1e01fc16
```

### Coordinates that do NOT exist, recorded because confirming one means ruling out the others

The cost tool's coordinate took three attempts. The form a reader would guess from the chart's
source repository name is wrong, and guessing it is how a lab bootstrap breaks on somebody else's
machine:

| Tried | Result |
|---|---|
| `oci://ghcr.io/opencost/opencost-helm-chart/opencost` | `helm show chart` fails — no such repository |
| `oci://ghcr.io/opencost/opencost-helm-chart/charts/opencost` | fails |
| `oci://ghcr.io/opencost/opencost/charts/opencost` | fails |
| **`oci://ghcr.io/opencost/charts/opencost`** | **resolves** — version `2.5.32`, appVersion `1.121.3` |

Cross-checked against the classic HTTP repository `https://opencost.github.io/opencost-helm-chart`,
which lists the same `2.5.32` / `1.121.3` pair. Both routes serve the same chart; the OCI route is
the one this layer uses, because `helm pull` prints a manifest digest for it and that digest is what
`create.sh` verifies.

---

## 2. Image pins — every one a manifest-list INDEX digest

Four images, which is every image the three releases actually run with the values this layer
commits. The **index** digest is recorded rather than a per-architecture one, so a single reference
resolves correctly on this `linux/arm64` host and on an `linux/amd64` CI runner — the property the
CI plan's architecture matrix depends on.

| Image reference (index digest) | Human version | Platforms the manifest list reported | Resolved |
|---|---|---|---|
| `quay.io/prometheus/prometheus@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` | Prometheus `v3.15.0` | `linux/amd64` `linux/arm/v7` `linux/arm64` `linux/ppc64le` `linux/riscv64` `linux/s390x` | 2026-10-14 |
| `quay.io/prometheus-operator/prometheus-config-reloader@sha256:06b52bd4dbe3ed6dd5905aadaf8b9987d9da4c31d37bb86deaadae68cee2d26b` | config-reloader `v0.94.1` | `linux/amd64` `linux/arm/v7` `linux/arm64` `linux/ppc64le` `linux/s390x` | 2026-10-14 |
| `docker.io/grafana/grafana@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572` | Grafana `13.2.3` | `linux/amd64` `linux/arm/v7` `linux/arm64` | 2026-10-14 |
| `ghcr.io/opencost/opencost@sha256:4cdd173253e5abba048dfe2cfa968707a5b59d774157d5356940d0d923a6c281` | OpenCost `1.121.3` | `linux/amd64` `linux/arm64` | 2026-10-14 |

**Every one of the four carries both `linux/amd64` and `linux/arm64`. No row is blocking.**

### The resolving command, verbatim

```
docker buildx imagetools inspect quay.io/prometheus/prometheus:v3.15.0
docker buildx imagetools inspect quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1
docker buildx imagetools inspect grafana/grafana:13.2.3
docker buildx imagetools inspect ghcr.io/opencost/opencost:1.121.3
```

The `Digest:` line of each is the **index** digest — the one directly under `MediaType:
application/vnd.docker.distribution.manifest.list.v2+json`, not one of the per-architecture digests
listed below it under `Manifests:`. The platform column above is the `Platform:` lines of the same
output, read verbatim and de-duplicated.

**A single-platform manifest list would be a finding, not a footnote**, and this is the method that
finds it: Phase 1 recorded an image whose upstream release notes claimed an `arm64` build had landed
while every published manifest was `amd64`-only. The measurement is the authority, not the notes.
None of the four images here has that shape.

### The cost tool's upstream chart is already digest-pinned, and its digest is the index digest

`opencost` chart `2.5.32` ships
`tag: "1.121.3@sha256:4cdd173253e5abba048dfe2cfa968707a5b59d774157d5356940d0d923a6c281"` as its own
default. That digest was resolved independently with the command above and **matches the index
digest** — so the upstream pin is an index digest and not a per-architecture one. This layer restates
it in `values.yaml` rather than inheriting it silently, so the layer's whole pin set is readable in
one file.

### Two images the default renders would have pulled in, and are not installed

| Image | Why absent |
|---|---|
| `ghcr.io/opencost/opencost-ui` | the cost tool's own web UI, disabled. The dashboard surface in this layer is Grafana; a second web UI is a second image, a second Deployment and a second memory term for a surface this course does not teach from |
| `docker.io/bats/bats` | the dashboard chart's `helm test` hook, disabled. Leaving it enabled would put a fourth image reference in the committed manifest for a Pod this layer never runs |

Neither is pinned here, because neither is installed. If either is ever enabled it needs a row in
this table first.

---

## 3. Why the bundled monitoring distribution is not installed

**The reason is a measured budget, not a preference.** Written here so the next person reaching for
the convenient chart reads the arithmetic instead of re-deriving it:

| Figure | Value | Where it was measured |
|---|---|---|
| declared-minimum lab budget | **4500 MiB** | `course.config.json` `lab.sizes.8.budget_mb` |
| the base profile at rest, with its three feature gates | **1908 MiB** of summed container peak | `planning/lab-tests/03-grid-core.md`, reproduced three times within 4 MiB |
| headroom the addon layers share | **~2592 MiB** | the subtraction, which is arithmetic and is labelled as such |

The bundled distribution carries, beyond the collector: an operator and its custom resource
definitions, an alert manager, a node exporter **per node**, a kube-state-metrics deployment, and a
default rule and dashboard set. This course reads almost none of it at this stage, and the operations
module installs the node exporter and kube-state-metrics itself, in the lesson that teaches what they
are for. Three slim releases cost what this layer actually uses.

A second reason, smaller but real: the bundled distribution installs the `monitoring.coreos.com/v1`
custom resource definitions, which the standalone collector chart does not. Nothing at this layer
needs them, and a cluster-scoped custom resource definition installed by a layer is a thing the
layer's teardown then has to remove correctly.

---

## 4. The dashboard major is a forward schema contract, and the chart does not agree with it yet

**Pinned: Grafana `13.2.3`.** The pin is on the **major**, and it is a contract rather than a version
preference: a dashboard's JSON is schema-versioned against the major it was authored on, and the
course generates dashboards in a later phase. **The consuming phase is the operations and cost
module's own phase (M12), which is where the dashboards are authored and where a wrong schema costs a
re-author rather than a re-render.** `verify.sh` reads the running instance's own reported version and
asserts the major, so a drift fails in this layer rather than in the phase whose dashboards stop
rendering.

**The divergence, stated rather than smoothed over.** Chart `10.5.15` declares appVersion `12.3.1`,
and **no chart in that series publishes a 13.x appVersion** — every one of the twelve most recent
chart versions reads `12.3.1`. The image `grafana/grafana:13.2.3` exists and is multi-architecture;
the chart has simply not caught up. So this layer **overrides the chart's own default** by setting
`image.tag` and `image.sha` in `values.yaml`, which is the only pin in this layer that does not come
from its chart.

Measured, 2026-10-14:

```
helm search repo grafana/grafana --versions   # every recent chart version: appVersion 12.3.1
docker buildx imagetools inspect grafana/grafana:13.2.3   # exists, multi-arch index digest
```

What follows: the chart-and-image combination this layer installs is **not** an upstream-tested
pairing, so it is verified here by behaviour — the Deployment reaches Available and the instance's
own `/api/health` reports a `13.x` version — rather than assumed from the chart. What does **not**
follow is that the pin is wrong; the course's technology authority records `13.2.3` as the current
release, and a dashboard generated against `12.3.1` would be the thing that has to be re-authored.

Routed to the pre-recording checklist as part of the existing ledger item
`GRAFANA-V13-DASHBOARD-SCHEMA` — see § 6.

### The dashboard chart is marked deprecated in its own metadata, and a learner will see it say so

Measured 2026-10-14: `grafana` chart `10.5.15` carries **`deprecated: true` in its own
`Chart.yaml`**, on both the OCI route this layer uses and the classic HTTP repository. The
consequence is visible on every install — `helm pull` prints
`level=WARN msg="this chart is deprecated"` — so it is recorded here rather than left for a learner
to discover and mistrust.

What it does and does not mean, stated narrowly because the chart metadata says nothing beyond the
flag:

- **It installs and it works.** Every figure in `planning/lab-tests/03-addon-ops.md` was measured on
  it.
- The project publishes a **`grafana-operator`** chart (`5.25.0` at the same reading), which is the
  path the deprecation plausibly points at. This layer does **not** take it: an operator is a
  controller Deployment plus cluster-scoped custom resource definitions, which is more memory
  against the 4500 MiB budget and more surface for the teardown to reclaim, for a layer that runs
  one dashboard instance with no dashboards in it.
- **No successor is named in the chart's own metadata**, so "replaced by the operator" is an
  inference and is not stated as a fact anywhere in this course.

Routed to the pre-recording checklist in § 6, with a re-check that is a single `helm show chart`.

---

## 5. The cost tool: what it is here for, and what this course will not say

**No cost figure is asserted by this layer, and none is published.** `verify.sh` asserts that the
tool starts, finds the metrics collector and answers its own readiness endpoint. It asserts nothing
about any number the tool computes.

The reason is the course's own evidence standard. The tool ships accelerator pricing schemas, which
is what makes the course's claim that it handles accelerator cost defensible — but on a laptop with
**no cloud pricing configured and no cloud integration enabled**, every rate it uses is a default
standing in for a price nobody paid. A figure derived from that is arithmetic over a fabricated rate
wearing a measurement's clothes, and publishing one would be precisely the overclaim the truth
contract exists to prevent.

What the course **does** take from it is a **data join against a synthetic metric stream** — pairing
a cost model with a device-utilisation series the course generates itself and declares as synthetic.
That is a later phase's lab. This plan ships the layer and proves it is healthy; it teaches nothing
and joins nothing.

`values.yaml` expresses the same boundary as configuration rather than only as prose: the cloud-cost
integration is explicitly disabled.

---

## 6. Where every pin in this file is routed, and why it is routed at all

**None of these components was version-verified by prior research.** The project's technology table
names versions for all three and the project's own pre-recording inventory flags OCI chart
coordinates as unconfirmed. Everything above was resolved for the first time in plan `03-06`.

**The routing rule, and why it is not "add an M12 checklist".** The consuming module is M12
(Operations & Cost). M12 is **not** one of the seven volatile modules, so it has no pre-recording
gate of its own, and `STANDARDS.md` § `pre-recording.mjs` fixes what happens in exactly that case: a
tracked item whose consuming module has no gate is **carried on all seven instances**, labelled with
the module that consumes it. Inventing an eighth instance would contradict the checker's own fixed
list of seven. So the routing is to all seven, and an eighth file was deliberately not created.

| Pin | Routed to | Re-check trigger |
|---|---|---|
| the three chart coordinates and their versions | all seven `planning/pre-recording/m*.md`, § *Items routed here by plan 03-06* | charts in this set move on a weekly-to-monthly cadence; re-resolve the coordinate, the version and the chart digest before M12 records |
| the four image index digests | same | a release tag is mutable and a digest is not; re-resolve each index digest and re-confirm both architectures before M12 records |
| the dashboard major as a schema contract | same, and the existing ledger item `GRAFANA-V13-DASHBOARD-SCHEMA` which already rides on all seven | the chart publishes a 13.x appVersion (at which point the override in `values.yaml` should be removed), **or** a generated dashboard fails to load against the pinned major |
| the no-cost-figure boundary | same | it does not expire; it is routed so a later module re-reads the boundary before writing a sentence about cost |
| the dashboard chart carrying `deprecated: true` | same | a single `helm show chart` on the pinned coordinate. It clears when the flag is gone, or when upstream names a successor and the layer is re-cut onto it |

---

## 7. Resolved digests confirmed against the running workloads

**READ 2026-10-14, off a live layer.** Every pin in § 2 was honoured by a container the node
actually started, so this register now records not only what was resolved but that the cluster
agreed. A manifest can ask for a digest and a node can resolve something else; that is the half a
written-only pin never catches, and it is why this table reports what the **kubelet** said rather
than what the manifest asked for.

| Container | `imageID` reported by the kubelet | Matches the § 2 pin |
|---|---|---|
| `prometheus-server` | `quay.io/prometheus/prometheus@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` | yes |
| `prometheus-server-configmap-reload` | `quay.io/prometheus-operator/prometheus-config-reloader@sha256:06b52bd4dbe3ed6dd5905aadaf8b9987d9da4c31d37bb86deaadae68cee2d26b` | yes |
| `grafana` | `docker.io/grafana/grafana@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572` | yes |
| `opencost` | `ghcr.io/opencost/opencost@sha256:4cdd173253e5abba048dfe2cfa968707a5b59d774157d5356940d0d923a6c281` | yes |

**Each reported digest is the INDEX digest, not a per-architecture one.** That is the fact plan
`03-08`'s architecture matrix rests on, and it is now read back off a running container rather than
assumed from the manifest list: the same reference will resolve on an `linux/amd64` runner.

Read with:

```
kubectl --context kind-grid-core -n grid-ops get pods \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}{end}'
```

The same comparison runs inside `create.sh` after every rollout and **fails the install** on a
mismatch, so this table records an assertion that is enforced rather than a one-off observation.
Measurement conditions for the run it was read from:
`planning/lab-tests/03-addon-ops.md` § *Declared environment*.

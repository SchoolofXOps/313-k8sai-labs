# Landscape grading

## Grading criteria

**Maturity.** What has shipped, read from a release artifact and never from an adjective — `resource.k8s.io/v1` served by Kubernetes 1.34, say, or `jobset.x-k8s.io/v1alpha2` at JobSet v0.12.0.

- `shipped-and-stable` — a GA or `v1` API served at a named release tag, or a project at 1.0 or later with a stable API.
- `shipped-and-immature` — an alpha or beta API group, a beta feature gate that is off by default, or a release of a project before 1.0.
- `announced-or-roadmap` — no release artifact exists.

**Recommendation.** What this course's evidence supports you doing with it.

- `bet-on-it` — `shipped-and-stable`, AND governed upstream (a Kubernetes SIG or the CNCF), AND taught as a lab in this course.
- `pilot-it` — shipped but immature, or governed by a vendor with a released artifact.
- `read-it-fluently` — announced, taught only as a BRIEF here, or outside this course's install path.

**Evidence grade.** The confidence of the claims-ledger entry the row names, with the date it was read.

- `verified` — the fact was read from the artifact the ledger entry names.
- `cited` — the fact rests on a published source that was read but not independently reproduced, such as a product page or a press release.
- `unverified` — this course pins no version for the entry, so its release cell sends you to the project's own releases page.

**How the definitions are applied.**

- Where an entry meets both maturity definitions, the API it serves decides. A `v1` API in a project still numbered 0.x is `shipped-and-stable` (LeaderWorkerSet serves `leaderworkerset.x-k8s.io/v1` at v0.11.1), and a 1.0 project serving an alpha or beta API is `shipped-and-immature` (kagent v1.0.0 serves `api.kagent.dev/v1alpha3`). An entry with several APIs is graded by the least settled one a workload has to use.
- The project's release number decides only for an entry that serves no Kubernetes API of its own.
- An entry with no public release artifact you can open at a version, such as a commercial product, a managed cloud service or a certification programme, is graded `announced-or-roadmap`. This axis grades what you can read at a version, not whether a vendor sells the product today.
- Where an entry meets both the `pilot-it` and the `read-it-fluently` definitions, `read-it-fluently` applies, because this course gives you no lab to pilot it from.

## My grading

| Entry | Maturity | Recommendation | Evidence grade | Source | Read on |
| --- | --- | --- | --- | --- | --- |
| DRA core (resource.k8s.io/v1) | shipped-and-stable | bet-on-it | verified | https://github.com/kubernetes/kubernetes/pull/132706 | 2026-11-12 |
| Workload and PodGroup gang scheduling | shipped-and-immature | read-it-fluently | verified | https://raw.githubusercontent.com/kubernetes/website/72786d43a07fafa626843a6f8a56a6ee5f0db7af/content/en/docs/reference/command-line-tools-reference/feature-gates/GenericWorkload.md | 2026-11-12 |
| JobSet | shipped-and-immature | pilot-it | verified | https://github.com/kubernetes-sigs/jobset/releases/tag/v0.12.0 | 2026-11-12 |
| LeaderWorkerSet | shipped-and-stable | read-it-fluently | verified | https://github.com/kubernetes-sigs/lws/releases/tag/v0.11.1 | 2026-11-12 |
| Agent Sandbox | shipped-and-immature | pilot-it | verified | https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v1.0.5 | 2026-11-12 |
| the CNCF AI conformance programme | announced-or-roadmap | read-it-fluently | verified | https://github.com/cncf/k8s-ai-conformance/blob/c64e5bc8085da207715df96e458f2c6585c9f53e/faq.md | 2026-11-12 |

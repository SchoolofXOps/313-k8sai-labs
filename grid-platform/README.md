# `grid-platform` — the accumulating platform repository

One Git repository the learner grows by hand, one layer per module, from an empty cluster that can
be read correctly to a platform that stays standing when three teams collide. By M13 this
repository **is** the portfolio artifact a learner shows at interview.

It grows in place. There is no per-module fresh checkout and no provided snapshot, because a
snapshot would hand the learner the state that the labs exist to make them produce. Continuity
lives in this repository's history and its reference tags, not in a cluster left running — an 8 GB
laptop cannot keep the platform up between sessions, and platform teams do not work that way
either.

## What this directory contains today

Thirteen files: this one, and one `README.md` per directory. Nothing else. Measured
2026-10-07 — `git ls-files -- labs/grid-platform` reports 13 tracked files, zero lab artifacts.
That is the whole point of the seed: every one of the twelve directories already has a documented
address and a declared owning module, so a module author in a later phase writes into a
pre-assigned path instead of inventing one on the day.

No `.gitkeep` or `.keep` files. Git cannot track an empty directory, and a marker file beside a
README is a second thing to maintain that says nothing. The READMEs are the content.

## Reference-tag convention

**Tag name shape:** `grid-v<major>[.<minor>]` — `grid-v0`, `grid-v0.1`, `grid-v1.2`, `grid-v4.0`.
Lowercase, one leading `v`, no build suffix, no pre-release suffix.

**Reference-tag owner:** Gourav Shah — School of DevOps & AI. Read from `course.config.json`'s
`course.author` field and the design spec's course-identity table; no artifact in this repository named a
tag owner before this seed, so the course author is named here and the assignment is flagged for
founder sign-off in `02-11-SUMMARY.md` rather than left blank. A convention with no owner is a
convention nobody maintains.

**The tags are cut on the PUBLIC labs repository, not here.** They live on
`SchoolofXOps/313-k8sai-labs`, because that is the repository a learner clones and checks out. A
tag that exists only in the private authoring repository is unreachable for the person it was cut
for. This directory is where the tree is **authored**; the public repository is where it is
**consumed**, and the reference points have to exist where they are consumed.

The sync direction is one-way, private to public, through `scripts/sync-grid.mjs`. That script
strips the leading `labs/` segment, so this tree lands at `grid-platform/` at the public
repository's root — matching the convention the public repository already uses for every other lab
directory. It copies only; cutting a reference point and publishing one are the ship path's job in
a later phase.

## Version progression

| Tag | Module | The platform becomes | Phase |
|---|---|---|---|
| `grid-v0` | M1 | an empty cluster that can be read correctly | 4 |
| `grid-v0.1` | M3 | a design document and an evidence-graded landscape | 5 |
| `grid-v0.5` | M4 | devices requestable by attribute, with driver lifecycle and health under control | 5 |
| `grid-v1.0` | M5 | quota'd, queued, gang-admitted, preemptible, topology-aware | 6 |
| `grid-v1.2` | M6 | data and collective paths that do not starve the accelerator | 6 |
| `grid-v1.5` | M7 | training that resumes from a checkpoint after a worker dies | 7 |
| `grid-v2.0` | M8 | models served with SLO-driven autoscaling | 7 |
| `grid-v2.5` | M9 | requests routed by load and cache locality | 8 |
| `grid-v3.0` | M10 | a data layer, verified artifacts, GitOps promotion, a platform API | 7 and 8 |
| `grid-v3.5` | M11 | agents hosted inside a bounded blast radius | 5 |
| `grid-v3.8` | M12 | observable, costed, recoverable, upgradeable | 8 |
| `grid-v4.0` | M13 | still standing when all three teams collide | 9 |

M2 cuts no reference point. It is a design brief with no build step, and its two artifacts
(`docs/capacity-model.md`, `docs/cost-model.md`) land under M3's `grid-v0.1`.

The tag order is not the authoring order. M11 cuts `grid-v3.5` in Phase 5 and M10 cuts `grid-v3.0`
across Phases 7 and 8, because the authoring sequence follows cluster-profile cost and risk rather
than the module numbers. The single-writer property below is what makes that safe.

## The single-writer property

**Each module writes exactly one new directory.** Two modules never own the same directory, so
modules can be authored out of order and in parallel waves without racing on this tree, and any one
module can be re-authored or re-cut without touching its neighbours. When a feature gate flips
default-on in a later Kubernetes release, `capacity/` changes and nothing else does.

Each directory's own `README.md` carries its address: what lands there, which module writes it, and
what does not land there. Read that file before writing into a directory — the half that says what
does **not** land there is the half that stops an author reaching for the nearest plausible
directory.

Two directories are declared exceptions, each stated in its own README with the reason:

- `clusters/` — every module that needs its own cluster shape adds its own profile subdirectory.
- `docs/` — append-only and file-scoped: every module adds its own named file.

A third exception is a decision, not a convenience. It needs a line in the directory's README
saying who writes what, or the property it breaks is invisible until the phase that authors second.

## What deliberately does not exist yet

**The capability-per-version status page.** It reports, for each reference point, what the platform
can do, what is still broken, and which module fixes it — and that data does not exist until the
modules are authored. Writing it now would mean inventing the capability rows, which is the one
thing this course's evidence rules forbid. Phase 4 owns it, alongside the first reference point.

**Every lab artifact.** Twelve empty addresses and no manifests. Phases 4 through 9 fill them.

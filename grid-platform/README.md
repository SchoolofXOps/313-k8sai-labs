# `grid-platform` — the accumulating platform repository

One Git repository the learner grows by hand, one layer per module, from an empty cluster that can
be read correctly to a platform that stays standing when three teams collide. By M13 this
repository **is** the portfolio artifact a learner shows at interview.

It grows in place. There is no per-module fresh checkout, and the `main` you clone carries no
snapshot of any module's end state, because a snapshot on `main` would hand every new learner the
state that the labs exist to make them produce. The course's end states live somewhere else: the
`grid-v*` reference tags, on a separate `grid-reference` branch of the public repository, which you
check out only when you start mid-course or want to compare (see the reference-tag convention
below). Continuity lives in this repository's history and in those tags, not in a cluster left
running — an 8 GB laptop cannot keep the platform up between sessions, and platform teams do not
work that way either.

## What this directory contains on a fresh clone of `main`

Thirteen files: this one, and one `README.md` per directory. None of them is a lab's work. From
your first lab onwards, each module adds its files here, and so does restoring a `grid-v*`
reference point. So once you have started, this directory holds more than the thirteen. That is
the whole point of the seed: every one of the twelve directories already has a documented
address and a declared owning module, so a module author in a later phase writes into a
pre-assigned path instead of inventing one on the day.

No `.gitkeep` or `.keep` files. Git cannot track an empty directory, and a marker file beside a
README is a second thing to maintain that says nothing. The READMEs are the content.

## Reference-tag convention

**Tag name shape:** `grid-v<major>[.<minor>]` — `grid-v0`, `grid-v0.1`, `grid-v1.2`, `grid-v4.0`.
Lowercase, one leading `v`, no build suffix, no pre-release suffix.

**Reference-tag owner:** Gourav Shah — School of DevOps & AI. Read from `course.config.json`'s
`course.author` field and the design spec's course-identity table; no artifact in this repository named a
tag owner before this seed, so the course author is named here rather than the field being left
blank. A convention with no owner is a
convention nobody maintains.

**The tags are cut on the PUBLIC labs repository, not here.** They live on
`SchoolofXOps/313-k8sai-labs`, because that is the repository a learner clones and checks out. A
tag that exists only in the private authoring repository is unreachable for the person it was cut
for. This directory is where the tree is **authored**; the public repository is where it is
**consumed**, and the reference points have to exist where they are consumed.

**The tags live on the public `grid-reference` branch, never on `main`.** `main` stays the seed:
twelve directories, a README each, no answers. Each cut merges the current `main` into
`grid-reference` with an ordinary merge, adds one commit carrying the module's end-state files, and
puts an annotated `grid-v*` tag on that commit. Pushes are fast-forward only; a published tag is
never moved.

The sync direction is one-way, private to public, through `scripts/sync-grid.mjs`. That script
strips the leading `labs/` segment, so this tree lands at `grid-platform/` at the public
repository's root — matching the convention the public repository already uses for every other lab
directory. It copies only, and it publishes only `labs/`. The end-state files a tag adds are
authored outside `labs/` in the private source repository, so the sync can never carry them to
`main`; the cut copies them onto `grid-reference` by hand.

**Starting mid-course.** From a current `main` checkout, fetch the course's tags and restore only
this directory from the reference point:

```bash
git fetch --tags && git checkout grid-v0 -- grid-platform
```

If you have already renamed the course's remote to `upstream`, as the setup page asks, fetch from it
by name: `git fetch upstream --tags`. Restoring `grid-platform` alone keeps the current lab scripts
under `clusters/` and `tools/`. A whole-tree `git checkout grid-v0` would pin you to the scripts as
they were when the tag was cut.

**Learners never cut `grid-v*` tags.** That name space is the course's. Your clone fetches the
course's tags, so a `grid-v0` of your own collides with it. Commit with the module named in the
message (for example `m1: baseline failures recorded`) and push to a remote you own.

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

**Capability rows for reference points not yet validated.** The capability-per-version page
(Reference → Capability by version on the course site) reports, for each reference point, what the
platform can do, what is still broken, and which module fixes it. A row appears only after its
module's lab checks have passed on a live run; `grid-v0` is the first. Writing a row earlier would
mean inventing capabilities, which is the one thing this course's evidence rules forbid.

**Every lab artifact.** Twelve empty addresses and no manifests. Phases 4 through 9 fill them.

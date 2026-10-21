# `clusters/` — cluster profiles, one subdirectory per profile

Every lab in this course starts by creating a cluster and ends by tearing it down, because one
8 GB machine runs one profile at a time. A profile is the reproducible description of one cluster
shape: its `kind` config with the pinned node image and the feature gates that shape needs, plus
the three scripts that drive it.

| What lands here | Owning module |
|---|---|
| the base profile — `kind` config, `create.sh`, `verify.sh`, `teardown.sh` | M1 |
| one additional profile subdirectory per module whose lab needs a different cluster shape | M1–M13 |

**MULTI-WRITER EXCEPTION:** this directory is written by more than one module, and that is a
decision rather than a lapse. A profile is a per-lab resource, so forcing every profile through one
owning module would mean editing a sibling module's file every time a lab's cluster shape changed —
which is the merge conflict the single-writer property exists to prevent. The property is preserved
one level down instead: **each module adds its own profile subdirectory and never edits a
sibling's.** M1 owns the base profile and the script contract the others copy.

## What does not land here

- Workload manifests of any kind. A profile describes the cluster, not what runs on it. Device
  manifests go to `nodes/`, queueing objects to `capacity/`, model servers to `serving/`.
- Anything a learner's machine generates while running a lab — cluster state, kubeconfigs, logs.
  The authored tree is what is tracked.
- Host setup instructions. Installing the container runtime, `kind`, `kubectl` and `helm` happens
  once and belongs on the lesson page, not in a per-profile script.

## Why the owner is named at all

A later phase authoring M6 needs to know, without reading six other modules, whether its storage
lab extends the base profile or adds its own. The answer is in this table, and the answer is
settled before any of those phases start.

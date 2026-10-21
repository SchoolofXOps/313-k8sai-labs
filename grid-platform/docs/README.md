# `docs/` — the written platform record

The documents a platform team actually keeps: how the platform is laid out, how sizing was reasoned
about, what it costs, what the team decided and why, and what an agent is allowed to do without
asking. This is the half of the portfolio artifact a reader reads rather than runs.

| What lands here | Owning module |
|---|---|
| the platform design document and the evidence-graded landscape assessment | M3 |
| the capacity model and the cost model | M2 |
| the decision trees — which mechanism to reach for, with the criteria stated | M3 |
| the autonomy policy for hosted agents | M11 |
| the chargeback model and the recovery plan | M12 |
| the diagnostic evidence and the interview question set from the capstone | M13 |
| one named file per module, appended, never edited by a sibling | M1–M13 |

**MULTI-WRITER EXCEPTION:** this directory is written by more than one module, and that is a
decision rather than a lapse. The platform record is the one artifact that only means something
when it accumulates across the whole course — a design document that covered devices but not
quota, cost but not recovery, would not be the thing a reader is being shown. The single-writer
property is preserved **at file scope instead of directory scope: each module adds its own named
file and never edits a sibling's.** That keeps out-of-order authoring safe for exactly the same
reason directory ownership does elsewhere — two phases authoring in parallel touch different files.

## What does not land here

- Manifests of any kind. Every executable artifact has its own directory; this one holds prose and
  the models that reason about it.
- Course production records — audit reports, pre-recording checklists, lab validation transcripts.
  Those are authoring records rather than learner content, they never sync to the public
  repository, and the sync script's exclusion set enforces that rather than relying on anyone
  remembering it.
- The capability-per-version status page. It is published on the course site rather than committed
  here, because it reports on reference points cut on the public repository.
- Lesson text. A lesson teaches; a design document records what was decided. A learner who copies
  a lesson page in here has produced course notes, not a platform record.

## Why the owner is named at all

Six modules write files here across six phases. Naming the file per module in advance is what stops
two phases from both authoring `design.md` and discovering it at merge.

# `runbooks/` — the written procedures, one file per procedure

Prose, not manifests. Each file is a procedure an operator follows under pressure: the trigger, the
read-only commands that establish what is happening, the intervention, the rollback condition, and
the verification that the platform is back.

| What lands here | Owning module |
|---|---|
| the accelerator-driver upgrade procedure | M12 |
| the node drain procedure for a node holding allocated devices | M12 |
| the incident playbook, organised by symptom category | M12 |
| the backup and recovery procedure, with its measured recovery objectives stated | M12 |
| the emergency stop procedure for a runaway tenant | M12 |

Any recovery figure a procedure states is measured on a restore that was actually performed, in a
declared environment, and the procedure says which environment. A recovery objective nobody has
timed is an aspiration, and an aspiration in a runbook is worse than a blank field.

## What does not land here

- Alert rules. The rule that pages belongs in `observability/`; the procedure it pages into belongs
  here. They are separate files on purpose, because the rule changes with the metric and the
  procedure changes with the platform.
- Dashboards, queries and cost models. Those are `observability/`.
- The objects a procedure operates on. A procedure references manifests in other directories; it
  does not hold copies of them.
- Capstone diagnostic transcripts. The capstone exercises these procedures and records its evidence
  under `docs/`; it does not rewrite them.

## Why the owner is named at all

M13's scored exercise reads these files and deliberately does not edit them, which is what makes
the capstone a test of diagnostic method rather than a test of whether the learner can rewrite a
procedure to match the fault.

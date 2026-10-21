# `training/` — distributed training as a platform service

The split this directory exists to make visible: a platform engineer authors the runtime, an ML
engineer submits a job against it. Both halves are tracked here, and the boundary between them is
the lesson.

| What lands here | Owning module |
|---|---|
| cluster-scoped training runtime manifests, authored by the platform engineer | M7 |
| job templates submitted against those runtimes, authored by the model engineer | M7 |
| the checkpoint policy — where checkpoints are written, how often, and what resume reads | M7 |
| the grouped-job and leader-worker manifests the runtimes compile down to | M7 |
| the distributed job's own container entrypoint and its rendezvous configuration | M7 |

The training the core path actually runs is a two-worker CPU job with a real rendezvous, a real
worker failure and a real resume from checkpoint. Collective-library behaviour across a device
interconnect is a separate claim and is taught on the rented-hardware track with its instance type
declared.

## What does not land here

- The queue the job is submitted into. Quota and admission are `capacity/` and belong to M5; this
  directory only names the queue.
- The shared volume the checkpoint is written to. That claim is `dataplane-storage/`, written by M6.
- Model serving. A trained artifact being served is `serving/`.
- Training job dashboards and alert rules. Those are `observability/`.

## Why the owner is named at all

M12's remediation loop ends by requeueing a gang-admitted job from this directory and watching it
resume from its checkpoint, and M13 breaks one of these manifests deliberately. Both read it; only
M7 writes it.

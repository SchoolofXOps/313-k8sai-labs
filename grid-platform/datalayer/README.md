# `datalayer/` — the stateful layer and the supply chain that admits it

The parts of an AI platform that are not the model: the database that holds the vectors, the
pipeline that fills it, the signature check at admission, and the reconciler that promotes any of
it between environments.

| What lands here | Owning module |
|---|---|
| the vector database StatefulSet, its service and its volume claim | M10 |
| ingestion workflow manifests and their templates | M10 |
| the signature-verification admission policy and the trust root it verifies against | M10 |
| the GitOps application manifests that reconcile this repository | M10 |
| the platform-API surface a tenant submits against, assembled over the queueing and serving layers | M10 |

The replica count is a machine-size decision, not a default: one replica on the 8 GB profile, three
on 16 GB. Whichever a lab runs, it is stated on the page with the budget that forced it.

## What does not land here

- Retrieval quality, chunking strategy and reranking. Those are application concerns and are out of
  this course's scope by decision; they are named once at the boundary with a pointer.
- The queue the ingestion workflow is admitted through. That is `capacity/`.
- The model server the platform API fronts. That is `serving/`.
- Backup and recovery procedure for this data. The procedure is a runbook and lives in `runbooks/`;
  only the objects being backed up live here.

## Why the owner is named at all

M10's own artifacts arrive in two passes — two standalone labs in one phase and the integrative
labs in the next — so this directory is written across two phases by one module. That is a single
writer over time, not a shared directory, and it is the reason the owner column says one module
rather than a phase.

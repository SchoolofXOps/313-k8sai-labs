# `capacity/` — quota, queueing and admission

Who may have a scarce device, how long they wait for it, and what gets evicted when something more
urgent arrives. Every object here is a queueing-controller object, not a scheduler object.

| What lands here | Owning module |
|---|---|
| `ResourceFlavor` manifests, including the device mappings that make a device-claiming workload chargeable | M5 |
| `ClusterQueue` and `LocalQueue` manifests, with their cohort and borrowing configuration | M5 |
| `PriorityClass` manifests and the preemption policy that reads them | M5 |
| the topology object and the flavor fields that constrain placement to a topology label | M5 |
| the admission-check configuration | M5 |
| the queueing controller's own install values and its enabled feature gates | M5 |

Every manifest here is `kueue.x-k8s.io/v1beta2`. The controller release this course pins stopped
serving the earlier beta version, so any manifest copied from a 2025 tutorial or from the sibling
Kubernetes course is rejected by the API server rather than quietly accepted. Upstream ships a
migration script for inherited files.

## What does not land here

- Device inventory. What a device is, and which attributes it advertises, is `nodes/` and belongs
  to M4. This directory only references those attributes by name.
- The in-tree workload and pod-group objects. They are taught beside the queueing path as the
  direction of travel, behind a feature gate that is off by default in everyone else's cluster, and
  they are demonstrated from the lesson page rather than committed as platform configuration.
- Job and training specs. A `TrainJob` that *uses* a queue lives in `training/`.
- Cluster creation, including the fake-node profile the scale labs need. That is `clusters/`.

## Why the owner is named at all

M7's training jobs and M8's serving deployments both submit into queues defined here, and M13's
three-team collision runs entirely against this directory's objects. All three read it; only M5
writes it.

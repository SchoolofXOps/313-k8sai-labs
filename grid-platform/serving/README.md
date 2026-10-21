# `serving/` — the model-serving control plane and its workloads

What it takes to get a model answering requests and to keep it answering under load: the server
itself, the probes that decide when it is ready, the artifact it loads, and the scaling signal.

| What lands here | Owning module |
|---|---|
| model-server Deployment manifests, with their startup, readiness and liveness probes | M8 |
| the serving custom resources and the runtime definitions that back them | M8 |
| the model artifact claim and the node-local cache reference the server mounts | M8 |
| the horizontal autoscaler and the external-metric scaler configuration | M8 |
| the multi-host serving manifests for a model that does not fit one node | M8 |
| the simulator configuration used by the core-path labs, published beside every figure derived from it | M8 |

The core path serves against an upstream inference simulator with an interface a client cannot
distinguish from the engine it stands in for. Every figure derived from it ships with its own
configuration beside it, claims direction and mechanism rather than magnitude, and uses a verb that
matches what happened — modelled, demonstrated, showed — never measured. The real engine runs on
the rented-hardware track.

## What does not land here

- Request routing between replicas. Routing policy, the endpoint picker and the gateway are
  `routing/`, written by M9. This directory stops at the server's own port.
- The queue the serving workload is admitted through. That is `capacity/`.
- The cache tier the server reads from. That is `dataplane-storage/`.
- Serving dashboards, alert rules and the latency recording rules. Those are `observability/`.

## Why the owner is named at all

M8 and M9 split one subject down the middle, and the seam is the reason this directory and
`routing/` are separate. Queue depth drives a replica count here and an endpoint choice there, and
those are two different owners of the same signal.

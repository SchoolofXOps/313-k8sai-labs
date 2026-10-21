# `routing/` — the request data plane in front of the model servers

Everything between a client and a model server replica: the gateway, the pool of endpoints, the
component that picks one, and the policy it picks by.

| What lands here | Owning module |
|---|---|
| `InferencePool` manifests on `inference.networking.k8s.io/v1` | M9 |
| gateway and route manifests on `gateway.networking.k8s.io/v1` | M9 |
| the endpoint-picker deployment and its configuration, with the image tag it runs pinned | M9 |
| the routing-policy configuration for each policy the comparison lab contrasts | M9 |
| the prefill/decode split manifests, where the lab reaches them | M9 |

Two facts about this surface are load-bearing and both are stated on the lesson page: the upstream
project owns the pool API and the picker *protocol*, while the picker *implementation* lives in a
separate project; and the minimal reference picker image is published for one CPU architecture
only, measured 2026-10-04, so the routing lab runs on the multi-architecture router instead and
says why.

## What does not land here

- The model server itself, its probes and its autoscaler. Those are `serving/`, written by M8.
- Cluster creation, including the fresh profile the routing lab needs with autoscaling explicitly
  disabled. That is `clusters/`.
- The cache whose residency the policy scores on. The simulated cache belongs to the server in
  `serving/`; this directory only reads the events it publishes.
- Routing dashboards and alert rules. Those are `observability/`.

## Why the owner is named at all

This is the most volatile upstream surface in the course — a single minor release moved component
ownership between projects and removed APIs. Isolating it in one directory with one owner is what
lets it be re-authored at recording time without touching eleven other modules.

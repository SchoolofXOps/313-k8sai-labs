# `agents/` — agents as a hosted workload class

An agent here is a workload with an unusual security surface, not an application to be written.
What lands in this directory is the boundary a platform engineer puts around it.

| What lands here | Owning module |
|---|---|
| sandbox templates and the warm-pool configuration | M11 |
| the sandbox runtime class and the isolation runtime it names | M11 |
| the tool-server deployment and its service account | M11 |
| the role and binding that scope what the agent may read and change | M11 |
| the egress policy and the audit configuration that records what the agent did | M11 |

Nested isolation under the course's own cluster runtime is proven on both CPU architectures,
measured 2026-10-05 by reading the isolation kernel's version string from inside the pod on two
machines. One caveat is stated on the page every time: a reduced capability set is evidence of
configuration, not proof of isolation.

## What does not land here

- Agent frameworks, SDKs and adapters. The labs run the controller and its custom resource only,
  and the SDKs are named explicitly as a different course's scope.
- Application prompts, tool implementations and agent logic. This directory holds the hosting
  boundary, not the agent.
- The queue the sandbox pool is admitted through. That is `capacity/`.
- Agent audit dashboards and alert rules. Those are `observability/`.

## Why the owner is named at all

M11 is authored out of module order, in the same phase as M3 and M4, specifically so this
directory's hardest technical risk is cashed early. Having the address and the owner fixed in
advance is what makes authoring at position three instead of position eleven safe.

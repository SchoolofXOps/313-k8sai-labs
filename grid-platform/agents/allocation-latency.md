# Sandbox allocation latency

Five cold Sandbox creates in agent-probes, one after another, each deleted before the next.
Seconds = the Ready condition's lastTransitionTime minus metadata.creationTimestamp, at one-second resolution.
A measurement in the environment below, not a portable figure.

## Declared environment

Host: Darwin arm64
Container runtime VM: Alpine Linux v3.23, kernel 6.18.36-0-virt, 5 CPUs, 8315465728 bytes of memory
Kubernetes: v1.37.0
gVisor: release-20260928.0
Agent Sandbox: registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.5
Node image: 313-grid-sandbox-node:v1.37.x-runsc 

## Runs

| Run | Sandbox | creationTimestamp | Ready lastTransitionTime | Seconds |
|---|---|---|---|---|
| 1 | latency-1 | 2026-11-12T10:44:16Z | 2026-11-12T10:44:16Z | 0 |
| 2 | latency-2 | 2026-11-12T10:44:18Z | 2026-11-12T10:44:19Z | 1 |
| 3 | latency-3 | 2026-11-12T10:44:20Z | 2026-11-12T10:44:21Z | 1 |
| 4 | latency-4 | 2026-11-12T10:44:22Z | 2026-11-12T10:44:23Z | 1 |
| 5 | latency-5 | 2026-11-12T10:44:24Z | 2026-11-12T10:44:25Z | 1 |

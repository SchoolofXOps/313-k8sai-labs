# Sandbox suspend and resume

One Sandbox, suspend-demo in agent-probes, under runsc, with one claim template, workspace, mounted at /data.
Suspended by setting spec.operatingMode to Suspended, resumed by setting it back to Running.
A cold restart, not a checkpoint: the claim was kept and the memory was not.

## Declared environment

Host: Darwin arm64
Container runtime VM: Alpine Linux v3.23, kernel 6.18.36-0-virt, 5 CPUs, 8315465728 bytes of memory
Kubernetes: v1.37.0
gVisor: release-20260928.0
Agent Sandbox: registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.11
Node image: 313-grid-sandbox-node:v1.37.x-runsc 

## Identity

| Object | Before suspend | After resume |
|---|---|---|
| Pod suspend-demo | c6da54e5-142e-4340-86c3-c81787bdeb08 | f388bc60-3560-46e5-a5df-b0369412bd02 |
| PVC workspace-suspend-demo | 2e717c3f-06e3-4a8a-aeb5-3eeb3cfb6f81 | 2e717c3f-06e3-4a8a-aeb5-3eeb3cfb6f81 |

## Read inside the resumed sandbox

| Path | State |
|---|---|
| /data/note.txt, on the claim | present |
| /dev/shm/marker.txt, in memory | absent |

## Controller metrics after the resume

Recorded in the environment above, read once, never asserted.

    agent_sandbox_resume_latency_ms_sum{namespace="agent-probes",owned_by="None",sandbox_template="unknown"} 1548
    agent_sandbox_resume_latency_ms_count{namespace="agent-probes",owned_by="None",sandbox_template="unknown"} 1
    agent_sandbox_resume_total{namespace="agent-probes",owned_by="None",result="ready",sandbox_template="unknown"} 1
    agent_sandbox_resume_total{namespace="agent-probes",owned_by="None",result="requested",sandbox_template="unknown"} 1
    agent_sandbox_suspend_latency_ms_sum{namespace="agent-probes",owned_by="None",sandbox_template="unknown"} 1485
    agent_sandbox_suspend_latency_ms_count{namespace="agent-probes",owned_by="None",sandbox_template="unknown"} 1
    agent_sandbox_suspend_total{namespace="agent-probes",owned_by="None",result="pod_terminated",sandbox_template="unknown"} 1
    agent_sandbox_suspend_total{namespace="agent-probes",owned_by="None",result="requested",sandbox_template="unknown"} 1
    agent_sandboxes{created_by="unknown",expired="false",launch_type="cold",namespace="agent-probes",operating_mode="Running",owned_by="None",ready_condition="true",sandbox_template="unknown"} 2

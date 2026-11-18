# Distributed slowdown — classification of the synthetic evidence bundle

The bundle in m6/slowdown-evidence/ is synthetic and course-authored. No device, NIC or fabric produced it.

| Step | Signal | Evidence file | What it shows | Ruled in or out |
|---|---|---|---|---|
| 1 | Device telemetry | 01-device-telemetry.txt | busy drops from about 91 to about 34 on all eight, with no errors and no throttling: healthy and waiting | ruled out — the devices are idle, not failing |
| 2 | Dataloader timing | 02-dataloader-timing.txt | data wait unchanged and the prefetch queue full, while the all-reduce wait grows to most of the step | ruled out — the wait is in the collective, not the data |
| 3 | NCCL logs | 03-nccl-log.txt | NET/IB finds no device, so NCCL uses the Socket transport on eth0 between the two nodes | ruled in — collectives go over sockets on the ordinary interface |
| 4 | Interface counters | 04-interface-counters.txt | eth0 runs near its line rate with receive drops, and ib0 carries nothing | ruled in — the shared interface is saturated and the fast one idle |
| 5 | RDMA counters | 05-rdma-counters.txt | rdma0 is up and error-free but moves almost no data | ruled out as broken — it is healthy and unused |
| 6 | Topology | 06-topology.txt | the container got eth0 and no RDMA device, rdma0 sits under another PCIe root, and the claim asked for accelerators only, with no constraint | ruled in — this is where the fast NIC was left out |

Root cause: the training Pod's claim asked only for accelerators, so the container never got the RDMA NIC and NCCL fell back to sockets on the shared eth0, which all-reduce saturated; a claim that names an RDMA NIC beside the accelerators, with a matchAttribute on their PCIe root, would have stopped this at scheduling instead.

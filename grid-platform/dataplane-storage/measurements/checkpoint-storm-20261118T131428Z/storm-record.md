# Checkpoint storm — 3 writers at once against 1 writer alone, on one shared claim

Host: Darwin 25.5.0 arm64
Container runtime VM: 6.18.36-0-virt kernel, 5 cpu, 8120572Ki memory, as the kind node reports it
Kubernetes: v1.37.0
Other containers on the VM: 6 when the storm started and 6 when it ended, counted by this script with docker ps (this cluster's own node containers left out, no names recorded)
Harness run id: none — this script, not run.sh

## Knobs

| Knob | Value |
|---|---|
| Storm run id | `20261118T131428Z` |
| Writers | 3, each writing once alone in turn (warm-up), then all 3 at once, then storm-writer-0 alone |
| Payload per writer per run | 128 MiB, written with fsync inside the timed region |
| Claim | `spike02-nfs-rwx` (StorageClass `spike02-nfs`, ReadWriteMany) in `spike-02` |
| Writer image | `python@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a` |
| Writer memory limit | 640Mi (SIZE_MB * 3 + 256, the harness's formula) |
| Probe | `probe.py` beside this file, read from ConfigMap `spike-02-probe` |

## Results

| Mode | Writer | Write (MiB/s) |
|---|---|---|
| warm-up | storm-writer-0 | 1.4 |
| warm-up | storm-writer-1 | 128.5 |
| warm-up | storm-writer-2 | 85.9 |
| concurrent | storm-writer-0 | 67.7 |
| concurrent | storm-writer-1 | 68.6 |
| concurrent | storm-writer-2 | 68.8 |
| single | storm-writer-0 | 535 |

The warm-up rows are the volume's first writes from these writers. They are recorded and are
not part of the comparison: the concurrent rows and the single row both ran after them, on a
volume every writer had already written to.

Scope: every figure is for this machine, this VM and this run. None is disk performance: the
host's page cache sits under the VM's disk where the guest cannot evict it. The figures are
recorded beside their configuration and are never compared to a threshold.

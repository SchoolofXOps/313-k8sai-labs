Host: Darwin 25.5.0 arm64
Container runtime VM: 6.18.36-0-virt kernel, 5 cpu, 8120572Ki memory, as the kind node reports it
Kubernetes: v1.37.0
Other containers on the VM: one container from another project: a PostgreSQL database
Harness run id: 20261120T101001Z
Tier split: the split of the local paths (pvc, hostpath) above the network paths (s3, nfs) did not hold throughout: in repetition 1 it held on write and held on read; in repetition 2 it held on write and broke on read (s3 and nfs came out above hostpath)

Scope: no pvc-versus-hostpath claim, no ranking of nfs against s3 on write, and no figure in this directory is disk performance. Every figure is for this machine and this run, with harness-config.md beside it.

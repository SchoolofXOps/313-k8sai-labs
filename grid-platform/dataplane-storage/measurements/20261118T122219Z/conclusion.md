Host: Darwin 25.5.0 arm64
Container runtime VM: 6.18.36-0-virt kernel, 5 cpu, 8120572Ki memory, as the kind node reports it
Kubernetes: v1.37.0
Other containers on the VM: six containers from other projects: two PostgreSQL databases, an LLM gateway, a CPU model server, a chat bot and an Ubuntu shell
Harness run id: 20261118T122454Z
Tier split: both local paths (pvc, hostpath) came out above both network paths (s3, nfs) in the first repetition, on write and on read, but not in the second: s3 came out above both local paths there, on write and on read

Scope: no pvc-versus-hostpath claim, no ranking of nfs against s3 on write, and no figure in this directory is disk performance. Every figure is for this machine and this run, with harness-config.md beside it.

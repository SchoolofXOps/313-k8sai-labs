# Capability probe matrix

One fixed script (m11/probe-matrix.sh), run in probe-sandbox (runsc) and probe-plain (runc) on the same node, with no NetworkPolicy applied.

| Probe | Sandboxed (runsc) | Plain Pod (runc) | Same outcome? |
|---|---|---|---|
| `kernel-version` | `4.19.0-gvisor` | `6.18.36-0-virt` | no |
| `proc-sys-kernel-entries` | `20` | `110` | no |
| `host-kernel-symbols` | `absent` | `readable` | no |
| `raw-socket` | `failed:ping:_permission_denied_(are_you_root?)` | `ok` | no |
| `privileged-op` | `failed:mount:_permission_denied_(are_you_root?)` | `failed:mount:_permission_denied_(are_you_root?)` | yes |
| `cloud-metadata` | `closed` | `closed` | yes |
| `kubernetes-api` | `open token=mounted` | `open token=mounted` | yes |
| `outbound` | `open` | `open` | yes |

## Egress policy, outbound probe re-run

- no policy: sandboxed open, plain open
- sandbox-egress-deny: sandboxed closed, plain closed
- plus sandbox-egress-allow-443: sandboxed open, plain open
- the deny policy closed outbound TCP 443 for the sandboxed Pod, and the allow policy reopened it

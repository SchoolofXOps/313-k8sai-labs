# Platform design

The platform runs AI workloads for three internal tenants on one shared fleet of accelerators. This document records who the tenants are, what they run, what the platform offers today, who owns each layer, and the decisions that later modules make.

## Tenants

| Tenant | What it runs | Priority |
| --- | --- | --- |
| `research` | distributed training and fine-tuning experiments | waits in a queue; may be preempted by `product` |
| `data` | batch dataset preparation | lowest; may be interrupted and resumed |
| `product` | models served to users, and the agents built on them | highest; capacity must be there when traffic arrives |

## Workload classes

| Class | Tenants | What it needs from the platform |
| --- | --- | --- |
| Data preparation | `data` | CPU-heavy batch jobs, fast reads from object storage, tolerance of interruption |
| Training and fine-tuning | `research` | a group of Pods placed all at once or not at all, devices requested by attribute, checkpoints that survive a lost worker |
| Inference | `product` | a readiness gate for a slow model load, autoscaling on a queue signal, routing by load and cache locality |
| Agents | `product`, `research` | a sandboxed runtime, a narrow identity per tool server, an audit trail of every change |

## Capabilities

Capacity and cost inputs: the [capacity model](capacity-model.md) and the [cost model](cost-model.md), from Module 2. Status today comes from [the gap report](kar-gap-report.md).

| Capability | Status today | Delivered by |
| --- | --- | --- |
| Devices requested by attribute | not available: resource.k8s.io/v1 served, no driver | M4 |
| Quota, queues and gang admission | not available: no queueing layer installed | M5 |
| Storage and network paths that keep accelerators busy | not available | M6 |
| Training that resumes from a checkpoint | not available: no training operator installed | M7 |
| Model serving with autoscaling on a queue signal | not available: no metrics API registered | M8 |
| Routing by load and cache locality | not available: no Gateway API served | M9 |
| A data layer, verified artifacts and promotion through Git | not available | M10 |
| Sandboxed agents with a narrow identity | not available: no RuntimeClass defined | M11 |
| Metrics, cost per tenant and recovery | not available: no monitoring stack | M12 |

## Architecture by layer

| Layer | Components | Owner |
| --- | --- | --- |
| `nodes` | device driver, DeviceClasses, ResourceClaimTemplates | `DRA` driver, run by `platform` |
| `capacity` | ResourceFlavors, ClusterQueues, LocalQueues, PriorityClasses | `Kueue`, configured by `platform` |
| `dataplane-storage` | StorageClasses, cache tiers, secondary networks | `platform` |
| `training` | training runtimes, job templates, checkpoint policy | training operator, run by `platform`; jobs owned by `research` |
| `serving` | model-server Deployments, probes, autoscalers | `platform` runtime; models owned by `product` |
| `routing` | InferencePool, endpoint picker, Gateway and routes | `Gateway API` implementation, run by `platform` |
| `datalayer` | vector database, ingestion workflows, admission policy | `platform`; data owned by `data` |
| `agents` | sandbox templates, tool servers, RBAC, egress policy | `platform`; agents owned by `product` |
| `observability` | Prometheus rules, dashboards, chargeback queries | `platform` |

## Ownership boundaries

| Boundary | Owner |
| --- | --- |
| which device a claim gets | `DRA` |
| when a batch workload is admitted against quota | `Kueue` |
| the tenants, the quota and the capability list | `platform` |
| the model, its framework and its weights | `research` and `product` |
| prompts, keys and per-team budgets above the model endpoint | `product` |

## Decisions deferred

| Decision | Deferred to | Why not now |
| --- | --- | --- |
| which device classes exist and which sharing mode each allows | M4 | no driver publishes a device yet |
| how much quota each tenant gets, and who may borrow | M5 | the objects that enforce quota arrive in M5 |
| where checkpoints are written | M6 | the storage paths are measured in M6 |
| how model weights reach a node | M8 | the delivery paths are compared in M8 |
| which routing policy each model uses | M9 | routing needs model servers to route to |
| what an agent may do without approval | M11 | the autonomy policy is written in M11 |
| how long a model artifact stays in the registry after its last deployment | M10 | artifact verification and promotion through Git arrive in M10 |

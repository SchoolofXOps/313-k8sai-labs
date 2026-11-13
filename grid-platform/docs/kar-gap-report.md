# KAR gap report

Source: the Kubernetes AI Conformance checklist for 1.37, `docs/AIConformance-1.37.yaml` at commit `c64e5bc8085da207715df96e458f2c6585c9f53e` of `cncf/k8s-ai-conformance`. Cluster: `grid-core` at SIZE=8 with no addons, Kubernetes v1.37.0. Audited on 2026-11-12.

## Headline

resource.k8s.io/v1 is served, but no driver publishes a ResourceSlice: no device can be requested by attribute yet. Module 4 closes this.

## Requirements

| Item | Category | Level | Verdict | Evidence command | Reading | Closed by |
| --- | --- | --- | --- | --- | --- | --- |
| `accelerator-driver-runtime` | accelerators | SHOULD | not verifiable on this cluster | `kubectl --context kind-grid-core get resourceslices` | no accelerator and no driver; zero ResourceSlices | M4 (synthetic devices) |
| `accelerator-sharing` | accelerators | SHOULD | not verifiable on this cluster | `kubectl --context kind-grid-core api-resources --api-group=resource.k8s.io` | the DRA API is served; there is no device to share | M4 |
| `virtualized-accelerator` | accelerators | SHOULD | not applicable | none | no virtualized accelerator exists on a laptop | M4 (concepts only) |
| `inference-gateway` | networking | MUST | verifiable here | `kubectl --context kind-grid-core api-resources --api-group=gateway.networking.k8s.io` | no Gateway API resources served: a gap | M9 |
| `inference-extension-routing` | networking | SHOULD | verifiable here | `kubectl --context kind-grid-core api-resources --api-group=inference.networking.k8s.io` | nothing served: a gap | M9 |
| `high-performance-networking` | networking | SHOULD | not verifiable on this cluster | none | needs RDMA-class network hardware | M6 (BRIEF) |
| `disaggregated-inference` | networking | SHOULD | verifiable here | `kubectl --context kind-grid-core get pods -A` | no inference server installed: a gap | M9 (BRIEF) |
| `gang-scheduling` | schedulingOrchestration | MUST | verifiable here | `kubectl --context kind-grid-core api-versions` | scheduling.k8s.io/v1beta1 is served, but no gang-scheduling solution is installed: a gap | M5 |
| `cluster-autoscaling` | schedulingOrchestration | MUST | not applicable | none | a kind cluster has no node groups; the checklist allows not applicable with this justification | M4 (BRIEF, 4.7) |
| `pod-autoscaling` | schedulingOrchestration | MUST | verifiable here | `kubectl --context kind-grid-core get apiservice v1beta1.metrics.k8s.io` | autoscaling/v2 is served, but no metrics API is registered: a gap | M8 |
| `accelerator-metrics` | observability | MUST | not verifiable on this cluster | none | there is no accelerator to measure | M12 |
| `ai-service-metrics` | observability | MUST | verifiable here | `kubectl --context kind-grid-core api-resources --api-group=monitoring.coreos.com` | no monitoring stack: a gap | M12 |
| `secure-accelerator-access` | security | MUST | verifiable here | `kubectl --context kind-grid-core get resourceslices` | resource.k8s.io/v1 is served, but no driver publishes a ResourceSlice: the headline gap | M4 |
| `workload-sandboxing` | security | SHOULD | verifiable here | `kubectl --context kind-grid-core get runtimeclass` | no RuntimeClass: a gap | M11 |
| `ai-operator` | operator | MUST | verifiable here | `kubectl --context kind-grid-core get crd` | no AI operator CRDs: a gap | M7 |

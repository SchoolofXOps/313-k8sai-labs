#!/usr/bin/env bash
# List the Kubernetes AI Conformance requirements for Kubernetes 1.37, read from a pinned commit of
# the CNCF conformance repository. Prints category, level and the course label for each item, then
# a count line. Reads nothing from your cluster.
set -euo pipefail
KAR_COMMIT=c64e5bc8085da207715df96e458f2c6585c9f53e
KAR_URL="https://raw.githubusercontent.com/cncf/k8s-ai-conformance/${KAR_COMMIT}/docs/AIConformance-1.37.yaml"
curl -fsSL "$KAR_URL" | LC_ALL=C awk '
BEGIN {
  label["accelerators 1"] = "accelerator-driver-runtime"
  label["accelerators 2"] = "accelerator-sharing"
  label["accelerators 3"] = "virtualized-accelerator"
  label["networking 1"] = "inference-gateway"
  label["networking 2"] = "inference-extension-routing"
  label["networking 3"] = "high-performance-networking"
  label["networking 4"] = "disaggregated-inference"
  label["schedulingOrchestration 1"] = "gang-scheduling"
  label["schedulingOrchestration 2"] = "cluster-autoscaling"
  label["schedulingOrchestration 3"] = "pod-autoscaling"
  label["observability 1"] = "accelerator-metrics"
  label["observability 2"] = "ai-service-metrics"
  label["security 1"] = "secure-accelerator-access"
  label["security 2"] = "workload-sandboxing"
  label["operator 1"] = "ai-operator"
}
/^spec:/ { inspec = 1; next }
inspec && /^  [A-Za-z]+:$/ { cat = $1; sub(/:$/, "", cat); n = 0; next }
inspec && /^    - id:/ { n++; next }
inspec && /^      level:/ {
  key = cat " " n
  if (!(key in label)) { printf "UNLABELLED item: %s\n", key; bad = 1 }
  printf "%-24s %-6s %s\n", cat, $2, label[key]
  total++
  if ($2 == "MUST") must++
  else if ($2 == "SHOULD") should++
}
END {
  printf "requirements=%d MUST=%d SHOULD=%d\n", total, must, should
  if (bad || total != 15) exit 1
}'

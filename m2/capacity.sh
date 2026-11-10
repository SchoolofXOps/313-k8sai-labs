#!/usr/bin/env bash
# capacity.sh DEMAND.conf
# Estimates the accelerators one model service needs from demand, then varies each input by 25 percent.
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/read-conf.sh
. "$HERE/lib/read-conf.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: bash m2/capacity.sh DEMAND.conf" >&2
  exit 2
fi
D="$1"
# model_file and accelerators_file are written relative to the labs tree root (the directory that
# holds m2/), as the shipped demand.conf has them. Resolve them against that root, not the caller's
# directory, so the calculator works from anywhere; the header still prints them as written.
from_root() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$(cd "$HERE/.." && pwd)" "$1" ;; esac; }
MODEL_AS_WRITTEN=$(conf_get "$D" model_file)
AFILE_AS_WRITTEN=$(conf_get "$D" accelerators_file)
MODEL=$(from_root "$MODEL_AS_WRITTEN")
AFILE=$(from_root "$AFILE_AS_WRITTEN")
ACC=$(conf_get "$D" accelerator)
PARAMS=$(conf_num "$MODEL" parameters)
LAYERS=$(conf_pos "$MODEL" num_hidden_layers)
KVH=$(conf_pos "$MODEL" num_key_value_heads)
HD=$(conf_pos "$MODEL" head_dim)
NAME=$(conf_get "$MODEL" name)
LABEL=$(conf_get "$AFILE" "${ACC}_label")
MEM=$(conf_pos "$AFILE" "${ACC}_memory_gb")
PB=$(conf_pos "$D" precision_bytes)
OVH=$(conf_num "$D" overhead_fraction)
RPS=$(conf_num "$D" arrival_rate_rps)
LAT=$(conf_num "$D" mean_latency_s)
CTX=$(conf_pos "$D" context_tokens)
TPR=$(conf_num "$D" tokens_per_request)
TPS=$(conf_pos "$D" tokens_per_second_per_replica)
RES=$(conf_num "$D" failure_reserve_fraction)
FRAG=$(conf_num "$D" fragmentation_fraction)

assumptions_header
echo "  demand file: $D"
conf_dump "$D"
echo "  model file: $MODEL_AS_WRITTEN"
conf_dump "$MODEL" '^(name|revision|parameters|num_hidden_layers|num_key_value_heads|head_dim)$'
echo "  accelerator: $ACC"
conf_dump "$AFILE" "^${ACC}_(label|memory_gb)\$"
echo "  method: concurrency = arrival rate * latency (Little's law); replicas = the larger of the memory need and the throughput need"
echo

awk -v params="$PARAMS" -v layers="$LAYERS" -v kvh="$KVH" -v hd="$HD" -v pb="$PB" -v ovh="$OVH" \
    -v mem="$MEM" -v rps="$RPS" -v lat="$LAT" -v ctx="$CTX" -v tpr="$TPR" -v tps="$TPS" \
    -v res="$RES" -v frag="$FRAG" -v name="$NAME" -v label="$LABEL" '
function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
function ceilp(x) { return ceil(x - 1e-9 > 0 ? x - 1e-9 : x) }
# fleet(rps, lat, ctx, tpr, tps, res, frag) sets R_* globals and returns the recommended accelerator count,
# or -1 when even 64 accelerators per replica cannot hold the weights plus the cache of one request
function fleet(rps, lat, ctx, tpr, tps, res, frag,    w, kvr, n, cmax, conc, rmem, rthr, rbind, rres, acc) {
  w = params * pb / 1e9
  kvr = 2 * layers * kvh * hd * pb * ctx / 1e9
  conc = rps * lat
  n = 1
  while (1) {
    cmax = int((n * mem / (1 + ovh) - w) / kvr)
    if (cmax >= 1) break
    n++
    if (n > 64) break
  }
  R_conc = conc; R_w = w; R_kvr = kvr
  if (cmax < 1) return -1
  rmem = ceilp(conc / cmax)
  rthr = ceilp(rps * tpr / tps)
  rbind = (rmem > rthr) ? rmem : rthr
  rres = ceilp(rbind * (1 + res))
  acc = ceilp(rres * n * (1 + frag))
  R_conc = conc; R_n = n; R_cmax = cmax; R_rmem = rmem; R_rthr = rthr; R_rbind = rbind
  R_rres = rres; R_pre = rres * n; R_w = w; R_kvr = kvr
  R_which = (rmem > rthr) ? "memory" : ((rthr > rmem) ? "throughput" : "both equally")
  return acc
}
BEGIN {
  base = fleet(rps, lat, ctx, tpr, tps, res, frag)
  printf "RESULTS (modelled for %s on %s):\n", name, label
  printf "concurrent_requests=%.1f\n", R_conc
  printf "weights_gb=%.2f\n", R_w
  printf "kv_gb_per_request=%.3f\n", R_kvr
  if (base < 0) {
    print "accelerators_per_replica=does-not-fit-within-64 (the weights plus the cache of one request need more than 64 of these accelerators)"
    print "accelerators_recommended=does-not-fit-within-64"
  } else {
  printf "accelerators_per_replica=%.0f\n", R_n
  printf "max_concurrent_requests_per_replica=%.0f\n", R_cmax
  printf "replicas_from_memory=%.0f\n", R_rmem
  printf "replicas_from_throughput=%.0f\n", R_rthr
  printf "replicas_binding=%.0f (%s binds)\n", R_rbind, R_which
  printf "replicas_with_failure_reserve=%.0f\n", R_rres
  printf "accelerators_before_fragmentation=%.0f\n", R_pre
  printf "accelerators_recommended=%.0f\n", base
  }
  print ""
  print "SENSITIVITY (each input varied by 25 percent, others held at their stated value):"
  printf "%-32s %12s %10s %10s %7s\n", "input", "base_value", "at_minus25", "at_plus25", "swing"
  names[1] = "arrival_rate_rps";            vals[1] = rps
  names[2] = "mean_latency_s";              vals[2] = lat
  names[3] = "context_tokens";              vals[3] = ctx
  names[4] = "tokens_per_request";          vals[4] = tpr
  names[5] = "tokens_per_second_per_replica"; vals[5] = tps
  names[6] = "failure_reserve_fraction";    vals[6] = res
  names[7] = "fragmentation_fraction";      vals[7] = frag
  # every input that ties for the largest swing is named: naming the first of two equal swings
  # would tell the learner one input dominates when two move the answer equally
  best = -1; bestname = ""
  for (i = 1; i <= 7; i++) {
    for (j = 0; j < 2; j++) {
      f = (j == 0) ? 0.75 : 1.25
      a = rps; b = lat; c = ctx; d = tpr; e = tps; g = res; h = frag
      if (i == 1) a = rps * f
      if (i == 2) b = lat * f
      if (i == 3) c = ctx * f
      if (i == 4) d = tpr * f
      if (i == 5) e = tps * f
      if (i == 6) g = res * f
      if (i == 7) h = frag * f
      out[j] = fleet(a, b, c, d, e, g, h)
    }
    # a case that does not fit is printed as such; it has no swing to compare
    lo = (out[0] < 0) ? "no-fit" : out[0]; hi = (out[1] < 0) ? "no-fit" : out[1]
    if (out[0] < 0 || out[1] < 0) { printf "%-32s %12s %10s %10s %7s\n", names[i], vals[i], lo, hi, "n/a"; continue }
    sw = out[1] - out[0]; if (sw < 0) sw = -sw
    printf "%-32s %12s %10s %10s %7.0f\n", names[i], vals[i], lo, hi, sw
    if (sw > best) { best = sw; bestname = names[i] } else if (sw == best) bestname = bestname "," names[i]
  }
  if (best < 0) print "largest_swing=none (no varied case fits within 64 accelerators per replica)"
  else printf "largest_swing=%s (%.0f accelerators between the two cases)\n", bestname, best
}'

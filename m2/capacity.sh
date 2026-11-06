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
MODEL=$(conf_get "$D" model_file)
AFILE=$(conf_get "$D" accelerators_file)
ACC=$(conf_get "$D" accelerator)
PARAMS=$(conf_num "$MODEL" parameters)
LAYERS=$(conf_num "$MODEL" num_hidden_layers)
KVH=$(conf_num "$MODEL" num_key_value_heads)
HD=$(conf_num "$MODEL" head_dim)
NAME=$(conf_get "$MODEL" name)
LABEL=$(conf_get "$AFILE" "${ACC}_label")
MEM=$(conf_num "$AFILE" "${ACC}_memory_gb")
PB=$(conf_num "$D" precision_bytes)
OVH=$(conf_num "$D" overhead_fraction)
RPS=$(conf_num "$D" arrival_rate_rps)
LAT=$(conf_num "$D" mean_latency_s)
CTX=$(conf_num "$D" context_tokens)
TPR=$(conf_num "$D" tokens_per_request)
TPS=$(conf_num "$D" tokens_per_second_per_replica)
RES=$(conf_num "$D" failure_reserve_fraction)
FRAG=$(conf_num "$D" fragmentation_fraction)

assumptions_header
echo "  demand file: $D"
conf_dump "$D"
echo "  model file: $MODEL"
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
# fleet(rps, lat, ctx, tpr, tps, res, frag) sets R_* globals and returns the recommended accelerator count
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
  printf "accelerators_per_replica=%d\n", R_n
  printf "max_concurrent_requests_per_replica=%d\n", R_cmax
  printf "replicas_from_memory=%d\n", R_rmem
  printf "replicas_from_throughput=%d\n", R_rthr
  printf "replicas_binding=%d (%s binds)\n", R_rbind, R_which
  printf "replicas_with_failure_reserve=%d\n", R_rres
  printf "accelerators_before_fragmentation=%d\n", R_pre
  printf "accelerators_recommended=%d\n", base
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
  best = 0; bestname = names[1]
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
    sw = out[1] - out[0]; if (sw < 0) sw = -sw
    printf "%-32s %12s %10d %10d %7d\n", names[i], vals[i], out[0], out[1], sw
    if (sw > best) { best = sw; bestname = names[i] }
  }
  printf "largest_swing=%s (%d accelerators between the two cases)\n", bestname, best
}'

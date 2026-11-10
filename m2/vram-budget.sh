#!/usr/bin/env bash
# vram-budget.sh MODEL.conf SCENARIO.conf
# Estimates the memory one model server needs and whether it fits on each accelerator in inputs/accelerators.conf.
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/read-conf.sh
. "$HERE/lib/read-conf.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: bash m2/vram-budget.sh MODEL.conf SCENARIO.conf" >&2
  exit 2
fi
MODEL="$1"
SCEN="$2"
ACCEL="$HERE/inputs/accelerators.conf"

NAME=$(conf_get "$MODEL" name)
PARAMS=$(conf_num "$MODEL" parameters)
LAYERS=$(conf_num "$MODEL" num_hidden_layers)
KVH=$(conf_num "$MODEL" num_key_value_heads)
HD=$(conf_num "$MODEL" head_dim)
PB=$(conf_num "$SCEN" precision_bytes)
CTX=$(conf_num "$SCEN" context_tokens)
CONC=$(conf_num "$SCEN" concurrent_requests)
OVH=$(conf_num "$SCEN" overhead_fraction)
LIST=$(conf_get "$ACCEL" accelerators)

assumptions_header
echo "  model file: $MODEL"
conf_dump "$MODEL" '^(name|revision|parameters|num_hidden_layers|num_key_value_heads|head_dim|native_precision)$'
echo "  scenario file: $SCEN"
conf_dump "$SCEN" '^(precision_bytes|context_tokens|concurrent_requests|overhead_fraction)$'
echo "  accelerator file: m2/inputs/accelerators.conf"
conf_dump "$ACCEL" '_(label|memory_gb)$'
echo "  formula: weights = parameters * precision_bytes; kv per token = 2 * layers * kv_heads * head_dim * precision_bytes"
echo "  formula: total = (weights + kv for all concurrent requests) * (1 + overhead_fraction)"
echo
echo "RESULTS (modelled for $NAME):"
# One awk program computes the total AND the fit verdict, from the exact total in bytes. The total
# never leaves awk: printed with %d and parsed back by the shell, it clamped at 2^31-1 on awks
# whose %d goes through a C int (mawk), and every model then "fit" every card. Integers print with
# %.0f for the same reason.
ROWS=""
for a in $LIST; do
  LABEL=$(conf_get "$ACCEL" "${a}_label")
  MEM=$(conf_num "$ACCEL" "${a}_memory_gb")
  ROWS="${ROWS}${LABEL}	${MEM}
"
done
printf '%s' "$ROWS" | awk -F '\t' -v p="$PARAMS" -v l="$LAYERS" -v k="$KVH" -v h="$HD" -v b="$PB" -v c="$CTX" -v n="$CONC" -v o="$OVH" '
  BEGIN {
    w = p * b; kvt = 2 * l * k * h * b; kvr = kvt * c; kva = kvr * n
    tot = (w + kva) * (1 + o)
    printf "weights_gb=%.2f\n", w / 1e9
    printf "kv_bytes_per_token=%.0f\n", kvt
    printf "kv_gb_per_request=%.3f\n", kvr / 1e9
    printf "kv_gb_all_requests=%.2f\n", kva / 1e9
    printf "overhead_gb=%.2f\n", (w + kva) * o / 1e9
    printf "total_gb=%.2f\n", tot / 1e9
    print ""
    print "FIT ON ONE ACCELERATOR (modelled, no tensor parallelism, vendor memory used as printed):"
  }
  NF == 2 {
    head = $2 - tot / 1e9
    printf "%-24s %5.0f GB  %-12s headroom_gb=%.2f\n", $1, $2, (head >= 0 ? "fits" : "does not fit"), head
  }'

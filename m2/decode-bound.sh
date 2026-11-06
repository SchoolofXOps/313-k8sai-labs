#!/usr/bin/env bash
# decode-bound.sh MODEL.conf
# Estimates an upper bound on single-request decode speed: memory bandwidth divided by the weight bytes read per token.
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/read-conf.sh
. "$HERE/lib/read-conf.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: bash m2/decode-bound.sh MODEL.conf" >&2
  exit 2
fi
MODEL="$1"
ACCEL="$HERE/inputs/accelerators.conf"
NAME=$(conf_get "$MODEL" name)
PARAMS=$(conf_num "$MODEL" parameters)
PB=$(conf_num "$MODEL" native_precision_bytes)
LIST=$(conf_get "$ACCEL" accelerators)

assumptions_header
echo "  model file: $MODEL"
conf_dump "$MODEL" '^(name|revision|parameters|native_precision|native_precision_bytes)$'
echo "  accelerator file: m2/inputs/accelerators.conf"
conf_dump "$ACCEL" '_(label|memory_gb|bandwidth_gb_s)$'
echo "  conditions: batch size 1, weights read once per token, no cache reads, no kernel overhead, no overlap"
echo "  bound: tokens per second <= memory bandwidth (GB/s) / weight bytes (GB)"
echo
echo "RESULTS (modelled for $NAME):"
W=$(awk -v p="$PARAMS" -v b="$PB" 'BEGIN { printf "%.6f", p * b / 1e9 }')
for a in $LIST; do
  LABEL=$(conf_get "$ACCEL" "${a}_label")
  BW=$(conf_num "$ACCEL" "${a}_bandwidth_gb_s")
  MEM=$(conf_num "$ACCEL" "${a}_memory_gb")
  awk -v bw="$BW" -v w="$W" -v lab="$LABEL" -v key="$a" -v mem="$MEM" 'BEGIN {
    note = (w > mem) ? " [weights exceed one card]" : ""
    printf "%-10s %-24s %6.0f GB/s / %8.4f GB = %7.1f tokens/s%s (estimate)\n", key, lab, bw, w, bw / w, note
  }'
done

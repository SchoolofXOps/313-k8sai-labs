#!/usr/bin/env bash
# kv-blocks.sh MODEL.conf SCENARIO.conf
# Estimates the cache memory wasted at the end of each sequence's last block, for paged blocks and for a reserve-the-maximum scheme.
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/read-conf.sh
. "$HERE/lib/read-conf.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: bash m2/kv-blocks.sh MODEL.conf SCENARIO.conf" >&2
  exit 2
fi
MODEL="$1"
SCEN="$2"
NAME=$(conf_get "$MODEL" name)
LAYERS=$(conf_num "$MODEL" num_hidden_layers)
KVH=$(conf_num "$MODEL" num_key_value_heads)
HD=$(conf_num "$MODEL" head_dim)
PB=$(conf_num "$SCEN" precision_bytes)
CTX=$(conf_num "$SCEN" context_tokens)
CONC=$(conf_num "$SCEN" concurrent_requests)
BLK=$(conf_num "$SCEN" block_tokens)
SAMPLE=$(conf_get "$SCEN" sequence_tokens_sample)

assumptions_header
echo "  model file: $MODEL"
conf_dump "$MODEL" '^(name|revision|num_hidden_layers|num_key_value_heads|head_dim)$'
echo "  scenario file: $SCEN"
conf_dump "$SCEN" '^(precision_bytes|context_tokens|concurrent_requests|block_tokens|sequence_tokens_sample)$'
echo "  method: a sequence of L tokens needs ceil(L / block_tokens) blocks; the unused tail of its last block is internal fragmentation"
echo "  method: the reserve-the-maximum scheme sets aside context_tokens for every request, whatever its real length"
echo
echo "RESULTS (modelled for $NAME):"
awk -v l="$LAYERS" -v k="$KVH" -v h="$HD" -v b="$PB" -v ctx="$CTX" -v conc="$CONC" -v blk="$BLK" -v sample="$SAMPLE" '
function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
BEGIN {
  kvt = 2 * l * k * h * b
  printf "block_bytes=%d\n", kvt * blk
  printf "%-8s %-8s %-10s %-14s %-16s\n", "tokens", "blocks", "tail_waste", "paged_waste_pct", "reserved_waste_pct"
  n = split(sample, s, " ")
  for (i = 1; i <= n; i++) {
    L = s[i]; nb = ceil(L / blk); alloc = nb * blk
    waste = alloc - L; rwaste = ctx - L
    printf "%-8d %-8d %-10d %-14.1f %-16.1f\n", L, nb, waste, 100 * waste / alloc, 100 * rwaste / ctx
    tw += waste; ta += alloc; tr += ctx - L; tl += L; tb += nb
  }
  printf "mean_blocks_per_request=%.1f\n", tb / n
  printf "paged_waste_gb_for_all_requests=%.4f\n", (tw / n) * conc * kvt / 1e9
  printf "reserved_waste_gb_for_all_requests=%.4f\n", (tr / n) * conc * kvt / 1e9
  printf "paged_fragmentation_pct=%.2f\n", 100 * tw / ta
  printf "reserved_fragmentation_pct=%.2f\n", 100 * tr / (n * ctx)
}'

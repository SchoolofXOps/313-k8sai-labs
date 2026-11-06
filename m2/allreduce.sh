#!/usr/bin/env bash
# allreduce.sh INTERCONNECT.conf
# Estimates the bandwidth term of a ring all-reduce: 2(N-1)/N * S / B, for each link class in the file.
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/read-conf.sh
. "$HERE/lib/read-conf.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: bash m2/allreduce.sh INTERCONNECT.conf" >&2
  exit 2
fi
F="$1"
N=$(conf_num "$F" participants)
S=$(conf_num "$F" message_gb)
LIST=$(conf_get "$F" links)

assumptions_header
echo "  interconnect file: $F"
conf_dump "$F"
echo "  conditions: bandwidth term only; ignores per-hop latency, overlap with compute and the topology of the real fabric"
echo "  formula: time = 2 * (N - 1) / N * S / B"
echo
echo "RESULTS (modelled):"
for l in $LIST; do
  LABEL=$(conf_get "$F" "${l}_label")
  B=$(conf_num "$F" "${l}_gb_s")
  awk -v n="$N" -v s="$S" -v b="$B" -v lab="$LABEL" -v key="$l" 'BEGIN {
    printf "%-12s %-28s B=%6.1f GB/s time_s=%.4f (estimate)\n", key, lab, b, 2 * (n - 1) / n * s / b
  }'
done

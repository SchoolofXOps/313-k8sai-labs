#!/usr/bin/env bash
# load.sh — request loops for the M1 lab, run through the in-cluster 'client' Pod.
#
#   bash m1/load.sh probe              one completion through the Service, print the result line
#   bash m1/load.sh ready [attempts]   one request per second until one is answered (default 30), print each
#   bash m1/load.sh loop [seconds]     one request per second through the Service, print the result of each
#   bash m1/load.sh load [workers] [seconds]
#                                      N concurrent request loops through the Service, for a queue to form
#
# Every request goes 'kubectl exec client -- wget ... http://sim:8000'. Nothing here is a measurement:
# the simulator models its latency from a published profile.
# bash 3.2 compatible.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"
K="kubectl --context kind-grid-core -n m1-baseline"
BODY='{"model":"m1-sim","prompt":"Say hello from the platform team","max_tokens":32}'

one() {
  # prints the HTTP status line, or the wget error text when the connection is refused
  $K exec client -- sh -c "wget -q -S -O /dev/null -T 3 --header 'Content-Type: application/json' --post-data '$BODY' http://sim:8000/v1/completions 2>&1 | grep -E 'HTTP/|wget:' | head -1" || true
}

mode="${1:-probe}"
case "$mode" in
  probe)
    one
    ;;
  ready)
    # The simulator opens its port a moment AFTER it logs startup-state=serving, so a single probe
    # sent on that log line can be refused. Send one request per second until one is answered,
    # printing every attempt, and give up after the bound with a non-zero exit.
    tries="${2:-30}"
    n=1
    while [ "$n" -le "$tries" ]; do
      r="$(one)"
      printf 'attempt %s: %s\n' "$n" "$r"
      case "$r" in
        *"HTTP/1.1 200"*) exit 0 ;;
      esac
      sleep 1
      n=$((n + 1))
    done
    echo "no answer within $tries attempts"
    exit 1
    ;;
  loop)
    secs="${2:-100}"
    i=0
    while [ "$i" -lt "$secs" ]; do
      printf '%s %s\n' "$(date -u +%H:%M:%S)" "$(one)"
      sleep 1
      i=$((i + 1))
    done
    ;;
  load)
    workers="${2:-20}"
    secs="${3:-45}"
    $K exec client -- sh -c "
      end=\$((\$(date +%s) + $secs))
      w=0
      while [ \$w -lt $workers ]; do
        ( while [ \$(date +%s) -lt \$end ]; do
            wget -q -O /dev/null -T 30 --header 'Content-Type: application/json' --post-data '$BODY' http://sim:8000/v1/completions || true
          done ) &
        w=\$((w + 1))
      done
      wait
    "
    ;;
  *)
    echo "usage: bash m1/load.sh probe | ready [attempts] | loop [seconds] | load [workers] [seconds]" >&2
    exit 2
    ;;
esac

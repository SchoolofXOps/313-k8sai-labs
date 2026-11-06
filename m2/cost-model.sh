#!/usr/bin/env bash
# cost-model.sh COST.conf
# Models the annual cost of an accelerator fleet at two utilisation levels, then the effect of each of four levers.
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/read-conf.sh
. "$HERE/lib/read-conf.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: bash m2/cost-model.sh COST.conf" >&2
  exit 2
fi
C="$1"
N=$(conf_num "$C" accelerators)
HRS=$(conf_num "$C" hours_per_year)
BASIS=$(conf_get "$C" price_basis)
PRICE=$(conf_num "$C" "price_${BASIS}_usd_per_accel_hour")
PD=$(conf_num "$C" price_on_demand_usd_per_accel_hour)
PR=$(conf_num "$C" price_reserved_usd_per_accel_hour)
PS=$(conf_num "$C" price_spot_usd_per_accel_hour)
UL=$(conf_num "$C" utilisation_low)
UH=$(conf_num "$C" utilisation_high)
TPS=$(conf_num "$C" tokens_per_second_per_accelerator)
SH=$(conf_num "$C" share_utilisation_gain)
QU=$(conf_num "$C" queue_utilisation_gain)
PK=$(conf_num "$C" pack_accelerators_released)
RC=$(conf_num "$C" reclaim_idle_fraction)

assumptions_header
echo "  cost file: $C"
conf_dump "$C"
echo "  prices are declared assumptions - replace with your own quote. They are not market rates."
echo "  the lever effects are declared assumptions - replace with your own measurement."
echo "  levers are shown one at a time against utilisation_low; their effects overlap, so do not add them up"
echo

awk -v n="$N" -v hrs="$HRS" -v basis="$BASIS" -v price="$PRICE" -v pd="$PD" -v pr="$PR" -v ps="$PS" \
    -v ul="$UL" -v uh="$UH" -v tps="$TPS" -v sh="$SH" -v qu="$QU" -v pk="$PK" -v rc="$RC" '
function row(tag, u, cost, accel,    useful) {
  useful = accel * hrs * u
  printf "%-8s utilisation=%.2f useful_accel_hours=%d cost_usd=%d usd_per_useful_accel_hour=%.2f useful_tokens_per_usd=%d\n", \
    tag, u, useful, cost, cost / useful, tps * 3600 * u / price
}
BEGIN {
  cost = n * hrs * price
  print "RESULTS (modelled):"
  printf "accelerator_hours_per_year=%d\n", n * hrs
  printf "annual_fleet_cost_usd=%d\n", cost
  printf "annual_cost_on_demand_usd=%d\n", n * hrs * pd
  printf "annual_cost_reserved_usd=%d\n", n * hrs * pr
  printf "annual_cost_spot_usd=%d\n", n * hrs * ps
  printf "price_basis=%s usd_per_accel_hour=%.2f\n", basis, price
  print ""
  print "FLEET AT TWO UTILISATION LEVELS:"
  row("low", ul, cost, n)
  row("high", uh, cost, n)
  print ""
  print "THE FOUR LEVERS (each alone, against utilisation_low):"
  row("base", ul, cost, n)
  row("share", ul + sh, cost, n)
  row("queue", ul + qu, cost, n)
  # pack: same useful hours on fewer accelerators
  useful0 = n * hrs * ul
  nn = n - pk
  printf "%-8s accelerators=%d utilisation=%.2f useful_accel_hours=%d cost_usd=%d usd_per_useful_accel_hour=%.2f saving_usd=%d\n", \
    "pack", nn, useful0 / (nn * hrs), useful0, nn * hrs * price, nn * hrs * price / useful0, pk * hrs * price
  # reclaim: return a fraction of idle hours, so they are not paid for
  # whole hours, rounded once, so the printed hours, cost and saving agree with each other
  idle = n * hrs * (1 - ul)
  ret = int(idle * rc + 0.5)
  rsave = int(ret * price + 0.5)
  rcost = cost - rsave
  printf "%-8s idle_hours_returned=%d utilisation=%.2f useful_accel_hours=%d cost_usd=%d usd_per_useful_accel_hour=%.2f saving_usd=%d\n", \
    "reclaim", ret, useful0 / (n * hrs - ret), useful0, rcost, rcost / useful0, rsave
}'

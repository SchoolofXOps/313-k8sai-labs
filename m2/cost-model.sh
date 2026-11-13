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
N=$(conf_pos "$C" accelerators)
HRS=$(conf_pos "$C" hours_per_year)
BASIS=$(conf_get "$C" price_basis)
PRICE=$(conf_pos "$C" "price_${BASIS}_usd_per_accel_hour")
PD=$(conf_num "$C" price_on_demand_usd_per_accel_hour)
PR=$(conf_num "$C" price_reserved_usd_per_accel_hour)
PS=$(conf_num "$C" price_spot_usd_per_accel_hour)
UL=$(conf_pos "$C" utilisation_low)
UH=$(conf_pos "$C" utilisation_high)
TPS=$(conf_num "$C" tokens_per_second_per_accelerator)
SH=$(conf_num "$C" share_utilisation_gain)
QU=$(conf_num "$C" queue_utilisation_gain)
PK=$(conf_num "$C" pack_accelerators_released)
RC=$(conf_num "$C" reclaim_idle_fraction)
# pack divides by the accelerators left after the release, so at least one must be left.
if ! awk -v n="$N" -v pk="$PK" 'BEGIN { exit !(pk < n) }'; then
  echo "error: pack_accelerators_released ($PK) must be fewer than accelerators ($N) in $C" >&2
  exit 2
fi

assumptions_header
echo "  cost file: $C"
conf_dump "$C"
echo "  prices are declared assumptions - replace with your own quote. They are not market rates."
echo "  the lever effects are declared assumptions - replace with your own measurement."
echo "  levers are shown one at a time against utilisation_low; their effects overlap, so do not add them up"
echo

awk -v n="$N" -v hrs="$HRS" -v basis="$BASIS" -v price="$PRICE" -v pd="$PD" -v pr="$PR" -v ps="$PS" \
    -v ul="$UL" -v uh="$UH" -v tps="$TPS" -v sh="$SH" -v qu="$QU" -v pk="$PK" -v rc="$RC" '
# Every printed money and hour figure is rounded ONCE, by r(), and every figure derived from
# printed ones (the saving of a lever, a rate per useful hour) is computed from the rounded values, so
# the printed numbers reproduce each other: the cost of a lever plus its saving is the fleet cost, and
# cost / hours is the printed rate. Integers print with %.0f, never %d: some awks (mawk) pass %d
# through a C int, which clamps at 2^31-1 and truncates.
function r(x) { return int(x + 0.5) }
function rate(cost, hours) { return (hours > 0) ? sprintf("%.2f", cost / hours) : "n/a" }
function row(tag, u, cost, accel,    useful) {
  useful = r(accel * hrs * u)
  printf "%-8s utilisation=%.2f useful_accel_hours=%.0f cost_usd=%.0f usd_per_useful_accel_hour=%s useful_tokens_per_usd=%.0f\n", \
    tag, u, useful, cost, rate(cost, useful), r(tps * 3600 * u / price)
}
BEGIN {
  cost = r(n * hrs * price)
  print "RESULTS (modelled):"
  printf "accelerator_hours_per_year=%.0f\n", r(n * hrs)
  printf "annual_fleet_cost_usd=%.0f\n", cost
  printf "annual_cost_on_demand_usd=%.0f\n", r(n * hrs * pd)
  printf "annual_cost_reserved_usd=%.0f\n", r(n * hrs * pr)
  printf "annual_cost_spot_usd=%.0f\n", r(n * hrs * ps)
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
  # pack: same useful hours on fewer accelerators; the saving is what the fleet cost loses
  useful0 = n * hrs * ul
  u0 = r(useful0)
  nn = n - pk
  pcost = r(nn * hrs * price)
  printf "%-8s accelerators=%.0f utilisation=%.2f useful_accel_hours=%.0f cost_usd=%.0f usd_per_useful_accel_hour=%s saving_usd=%.0f\n", \
    "pack", nn, useful0 / (nn * hrs), u0, pcost, rate(pcost, u0), cost - pcost
  # reclaim: return a fraction of idle hours, so they are not paid for
  # whole hours, rounded once, so the printed hours, cost and saving agree with each other
  idle = n * hrs * (1 - ul)
  ret = r(idle * rc)
  rsave = r(ret * price)
  rcost = cost - rsave
  printf "%-8s idle_hours_returned=%.0f utilisation=%.2f useful_accel_hours=%.0f cost_usd=%.0f usd_per_useful_accel_hour=%s saving_usd=%.0f\n", \
    "reclaim", ret, useful0 / (n * hrs - ret), u0, rcost, rate(rcost, u0), rsave
}'

#!/bin/sh
# labs/m11/probe-table.sh — join the two probe runs into the probe-matrix table
#
#   sh m11/probe-table.sh evidence/m11/probe-sandboxed.txt evidence/m11/probe-plain.txt
#
# Reads the `probe=<name> result=<...>` lines probe-matrix.sh printed in each
# Pod and prints one markdown table, eight rows, in the probe order. The
# `Same outcome?` cell is `yes` when the two result fields are equal and `no`
# when they are not. It is computed, never typed, so a row where nothing
# differs says so rather than inventing a differential.
#
# A probe missing from either file prints `missing` in that cell, which the
# lab's checks refuse.
set -eu
SANDBOXED="${1:?usage: probe-table.sh <sandboxed-output> <plain-output>}"
PLAIN="${2:?usage: probe-table.sh <sandboxed-output> <plain-output>}"

result_of() {
  # $1 file, $2 probe name -> everything after "result=" on that probe's line
  sed -n "s/^probe=$2 result=//p" "$1" | sed -n '1p'
}

echo '| Probe | Sandboxed (runsc) | Plain Pod (runc) | Same outcome? |'
echo '|---|---|---|---|'
for p in kernel-version proc-sys-kernel-entries host-kernel-symbols raw-socket privileged-op cloud-metadata kubernetes-api outbound; do
  s="$(result_of "${SANDBOXED}" "${p}")"
  r="$(result_of "${PLAIN}" "${p}")"
  [ -n "${s}" ] || s=missing
  [ -n "${r}" ] || r=missing
  if [ "${s}" = "${r}" ]; then same=yes; else same=no; fi
  echo "| \`${p}\` | \`${s}\` | \`${r}\` | ${same} |"
done

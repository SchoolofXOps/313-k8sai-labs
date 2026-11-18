#!/usr/bin/env bash
# addon-nvml-mock — the Xid round trip: inject one Xid on one mock device, read
# the exporter's DCGM_FI_DEV_XID_ERRORS family carrying it, then put everything
# back the way it was found.
#
# WHY A ROUND TRIP AND NOT A READ. Before any Xid is held, the exporter exports
# NO DCGM_FI_DEV_XID_ERRORS series at all — not a zero, nothing (SPIKE-09
# `14-dcgm-baseline.txt`: `none`). So "the exporter serves its Xid family" can
# only be shown by giving it one. And DCGM LATCHES the last Xid per device
# (Mokka's inject-xid.sh says so; a series that is present does not mean a
# fault is current), so clearing the mock's override does not clear the series.
# The latch lives in the exporter's embedded host engine, so the probe restarts
# the exporter's Pod and reads its own device's sample gone again. A one-way
# probe could not tell a working delivery path from a series that had been
# there all along; the return leg is what makes it a probe.
#
# EVERY ASSERTION IS SCOPED TO THE PROBE'S OWN DEVICE AND CODE. The probe uses
# the LAST mock device and judges only that device's sample. Other devices may
# hold Xids of their own — Module 4's lab leaves 48, 63 and 79 held on devices
# 0 to 2 — and the probe neither requires them absent nor erases them. Measured
# on the live layer (planning/lab-tests/raw/05-review-addition-fix/
# wr01-replay.txt): a replacement exporter Pod replays every Xid the mock still
# HOLDS as an override, so a learner's held Xids come back on the new Pod. What
# would NOT come back is a latched sample whose override is gone. So before it
# writes anything the probe reads the mock's held overrides, and it REFUSES —
# writing nothing — when:
#   - a device other than its own carries a latched sample no held override
#     backs (replacing the Pod would erase it); or
#   - its own device already carries a sample or an override (a leftover from
#     an interrupted probe, or a learner's own injection): the probe could not
#     tell its injection's delivery from what was already there.
# After the replacement it asserts both halves: its own device's sample is
# gone, and every sample the other devices carried before is served again.
#
# WHAT IT CHANGES. One failure override on its own device, written with the
# mock's control tool (`nvml-mock-ctl fail`) and cleared again (`nvml-mock-ctl
# reset`, that device only), and the exporter's Pod, replaced. The mock, its
# other devices' overrides and the device plugin are untouched. It is the one
# script of this layer that writes; verify.sh does not run it.
#
# THE XID IS A VALUE, NOT A FAULT. It is written to the mock's override file and
# replayed through the mock's event set. Its timing, and the fact that it
# arrives at all, come from the mock. The device is a mock device; the message
# text DCGM attaches to the code is DCGM's own catalogue string for that code.
#
# Usage:
#   bash xid-probe.sh            # the round trip; exits 0 only after both legs
#
# Env:
#   export KUBECONFIG=/tmp/grid-core.kubeconfig   # set by the base profile
#   PROBE_XID      the code to inject (default 48, the first code SPIKE-09 injected)
#   READ_TIMEOUT   seconds to wait for each leg (default 180)
#
# Reporting contract: every hard assert prints `FAIL: <what> <remedy>` to stderr
# and exits 1; on success exactly one line beginning `OK:` is printed.
# bash-3.2 compatible (macOS default shell). No arrays.
set -euo pipefail

LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTEXT="${CONTEXT:-kind-grid-core}"
export KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"

NS_MOCK="mokka"
NS_EXPORTER="dcgm-exporter"
PROBE_XID="${PROBE_XID:-48}"
READ_TIMEOUT="${READ_TIMEOUT:-180}"
FAMILY="DCGM_FI_DEV_XID_ERRORS"

kc() { kubectl --context "${CONTEXT}" "$@"; }

case "${PROBE_XID}" in
  ''|*[!0-9]*) echo "FAIL: PROBE_XID='${PROBE_XID}' is not a non-negative integer." >&2; exit 1 ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to pick the Running Pods. Install it and re-run; nothing was changed." >&2
  exit 1
fi

running_pod() {
  kc -n "$1" get pod -l "$2" --field-selector status.phase=Running -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name] | first // ""' 2>/dev/null || true
}
scrape() {
  kc get --raw "/api/v1/namespaces/${NS_EXPORTER}/pods/$1:9400/proxy/metrics" 2>/dev/null || true
}
# The mock devices the exporter serves, as the distinct device indices on its
# per-device series. Only indices are read; no value of any series.
device_indices() {
  printf '%s\n' "$1" | sed -n 's/^DCGM_FI_DEV_[A-Z_]*.*[{,]gpu="\([0-9]\{1,\}\)".*$/\1/p' | sort -un
}

# The family's samples as sorted "gpu:err_code" words, one per device that
# carries one. Only the two labels are read; no value of any series.
xid_pairs() {
  printf '%s\n' "$1" | sed -n "/^${FAMILY}{/p" \
    | sed -n 's/^.*[{,]gpu="\([0-9]\{1,\}\)".*[{,]err_code="\([0-9]\{1,\}\)".*$/\1:\2/p; t
s/^.*[{,]err_code="\([0-9]\{1,\}\)".*[{,]gpu="\([0-9]\{1,\}\)".*$/\2:\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# The overrides the mock holds, as "gpu:code" words, read off `nvml-mock-ctl
# status` (devices are `  "N":` lines, a held Xid is a `code: C` line under one).
held_pairs() {
  printf '%s\n' "$1" | awk '
    /^  "[0-9]+":/ { d = $1; gsub(/[":]/, "", d) }
    /^ +code: [0-9]+/ && d != "" { print d ":" $2 }' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# word_in <word> <space-separated list>
word_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

MOCK_POD="$(running_pod "${NS_MOCK}" app.kubernetes.io/name=nvml-mock)"
EXPORTER_POD="$(running_pod "${NS_EXPORTER}" app.kubernetes.io/name=dcgm-exporter)"
if [ -z "${MOCK_POD}" ] || [ -z "${EXPORTER_POD}" ]; then
  echo "FAIL: no Running mock Pod ('${MOCK_POD:-none}') or exporter Pod ('${EXPORTER_POD:-none}')." >&2
  echo "      The probe needs the layer applied WITH its consumers:" >&2
  echo "        bash ${ADDON_DIR}/create.sh" >&2
  exit 1
fi

BEFORE="$(scrape "${EXPORTER_POD}")"
INDICES="$(device_indices "${BEFORE}")"
if [ -z "${INDICES}" ]; then
  echo "FAIL: the exporter Pod ${EXPORTER_POD} serves no per-device series, so there is no device to probe." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_EXPORTER} logs ${EXPORTER_POD}" >&2
  exit 1
fi
# The LAST mock device: SPIKE-09 and M4.8's own injections use devices 0 to 2,
# so the probe stays off them.
TARGET="$(printf '%s\n' "${INDICES}" | sed -n '$p')"

# --- before writing anything: what is held, and would the probe disturb it ---
if ! STATUS="$(kc -n "${NS_MOCK}" exec "${MOCK_POD}" -c node-agent -- nvml-mock-ctl status 2>/dev/null)"; then
  echo "FAIL: could not read the mock's held overrides, so the probe cannot tell what replacing the exporter would erase. Nothing was changed." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} exec ${MOCK_POD} -c node-agent -- nvml-mock-ctl status" >&2
  exit 1
fi
LATCHED="$(xid_pairs "${BEFORE}")"
HELD="$(held_pairs "${STATUS}")"
OTHERS=""
UNBACKED=""
for _p in ${LATCHED}; do
  if [ "${_p%%:*}" = "${TARGET}" ]; then
    echo "FAIL: mock device ${TARGET}, the probe's own device, already carries the Xid sample ${_p} before any injection." >&2
    echo "      The probe could not tell its own delivery from it. Nothing was changed." >&2
    echo "      If it is an interrupted probe's leftover: kubectl --context ${CONTEXT} -n ${NS_MOCK} exec ${MOCK_POD} -c node-agent -- nvml-mock-ctl reset --gpu ${TARGET}" >&2
    echo "      then replace the exporter Pod: kubectl --context ${CONTEXT} -n ${NS_EXPORTER} delete pod ${EXPORTER_POD} --timeout=120s" >&2
    exit 1
  fi
  OTHERS="${OTHERS:+${OTHERS} }${_p}"
  word_in "${_p}" "${HELD}" || UNBACKED="${UNBACKED:+${UNBACKED} }${_p}"
done
for _p in ${HELD}; do
  if [ "${_p%%:*}" = "${TARGET}" ]; then
    echo "FAIL: mock device ${TARGET}, the probe's own device, holds an override (${_p}) that the probe did not write." >&2
    echo "      Its reset would clear it. Nothing was changed. Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} exec ${MOCK_POD} -c node-agent -- nvml-mock-ctl status" >&2
    exit 1
  fi
done
if [ -n "${UNBACKED}" ]; then
  echo "FAIL: the exporter Pod ${EXPORTER_POD} carries latched Xid sample(s) ${UNBACKED} that no override in the mock still holds." >&2
  echo "      A replaced exporter replays only what the mock holds, so the probe would erase them. Nothing was changed." >&2
  echo "      Read them first (they are evidence), or run the probe before an injection." >&2
  exit 1
fi

# --- leg 1: inject, and read its own device carrying its own code ------------
if ! kc -n "${NS_MOCK}" exec "${MOCK_POD}" -c node-agent -- \
       nvml-mock-ctl fail --gpu "${TARGET}" --mode ecc_uncorrectable --xid "${PROBE_XID}" >/dev/null 2>&1; then
  echo "FAIL: the mock's control tool refused to inject Xid ${PROBE_XID} on mock device ${TARGET}." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} exec ${MOCK_POD} -c node-agent -- nvml-mock-ctl status" >&2
  exit 1
fi
_w=0
SEEN=no
while [ "${_w}" -lt "${READ_TIMEOUT}" ]; do
  M="$(scrape "${EXPORTER_POD}")"
  if word_in "${TARGET}:${PROBE_XID}" "$(xid_pairs "${M}")"; then
    SEEN=yes
    break
  fi
  sleep 5
  _w=$((_w + 5))
done
INJECT_SECONDS="${_w}"

# Clear the override whatever leg 1 found, so a failed probe does not leave a
# failed mock device behind it.
kc -n "${NS_MOCK}" exec "${MOCK_POD}" -c node-agent -- nvml-mock-ctl reset --gpu "${TARGET}" >/dev/null 2>&1 || true

if [ "${SEEN}" != "yes" ]; then
  echo "FAIL: after ${INJECT_SECONDS}s the exporter's ${FAMILY} family carries no sample for mock device ${TARGET} with err_code ${PROBE_XID}." >&2
  echo "      The override was written and has now been reset; the delivery path from the mock to the exporter did not show it." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_EXPORTER} logs ${EXPORTER_POD}" >&2
  exit 1
fi

# --- leg 2: drop the exporter's latch; its own device clear, the rest kept ---
kc -n "${NS_EXPORTER}" delete pod "${EXPORTER_POD}" --wait=true --timeout=120s >/dev/null 2>&1 || true
_w=0
NEW_POD=""
CLEARED=no
MISSING="${OTHERS}"
OWN=""
while [ "${_w}" -lt "${READ_TIMEOUT}" ]; do
  NEW_POD="$(running_pod "${NS_EXPORTER}" app.kubernetes.io/name=dcgm-exporter)"
  if [ -n "${NEW_POD}" ] && [ "${NEW_POD}" != "${EXPORTER_POD}" ]; then
    M="$(scrape "${NEW_POD}")"
    if [ -n "$(device_indices "${M}")" ]; then
      AFTER="$(xid_pairs "${M}")"
      OWN=""
      for _p in ${AFTER}; do [ "${_p%%:*}" = "${TARGET}" ] && OWN="${_p}"; done
      MISSING=""
      for _p in ${OTHERS}; do word_in "${_p}" "${AFTER}" || MISSING="${MISSING:+${MISSING} }${_p}"; done
      if [ -z "${OWN}" ] && [ -z "${MISSING}" ]; then CLEARED=yes; break; fi
    fi
  fi
  sleep 5
  _w=$((_w + 5))
done
if [ "${CLEARED}" != "yes" ]; then
  echo "FAIL: after ${_w}s the replacement exporter Pod '${NEW_POD:-none}' does not show the probe's device clear with every earlier sample kept." >&2
  [ -n "${OWN}" ] && echo "      mock device ${TARGET} still carries ${OWN}: a held Xid was replayed onto it." >&2
  [ -n "${MISSING}" ] && echo "      not served again: ${MISSING} (they were carried before the probe and their overrides are still held)." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} exec ${MOCK_POD} -c node-agent -- nvml-mock-ctl status" >&2
  exit 1
fi

echo "OK: Xid round trip on mock device ${TARGET} — injected ${PROBE_XID}, read on the exporter's ${FAMILY} family after ${INJECT_SECONDS}s, override reset, exporter Pod replaced (${EXPORTER_POD} -> ${NEW_POD}) and device ${TARGET}'s sample gone again after ${_w}s; samples other devices held before the probe, served again: ${OTHERS:-none}."
echo "  the Xid is a value written to the mock's override file and replayed through its event set — not a driver fault, and its timing is the mock's"

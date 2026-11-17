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
# the exporter's Pod and reads the family gone again. A one-way probe could not
# tell a working delivery path from a series that had been there all along;
# the return leg is what makes it a probe.
#
# WHAT IT CHANGES, AND WHAT IT LEAVES. It writes one failure override on one
# mock device with the mock's own control tool (`nvml-mock-ctl fail`), clears
# exactly that device's overrides (`nvml-mock-ctl reset`), and replaces the
# exporter's Pod. It leaves the mock and the device plugin untouched. A learner
# who injected Xids of their own before running this loses the exporter's
# latched copies of them, because the replacement Pod starts with an empty
# latch; their overrides in the mock are not touched. Run it before a lab's own
# injection, never between an injection and its read.
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
case "${BEFORE}" in
  *"${FAMILY}{"*) FAMILY_BEFORE=present ;;
  *) FAMILY_BEFORE=absent ;;
esac

# --- leg 1: inject, and read the family carrying it ---------------------------
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
  # Captured, never piped into a quiet matcher: under `pipefail` a successful
  # quiet match returns 141. sed reads its input to the end. The two label
  # filters are separate so the match does not depend on label order.
  HIT="$(printf '%s\n' "${M}" | sed -n "/^${FAMILY}{/p" | sed -n "/gpu=\"${TARGET}\"/p" | sed -n "/err_code=\"${PROBE_XID}\"/p")"
  if [ -n "${HIT}" ]; then
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

# --- leg 2: drop the exporter's latch, and read the family gone ---------------
kc -n "${NS_EXPORTER}" delete pod "${EXPORTER_POD}" --wait=true --timeout=120s >/dev/null 2>&1 || true
_w=0
NEW_POD=""
CLEARED=no
while [ "${_w}" -lt "${READ_TIMEOUT}" ]; do
  NEW_POD="$(running_pod "${NS_EXPORTER}" app.kubernetes.io/name=dcgm-exporter)"
  if [ -n "${NEW_POD}" ] && [ "${NEW_POD}" != "${EXPORTER_POD}" ]; then
    M="$(scrape "${NEW_POD}")"
    if [ -n "$(device_indices "${M}")" ]; then
      case "${M}" in
        *"${FAMILY}{"*) : ;;
        *) CLEARED=yes; break ;;
      esac
    fi
  fi
  sleep 5
  _w=$((_w + 5))
done
if [ "${CLEARED}" != "yes" ]; then
  echo "FAIL: after ${_w}s the replacement exporter Pod '${NEW_POD:-none}' is not serving device series without a ${FAMILY} sample." >&2
  echo "      Either it is not serving yet, or a held Xid was replayed into its fresh latch." >&2
  echo "      Inspect: kubectl --context ${CONTEXT} -n ${NS_MOCK} exec ${MOCK_POD} -c node-agent -- nvml-mock-ctl status" >&2
  exit 1
fi

echo "OK: Xid round trip on mock device ${TARGET} — injected ${PROBE_XID}, read on the exporter's ${FAMILY} family after ${INJECT_SECONDS}s, override reset, exporter Pod replaced (${EXPORTER_POD} -> ${NEW_POD}) and the family gone again after ${_w}s (it was ${FAMILY_BEFORE} before the probe)."
echo "  the Xid is a value written to the mock's override file and replayed through its event set — not a driver fault, and its timing is the mock's"

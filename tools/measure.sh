#!/usr/bin/env bash
# measure.sh — peak RSS per lab profile, read from the kernel's own high-water marks
#
# TWO numbers per profile, neither of them sampled:
#
#   1. per-component — cgroup v2 `memory.peak` read INSIDE every node container
#      of the profile and summed. memory.peak is the kernel-recorded high-water
#      mark for that cgroup, so nothing is missed between reads. The
#      per-container breakdown is printed too: that is what lets a profile be
#      reduced component-by-component when it is over budget.
#
#   2. summed VM cgroup high-water — the sum of /sys/fs/cgroup/*/memory.peak
#      across the Rancher Desktop VM's top-level cgroups, read over
#      `rdctl shell`. The VM's ROOT cgroup carries no memory controller (there
#      is no /sys/fs/cgroup/memory.peak on this VM), so its top-level cgroups
#      are the highest level at which the kernel records a high-water mark.
#
#      It is NOT called a "peak", because it is not one: the siblings reach
#      their high-water marks at DIFFERENT times, so their sum is neither a
#      simultaneous total nor bounded by the VM ceiling, and because
#      memory.peak never resets it rises monotonically for the life of the
#      boot. On an idle VM with no containers running at all it read 7459 MiB
#      against a 4500 MiB budget — the VM's whole session history, credited to
#      whatever profile the tool was pointed at.
#
#      So this figure is published ONLY when it is attributable: when a
#      baseline exists for the profile AND that baseline was recorded during
#      the current boot. Otherwise the cell reads `unattributable` with the
#      reason, and the raw sum appears in the breakdown explicitly marked as
#      not-a-peak. A VM-wide figure is meaningful immediately after a VM
#      restart and at no other time; `read` enforces that rather than trusting
#      the operator to remember it.
#
# Polling and timer-driven sampling are deliberately NOT implemented: a
# sampling reader misses the short spike between reads, and that spike is
# exactly the event that OOM-kills a learner on an 8 GB laptop.
#
# Reset semantics (Linux 6.18 on this VM): writing to memory.peak resets only
# the peak seen through THAT open file descriptor — a later `cat` opens a new
# fd and reads the global high-water again. So `reset` cannot zero the kernel
# counter across processes. `reset` therefore records a BASELINE snapshot
# stamped with the VM's boot epoch and the wall time it was taken, and `read`
# prints it beside the reading — with its age — so it is visible how much of
# the figure this run is responsible for. Restarting the VM is the only way to
# zero the VM-wide counter; spike-00-preflight.md records that the VM was
# restarted before the measured run, which is what makes its VM-wide figure
# attributable. `read` now REFUSES to publish a summed VM figure whose
# baseline came from an earlier boot, which is the same precondition expressed
# as code instead of as operator discipline.
#
# A cell that cannot be read is written as the literal `unmeasured` with its
# reason. Never `0` — a profile that produced no reading has not been measured
# at 0 MiB — and the row is never omitted.
#
# Usage:
#   bash measure.sh reset <profile>
#   bash measure.sh read  <profile> [<profile> ...]
#   bash measure.sh run   <profile> -- <command ...>
#
# Env:
#   BUDGET_MB   lab budget in MiB (default 4500, the 8 GB-profile lab budget)
#   CONFIG      label for the cluster configuration this reading was taken
#               against, e.g. gates-on / gates-off (default `unlabelled`).
#               A peak-RSS figure whose configuration is not stated is not a
#               measurement: the same profile with different feature gates is
#               a different cluster, and publishing one number beside the
#               other's conditions is the failure this column prevents.
#   OUT         also append the rendered markdown rows to this file
#   STATE_DIR   where baselines are kept (default /tmp/measure-rss)
#   FILTER      docker-ps name pattern selecting the containers to read
#               (default: the profile argument). The profile is the LABEL a
#               reading is published under; the filter is what names the
#               running containers. They are only the same word when the
#               profile IS a cluster name. The four-path harness, for example,
#               publishes under `storage-four-path` but runs on the
#               `spike-core` nodes, so it needs FILTER=spike-core.
#
# `read` EXITS NON-ZERO when a profile matched no running container: a harness
# that measured nothing must not report success.
#
# Wrappable around ANY spike's cluster, which is the point: RSS data accrues
# for free while the other spikes run.
#
# Idempotent: reset/read change nothing on the cluster; both are read-only.
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

# --- pinned-binary resolution -------------------------------------------------
# Kept identical to the cluster profiles so one PATH story covers the whole lab
# surface. This script needs only docker, rdctl and python3; on this host there
# is exactly one docker (~/.rd/bin/docker) and one rdctl, so the prepend cannot
# change which of those resolves. Override with LAB_BIN_PREFIX.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-/opt/homebrew/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH

BUDGET_MB="${BUDGET_MB:-4500}"
CONFIG="${CONFIG:-unlabelled}"
OUT="${OUT:-}"
STATE_DIR="${STATE_DIR:-/tmp/measure-rss}"
FILTER="${FILTER:-}"

usage() {
  echo "usage: bash measure.sh reset <profile>" >&2
  echo "       bash measure.sh read  <profile> [<profile> ...]" >&2
  echo "       bash measure.sh run   <profile> -- <command ...>" >&2
  echo "" >&2
  echo "  FILTER=<docker name pattern>  which containers to read, when the" >&2
  echo "       profile LABEL is not also a container-name pattern. Defaults" >&2
  echo "       to the profile." >&2
  exit 2
}

# The docker-ps name pattern for a profile: FILTER when set, else the profile
# label itself.
#
# These are two different things and conflating them is WINDOWS #5. The profile
# is the LABEL a reading is published under in a spike record
# (`storage-four-path`); the filter is what actually names the running
# containers (`spike-core`, whose nodes are spike-core-control-plane and
# spike-core-worker). Plans 01-02 and 01-03 both reset against a profile label
# that matched zero containers, which is why their .containers.baseline files
# are 0 bytes. Defaulting the filter to the profile keeps every existing
# single-word invocation working.
profile_filter() {
  if [ -n "${FILTER}" ]; then printf '%s' "${FILTER}"; else printf '%s' "$1"; fi
}

# Every running container whose name matches the filter — the kind/kwok nodes.
node_containers() {
  docker ps --filter "name=$1" --format '{{.Names}}' 2>/dev/null | LC_ALL=C sort
}

# Kernel high-water mark for one container's own cgroup, in bytes. Empty when
# unreadable (container gone, OOM-killed before the read, or no cgroup v2).
#
# The trailing `|| true` is load-bearing, not defensive noise. Under the
# `set -o pipefail` above, a failing producer (`docker exec` against a
# container that vanished or was OOM-killed between the `docker ps` and this
# read) makes the WHOLE pipeline non-zero. Without `|| true` the function
# returns non-zero, the caller's `p="$(container_peak ...)"` inherits that
# status, and `set -e` kills the script — so the `unmeasured`-with-a-reason
# branch this file promises at lines 32-34 could never run for the very cause
# it names. Returning empty-and-zero IS the contract: the caller decides.
container_peak() {
  docker exec "$1" cat /sys/fs/cgroup/memory.peak 2>/dev/null \
    | tr -d '[:space:]' || true
}

# Summed kernel high-water mark across the VM's top-level cgroups, in bytes.
# Empty when `rdctl shell` fails or no top-level cgroup exposes memory.peak.
#
# Same `|| true` reasoning as container_peak: on ANY host without `rdctl` — a
# Linux learner, the ubuntu-24.04 amd64 CI runner, or Rancher Desktop simply
# not running — the producer exits 127. Without `|| true` that aborted
# `measure.sh run <profile> -- <lab>` at the `reset` step, BEFORE the wrapped
# lab command ever ran, so the harness silently failed to run the thing it was
# asked to measure.
vm_peak_bytes() {
  rdctl shell sh -c \
    'for f in /sys/fs/cgroup/*/memory.peak; do [ -f "$f" ] && cat "$f"; done' \
    2>/dev/null \
  | python3 -c 'import sys
vals = [int(x) for x in sys.stdin.read().split() if x.isdigit()]
print(sum(vals) if vals else "")' || true
}

# The VM's boot time as a unix epoch, read from /proc/stat's `btime` INSIDE the
# VM. Empty when unreadable.
#
# This is the precondition that makes the summed figure above mean anything.
# `memory.peak` is a high-water mark that NEVER resets while the VM lives, and
# the VM's top-level cgroups reach their peaks at different times, so the sum
# is monotonic for the life of the boot — it is not a simultaneous total and it
# is not bounded by the VM ceiling. A summed figure is therefore attributable
# to a profile ONLY if the baseline it is being compared against was recorded
# during the SAME boot. Plan 01-06 got this right by restarting the VM before
# every profile it measured; `read` enforces that discipline rather than asking
# the operator to remember it.
vm_boot_epoch() {
  rdctl shell awk '/^btime /{print $2}' /proc/stat 2>/dev/null \
    | tr -d '[:space:]' || true
}

# Emit this profile's readings as TSV: profile<TAB>kind<TAB>name<TAB>value
collect_profile() {
  local profile="$1" c p vm base found boot filt
  filt="$(profile_filter "${profile}")"
  found=0
  for c in $(node_containers "${filt}"); do
    p="$(container_peak "${c}" || true)"
    if [ -n "${p}" ]; then
      printf '%s\tcontainer\t%s\t%s\n' "${profile}" "${c}" "${p}"
      found=1
    else
      printf '%s\tcontainer_unreadable\t%s\t%s\n' "${profile}" "${c}" \
        "memory.peak unreadable in ${c} (container gone, or OOM-killed before the read)"
    fi
  done
  if [ "${found}" -eq 0 ]; then
    printf '%s\tcontainer_none\t-\t%s\n' "${profile}" \
      "no running container matched the name filter '${filt}'"
  fi

  vm="$(vm_peak_bytes || true)"
  if [ -n "${vm}" ]; then
    printf '%s\tvm\t-\t%s\n' "${profile}" "${vm}"
  else
    printf '%s\tvm_unreadable\t-\t%s\n' "${profile}" \
      "rdctl shell failed, or no top-level VM cgroup exposed memory.peak"
  fi

  # The current boot epoch travels with the reading so the renderer can decide
  # whether the baseline is from this boot (attributable) or an earlier one
  # (a monotonic sum, which must NOT be published as a figure).
  boot="$(vm_boot_epoch || true)"
  printf '%s\tvm_boot\t-\t%s\n' "${profile}" "${boot:-unknown}"
  printf '%s\tnow\t-\t%s\n' "${profile}" "$(date -u +%s)"

  if [ -f "${STATE_DIR}/${profile}.vm.baseline" ]; then
    base="$(cat "${STATE_DIR}/${profile}.vm.baseline")"
    printf '%s\tvm_baseline\t-\t%s\n' "${profile}" "${base}"
  fi
}

PY_RENDER='import sys

budget = float(sys.argv[1])
config = sys.argv[2] if len(sys.argv) > 2 else "unlabelled"
rows = {}

for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 4:
        continue
    prof, kind, name, val = parts[0], parts[1], parts[2], parts[3]
    r = rows.setdefault(prof, {"c": [], "cbad": [], "cnone": None,
                               "vm": None, "vmerr": None, "vmbase": None,
                               "boot": None, "now": None, "basebase": None,
                               "basewall": None})
    if kind == "container":
        r["c"].append((name, int(val)))
    elif kind == "container_unreadable":
        r["cbad"].append((name, val))
    elif kind == "container_none":
        r["cnone"] = val
    elif kind == "vm":
        r["vm"] = int(val)
    elif kind == "vm_unreadable":
        r["vmerr"] = val
    elif kind == "vm_boot":
        r["boot"] = None if val == "unknown" else val
    elif kind == "now":
        r["now"] = int(val)
    elif kind == "vm_baseline":
        # Stamped form: "<boot-epoch> <wall-epoch> <bytes>".
        # Legacy form:  "<bytes>" or "unmeasured" — carries no boot epoch, so
        # it cannot be shown to belong to this boot and is unattributable.
        f = val.split()
        if len(f) == 3:
            r["basebase"] = None if f[0] == "unknown" else f[0]
            r["basewall"] = None if not f[1].isdigit() else int(f[1])
            r["vmbase"] = None if f[2] == "unmeasured" else int(f[2])
        else:
            r["vmbase"] = None if val.strip() == "unmeasured" else int(val.strip())

def mib(b):
    return b / 1024.0 / 1024.0

def hms(secs):
    h, rem = divmod(int(secs), 3600)
    m, s = divmod(rem, 60)
    return "%dh%02dm" % (h, m) if h else "%dm%02ds" % (m, s)

# Is this profile summed VM figure attributable to a measured run?
#
# Only when the baseline was recorded during the CURRENT boot. memory.peak
# never resets while the VM lives, so across a reboot boundary the sum carries
# the whole previous boot of history, and a delta against it is meaningless.
# Returns (ok, reason-when-not-ok).
def vm_attributable(r):
    if r["vm"] is None:
        return False, r["vmerr"] or "no reading obtained"
    if r["boot"] is None:
        return False, ("VM boot time unreadable, so the baseline cannot be "
                       "shown to belong to this boot")
    if r["vmbase"] is None and r["basebase"] is None:
        return False, ("no baseline for this profile — a bare sum of "
                       "never-resetting sibling high-water marks is the whole "
                       "boot of history, not the peak of this profile; run "
                       "`measure.sh reset` (ideally just after a VM restart) "
                       "first")
    if r["basebase"] is None:
        return False, ("baseline is unstamped (recorded before boot-stamping "
                       "existed), so it cannot be shown to belong to this "
                       "boot; re-run `measure.sh reset`")
    if r["basebase"] != r["boot"]:
        return False, ("baseline predates the current boot (baseline boot %s, "
                       "current boot %s); the summed high-water is monotonic "
                       "across the whole life of the VM, so this figure is not "
                       "the peak of this profile. Restart the VM, then `measure.sh "
                       "reset`." % (r["basebase"], r["boot"]))
    return True, ""

lines = []
# The VM column is NOT a "peak": it is the sum of several independent sibling
# cgroup high-water marks reached at different times. Named for what it is.
lines.append("| profile | configuration | summed container peak (MiB) "
             "| summed VM cgroup high-water (MiB) | budget (MiB) "
             "| over budget? | reduction needed |")
lines.append("|---|---|---|---|---|---|---|")

# Deterministic order: profile name ascending, so two runs diff cleanly even
# when two profiles report an identical peak.
for prof in sorted(rows):
    r = rows[prof]
    if r["c"]:
        total_mib = mib(sum(v for _, v in r["c"]))
        csum = "%.0f" % total_mib
        over = total_mib > budget
        overcell = "yes" if over else "no"
        reduction = ("%.0f" % (total_mib - budget)) if over else "none"
    else:
        reason = r["cnone"] or (r["cbad"][0][1] if r["cbad"] else "no reading obtained")
        csum = "unmeasured (%s)" % reason
        overcell = "unmeasured"
        reduction = "unmeasured"
    vmok, vmwhy = vm_attributable(r)
    if vmok:
        vmcell = "%.0f" % mib(r["vm"])
    else:
        # Refuse to publish the number. Printing it with a caveat is not
        # enough: this table is shaped for direct paste into a spike record,
        # where the cell outlives the caveat.
        vmcell = "unattributable (%s)" % vmwhy
    lines.append("| %s | %s | %s | %s | %.0f | %s | %s |"
                 % (prof, config, csum, vmcell, budget, overcell, reduction))

print("\n".join(lines))
print("")
print("Breakdown (kernel-recorded cgroup v2 memory.peak, no sampling):")
for prof in sorted(rows):
    r = rows[prof]
    print("  %s [%s]:" % (prof, config))
    for name, v in sorted(r["c"]):
        print("    %-34s %8.0f MiB   (/sys/fs/cgroup/memory.peak)" % (name, mib(v)))
    for name, why in sorted(r["cbad"]):
        print("    %-34s unmeasured — %s" % (name, why))
    if r["cnone"]:
        print("    (no node container) unmeasured — %s" % r["cnone"])
    vmok, vmwhy = vm_attributable(r)
    if r["vm"] is None:
        print("    %-34s unmeasured — %s" % ("summed VM cgroup high-water", r["vmerr"]))
    elif not vmok:
        # The raw sum is still shown here, in the breakdown, explicitly NOT as
        # a peak and with the reason it cannot be attributed — so the operator
        # can see what the kernel reported without being handed a number the
        # table would imply belongs to this profile.
        print("    %-34s %8.0f MiB   (raw sum; NOT the peak of this profile)"
              % ("summed VM cgroup high-water", mib(r["vm"])))
        print("    %-34s unattributable — %s" % ("", vmwhy))
    else:
        print("    %-34s %8.0f MiB   (sum of /sys/fs/cgroup/*/memory.peak in the VM)"
              % ("summed VM cgroup high-water", mib(r["vm"])))
        if r["vmbase"] is not None:
            age = ""
            if r["basewall"] is not None and r["now"] is not None:
                age = ", recorded %s ago" % hms(r["now"] - r["basewall"])
            print("    %-34s %8.0f MiB   (high-water at reset time%s)"
                  % ("baseline (this boot)", mib(r["vmbase"]), age))
            print("    %-34s %8.0f MiB   (rise since that baseline)"
                  % ("rise since baseline", mib(r["vm"] - r["vmbase"])))
'

cmd_reset() {
  local profile="$1" vm c p boot filt n
  mkdir -p "${STATE_DIR}"
  vm="$(vm_peak_bytes || true)"
  boot="$(vm_boot_epoch || true)"
  # Stamped, three fields: <vm-boot-epoch> <reset-wall-epoch> <bytes>.
  # The boot epoch is what lets `read` refuse to publish a figure whose
  # baseline came from a previous boot; the wall epoch is what lets it state
  # how old the baseline is, so a delta can never be read as "during this run"
  # when it was not. A single-field (pre-stamp) baseline is treated by `read`
  # as unattributable, which correctly invalidates the stale files that
  # accumulated in STATE_DIR before this stamping existed.
  printf '%s %s %s\n' "${boot:-unknown}" "$(date -u +%s)" "${vm:-unmeasured}" \
    > "${STATE_DIR}/${profile}.vm.baseline"
  : > "${STATE_DIR}/${profile}.containers.baseline"
  filt="$(profile_filter "${profile}")"
  n=0
  for c in $(node_containers "${filt}"); do
    p="$(container_peak "${c}" || true)"
    printf '%s %s\n' "${c}" "${p:-unmeasured}" \
      >> "${STATE_DIR}/${profile}.containers.baseline"
    n=$((n + 1))
  done
  echo "measure.sh: baseline recorded for profile '${profile}' in ${STATE_DIR}"
  echo "  container name filter:       ${filt}"
  echo "  VM-wide high-water at reset: ${vm:-unmeasured} bytes"
  echo "  VM boot epoch at reset:      ${boot:-unknown}"
  echo "  node containers at reset:    ${n}"
  # A zero match at RESET time is legitimate — `measure.sh run spike-core --
  # bash create.sh` baselines before the cluster exists — so this warns rather
  # than failing. At READ time it is a hard failure: see cmd_read.
  if [ "${n}" -eq 0 ]; then
    echo "  NOTE: no running container matched '${filt}'. That is expected if" >&2
    echo "        the wrapped command creates the cluster; otherwise set" >&2
    echo "        FILTER=<pattern> — the profile label is not a container name." >&2
  fi
}

cmd_read() {
  local tsv profile rendered none
  tsv="$(mktemp -t measure-rss)"
  for profile in "$@"; do
    collect_profile "${profile}" >> "${tsv}"
  done
  rendered="$(python3 -c "${PY_RENDER}" "${BUDGET_MB}" "${CONFIG}" < "${tsv}")"
  # Count the zero-match profiles BEFORE the temp file goes away.
  none="$(grep -c '	container_none	' "${tsv}" || true)"
  rm -f "${tsv}"
  printf '%s\n' "${rendered}"
  if [ -n "${OUT}" ]; then
    printf '%s\n' "${rendered}" >> "${OUT}"
    echo "measure.sh: rows appended to ${OUT}"
  fi
  # A harness that measured nothing must not report success. Before this, a
  # profile whose filter matched no container printed `unmeasured` and exited
  # 0, so no caller, CI step or checks.json gate could tell the difference
  # between "measured and within budget" and "measured nothing at all" — and
  # the one invocation documented in four-path/run.sh was exactly such a case.
  if [ "${none}" -ne 0 ]; then
    echo "FAIL: ${none} profile(s) matched no running container; nothing was" >&2
    echo "      measured for them. The profile label is a docker name pattern" >&2
    echo "      unless FILTER is set — e.g. the four-path harness runs on the" >&2
    echo "      spike-core nodes, so it needs FILTER=spike-core." >&2
    return 1
  fi
}

cmd_run() {
  local profile="$1" rc readrc
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
  [ "$#" -gt 0 ] || usage
  cmd_reset "${profile}"
  echo
  echo "measure.sh: running — $*"
  echo
  set +e
  "$@"
  rc=$?
  set -e
  echo
  echo "measure.sh: command exited ${rc}; reading peaks before anything is torn down."
  echo
  # Read even on failure: an OOM-killed run is itself the measurement, and it
  # must be recorded as `unmeasured` with its reason rather than lost.
  #
  # The wrapped command's own exit code wins when it failed — that is the more
  # specific diagnosis. When the lab passed but nothing was measured, cmd_read
  # returns 1 and that becomes the result: a green lab with no measurement is
  # not a successful measurement run.
  readrc=0
  cmd_read "${profile}" || readrc=$?
  if [ "${rc}" -ne 0 ]; then return "${rc}"; fi
  return "${readrc}"
}

[ "$#" -ge 2 ] || usage
SUBCOMMAND="$1"
shift

case "${SUBCOMMAND}" in
  reset) cmd_reset "$1" ;;
  read)  cmd_read "$@" ;;
  run)   cmd_run "$@" ;;
  *)     usage ;;
esac

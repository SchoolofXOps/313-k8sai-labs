#!/usr/bin/env bash
# size-gate.sh — the ONE place SIZE is validated, and the ONE place the skip
# token is emitted.
#
# Both SOURCED and EXECUTED, which is unusual enough to state up front:
#
#   sourced   . "${LABS_DIR}/tools/size-gate.sh"   -> assert_size, size_value
#   executed  bash size-gate.sh <required-size> -- <command ...>
#
# Why this file exists
# -------------------
# The machine-size contract is written in STANDARDS.md § SIZE-GATE, and this
# helper IMPLEMENTS it rather than defining it. The ordering is load-bearing and
# it is a repair this project already had to make once: C15 never fixed the
# synthetic-device caption's form, so the form was fixed in the authority BEFORE
# the checker was written, because a checker that invents the form becomes the
# authority by accident. The same applies to a shell literal. If the skip token
# below were invented here, this file would be the authority on it, and nothing
# would notice.
#
# So every literal in this file is a copy of a decision made elsewhere:
#
#   the accepted set and the default  -> course.config.json  lab.sizes
#   the per-size numbers             -> course.config.json  lab.sizes.<n>
#   the skip token's exact text      -> STANDARDS.md § SIZE-GATE
#
# Read through the MIRROR beside this file rather than from course.config.json
# directly, because course.config.json is not published. See "where the config
# lives" below; the contract is STANDARDS.md § SIZE-GATE, "The two trees".
#
# What `assert_size` is for
# ------------------------
# SIZE accepts exactly two values and ROUNDS NOTHING. A SIZE=12 that quietly
# became a SIZE=8 cluster is worse than either honest outcome, because it would
# run: the learner would get a cluster, and it would not be the cluster the lab
# was written against. So an unaccepted value exits non-zero NAMING the rejected
# value.
#
# What the executed form is for
# ----------------------------
# A profile's checks.json cannot express conditionality on the check OBJECT.
# CourseSmith's runner evaluates checks as a flat array, runs every entry, and
# IGNORES an unrecognised key — so a `"size": 16` field would not skip a check,
# it would leave it running and failing while reading like a skip. The runner's
# own vocabulary is the only lever, so the conditionality lives in the `run`
# string:
#
#   "run": "bash labs/tools/size-gate.sh 16 -- kubectl get nodes --no-headers | wc -l"
#   "assert": {"matches": "^ *3$|^SIZE-GATE: skipped"}
#
# At the required size the command runs and its output is asserted; at the other
# size this script prints the fixed token and exits 0, and the alternation
# matches that instead. The alternation is visible in the checks file on purpose
# — a reader can see which checks are conditional and on what.
#
# Usage:
#   bash size-gate.sh 16 -- kubectl get nodes      # runs it at SIZE=16, skips at SIZE=8
#   SIZE=12 bash size-gate.sh 8 -- true            # exits non-zero, names 12
#
# Env:
#   SIZE        the learner's machine size. Accepted: 8, 16. Default: 8.
#               Exported once in the shell, because the profile triple is three
#               separate scripts and a learner who creates at 16 must verify and
#               tear down at 16 — an argument has to be repeated and WILL be
#               forgotten.
#   LAB_SIZES   path to the lab-sizes mirror (default: lab-sizes.json beside
#               this file). See "where the config lives" below.
#
# Idempotent: read-only. It validates, reads config and either runs the caller's
# command or prints one line.
# bash-3.2 compatible (macOS default shell). No arrays, no `local -n`.

# --- where the config lives ---------------------------------------------------
# Resolved from THIS file's own directory and NEVER ABOVE IT.
#
# The comment that used to sit here had the principle right and the
# implementation wrong, and recording that is worth more than quietly fixing it:
# it said a config resolved against $PWD "is found on the author's machine and
# missing on the learner's", and then resolved `${SIZE_GATE_DIR}/../..` —
# which is the repository root in the private tree and the clone's PARENT in the
# published one. The defect the comment was written to prevent arrived by the
# other route.
#
# MEASURED 2026-10-21 in a tree built by `sync-grid --source labs --write`: every
# script the learner-facing setup page names failed at `assert_size` with
# `course.config.json not found at '<clone>/../course.config.json'`, and the
# remedy that failure printed named a file the learner does not have. Evidence:
# planning/lab-tests/03-setup-dry-run.md §§ 13-14 and its 2026-10-21 addendum.
#
# `scripts/sync-grid.mjs` publishes labs/<x>/ as <x>/ at the clone root, so this
# file is at labs/tools/ privately and tools/ for a learner — one level
# shallower, with NOTHING above the clone root. Two consequences, and they are
# the whole rule:
#
#   1. the path is a SIBLING. Zero upward segments, so it cannot escape the
#      clone no matter how deep or shallow the tree is.
#   2. it points at the MIRROR, lab-sizes.json, not at course.config.json, which
#      is at the repository root and is never published. The mirror is a
#      generated verbatim copy of course.config.json's lab.sizes block, wrapped
#      in the same {"lab":{"sizes": ...}} shape so the reader below is unchanged.
#      Generated and drift-gated by scripts/lab-sizes.mjs; contract in
#      STANDARDS.md § SIZE-GATE, "The two trees".
#
# course.config.json is still the single source. This reads its mirror, and
# nothing here invents a number.
SIZE_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_SIZES="${LAB_SIZES:-${SIZE_GATE_DIR}/lab-sizes.json}"

SIZE="${SIZE:-}"

# The skip token's exact text, FIXED in STANDARDS.md § SIZE-GATE and copied here
# rather than composed. Two placeholders, substituted at print time.
#   SIZE-GATE: skipped (requires SIZE=<n>, SIZE is <m>)

# --- reading the config -------------------------------------------------------
# node -e + JSON.parse, and deliberately NOT a command-line JSON or YAML tool.
# Three reasons, all measured on this project:
#   1. the project pins its parsers; `node` is the pinned runtime and is already
#      a hard dependency of the standards gate.
#   2. two incompatible programs share the name `yq`, and the one on the
#      authoring host is not the one CI gets.
#   3. this host's `grep` is wrapped by a shim that REJECTS `-n`/`-r` and prints
#      nothing, which reads as clean. A config read built on grep would fail
#      open.
#
# Prints the value on stdout and nothing else; prints nothing and returns
# non-zero when the key is absent.
size_gate_config() {
  node -e '
    const fs = require("fs");
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const sizes = (cfg.lab || {}).sizes;
    if (!sizes) process.exit(3);
    const q = process.argv[2];
    if (q === "accepted") { process.stdout.write(sizes.accepted.join(" ")); process.exit(0); }
    if (q === "default")  { process.stdout.write(String(sizes.default));    process.exit(0); }
    const size = process.argv[3];
    const row = sizes[String(size)];
    if (!row || typeof row[q] !== "number") process.exit(4);
    process.stdout.write(String(row[q]));
  ' "${LAB_SIZES}" "$1" "${2:-}" 2>/dev/null
}

# --- the validation -----------------------------------------------------------
# Never `cmd | grep -q PATTERN` under `set -o pipefail`: that returns 141 on a
# SUCCESSFUL match, because grep exits the instant it matches and the writer
# takes SIGPIPE. It produced a near-miss false architecture verdict in Phase 1.
# Everything here captures into a variable and matches with `case`.
assert_size() {
  local accepted default_size want found

  if [ ! -f "${LAB_SIZES}" ]; then
    echo "FAIL: lab-sizes.json not found at '${LAB_SIZES}'." >&2
    echo "      The accepted SIZE values and every per-size number are read from" >&2
    echo "      its lab.sizes block; there is no fallback literal, on purpose." >&2
    echo "      It is expected BESIDE this script, in this clone, and is not" >&2
    echo "      something to fetch: if it is missing the clone is incomplete." >&2
    echo "      Re-clone, or in the authoring repository regenerate it with" >&2
    echo "      'node scripts/lab-sizes.mjs --write'." >&2
    echo "      Set LAB_SIZES=<path> only to point at a deliberate copy." >&2
    return 1
  fi

  accepted="$(size_gate_config accepted || true)"
  if [ -z "${accepted}" ]; then
    echo "FAIL: '${LAB_SIZES}' carries no lab.sizes block, so the accepted SIZE" >&2
    echo "      values cannot be read. See STANDARDS.md section SIZE-GATE for" >&2
    echo "      what that block must contain." >&2
    return 1
  fi

  default_size="$(size_gate_config default || true)"
  want="${SIZE:-${default_size}}"

  found=0
  # Intentional IFS word-splitting of the space-separated accepted list (bash-3.2
  # has no arrays worth using here, and pinned-bin.sh sets the same precedent).
  for one in ${accepted}; do
    if [ "${want}" = "${one}" ]; then found=1; fi
  done

  if [ "${found}" -ne 1 ]; then
    echo "FAIL: SIZE is '${want}', which is not an accepted machine size." >&2
    echo "      Accepted: ${accepted}. Default: ${default_size}." >&2
    echo "      SIZE is NEVER rounded to the nearest accepted value: a '${want}'" >&2
    echo "      that quietly became a ${default_size} would give you a cluster," >&2
    echo "      and it would not be the cluster the lab was written against." >&2
    echo "      Run one of:  export SIZE=${default_size}   # or the other accepted value" >&2
    return 1
  fi

  SIZE="${want}"
  export SIZE
  return 0
}

# One per-size number out of the mirror, for the CURRENT SIZE.
#   size_value worker_nodes  ->  1  at SIZE=8,  2 at SIZE=16
#
# Callers are expected to have run assert_size first; this re-resolves the
# default so a direct call is still correct rather than silently empty.
size_value() {
  local key="$1" want v
  want="${SIZE:-$(size_gate_config default || true)}"
  v="$(size_gate_config "${key}" "${want}" || true)"
  if [ -z "${v}" ]; then
    echo "FAIL: '${LAB_SIZES}' has no numeric lab.sizes.${want}.${key}." >&2
    echo "      Every per-size number is read from that block rather than" >&2
    echo "      hardcoded, so a missing key is a config defect and not a" >&2
    echo "      reason to fall back to a literal." >&2
    return 1
  fi
  printf '%s' "${v}"
}

# -----------------------------------------------------------------------------
# EXECUTED form. Guarded so sourcing this file defines the two functions and
# runs nothing — the guard is the sourced/executed discriminator, and without it
# a `. size-gate.sh` from create.sh would try to parse create.sh's own argv.
# -----------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail

  if [ "$#" -lt 1 ]; then
    echo "usage: bash size-gate.sh <required-size> -- <command ...>" >&2
    echo "       <required-size> is one of the accepted SIZE values." >&2
    exit 2
  fi

  REQUIRED="$1"
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
  if [ "$#" -lt 1 ]; then
    echo "usage: bash size-gate.sh <required-size> -- <command ...>" >&2
    echo "       no command was given after --; a gate with nothing to gate" >&2
    echo "       would exit 0 and prove nothing." >&2
    exit 2
  fi

  # Validated BEFORE the required size is compared. An invalid SIZE must fail
  # loudly even when the gate would have skipped anyway: a skip is a statement
  # that this check does not apply to this machine, and that statement is not
  # available for a machine size the course does not have.
  assert_size

  if [ "${SIZE}" = "${REQUIRED}" ]; then
    exec "$@"
  fi

  # The skip token, printed exactly as STANDARDS.md fixes it. Exit 0: a skip is
  # not a failure, and the caller's `assert` carries the
  # `^SIZE-GATE: skipped` alternation that matches this line.
  echo "SIZE-GATE: skipped (requires SIZE=${REQUIRED}, SIZE is ${SIZE})"
  exit 0
fi

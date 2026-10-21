#!/usr/bin/env bash
# platform-check.sh — asserts that every pinned lab image's MANIFEST LIST
# carries both Linux architectures this course runs on.
#
# Both SOURCED and EXECUTED:
#
#   sourced   . "${LABS_DIR}/tools/platform-check.sh"   -> platform_list, assert_platforms
#   executed  bash platform-check.sh                    -> checks every pinned reference
#             PLATFORM_CHECK_SELFTEST=1 bash platform-check.sh   -> the negative control
#
# Why this file exists, and why it is SEPARATE from the digest checker
# -------------------------------------------------------------------
# "Every image reference is digest-pinned" and "every pinned image is
# multi-architecture" are two different assertions, and conflating them would
# break one of the two:
#
#   * the FORM assertion is a static property of this repository. STANDARDS.md
#     § C17 and scripts/standards/image-digest-pin.mjs own it, it reads files
#     only, and it must keep working with no network — a standards gate that
#     made a registry call would fail on a plane.
#   * the PLATFORM assertion needs a registry round-trip. It cannot be static,
#     and it is the one network-dependent check on the lab surface.
#
# So C17 says *this reference carries an index digest* and this script says
# *that index actually carries both architectures*. The first is what makes ONE
# pin serve both arms; the second is what proves the pin can.
#
# THREE PROPERTIES THE IMPLEMENTATION MUST HAVE, each with its reason
# ------------------------------------------------------------------
# 1. ASSERT BY SET MEMBERSHIP, NEVER BY INDEX POSITION. A manifest list's entry
#    order is specified nowhere — not in the OCI image-index spec, not by any
#    registry — so an assertion that read "the first entry" or "the second
#    entry" would pass or fail on an ordering the registry is free to change
#    between pulls. Every comparison below is `case " ${list} " in *" ${want} "*`
#    against a space-delimited set, and nothing in this file subscripts a
#    platform list.
#
# 2. A SINGLE-PLATFORM LIST IS A FINDING, NAMING THE PLATFORM IT LACKS. Not a
#    warning and not a footnote. One image in this project's recorded set ships
#    a single-platform manifest at EVERY published tag — measured 2026-10-04,
#    planning/lab-tests/spike-00-preflight.md § NO-GO — while its upstream
#    release notes claim the arm64 fix landed. The measurement is the authority
#    and the notes are wrong, which is exactly why this assertion exists and
#    why that image is its negative control. Run it with
#    PLATFORM_CHECK_SELFTEST=1 and this script must REPORT it: a platform
#    assertion that has never reported a single-platform image is a platform
#    assertion nobody has tested, and a refactor that made it always pass would
#    be invisible.
#
# 3. THE IMAGE LIST COMES FROM ONE PLACE — the committed pin records themselves,
#    read out of the tree rather than retyped here. If the references were
#    duplicated into this file, the helper and the pins could disagree about
#    what the lab runs, and the helper would keep passing while asserting
#    something about images nothing applies. Where a reference lives in a
#    rendered manifest, it is read from that manifest.
#
# THE UPSTREAM NOTE THAT BELONGS BESIDE THIS ASSERTION
# ----------------------------------------------------
# kind's own v0.33.0 release note, quoted rather than paraphrased:
#
#   "NOTE: These node images support amd64 and arm64, both of our supported
#    platforms. You must use the same platform as your host"
#
# Those are two different statements and it is easy to collapse them. This
# script asserting that the INDEX carries both architectures is not the same as
# a learner being free to pick either: the learner must use their host's
# platform, and the index carrying both is what makes the SAME digest pin
# correct on an Apple Silicon laptop and on an amd64 runner. The pin is
# portable; the choice is not a choice.
#
# Env:
#   REQUIRED_PLATFORMS        space-separated set every manifest list must
#                             CONTAIN. Default: "linux/amd64 linux/arm64".
#   PLATFORM_CHECK_SELFTEST   when 1, check ONLY the known single-platform
#                             image and assert it is reported. Exits non-zero
#                             on success of that assertion, which is the point.
#   LAB_ROOT                  the lab tree to scan (default: the directory
#                             holding this script's own `tools/` directory).
#                             NOT the repository root — see below.
#
# Requires: docker (with buildx) and node, and NETWORK ACCESS. It is a metadata
# read and never a pull — no image bytes cross the wire.
#
# Idempotent: read-only. It inspects manifests and prints a verdict.
# bash-3.2 compatible (macOS default shell). No arrays, no `local -n`.
#
# Never pipes a command into a quiet pattern matcher: under `set -o pipefail`
# that returns a non-zero status on a SUCCESSFUL match, because the matcher
# exits at the first hit and the writer takes a signal. It produced a false
# architecture verdict in this project once already. Everything here captures
# into a variable and matches with `case`.

# --- the tree this scans, and why it is the LAB root and not the repository ---
# One level up from this script's own directory, never two.
#
# This used to resolve `../..` and then walk `${REPO_ROOT}/labs`, which is
# correct in the authoring repository and wrong for every learner:
# `scripts/sync-grid.mjs` publishes labs/<x>/ as <x>/ at the clone root, so this
# file sits at labs/tools/ privately and tools/ in a learner's clone. Two up
# from tools/ is the clone's PARENT, and `<parent>/labs` does not exist — so the
# collector walked nothing and the run died, or reported "no digest-pinned image
# reference was found" about a tree full of them. Same root cause as the one
# `size-gate.sh` carried; found by `scripts/lab-sizes.test.mjs`'s D1 assertion
# rather than by reading, which is what that assertion is for.
#
# One up from tools/ is the lab root in BOTH trees, because the strip removes a
# leading segment from this script and from its target alike, leaving the
# distance between them unchanged. Resolve to the lab root, scan it directly,
# and never name `labs` as a path component again.
PLATFORM_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="${LAB_ROOT:-$(cd "${PLATFORM_CHECK_DIR}/.." && pwd)}"

REQUIRED_PLATFORMS="${REQUIRED_PLATFORMS:-linux/amd64 linux/arm64}"

# THE NEGATIVE CONTROL. The Gateway API Inference Extension's lightweight
# endpoint picker at v1.6.2: a bare image manifest rather than an index,
# linux/amd64 only, with no arm64 entry at any published tag. Pinned by digest
# here like everything else, and deliberately NOT part of the scanned set — it
# is referenced by no lab script precisely BECAUSE it is unusable on Apple
# Silicon, so it has to be named to be tested.
PLATFORM_CHECK_CONTROL_REF="registry.k8s.io/gateway-api-inference-extension/lwepp@sha256:eafd37059f7a1e5be693be480b1831167e64debda605f3864b3528585be05b74"

# --- collecting the references ------------------------------------------------
# node, not grep or a shell loop, and the reason is measured rather than
# stylistic: this project's authoring host aliases `grep` to a wrapper that
# REJECTS -n/-r and prints nothing, which reads as a clean scan. A reference
# collector built on grep would fail OPEN — it would find no images, check
# nothing, and the count assertion below is the only thing that would notice.
# node is the pinned runtime and is already a hard dependency of the standards
# gate.
#
# The extensions are C17's corpus (`.sh`, `.yaml`, `.yml`) plus `.json`, which
# carries a digest in a profile's checks file, plus `.md`, which is where the
# digest REGISTERS live. C17 scopes `.md` out for its own reason — a register
# documents how a digest was resolved, naming the tag, and a form rule that
# read it would report the register. That reason does not apply here: this
# script matches only tokens that already carry a digest, so a register row is
# a reference and a resolving command is invisible to it.
#
# THE SELF-REFERENCE TRAP, HIT LIVE WHILE WRITING THIS FILE. The collector read
# `labs/tools/platform-check.sh` — itself — and picked up the negative control
# constant above as if it were a lab image. The run then reported a finding
# against an image no lab applies, which is a FALSE POSITIVE that reads exactly
# like a true one. Same shape STANDARDS.md § "The trap is not confined to
# authored content" names for a workflow grepping itself. The exclusion is ONE
# EXACT PATH and never a pattern, for C17's reason: a pattern excluding
# anything tools-looking would exclude the next helper that genuinely pinned an
# image.
platform_check_refs() {
  node -e '
    const fs = require("fs");
    const path = require("path");
    const root = process.argv[1];
    const EXT = new Set([".sh", ".yaml", ".yml", ".json", ".md"]);
    // The repository part may be a bare single-segment name (an implicit
    // Docker Hub reference such as `busybox` or `python`) and may carry a tag
    // before the digest, because a chart can compose `repo:tag@sha256:<d>`.
    const RE = /([a-z0-9][a-z0-9._\/-]*(?::[A-Za-z0-9._-]+)?)@sha256:([0-9a-f]{64})/g;
    // A purely numeric-dotted "repository" is not one: a chart values file
    // writes `tag: "1.121.3@sha256:<d>"`, which is an INPUT to a render and
    // half a reference. The whole reference is in the rendered manifest, which
    // this walk also reads, so dropping the fragment loses no image.
    const NUMERIC_ONLY = /^[0-9]+(?:\.[0-9]+)*$/;
    // One exact path, not a pattern. See the self-reference note above.
    const SELF = new Set([path.join(root, "tools", "platform-check.sh")]);
    const out = new Set();
    const walk = (dir) => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) { walk(p); continue; }
        if (!EXT.has(path.extname(e.name))) continue;
        if (SELF.has(p)) continue;
        const text = fs.readFileSync(p, "utf8");
        for (const m of text.matchAll(RE)) {
          // Strip a tag sitting between the repository and the digest. The
          // digest is what identifies the image; the tag beside it is
          // decoration that some registries reject on an inspect.
          const repo = m[1].includes("/")
            ? m[1].replace(/:[^:\/]+$/, "")
            : m[1].replace(/:[^:\/]+$/, "");
          if (NUMERIC_ONLY.test(repo)) continue;
          out.add(repo + "@sha256:" + m[2]);
        }
      }
    };
    walk(root);
    process.stdout.write([...out].sort().join("\n"));
  ' "${LAB_ROOT}"
}

# --- reading one manifest's platform set --------------------------------------
# Prints a space-separated platform set on stdout. Two calls, because the two
# manifest shapes answer different questions and the single-platform shape makes
# the index form ERROR rather than return empty:
#
#   an INDEX              -> `--raw` carries a `manifests` array with a
#                            `platform` per entry
#   a bare image MANIFEST -> `--raw` carries no `manifests` key at all, and
#                            asking for one is a template error. The platform
#                            then comes from the resolved image's own config.
#
# Attestation entries (`unknown/unknown`) are dropped: they are signatures
# attached to the index, not architectures it can run on, and counting them
# would let an index of nothing but attestations look populated.
#
# AND `linux/arm64/v8` IS `linux/arm64`. Measured, not assumed: two images in
# this project's pinned set — the measurement client and the CPU tokenizer —
# publish their arm64 entry WITH the `v8` variant while every other image
# publishes it without. `v8` is arm64's baseline variant, which is why
# containerd's own platform matcher normalises it away, and a set-membership
# test that did not would have reported two perfectly portable images as
# lacking arm64. That is a FALSE POSITIVE in the one direction that matters
# here: it would have sent an author hunting for a release that already exists.
#
# The normalisation is deliberately narrow and names its one case. `linux/arm`
# keeps its `v6`/`v7` variants, because those are genuinely different targets
# and an image shipping only `arm/v7` does NOT satisfy a request for `arm`.
platform_list() {
  local ref raw plat
  ref="$1"

  raw="$(docker buildx imagetools inspect --raw "${ref}" 2>&1)" || {
    echo "FAIL: could not read the manifest for '${ref}'." >&2
    echo "      Remedy: check network access and that the digest still exists in its registry." >&2
    echo "      Registry said: $(printf '%s' "${raw}" | sed -n '1,3p' | tr '\n' ' ')" >&2
    return 1
  }

  plat="$(printf '%s' "${raw}" | node -e '
    let s = "";
    process.stdin.on("data", (d) => { s += d; });
    process.stdin.on("end", () => {
      let j;
      try { j = JSON.parse(s); } catch { process.stdout.write("PARSE-ERROR"); return; }
      if (!Array.isArray(j.manifests)) { process.stdout.write("NO-MANIFESTS"); return; }
      const set = [];
      for (const m of j.manifests) {
        const p = m && m.platform;
        if (!p || !p.os || !p.architecture) continue;
        if (p.os === "unknown" || p.architecture === "unknown") continue;
        // `arm64/v8` normalises to `arm64`; every other variant is kept. See
        // the comment above this function for why this one case and no other.
        const variant = (p.architecture === "arm64" && p.variant === "v8") ? "" : (p.variant || "");
        const name = p.os + "/" + p.architecture + (variant ? "/" + variant : "");
        if (!set.includes(name)) set.push(name);
      }
      process.stdout.write(set.join(" "));
    });
  ')" || return 1

  case "${plat}" in
    PARSE-ERROR)
      echo "FAIL: the manifest for '${ref}' did not parse as JSON." >&2
      return 1
      ;;
    NO-MANIFESTS)
      # A bare image manifest: ONE platform, by construction. Read it from the
      # resolved image's config so the finding can name what the image IS as
      # well as what it lacks.
      plat="$(docker buildx imagetools inspect --format '{{json .Image.Platform}}' "${ref}" 2>/dev/null \
        | node -e '
            let s = "";
            process.stdin.on("data", (d) => { s += d; });
            process.stdin.on("end", () => {
              let p;
              try { p = JSON.parse(s); } catch { process.stdout.write(""); return; }
              if (!p || !p.os || !p.architecture) { process.stdout.write(""); return; }
              const variant = (p.architecture === "arm64" && p.variant === "v8") ? "" : (p.variant || "");
              process.stdout.write(p.os + "/" + p.architecture + (variant ? "/" + variant : ""));
            });
          ')"
      ;;
  esac

  printf '%s' "${plat}"
}

# --- the assertion ------------------------------------------------------------
# SET MEMBERSHIP in both loops. Returns 0 when every required platform is in the
# list, and otherwise names every one that is missing — plural, because an
# author fixing one at a time stops running the check.
assert_platforms() {
  local ref list missing one
  ref="$1"
  list="$2"
  missing=""

  if [ -z "${list}" ]; then
    echo "FAIL: '${ref}' reported NO platform at all." >&2
    echo "      An empty platform set is not a pass: it means the manifest was read and" >&2
    echo "      understood as carrying nothing runnable, which no lab image can be." >&2
    return 1
  fi

  for one in ${REQUIRED_PLATFORMS}; do
    case " ${list} " in
      *" ${one} "*) : ;;
      *) missing="${missing} ${one}" ;;
    esac
  done

  if [ -n "${missing}" ]; then
    echo "FAIL: '${ref}' lacks:${missing}" >&2
    echo "      It carries: ${list}" >&2
    echo "      A single-platform manifest is a FINDING and not a footnote — the pin resolves" >&2
    echo "      on one architecture and fails on the other, and the failure surfaces as an" >&2
    echo "      exec-format error inside a Pod rather than as a pull error." >&2
    echo "      Remedy: find a release that publishes the missing platform, or fence the lab" >&2
    echo "      that uses this image on the architecture it does not support and SAY SO." >&2
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# EXECUTED form. Guarded so sourcing defines the two functions and runs nothing.
# -----------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail

  for _tool in docker node; do
    if ! command -v "${_tool}" >/dev/null 2>&1; then
      echo "FAIL: ${_tool} is required — the platform set is read from each registry's manifest." >&2
      exit 1
    fi
  done

  # --- the negative control ---------------------------------------------------
  if [ "${PLATFORM_CHECK_SELFTEST:-0}" = "1" ]; then
    echo "platform-check SELFTEST: asserting the known single-platform image is REPORTED." >&2
    echo "  subject: ${PLATFORM_CHECK_CONTROL_REF}" >&2
    CONTROL_LIST="$(platform_list "${PLATFORM_CHECK_CONTROL_REF}")" || exit 1
    if assert_platforms "${PLATFORM_CHECK_CONTROL_REF}" "${CONTROL_LIST}"; then
      echo "FAIL: the negative control PASSED, which means this assertion cannot fail." >&2
      echo "      The reference above ships a single linux/amd64 manifest at every published" >&2
      echo "      tag (measured 2026-10-04, planning/lab-tests/spike-00-preflight.md), so a" >&2
      echo "      pass here means the platform check has stopped checking." >&2
      exit 1
    fi
    echo "platform-check SELFTEST: the single-platform image was reported, as it must be." >&2
    # Exits NON-ZERO on purpose. The caller's assertion is `test $? -ne 0`: the
    # script's job in this mode is to demonstrate a finding, and a finding is a
    # non-zero exit everywhere else in this tree too.
    exit 1
  fi

  # --- the real run -----------------------------------------------------------
  REFS="$(platform_check_refs)"
  if [ -z "${REFS}" ]; then
    echo "FAIL: no digest-pinned image reference was found under ${LAB_ROOT}." >&2
    echo "      A run that checked nothing exits 0 and reads as clean, so this is an error." >&2
    echo "      Either the tree moved or the collector stopped matching; check both before" >&2
    echo "      believing the lab surface has no pinned images." >&2
    exit 1
  fi

  CHECKED=0
  FINDINGS=0
  # A here-string rather than a pipe, so the loop body runs in THIS shell and
  # the two counters survive it. bash-3.2 has no lastpipe.
  while IFS= read -r REF; do
    [ -n "${REF}" ] || continue
    CHECKED=$(( CHECKED + 1 ))
    if ! LIST="$(platform_list "${REF}")"; then
      FINDINGS=$(( FINDINGS + 1 ))
      continue
    fi
    if assert_platforms "${REF}" "${LIST}"; then
      echo "  ok  ${REF}"
      echo "        ${LIST}"
    else
      FINDINGS=$(( FINDINGS + 1 ))
    fi
  done <<< "${REFS}"

  if [ "${FINDINGS}" -ne 0 ]; then
    echo "FAIL: ${FINDINGS} of ${CHECKED} pinned image(s) do not carry every required platform." >&2
    echo "      Required set: ${REQUIRED_PLATFORMS}" >&2
    exit 1
  fi

  echo "OK: ${CHECKED} pinned image(s) checked; every manifest list contains ${REQUIRED_PLATFORMS}."
  echo "    kind's own release note, for the node image: these images support amd64 and arm64,"
  echo "    and a learner must use the SAME PLATFORM AS THEIR HOST. The index carrying both is"
  echo "    what makes one digest pin correct on either machine; it is not a free choice."
fi

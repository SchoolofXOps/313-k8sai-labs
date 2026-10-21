#!/usr/bin/env node
// kueue-config-probe.mjs — read a Kueue `Configuration` document and print ONE
// machine-readable line describing the two things SC2 asserts about it.
//
// WHY THIS IS A PARSER AND NOT A grep OR AN awk
// ---------------------------------------------
// It replaced an `awk` line-counter that counted every `-` item after
// `deviceClassMappings:` — which, on the one mapping this course configures,
// counted TWO: the mapping's own `- name:` and the nested
// `deviceClassNames:`'s `- sim-accelerator.example.com`. The assertion it fed
// ("non-empty") was still right; the NUMBER it published in an `OK:` line was
// not. A figure in an OK: line is a claim, and a claim that is off by one
// because of YAML nesting is a claim nobody can check.
//
// The substring test it also replaced was weaker in a different way: a `case`
// match for the DeviceClass name anywhere in the document is satisfied by the
// name appearing in a COMMENT, so a Configuration that mentioned the right
// DeviceClass and mapped nothing would have passed.
//
// So this resolves the document and reads the actual fields.
//
// WHY `kubectl` IS THE PARSER, AND NOT A NODE YAML LIBRARY
// -------------------------------------------------------
// MEASURED 2026-10-14, run 38488339140 — the first ever CI run of
// `.github/workflows/profiles.yml`. This file used to `import yaml from
// "js-yaml"`, which is a devDependency of the REPOSITORY ROOT manifest. It
// resolved on the authoring host only because `node_modules/` happened to exist
// in the working tree. On both CI arms it failed identically:
//
//   Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'js-yaml'
//
// and the failure was not confined to CI. `scripts/sync-grid.mjs` publishes this
// file to the public labs repository and publishes NO `package.json` alongside
// it, so a learner who clones `313-k8sai-labs` and runs the queueing layer hit
// the same error — in the one layer whose entire point is SC2's
// `deviceClassMappings` assertion.
//
// Three fixes were available and this is the one that adds no dependency to a
// learner-facing repository and keeps a REAL parse:
//
//   `kubectl patch --local --type=merge -p '{}' -f - -o json`
//
// That is `sigs.k8s.io/yaml` — the same YAML-to-JSON conversion the API server's
// own clients use — running entirely offline. `--local` contacts no server, and
// `--kubeconfig /dev/null` is passed as well so "no cluster is contacted" is a
// property of the command rather than a claim in a comment. `kubectl` is not a
// new prerequisite: `labs/tools/pinned-bin.sh` already asserts it is present AND
// at the pinned 1.37.x, so the parser is pinned with the toolchain. JSON is then
// read with `JSON.parse`, which is built into Node.
//
// Hand-matching the YAML was the other candidate and was rejected: the two facts
// are extractable by pattern, but a pattern that cannot read a flow-style list
// or a quoted key either passes on input it did not understand or fails on
// configurations this course supports, and both are worse than the defect.
//
// THE SYNTHETIC CARRIER HEADER, AND WHY IT IS SAFE
// -----------------------------------------------
// `kubectl` refuses a document with no `kind`, and one of the two input shapes
// below — the chart values file — legitimately has none. So two lines are
// prepended to every document before conversion:
//
//   apiVersion: kueue-config-probe.invalid/absent
//   kind: ProbeCarrier
//
// MEASURED: `sigs.k8s.io/yaml` resolves duplicate mapping keys LAST-WINS, so a
// document carrying its own `apiVersion`/`kind` overrides both prepended lines
// and is read exactly as written; a document carrying neither becomes decodable
// without any field being dropped, because an unrecognised `kind` decodes as
// unstructured. The sentinel is reported as `none`, which is the same thing this
// probe has always printed for an absent `apiVersion` — so a Configuration that
// LOST its apiVersion, which is drift this check exists to catch, still comes out
// as `config_group=none` and still fails at the call site.
//
// One leading `---` IS REMOVED BEFORE THE PREPEND, and this is not cosmetic.
// `kueue-values.yaml` opens with 86 lines of comment and then a document-start
// marker at line 87. Prepending across that marker makes the header its own
// document and the real content a SECOND one with no `kind` — measured, and it
// failed exactly that way the first time this was written. A leading marker on a
// single-document stream is optional syntax, so dropping it changes nothing; any
// marker that is not the leading one still splits the stream, which is the next
// paragraph's case.
//
// A multi-document input is NOT silently half-read: the trailing documents have
// no `kind`, `kubectl` exits non-zero naming the one it could not decode, and
// this probe fails closed on that status.
//
// TWO INPUT SHAPES, ONE ASSERTION
// -------------------------------
// The same Configuration exists in two places and both are asserted in this
// phase, so one probe reads both rather than two readers drifting apart:
//
//   the LIVE ConfigMap     already IS a Configuration document
//   the COMMITTED values   carries it as a nested STRING at
//                          managerConfig.controllerManagerConfigYaml
//
// The nested form is unwrapped below. That is also why the committed values file
// can be asserted with no cluster at all, which is the one entry in this layer's
// checks.json that needs none.
//
// Usage:
//   node kueue-config-probe.mjs <config.yaml|values.yaml> [<device-class-name>]
//
// Output, one line, every field present every time:
//   config_group=<apiVersion> mappings=<n> maps_deviceclass=<yes|no|unasked> quota_resources=<csv>
//
// Exit 0 when the file parsed. Exit 1, with the reason on stderr and NO summary
// line on stdout, when it did not — a caller asserting on the summary line
// therefore fails closed rather than reading a partial line.
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

/** Overridable so a caller can name a specific binary; `kubectl` on PATH otherwise. */
const KUBECTL = process.env.KUBECTL || "kubectl";

/** The prepended header. `.invalid` is reserved by RFC 2606, so it can never be a real group. */
const CARRIER_API_VERSION = "kueue-config-probe.invalid/absent";
const CARRIER_KIND = "ProbeCarrier";

const [file, wantDeviceClass] = process.argv.slice(2);

if (!file) {
  console.error("usage: node kueue-config-probe.mjs <config.yaml> [<device-class-name>]");
  process.exit(1);
}

/**
 * Drop the stream's leading `---`, if the first line that is neither blank nor a comment is
 * exactly that. See the header: `kueue-values.yaml` carries one at line 87, and prepending the
 * carrier across it splits the stream in two.
 *
 * Only a bare marker is removed. `--- !something` is left alone and `kubectl` decides, because a
 * marker carrying a tag is not the optional syntax this is skipping.
 *
 * @param {string} text
 * @returns {string}
 */
function withoutLeadingMarker(text) {
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim() === "" || /^\s*#/.test(line)) continue;
    if (line.trim() === "---") {
      lines.splice(i, 1);
      return lines.join("\n");
    }
    return text;
  }
  return text;
}

/**
 * Resolve one YAML document to a plain object, or exit 1 with the reason.
 *
 * @param {string} text the document
 * @param {string} what how to name it in a failure message
 * @returns {object}
 */
function resolveDocument(text, what) {
  const carried = `apiVersion: ${CARRIER_API_VERSION}\nkind: ${CARRIER_KIND}\n${withoutLeadingMarker(text)}`;
  const r = spawnSync(
    KUBECTL,
    ["patch", "--local", "--kubeconfig", "/dev/null", "--type=merge", "-p", "{}", "-f", "-", "-o", "json"],
    { input: carried, encoding: "utf8" },
  );

  if (r.error) {
    console.error(
      `FAIL: could not run '${KUBECTL}' to resolve ${what}: ${r.error.message}`,
    );
    console.error(
      "      This probe uses kubectl as its YAML parser so that it needs no npm",
    );
    console.error(
      "      package. kubectl is already required by labs/tools/pinned-bin.sh;",
    );
    console.error(
      "      install the pinned 1.37.x and re-run. Nothing was changed.",
    );
    process.exit(1);
  }
  if (r.status !== 0) {
    const why = (r.stderr || "").trim() || `kubectl exited ${r.status}`;
    console.error(`FAIL: ${what} did not resolve as YAML: ${why}`);
    process.exit(1);
  }

  let doc;
  try {
    doc = JSON.parse(r.stdout);
  } catch (err) {
    console.error(
      `FAIL: ${what} did not convert to a single JSON object: ${err.message}`,
    );
    console.error(
      "      A multi-document stream converts to several objects and is refused here",
    );
    console.error(
      "      rather than half-read — the first document is not the subject.",
    );
    process.exit(1);
  }

  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    console.error(`FAIL: ${what} did not resolve to a mapping — it is empty or it is a scalar.`);
    process.exit(1);
  }
  return doc;
}

let text;
try {
  text = readFileSync(file, "utf8");
} catch (err) {
  console.error(`FAIL: could not read ${file}: ${err.message}`);
  process.exit(1);
}

// An empty file would otherwise resolve to the carrier header alone and report a
// clean nothing. Asserted here rather than left to the converter, because the
// converter sees a valid two-line document.
if (text.trim() === "") {
  console.error(`FAIL: ${file} is empty, so there is no Configuration to read.`);
  process.exit(1);
}

let doc = resolveDocument(text, file);

// Unwrap the chart-values shape. Done before anything is read, so every field
// below is read off a Configuration regardless of which file was given.
const nested = doc.managerConfig?.controllerManagerConfigYaml;
if (typeof nested === "string") {
  doc = resolveDocument(nested, `${file}'s managerConfig.controllerManagerConfigYaml`);
}

const rawGroup = typeof doc.apiVersion === "string" ? doc.apiVersion : "";
const group = rawGroup.length > 0 && rawGroup !== CARRIER_API_VERSION ? rawGroup : "none";

// Array.isArray rather than a truthiness test: `deviceClassMappings: {}` and
// `deviceClassMappings: ""` are both truthy and neither is a list of mappings.
const raw = doc.resources?.deviceClassMappings;
const mappings = Array.isArray(raw) ? raw : [];

// The quota resource NAMES — what ClusterQueue.nominalQuota counts. Printed so a
// caller can assert the name as well as the count, and sorted so the field is
// stable across renders.
const quotaResources = mappings
  .map((m) => (m && typeof m.name === "string" ? m.name : ""))
  .filter((n) => n.length > 0)
  .sort();

// Present in a REAL deviceClassNames list of a REAL mapping — not merely present
// in the file's text.
let mapsDeviceClass = "unasked";
if (wantDeviceClass) {
  const found = mappings.some(
    (m) => Array.isArray(m?.deviceClassNames) && m.deviceClassNames.includes(wantDeviceClass),
  );
  mapsDeviceClass = found ? "yes" : "no";
}

process.stdout.write(
  `config_group=${group} mappings=${mappings.length} ` +
    `maps_deviceclass=${mapsDeviceClass} quota_resources=${quotaResources.join(",")}\n`,
);

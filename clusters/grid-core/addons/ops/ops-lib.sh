#!/usr/bin/env bash
# ops-lib.sh — the two things create.sh and verify.sh both need, factored once.
#
# SOURCED, never executed:  . "${ADDON_DIR}/ops-lib.sh"
#
# Why this file exists
# -------------------
# Both scripts have to reach an in-cluster HTTP endpoint, and this layer binds
# no host port, maps no port and exposes no Ingress — that is what keeps it a
# LAYER rather than a profile. So every endpoint is reached through a port
# forward the calling script starts and kills, and every response is read by a
# small Python probe rather than by `curl`, because the thing being asserted is
# a JSON document's own fields and not an exit code.
#
# A second copy of a port-forward dance is a second thing that can be right
# while the first one is wrong, so it lives here. `labs/tools/pinned-bin.sh`
# set that precedent for the version asserts.
#
# THE PROBE IS WRITTEN TO A TEMP FILE AND THEN RUN, never fed to `python3 -`
# from a heredoc inside a command substitution. That second form is a shape
# this project has been bitten by twice: `$( ... <<'PY' ... PY )` is not
# reliably parsed by the bash that ships on the authoring platform, and the
# failure mode is the worst kind — the substitution produces nothing, the
# variable is never assigned, and the script runs on until `set -u` catches it
# somewhere unrelated.
#
# bash-3.2 compatible (macOS default shell). No arrays.

# --- port forwarding ----------------------------------------------------------
# FWD_PID and FWD_PORT are the caller's to read. fwd_start walks to a free local
# port before forwarding: killing a previous forward RETURNS before the socket
# is released, so the next forward's readiness check can succeed against the
# DYING previous one — a failure that is invisible in the response, because
# every response is still well-formed.
FWD_PID=""
FWD_PORT=""

fwd_stop() {
  if [ -n "${FWD_PID}" ]; then
    kill "${FWD_PID}" 2>/dev/null || true
    wait "${FWD_PID}" 2>/dev/null || true
  fi
  FWD_PID=""
}

# fwd_start <context> <namespace> <svc/name> <remote-port> <preferred-local-port>
# Prints nothing on success; sets FWD_PORT and FWD_PID. Returns 1 and explains
# on failure, so the caller owns the FAIL: wording and the remedy.
fwd_start() {
  _ctx="$1"; _ns="$2"; _target="$3"; _remote="$4"; _want="$5"
  _tries=0
  FWD_PORT="${_want}"
  while nc -z 127.0.0.1 "${FWD_PORT}" 2>/dev/null; do
    _tries=$((_tries + 1))
    if [ "${_tries}" -gt 50 ]; then
      echo "no free local port in ${_want}..$((_want + 50))" >&2
      return 1
    fi
    FWD_PORT=$((_want + _tries))
  done

  kubectl --context "${_ctx}" -n "${_ns}" port-forward "${_target}" \
    "${FWD_PORT}:${_remote}" >/dev/null 2>&1 &
  FWD_PID=$!

  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if nc -z 127.0.0.1 "${FWD_PORT}" 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "the forward to ${_ns}/${_target}:${_remote} never came up on 127.0.0.1:${FWD_PORT}" >&2
  fwd_stop
  return 1
}

# --- the probe ----------------------------------------------------------------
# ops_probe <mode> <base-url>   ->  one line of key=value facts on stdout
#
# Three modes, one per component, and each reads the component's OWN state
# document rather than anything Kubernetes says about the Pod:
#
#   targets          the collector's own target list. A collector whose every
#                    target is down is Running, Ready and Available and reports
#                    nothing, so the Pod's phase is indistinguishable between a
#                    working install and one that collects nothing.
#   grafana-health   the dashboard's own health endpoint, which reports the
#                    running VERSION. That is what makes the pinned major
#                    assertable rather than merely written down.
#   opencost-health  the cost tool's own readiness endpoint. NO cost figure is
#                    read here and none is asserted anywhere in this layer: on a
#                    laptop with no cloud pricing every rate is a default
#                    standing in for a price nobody paid.
#
# Never raises: an unreachable endpoint prints `reachable=no reason=<ExcType>`
# and exits 0, so the caller's `case` is the single place a failure is worded.
OPS_PROBE_PY=""

ops_probe_cleanup() {
  if [ -n "${OPS_PROBE_PY}" ]; then rm -f "${OPS_PROBE_PY}"; fi
  OPS_PROBE_PY=""
}

ops_probe() {
  _mode="$1"; _base="$2"
  OPS_PROBE_PY="$(mktemp "${TMPDIR:-/tmp}/addon-ops-probe.XXXXXX")"
  cat > "${OPS_PROBE_PY}" <<'PY'
import json, sys, urllib.request

mode, base = sys.argv[1], sys.argv[2]


def get(path):
    with urllib.request.urlopen(base + path, timeout=30) as r:
        return r.status, r.read().decode()


try:
    if mode == "targets":
        status, body = get("/api/v1/targets?state=active")
        data = json.loads(body)
        active = (data.get("data") or {}).get("activeTargets") or []
        total = len(active)
        up = sum(1 for t in active if t.get("health") == "up")
        jobs = ",".join(sorted({(t.get("labels") or {}).get("job", "?") for t in active})) or "-"
        down = ",".join(sorted({(t.get("labels") or {}).get("job", "?")
                                for t in active if t.get("health") != "up"})) or "-"
        print("reachable=yes status=%s targets_total=%d targets_up=%d jobs=%s not_up=%s"
              % (status, total, up, jobs, down))

    elif mode == "grafana-health":
        status, body = get("/api/health")
        data = json.loads(body)
        version = str(data.get("version") or "")
        major = version.split(".")[0] if version else "?"
        print("reachable=yes status=%s database=%s version=%s major=%s"
              % (status, data.get("database") or "?", version or "?", major))

    elif mode == "opencost-health":
        status, _ = get("/healthz")
        print("reachable=yes status=%s" % status)

    else:
        print("reachable=no reason=UnknownMode")
except Exception as exc:                      # reported, never swallowed
    print("reachable=no reason=%s" % type(exc).__name__)
PY
  python3 "${OPS_PROBE_PY}" "${_mode}" "${_base}" 2>/dev/null || true
  ops_probe_cleanup
}

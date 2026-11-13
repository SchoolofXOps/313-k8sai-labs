"""
labs/m11/actor.py - the scripted actor: it reads, it is refused, it proposes.

Module 11, "Governance for an actor that improvises". This is NOT an agent and it
uses no agent framework. It is a fixed script that does, in order, what an
agent with this identity would be able to do, so the lab can read the result
from the API server and its audit log instead of from a model's behaviour.

It runs as the Pod `actor` in agent-actor, under the ServiceAccount `actor`,
with the Pod's own mounted token and nothing else. Its RBAC:

    Role actor-read     in agent-target   get, list   configmaps
    Role actor-propose  in agent-actor    create, get configmaps

In order:

  1. reads ConfigMap target-settings in agent-target           -> read=ok
  2. tries to change it directly to mode: burst (a merge patch) -> direct-change=403
  3. writes its proposal as ConfigMap proposal-1 in agent-actor,
     whose data holds the full proposed manifest and a reason   -> proposal=proposal-1
  4. exits 0

Step 2 is refused by the API server because the actor's identity holds no
write verb in agent-target. The refusal is the API server's, and it is the
event the lab reads from the audit log, attributed to
system:serviceaccount:agent-actor:actor with code 403.

Exit codes: 0 when the run went as above; 1 when it could not read the
target; 2 when the direct change was NOT refused, which means the RBAC in
labs/m11/actor-rbac.yaml is not what the lab applied.

Python standard library only. Nothing is installed into the image.
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_API = "https://kubernetes.default.svc"
TARGET_NS = "agent-target"
TARGET = "target-settings"
PROPOSAL_NS = "agent-actor"
PROPOSAL = "proposal-1"
WANTED_MODE = "burst"


def call(path, method="GET", body=None, ctype="application/json"):
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = ctype
    req = urllib.request.Request(K8S_API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read()), e.code
        except ValueError:
            return {"message": e.reason}, e.code


def proposed_manifest(current):
    """The whole ConfigMap as the actor wants it, written as YAML by hand."""
    data = dict(current.get("data") or {})
    data["mode"] = WANTED_MODE
    lines = [
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        "  name: " + TARGET,
        "  namespace: " + TARGET_NS,
        "data:",
    ]
    for key in sorted(data):
        lines.append("  %s: %s" % (key, json.dumps(str(data[key]))))
    return "\n".join(lines) + "\n"


def main():
    current, code = call("/api/v1/namespaces/%s/configmaps/%s" % (TARGET_NS, TARGET))
    if code != 200:
        print("read=%d" % code, flush=True)
        return 1
    print("read=ok", flush=True)

    _, code = call(
        "/api/v1/namespaces/%s/configmaps/%s" % (TARGET_NS, TARGET),
        method="PATCH",
        body={"data": {"mode": WANTED_MODE}},
        ctype="application/merge-patch+json",
    )
    print("direct-change=%d" % code, flush=True)
    if code != 403:
        return 2

    proposal = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": PROPOSAL,
            "namespace": PROPOSAL_NS,
            "labels": {"app.kubernetes.io/part-of": "m11", "m11.k8sai/proposal-for": TARGET},
        },
        "data": {
            "manifest.yaml": proposed_manifest(current),
            "reason": "change %s/%s mode from %s to %s; the direct change was refused with 403, "
                      "so a human with the authority must review and apply it"
                      % (TARGET_NS, TARGET, (current.get("data") or {}).get("mode"), WANTED_MODE),
        },
    }
    _, code = call("/api/v1/namespaces/%s/configmaps" % PROPOSAL_NS, method="POST", body=proposal)
    if code in (200, 201):
        print("proposal=%s" % PROPOSAL, flush=True)
    elif code == 409:
        print("proposal=%s already-present" % PROPOSAL, flush=True)
    else:
        print("proposal-write=%d" % code, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

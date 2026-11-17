"""
labs/m11/mcp-server.py - a small MCP tool server whose identity can only read.

Module 11, "Tool servers as infrastructure". Ported from the 304-kubeadv M10
tool server's lineage: the same protocol subset, a smaller tool list, and one
fixed target namespace.

PROTOCOL. JSON-RPC 2.0 over HTTP. One endpoint does the work:

    POST /mcp        methods: initialize, tools/list, tools/call
    GET  /healthz    plain "ok", for the readiness probe

PORT. Read from the PORT environment variable, default 8080. The Service in
labs/m11/mcp-server.yaml exposes the same port as http://mcp-server:8080/mcp
inside the agent-mcp namespace.

PATHS. The code is mounted from the ConfigMap mcp-server-code at
/app/mcp-server.py. The API credentials are the Pod's own mounted
ServiceAccount token and CA, under /var/run/secrets/kubernetes.io/serviceaccount/.
The server holds no other credential.

TOOLS. Three, all against the namespace in TARGET_NAMESPACE (default
agent-target):

    list_pods          GET  pods                         allowed by Role mcp-read
    get_configmap      GET  one configmap                allowed by Role mcp-read
    create_configmap   POST a configmap                  REFUSED by the API server

create_configmap exists so a mutation can be attempted and denied. The tool
does not decide that it may not write. The ServiceAccount mcp-reader is bound
only to get and list, so the API server answers 403, and the tool relays that
answer, code included, to the caller. That is the lesson: the authority lives
in RBAC, outside the tool server, where the tool cannot talk its way past it.

Python standard library only. Nothing is installed into the image.
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_API = "https://kubernetes.default.svc"
PORT = int(os.environ.get("PORT", "8080"))
TARGET_NAMESPACE = os.environ.get("TARGET_NAMESPACE", "agent-target")
SERVER_NAME = "m11-readonly-tools"
SERVER_VERSION = "1.0.0"


def _credentials():
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    return token, ctx


def k8s_request(path, method="GET", body=None):
    """Call the API server as this Pod's ServiceAccount. Returns (json, code)."""
    token, ctx = _credentials()
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(K8S_API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read())
        except ValueError:
            err = {"message": e.reason}
        return err, e.code


TOOLS = [
    {
        "name": "list_pods",
        "description": "List the Pods in the target namespace (" + TARGET_NAMESPACE + ")",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_configmap",
        "description": "Read one ConfigMap in the target namespace",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
    {
        "name": "create_configmap",
        "description": "Create a ConfigMap in the target namespace (needs a write verb this identity does not hold)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "data": {"type": "object"},
            },
            "required": ["name"],
        },
    },
]


def _relay(data, code):
    """The API server's own answer, with its code, as the tool's text."""
    return json.dumps({"code": code, "reason": data.get("reason"), "message": data.get("message")})


def tool_list_pods(_args):
    data, code = k8s_request("/api/v1/namespaces/%s/pods" % TARGET_NAMESPACE)
    if code != 200:
        return False, _relay(data, code)
    pods = [p["metadata"]["name"] for p in data.get("items", [])]
    return True, json.dumps({"code": code, "namespace": TARGET_NAMESPACE, "pods": pods})


def tool_get_configmap(args):
    name = args.get("name")
    if not name:
        return False, "missing required argument: name"
    # Escaped, so a name such as "x?watch=true" or "../../y" stays one path
    # segment. The scope still comes from RBAC; this keeps the request the one
    # the tool says it makes.
    data, code = k8s_request(
        "/api/v1/namespaces/%s/configmaps/%s" % (TARGET_NAMESPACE, urllib.parse.quote(str(name), safe=""))
    )
    if code != 200:
        return False, _relay(data, code)
    return True, json.dumps({"code": code, "name": name, "data": data.get("data", {})})


def tool_create_configmap(args):
    name = args.get("name")
    if not name:
        return False, "missing required argument: name"
    body = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "namespace": TARGET_NAMESPACE},
        "data": args.get("data") or {},
    }
    data, code = k8s_request(
        "/api/v1/namespaces/%s/configmaps" % TARGET_NAMESPACE, method="POST", body=body
    )
    if code in (200, 201):
        return True, json.dumps({"code": code, "created": name})
    return False, _relay(data, code)


HANDLERS = {
    "list_pods": tool_list_pods,
    "get_configmap": tool_get_configmap,
    "create_configmap": tool_create_configmap,
}


def handle_initialize(_params):
    return {
        "protocolVersion": "2025-03-26",
        "capabilities": {"tools": {"listChanged": False}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def handle_tools_list(_params):
    return {"tools": TOOLS}


def handle_tools_call(params):
    handler = HANDLERS.get(params.get("name"))
    if handler is None:
        return {"content": [{"type": "text", "text": "unknown tool"}], "isError": True}
    ok, text = handler(params.get("arguments") or {})
    return {"content": [{"type": "text", "text": text}], "isError": not ok}


METHODS = {
    "initialize": handle_initialize,
    "tools/list": handle_tools_list,
    "tools/call": handle_tools_call,
}


class MCPHandler(BaseHTTPRequestHandler):
    # A client that stops sending cannot hold a worker for ever.
    timeout = 30

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, b"ok", "text/plain")
            return
        self._send(404, b"", "text/plain")

    def do_POST(self):
        if self.path != "/mcp":
            self._send(404, b"", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length))
            if not isinstance(req, dict):
                raise ValueError("not a JSON-RPC object")
        except ValueError:
            self._rpc({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            return
        method = METHODS.get(req.get("method"))
        if method is None:
            self._rpc({"jsonrpc": "2.0", "id": req.get("id"),
                       "error": {"code": -32601, "message": "Method not found"}})
            return
        params = req.get("params") or {}
        if not isinstance(params, dict) or not isinstance(params.get("arguments") or {}, dict):
            self._rpc({"jsonrpc": "2.0", "id": req.get("id"),
                       "error": {"code": -32602, "message": "Invalid params"}})
            return
        try:
            result = method(params)
        except Exception as e:  # an API timeout or URLError: answer, never drop the connection
            self._rpc({"jsonrpc": "2.0", "id": req.get("id"),
                       "error": {"code": -32603, "message": "Internal error: %s" % e.__class__.__name__}})
            return
        self._rpc({"jsonrpc": "2.0", "id": req.get("id"), "result": result})

    def _rpc(self, payload):
        self._send(200, json.dumps(payload).encode(), "application/json")

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[mcp-server] " + (fmt % args) + "\n")


# Threaded, so one slow client cannot block /healthz and take the Pod out of
# its Service.
SERVER_CLASS = ThreadingHTTPServer

if __name__ == "__main__":
    print("mcp-server listening on :%d, target namespace %s" % (PORT, TARGET_NAMESPACE), flush=True)
    SERVER_CLASS(("0.0.0.0", PORT), MCPHandler).serve_forever()

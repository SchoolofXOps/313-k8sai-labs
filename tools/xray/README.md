# Cluster X-Ray

A live view of **your own cluster**. It is one page that reads the cluster you created in the lab
and draws what it finds. It shows nothing made up: every value comes from your API server, read
with your own kubeconfig.

It is one tool for the whole course. Each module adds a lens, shown as a tab. The Baseline lens
lands with Module 1. The Devices, Capacity, Serving and Data plane tabs are greyed out until their
modules land.

## Run it

Open a second terminal at the root of your lab clone and run:

```bash
export KUBECONFIG=/tmp/grid-core.kubeconfig
bash tools/xray/serve.sh
```

Then open the URL it prints, `http://127.0.0.1:8001/xray/`. Stop it with Ctrl-C.

`KUBECONFIG` defaults to `/tmp/grid-core.kubeconfig` if you do not set it, and the script always
uses context `kind-grid-core`.

## The Baseline lens (Module 1)

It shows the three baseline failures from the Module 1 lab, as they happen. It reads the objects
the lab creates in namespace `m1-baseline`.

- **Pending Pods.** Every Pending Pod in the cluster, with its `PodScheduled=False` reason and
  message, straight from the Pod's condition. It also shows any extended resource the Pod asks
  for, such as the `device-request` Pod's `nvidia.com/gpu: 1`. This is a poll of
  `status.phase=Pending` every 2.5 seconds.
- **Service endpoints.** One card per Pod labelled `app=sim`. It puts the EndpointSlice's
  `ready`, `serving` and `terminating` beside the Pod's phase and the simulator's startup state.
  The startup state is the last `startup-state=` line in the `sim` container's log. That line is
  written by the lab's wrapper script, a timed wait, not a model load. When the endpoint says
  `ready=true` while the startup state still says `loading`, the card turns red. That is symptom
  two: the Service sends traffic to a Pod that is not listening yet.
- **HPA signal.** The HPA's current CPU utilisation, its target and its replicas. Beside them is
  the queue depth, `vllm:num_requests_waiting` for model `m1-sim`. It is read from the simulator's
  `/metrics` through the API server's service proxy. The HPA in this lab never reads that number.
  That gap is symptom three.

If something the lens needs does not exist yet, the panel says so and names the lab step that
creates it. A panel is never blank. For example, before you apply the HPA the panel says there is
no HPA named `sim` and shows the `kubectl apply -f m1/hpa.yaml` line.

## How it works

There is no backend and no token. `kubectl proxy` does two jobs from one port:

1. It serves this folder as static files under `/xray/`.
2. It forwards `/api/...` and `/apis/...` to your API server, signing each request with your
   kubeconfig.

The page and the API share one origin, so the browser can open raw `watch` streams and read Pod
logs and the service proxy directly. Everything you see change is real API traffic.

The page only sends GET requests. It cannot change your cluster.

The proxy listens on `127.0.0.1` only. That matters: it forwards with **your** credentials, so
anything that can reach the port can act as you. `serve.sh` passes no `--address`, on purpose.

The page is fully self-contained. All its CSS and JavaScript are inside `index.html`. It loads no
font, no script and no image from anywhere else. A course check, C11, fails the build if that ever
changes.

### The connection budget

Browsers allow only **6 HTTP/1.1 connections per host**. A long-lived watch holds one open the
whole time. So this lens holds **three** watches: the Pods and the events in `m1-baseline`, and the
EndpointSlices of Service `sim`. It polls everything else, one request at a time. The course caps
the tool at five long-lived streams, so later lenses have room.

Watches use WebSockets where the proxy allows it, because those do not count against the HTTP
pool. If an upgrade fails, the page falls back to a streamed HTTP request.

## Troubleshooting

- **`FAIL: no kubeconfig at /tmp/grid-core.kubeconfig`.** `/tmp` is cleared on reboot. Run
  `bash clusters/grid-core/create.sh` from the clone root. It reuses a running cluster and writes
  the file again.
- **Port busy.** Run `PORT=8002 bash tools/xray/serve.sh`.
- **"The API is unreachable".** `serve.sh` has stopped. Start it again.
- **"Namespace m1-baseline does not exist yet".** Apply `m1/namespace.yaml`, as the lab does. The
  page picks it up on its own; there is no need to reload.
- **The CPU card reads `<unknown>`.** metrics-server is missing or not yet Available. The panel
  shows its condition. Apply `m1/metrics-server.yaml` and wait.
- **Queue depth shows "proxy HTTP 503".** No `sim` Pod is accepting connections on port 8000. If
  the endpoints panel shows `startup-state=loading`, that is the lab's symptom two, live.

## Test it offline

```bash
node --test tools/xray/tests/m1-lens.test.mjs
```

The test starts a fake API server, loads the page in headless Chrome, and checks that each panel
shows its value. It also checks that a missing object shows its named message and that the page
holds no more than five long-lived connections. It needs Google Chrome; set `CHROME` to its path if
it is not in the default macOS location.

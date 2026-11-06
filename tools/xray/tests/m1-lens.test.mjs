// Cluster X-Ray — the M1 Baseline lens, tested offline.
//
// A fake API server behaves like `kubectl proxy`: it serves index.html under /xray/, answers the
// GETs the lens makes with FIXTURE objects (never captured cluster output), holds watch streams
// open the way the real API server does, and accepts watch=1 as a WebSocket upgrade. Headless
// Chrome loads the page over the DevTools protocol, and the assertions read the rendered DOM.
//
// What it proves:
//   1. each of the three panels renders its value from the objects the M1 lab creates;
//   2. a missing object renders a NAMED message that names the lab step, never a blank panel;
//   3. the page holds no more than five long-lived connections, over WebSocket AND over the
//      fetch-stream fallback, where every watch costs a slot of the six-per-host HTTP/1.1 pool;
//   4. the page issues GET requests only, and asks for no path outside the lens's own list.
//
// Run: node --test labs/tools/xray/tests/m1-lens.test.mjs   (published tree: tools/xray/tests/...)
// Env: CHROME=<path to a Chrome binary>   XRAY_PAGE=<alternate index.html, for a RED check>
//
// Live: XRAY_BASE=http://127.0.0.1:8001/xray/ node --test tools/xray/tests/m1-lens.test.mjs
//   With serve.sh running against a grid-core that carries the M1 lab's objects (304's XRAY_BASE
//   convention). The offline suite is skipped and the same three panels are asserted against your
//   real cluster. The endpoints assertion watches for XRAY_WINDOW_S seconds (default 240) and needs
//   the simulator restarted inside that window, from another terminal:
//     kubectl --context kind-grid-core -n m1-baseline rollout restart deployment/sim
//   XRAY_SHOT=<file.png> also writes a 1280x800 screenshot of the richest frame the window showed.
//   The test itself only reads: it opens the page and reads the DOM, as the page only GETs.
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE = fs.readFileSync(process.env.XRAY_PAGE || path.join(HERE, '..', 'index.html'));
const CHROME = process.env.CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const LIVE = process.env.XRAY_BASE || '';
const LIVE_SHOT = process.env.XRAY_SHOT || '';
const LIVE_WINDOW_MS = Number(process.env.XRAY_WINDOW_S || 240) * 1000;

const NS = 'm1-baseline';
const SIM_POD = 'sim-6d9c7b5f4-x2k8q';
const MAX_LONG_LIVED = 5;

/* ---------------------------------------------------------------- fixtures
   Every string below is a test fixture. Messages carry a `fixture:` prefix so nobody mistakes one
   for output captured from a cluster. */
const T0 = new Date(Date.now() - 90_000).toISOString();
const meta = (name, extra = {}) => ({ name, namespace: NS, uid: `uid-${name}`, resourceVersion: '100', creationTimestamp: T0, ...extra });

const devicePod = {
  metadata: meta('device-request'),
  spec: { containers: [{ name: 'device-request', resources: { limits: { 'nvidia.com/gpu': '1' } } }] },
  status: {
    phase: 'Pending',
    conditions: [{
      type: 'PodScheduled', status: 'False', reason: 'Unschedulable',
      message: 'fixture: 0/2 nodes are available: 2 Insufficient nvidia.com/gpu.',
    }],
  },
};
const simPod = {
  metadata: meta(SIM_POD, { labels: { app: 'sim' } }),
  spec: { nodeName: 'grid-core-worker', containers: [{ name: 'sim', resources: { requests: { cpu: '100m', memory: '32Mi' } } }] },
  status: {
    phase: 'Running',
    conditions: [{ type: 'PodScheduled', status: 'True' }, { type: 'Ready', status: 'True' }],
    containerStatuses: [{ name: 'sim', ready: true, restartCount: 0, state: { running: { startedAt: T0 } } }],
  },
};
const clientPod = {
  metadata: meta('client'),
  spec: { nodeName: 'grid-core-worker', containers: [{ name: 'client' }] },
  status: { phase: 'Running', containerStatuses: [{ name: 'client', ready: true, restartCount: 0, state: { running: {} } }] },
};
const slice = {
  metadata: meta('sim-7xq2m', { labels: { 'kubernetes.io/service-name': 'sim' } }),
  addressType: 'IPv4',
  endpoints: [{
    addresses: ['10.244.1.7'],
    conditions: { ready: true, serving: true, terminating: false },
    targetRef: { kind: 'Pod', name: SIM_POD, namespace: NS },
  }],
};
const event = {
  metadata: meta('device-request.fixture'), type: 'Warning', reason: 'FailedScheduling',
  involvedObject: { kind: 'Pod', name: 'device-request' }, lastTimestamp: T0,
  message: 'fixture: 0/2 nodes are available: 2 Insufficient nvidia.com/gpu.',
};
const LOG_LOADING = [
  'startup-state=loading (instrumentation: a timed wait of 60s, not a model load)',
  'startup-state=loading elapsed=5s of 60s',
  'startup-state=loading elapsed=10s of 60s',
  '',
].join('\n');
const hpa = (withCurrent) => ({
  apiVersion: 'autoscaling/v2', kind: 'HorizontalPodAutoscaler', metadata: meta('sim'),
  spec: {
    scaleTargetRef: { apiVersion: 'apps/v1', kind: 'Deployment', name: 'sim' },
    minReplicas: 1, maxReplicas: 4,
    metrics: [{ type: 'Resource', resource: { name: 'cpu', target: { type: 'Utilization', averageUtilization: 50 } } }],
  },
  status: withCurrent
    ? {
      currentReplicas: 1, desiredReplicas: 1,
      currentMetrics: [{ type: 'Resource', resource: { name: 'cpu', current: { averageUtilization: 30, averageValue: '30m' } } }],
      conditions: [{ type: 'ScalingActive', status: 'True', reason: 'ValidMetricFound' }],
    }
    : {
      currentReplicas: 1, desiredReplicas: 1,
      conditions: [{
        type: 'ScalingActive', status: 'False', reason: 'FailedGetResourceMetric',
        message: 'fixture: unable to get metrics for resource cpu',
      }],
    },
});
const apiservice = (available) => ({
  metadata: { name: 'v1beta1.metrics.k8s.io' },
  status: { conditions: [available
    ? { type: 'Available', status: 'True', reason: 'Passed' }
    : { type: 'Available', status: 'False', reason: 'MissingEndpoints', message: 'fixture: endpoints for service/metrics-server in "kube-system" have no addresses' }] },
});
const METRICS = [
  '# HELP vllm:num_requests_waiting Number of requests waiting to be processed.',
  '# TYPE vllm:num_requests_waiting gauge',
  'vllm:num_requests_waiting{model_name="m1-sim"} 16',
  'vllm:num_requests_running{model_name="m1-sim"} 4',
  '',
].join('\n');

/* Three scenarios. `full` is the lab after all three symptoms exist. `bare` is the namespace with
   nothing in it yet. `starting` is everything applied while the simulator's port is still shut and
   metrics-server is not yet Available. */
const SCENARIOS = {
  full: {
    ns: true, pending: [devicePod], pods: [devicePod, simPod, clientPod], slices: [slice], events: [event],
    log: { code: 200, body: LOG_LOADING }, hpa: { code: 200, body: hpa(true) },
    apiservice: { code: 200, body: apiservice(true) }, queue: { code: 200, body: METRICS },
  },
  bare: {
    ns: true, pending: [], pods: [], slices: [], events: [],
    log: { code: 404, body: '' }, hpa: { code: 404, body: notFound('horizontalpodautoscalers', 'sim') },
    apiservice: { code: 404, body: notFound('apiservices', 'v1beta1.metrics.k8s.io') },
    queue: { code: 404, body: notFound('services', 'sim') },
  },
  starting: {
    ns: true, pending: [], pods: [simPod, clientPod], slices: [slice], events: [],
    log: { code: 200, body: LOG_LOADING }, hpa: { code: 200, body: hpa(false) },
    apiservice: { code: 200, body: apiservice(false) },
    queue: { code: 503, body: 'fixture: error trying to reach service: dial tcp 10.244.1.7:8000: connect: connection refused' },
  },
  nonamespace: {
    ns: false, pending: [], pods: [], slices: [], events: [],
    log: { code: 404, body: '' }, hpa: { code: 404, body: notFound('horizontalpodautoscalers', 'sim') },
    apiservice: { code: 404, body: notFound('apiservices', 'v1beta1.metrics.k8s.io') },
    queue: { code: 404, body: notFound('namespaces', NS) },
  },
};
function notFound(kind, name) {
  return { kind: 'Status', apiVersion: 'v1', status: 'Failure', reason: 'NotFound', code: 404, message: `fixture: ${kind} "${name}" not found` };
}

/* ---------------------------------------------------------------- fake API server */
let scenario = SCENARIOS.full;
let allowWs = true;            // false = a proxy that refuses upgrades
const stats = { live: 0, maxLive: 0, ws: 0, httpStreams: 0, nonGet: [], unknown: new Set(), logQueries: [], sliceQueries: [] };
const sockets = new Set();
const KNOWN = new Set([
  '/xray/', '/xray/index.html', '/version', '/favicon.ico',
  `/api/v1/namespaces/${NS}`, '/api/v1/pods',
  `/api/v1/namespaces/${NS}/pods`, `/apis/discovery.k8s.io/v1/namespaces/${NS}/endpointslices`,
  `/api/v1/namespaces/${NS}/events`, `/apis/autoscaling/v2/namespaces/${NS}/horizontalpodautoscalers/sim`,
  '/apis/apiregistration.k8s.io/v1/apiservices/v1beta1.metrics.k8s.io',
  `/api/v1/namespaces/${NS}/services/sim:8000/proxy/metrics`,
]);
const LOG_PATH = new RegExp(`^/api/v1/namespaces/${NS}/pods/([^/]+)/log$`);

function liveUp() { stats.live++; stats.maxLive = Math.max(stats.maxLive, stats.live); }
function liveDown() { stats.live--; }
function json(res, code, body) { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); }
function list(items) { return { metadata: { resourceVersion: '100' }, items }; }
function isStream(u) { return u.searchParams.get('watch') === '1' || u.searchParams.get('watch') === 'true'; }
function bookmark() { return JSON.stringify({ type: 'BOOKMARK', object: { metadata: { resourceVersion: '100' } } }); }

function wsFrame(text) {
  const payload = Buffer.from(text);
  const len = payload.length;
  let head;
  if (len < 126) head = Buffer.from([0x81, len]);
  else if (len < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(len, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([head, payload]);
}

function listFor(p) {
  if (p === `/api/v1/namespaces/${NS}/pods`) return scenario.pods;
  if (p === `/apis/discovery.k8s.io/v1/namespaces/${NS}/endpointslices`) return scenario.slices;
  if (p === `/api/v1/namespaces/${NS}/events`) return scenario.events;
  return null;
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;
  if (req.method !== 'GET') {
    stats.nonGet.push(`${req.method} ${p}`);
    return json(res, 405, { kind: 'Status', code: 405, message: 'fixture: the X-Ray lens must only GET' });
  }
  const logMatch = p.match(LOG_PATH);
  if (!KNOWN.has(p) && !logMatch) stats.unknown.add(p);

  if (p === '/xray/' || p === '/xray/index.html') {
    res.writeHead(200, { 'content-type': 'text/html' }); return res.end(PAGE);
  }
  if (p === '/version') return json(res, 200, { gitVersion: 'v1.37.0', platform: 'linux/arm64' });
  if (p === `/api/v1/namespaces/${NS}`) {
    return scenario.ns ? json(res, 200, { kind: 'Namespace', metadata: { name: NS } }) : json(res, 404, notFound('namespaces', NS));
  }
  if (p === '/api/v1/pods') {
    if (u.searchParams.get('fieldSelector') !== 'status.phase=Pending') return json(res, 400, { message: 'fixture: expected the Pending field selector' });
    return json(res, 200, list(scenario.pending));
  }
  const items = listFor(p);
  if (items) {
    if (p.endsWith('/endpointslices')) stats.sliceQueries.push(u.searchParams.get('labelSelector'));
    if (isStream(u)) {
      // An HTTP/1.1 chunked stream that never ends: exactly what pins a slot.
      stats.httpStreams++; liveUp();
      res.writeHead(200, { 'content-type': 'application/json', 'transfer-encoding': 'chunked' });
      res.write(bookmark() + '\n');
      const t = setInterval(() => res.write(bookmark() + '\n'), 1000);
      req.on('close', () => { clearInterval(t); liveDown(); });
      return;
    }
    return json(res, 200, list(items));
  }
  if (logMatch) {
    stats.logQueries.push(u.search);
    res.writeHead(scenario.log.code, { 'content-type': 'text/plain' }); return res.end(scenario.log.body);
  }
  if (p === `/apis/autoscaling/v2/namespaces/${NS}/horizontalpodautoscalers/sim`) return json(res, scenario.hpa.code, scenario.hpa.body);
  if (p === '/apis/apiregistration.k8s.io/v1/apiservices/v1beta1.metrics.k8s.io') return json(res, scenario.apiservice.code, scenario.apiservice.body);
  if (p === `/api/v1/namespaces/${NS}/services/sim:8000/proxy/metrics`) {
    const q = scenario.queue;
    if (typeof q.body === 'string') { res.writeHead(q.code, { 'content-type': 'text/plain' }); return res.end(q.body); }
    return json(res, q.code, q.body);
  }
  return json(res, 404, notFound('path', p));
});

server.on('upgrade', (req, socket) => {
  // Minimal RFC 6455 server: handshake, then push text frames.
  const u = new URL(req.url, 'http://x');
  if (!allowWs || !isStream(u) || !listFor(u.pathname)) { socket.destroy(); return; }
  if (u.pathname.endsWith('/endpointslices')) stats.sliceQueries.push(u.searchParams.get('labelSelector'));
  stats.ws++; liveUp();
  const accept = crypto.createHash('sha1')
    .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const send = () => socket.write(wsFrame(bookmark() + '\n'));
  send();
  const t = setInterval(send, 1000);
  let down = false;
  const close = () => { clearInterval(t); if (!down) { down = true; liveDown(); } };
  socket.on('close', close);
  socket.on('error', close);
  socket.on('data', () => {});
});
server.on('connection', (s) => { sockets.add(s); s.on('close', () => sockets.delete(s)); });

/* ---------------------------------------------------------------- Chrome via CDP */
let chrome, profile, debugPort, base;

async function openTab(url) {
  const r = await fetch(`http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
  return r.json();
}
async function closeTab(t) {
  await fetch(`http://127.0.0.1:${debugPort}/json/close/${t.id}`);
}
async function evaluate(target, expression) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  const reply = new Promise((ok) => {
    ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id === 1) ok(d); };
  });
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
  const d = await reply;
  ws.close();
  if (d.result.exceptionDetails) throw new Error(`page threw: ${JSON.stringify(d.result.exceptionDetails)}`);
  return d.result.result.value;
}
/* Poll the page until `predicate(state)` holds, then return the state; fail with the last state. */
async function waitFor(target, predicate, what, timeoutMs = 12000) {
  const t0 = Date.now();
  let s;
  while (Date.now() - t0 < timeoutMs) {
    try { s = await evaluate(target, PROBE); } catch { s = undefined; }
    if (s && predicate(s)) return s;
    await sleep(250);
  }
  assert.fail(`timed out waiting for ${what}; last page state:\n${JSON.stringify(s, null, 2)}`);
}
/* Wait for the server to see no live stream from closed tabs before a budget measurement. */
async function settle() {
  for (let i = 0; i < 40 && stats.live > 0; i++) await sleep(100);
  stats.maxLive = stats.live;
}

const PROBE = `(() => {
  const t = (id) => { const el = document.getElementById(id); return el ? el.innerText.replace(/\\s+/g, ' ').trim() : null; };
  const cls = (sel) => { const el = document.querySelector(sel); return el ? el.className : null; };
  return {
    hook: typeof window.__xray === 'object',
    watch: t('watchTxt'),
    watchKeys: window.__xray ? window.__xray.WATCH_KEYS : null,
    pend: t('pendBody'),
    ep: t('epBody'),
    epCard: cls('#epBody .ep'),
    hpaMsgs: t('hpaMsgs'),
    cpu: t('kCpu'), tgt: t('kTgt'), rep: t('kRep'), q: t('kQ'), qs: t('kQS'),
    samples: document.querySelectorAll('#sampleRows tr').length,
    events: t('evList'),
    stubTabs: Array.from(document.querySelectorAll('#tabs .tab.stub')).map((e) => e.textContent.replace(/\\s+/g, ' ').trim()),
    activeTabs: Array.from(document.querySelectorAll('#tabs .tab.active')).map((e) => e.textContent.replace(/\\s+/g, ' ').trim()),
  };
})()`;

const PLACEHOLDER = /^Reading /;
function assertNoBlankPanel(s, label) {
  for (const k of ['pend', 'ep']) {
    assert.ok(s[k] && s[k].length > 0, `${label}: panel ${k} is blank`);
    assert.doesNotMatch(s[k], PLACEHOLDER, `${label}: panel ${k} never left its loading placeholder`);
  }
  // The HPA panel always carries its KPI cards; what must never stay blank is its message area OR
  // a real value in every KPI.
  const allValues = [s.cpu, s.tgt, s.rep, s.q].every((v) => v && v !== '—');
  assert.ok(allValues || (s.hpaMsgs && s.hpaMsgs.length > 0), `${label}: HPA panel shows neither values nor a message`);
  assert.doesNotMatch(s.hpaMsgs || '', PLACEHOLDER, `${label}: HPA panel never left its loading placeholder`);
}

describe('Cluster X-Ray M1 Baseline lens, offline against a fake API server', { skip: !!LIVE }, () => {
  before(async () => {
    assert.ok(fs.existsSync(CHROME), `headless Chrome not found at ${CHROME}; set CHROME`);
    await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
    base = `http://127.0.0.1:${server.address().port}/xray/`;
    profile = fs.mkdtempSync(path.join(os.tmpdir(), 'xray-chrome-'));
    debugPort = 9300 + Math.floor(Math.random() * 500);
    chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-first-run',
      `--user-data-dir=${profile}`, `--remote-debugging-port=${debugPort}`, 'about:blank'],
    { stdio: 'ignore' });
    for (let i = 0; i < 50; i++) {
      try { await fetch(`http://127.0.0.1:${debugPort}/json/version`); break; } catch { await sleep(200); }
    }
  });

  after(async () => {
    if (chrome) { const gone = new Promise((ok) => chrome.once('exit', ok)); chrome.kill('SIGKILL'); await gone; }
    for (const s of sockets) s.destroy();
    await new Promise((ok) => server.close(ok));
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  });

  it('renders all three panels from the M1 lab objects, within the connection budget', async () => {
    scenario = SCENARIOS.full; allowWs = true;
    await settle();
    const tab = await openTab(base);
    try {
      const s = await waitFor(tab, (x) => x.hook && x.watch === 'watch: connected' && x.q === '16' &&
        /startup-state=loading/.test(x.ep || '') && /device-request/.test(x.pend || ''), 'the full scenario to render');

      // Panel 1 — the Pending Pod, its PodScheduled condition, and what it asked for.
      assert.match(s.pend, /device-request/);
      assert.match(s.pend, /PodScheduled=False/);
      assert.match(s.pend, /reason Unschedulable/);
      assert.match(s.pend, /fixture: 0\/2 nodes are available: 2 Insufficient nvidia\.com\/gpu\./);
      assert.match(s.pend, /nvidia\.com\/gpu: 1 \(limits, container device-request\)/);

      // Panel 2 — the sim Pod: endpoint ready/serving beside phase and the labelled startup state.
      assert.match(s.ep, new RegExp(SIM_POD));
      assert.match(s.ep, /phase Running/);
      assert.match(s.ep, /endpoint ready true/i);
      assert.match(s.ep, /serving true/i);
      assert.match(s.ep, /terminating false/i);
      assert.match(s.ep, /startup-state=loading elapsed=10s of 60s/, 'the LAST startup-state line is the current state');
      assert.match(s.ep, /Routed but not listening/);
      assert.match(s.epCard, /\bmismatch\b/, 'a ready endpoint over a loading server is flagged');
      assert.doesNotMatch(s.ep, /client/, 'only Pods labelled app=sim belong in the endpoints panel');

      // Panel 3 — CPU, target and replicas beside the queue depth.
      assert.equal(s.cpu, '30%');
      assert.equal(s.tgt, '50%');
      assert.equal(s.rep, '1 / 1');
      assert.equal(s.q, '16');
      assert.match(s.qs, /running 4/);
      assert.ok(s.samples >= 1, 'the sample table records at least one tick');

      // The event strip and the tabs.
      assert.match(s.events, /FailedScheduling/);
      assert.deepEqual(s.activeTabs, ['Baseline M1']);
      assert.deepEqual(s.stubTabs, ['Devices M4', 'Capacity M5', 'Serving M8', 'Data plane M9']);

      // The budget, measured at the server and declared by the page.
      assert.ok(s.watchKeys.length <= MAX_LONG_LIVED, `the page declares ${s.watchKeys.length} watches`);
      await sleep(3000);
      assert.ok(stats.maxLive <= MAX_LONG_LIVED, `held ${stats.maxLive} long-lived connections, cap ${MAX_LONG_LIVED}`);
      assert.ok(stats.maxLive >= 1, 'no long-lived connection was ever opened, so the budget measured nothing');

      // The read paths the brief fixes.
      assert.ok(stats.sliceQueries.length > 0 && stats.sliceQueries.every((q) => q === 'kubernetes.io/service-name=sim'),
        `EndpointSlices are selected by Service name: ${JSON.stringify(stats.sliceQueries)}`);
      assert.ok(stats.logQueries.some((q) => /container=sim/.test(q) && /limitBytes=/.test(q)),
        `the startup state is read from the sim container's log head: ${JSON.stringify(stats.logQueries)}`);
      console.log('full scenario:', JSON.stringify({ maxLive: stats.maxLive, ws: stats.ws, httpStreams: stats.httpStreams }));
    } finally { await closeTab(tab); }
  });

  it('names the missing object and its lab step in every panel when the namespace is empty', async () => {
    scenario = SCENARIOS.bare; allowWs = true;
    const tab = await openTab(base);
    try {
      const s = await waitFor(tab, (x) => x.hook && /m1\/device-request\.yaml/.test(x.pend || '') &&
        /m1\/simulator\.yaml/.test(x.ep || '') && /m1\/hpa\.yaml/.test(x.hpaMsgs || ''), 'the bare scenario messages');
      assertNoBlankPanel(s, 'bare');
      assert.match(s.pend, /No Pending Pods in the cluster/);
      assert.match(s.pend, /Symptom one: a device request no node can satisfy/);
      assert.match(s.ep, /No Pod labelled app=sim and no endpoint for Service sim yet/);
      assert.match(s.ep, /Symptom two: a slow-starting server behind a Service with no readiness gate/);
      assert.match(s.hpaMsgs, /No HPA named sim in m1-baseline yet/);
      assert.match(s.hpaMsgs, /metrics-server is not installed/);
      assert.match(s.hpaMsgs, /m1\/metrics-server\.yaml/);
      assert.match(s.hpaMsgs, /Service sim does not exist yet/);
    } finally { await closeTab(tab); }
  });

  it('names the namespace step when m1-baseline does not exist', async () => {
    scenario = SCENARIOS.nonamespace; allowWs = true;
    const tab = await openTab(base);
    try {
      const s = await waitFor(tab, (x) => x.hook && /m1\/namespace\.yaml/.test(x.ep || '') &&
        /m1\/namespace\.yaml/.test(x.hpaMsgs || ''), 'the namespace-missing messages');
      assertNoBlankPanel(s, 'nonamespace');
      assert.match(s.ep, /Namespace m1-baseline does not exist yet/);
      assert.match(s.hpaMsgs, /Namespace m1-baseline does not exist yet/);
      assert.match(s.pend, /m1\/device-request\.yaml/, 'the cluster-wide Pending poll still answers');
    } finally { await closeTab(tab); }
  });

  it('degrades to named messages while the server port is shut and metrics-server is not Available', async () => {
    scenario = SCENARIOS.starting; allowWs = true;
    const tab = await openTab(base);
    try {
      const s = await waitFor(tab, (x) => x.hook && /proxy HTTP 503/.test(x.qs || '') && x.cpu === '<unknown>' &&
        /startup-state=loading/.test(x.ep || ''), 'the starting scenario messages');
      assertNoBlankPanel(s, 'starting');
      assert.match(s.hpaMsgs, /Queue depth unreadable: the service proxy answered HTTP 503/);
      assert.match(s.hpaMsgs, /metrics-server is installed but not Available/);
      assert.match(s.hpaMsgs, /MissingEndpoints/);
      assert.match(s.hpaMsgs, /The HPA has no CPU reading/);
      assert.match(s.hpaMsgs, /FailedGetResourceMetric/);
      assert.equal(s.tgt, '50%', 'the target still reads from spec while the current value is unknown');
      assert.match(s.ep, /Routed but not listening/);
    } finally { await closeTab(tab); }
  });

  it('stays within the budget on the fetch-stream fallback, where every watch costs a pool slot', async () => {
    scenario = SCENARIOS.full; allowWs = false;
    await settle();
    const before = stats.httpStreams;
    const tab = await openTab(base);
    try {
      const s = await waitFor(tab, (x) => x.hook && x.watch === 'watch: connected' && x.q === '16', 'the fallback to connect');
      await sleep(4000);
      const after = await evaluate(tab, PROBE);
      assert.equal(after.watch, 'watch: connected');
      assert.equal(after.cpu, '30%', 'polls still complete while the streams hold their slots');
      assert.ok(stats.httpStreams - before >= s.watchKeys.length, 'the watches fell back to HTTP streams');
      assert.ok(stats.maxLive <= MAX_LONG_LIVED, `held ${stats.maxLive} long-lived connections, cap ${MAX_LONG_LIVED}`);
      console.log('fallback:', JSON.stringify({ maxLive: stats.maxLive, httpStreams: stats.httpStreams - before }));
    } finally { await closeTab(tab); allowWs = true; }
  });

  it('the live probe reads every endpoint cell by its label, so live mode sees the values the page shows', async () => {
    // Live mode reads the endpoint cells through LIVE_PROBE. Its first live run read every cell as
    // undefined: innerText applies the labels' CSS text-transform, so a key built from innerText
    // was 'ENDPOINT READY', never 'endpoint ready'. This pins the probe to the fixture's values.
    scenario = SCENARIOS.full; allowWs = true;
    const tab = await openTab(base);
    try {
      await waitFor(tab, (x) => x.hook && /startup-state=loading/.test(x.ep || '') && /endpoint ready/i.test(x.ep || ''), 'the full scenario endpoints');
      const s = await evaluate(tab, LIVE_PROBE);
      assert.equal(s.cards.length, 1);
      const c = s.cards[0];
      assert.equal(c.pod, SIM_POD);
      assert.deepEqual(c.cells, { 'container ready': 'true', 'endpoint ready': 'true', serving: 'true', terminating: 'false' });
      assert.equal(c.mismatch, true);
      assert.match(c.startup, /startup-state=loading elapsed=10s of 60s/);
    } finally { await closeTab(tab); }
  });

  it('only ever GETs, and only the paths the lens declares', () => {
    assert.deepEqual(stats.nonGet, [], 'the lens must never write to the cluster');
    assert.deepEqual([...stats.unknown], [], `requests outside the lens's declared paths: ${[...stats.unknown].join(', ')}`);
  });
});

/* ---------------------------------------------------------------- LIVE mode (XRAY_BASE)
   The same three panels, read from a real grid-core through serve.sh. Nothing here is a fixture:
   every value the assertions print was read from the rendered page, which read it from the API
   server. One CDP session is held for the whole tab so the 1280x800 viewport override sticks. */
class Session {
  constructor(target) { this.target = target; this.id = 0; this.waiting = new Map(); }
  async open() {
    this.ws = new WebSocket(this.target.webSocketDebuggerUrl);
    await new Promise((ok, bad) => { this.ws.onopen = ok; this.ws.onerror = bad; });
    this.ws.onmessage = (m) => {
      const d = JSON.parse(m.data);
      const w = this.waiting.get(d.id);
      if (w) { this.waiting.delete(d.id); w(d); }
    };
  }
  send(method, params = {}) {
    const id = ++this.id;
    const reply = new Promise((ok) => this.waiting.set(id, ok));
    this.ws.send(JSON.stringify({ id, method, params }));
    return reply.then((d) => {
      if (d.error) throw new Error(`${method}: ${JSON.stringify(d.error)}`);
      return d.result;
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`page threw: ${JSON.stringify(r.exceptionDetails)}`);
    return r.result.value;
  }
  close() { try { this.ws.close(); } catch { /* already closed */ } }
}

const LIVE_PROBE = `(() => {
  const t = (el) => el ? el.innerText.replace(/\\s+/g, ' ').trim() : null;
  // Cell labels and values by textContent: innerText applies CSS text-transform (the labels are
  // uppercase on screen), and the keys must match the source text.
  const raw = (el) => el ? el.textContent.replace(/\\s+/g, ' ').trim() : null;
  const cards = Array.from(document.querySelectorAll('#epBody .ep')).map((el) => {
    const cells = {};
    el.querySelectorAll('.cell').forEach((c) => { cells[raw(c.querySelector('.cl'))] = raw(c.querySelector('.cv')); });
    const ss = el.querySelector('.ss');
    return {
      pod: t(el.querySelector('.eh b')), phase: t(el.querySelector('.phase')), cells,
      startup: t(ss), startupCls: ss ? ss.className.replace(/^ss\\s*/, '') : null,
      verdict: t(el.querySelector('.verdict')),
      mismatch: /\\bmismatch\\b/.test(el.className), healthy: /\\bhealthy\\b/.test(el.className),
    };
  });
  return {
    hook: typeof window.__xray === 'object',
    watch: t(document.getElementById('watchTxt')),
    pend: t(document.getElementById('pendBody')),
    ep: t(document.getElementById('epBody')),
    cards,
    hpaMsgs: t(document.getElementById('hpaMsgs')),
    cpu: t(document.getElementById('kCpu')), cpuS: t(document.getElementById('kCpuS')),
    tgt: t(document.getElementById('kTgt')), rep: t(document.getElementById('kRep')),
    q: t(document.getElementById('kQ')), qs: t(document.getElementById('kQS')),
  };
})()`;

async function liveWait(session, predicate, what, timeoutMs) {
  const t0 = Date.now();
  let s;
  while (Date.now() - t0 < timeoutMs) {
    try { s = await session.eval(LIVE_PROBE); } catch { s = undefined; }
    if (s && predicate(s)) return s;
    await sleep(500);
  }
  assert.fail(`LIVE: timed out waiting for ${what}; last page state:\n${JSON.stringify(s, null, 2)}`);
}
const stamp = () => new Date().toISOString().slice(11, 19) + 'Z';

describe('Cluster X-Ray M1 Baseline lens, LIVE against XRAY_BASE', { skip: !LIVE }, () => {
  let session, tab;
  before(async () => {
    assert.ok(fs.existsSync(CHROME), `headless Chrome not found at ${CHROME}; set CHROME`);
    profile = fs.mkdtempSync(path.join(os.tmpdir(), 'xray-chrome-'));
    debugPort = 9300 + Math.floor(Math.random() * 500);
    chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars',
      '--window-size=1280,800', `--user-data-dir=${profile}`, `--remote-debugging-port=${debugPort}`, 'about:blank'],
    { stdio: 'ignore' });
    for (let i = 0; i < 50; i++) {
      try { await fetch(`http://127.0.0.1:${debugPort}/json/version`); break; } catch { await sleep(200); }
    }
    tab = await openTab(LIVE);
    session = new Session(tab);
    await session.open();
    await session.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
    console.log(`LIVE ${stamp()} page ${LIVE}`);
  });

  after(async () => {
    if (session) session.close();
    if (tab) await closeTab(tab).catch(() => {});
    if (chrome) { const gone = new Promise((ok) => chrome.once('exit', ok)); chrome.kill('SIGKILL'); await gone; }
    if (profile) fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  });

  it('panel 1: the Pending device request shows PodScheduled=False, its reason and its message', async () => {
    const s = await liveWait(session, (x) => x.hook && /device-request/.test(x.pend || '') && /PodScheduled=False/.test(x.pend || ''),
      'the Pending panel to show device-request', 30000);
    assert.match(s.pend, /device-request/);
    assert.match(s.pend, /PodScheduled=False/);
    assert.match(s.pend, /reason Unschedulable/);
    assert.match(s.pend, /Insufficient nvidia\.com\/gpu/, 'the scheduler message names the missing resource');
    assert.match(s.pend, /nvidia\.com\/gpu: 1 \(limits, container app\)/);
    console.log(`LIVE ${stamp()} panel 1 read: ${s.pend}`);
  });

  it('panel 3: the HPA shows current CPU, target and replicas beside a queue-depth value', async () => {
    const s = await liveWait(session, (x) => /^\d+%$/.test(x.cpu || '') && x.tgt === '50%' &&
      /^\d+ \/ \d+$/.test(x.rep || '') && /^\d+$/.test(x.q || ''), 'the HPA panel to show four live values', 60000);
    assert.match(s.cpu, /^\d+%$/);
    assert.equal(s.tgt, '50%');
    assert.match(s.rep, /^\d+ \/ \d+$/);
    assert.match(s.q, /^\d+$/);
    assert.match(s.qs, /vllm:num_requests_waiting/);
    console.log(`LIVE ${stamp()} panel 3 read: cpu=${s.cpu} (${s.cpuS}) target=${s.tgt} replicas=${s.rep} queue=${s.q} (${s.qs})`);
  });

  it('panel 2: across a rollout restart an endpoint flips ready while the startup state still reads loading', async () => {
    console.log(`LIVE ${stamp()} panel 2 window open for ${LIVE_WINDOW_MS / 1000}s: restart deployment/sim now`);
    const last = new Map();        // pod -> last state key
    const transitions = [];        // every distinct per-pod state, in order
    const mismatchPods = new Set();
    const healthyAfterMismatch = new Set();
    const readyChanges = [];
    let best = { score: -1 }, queueSeen = [];
    const t0 = Date.now();
    let firstProbe = true;
    while (Date.now() - t0 < LIVE_WINDOW_MS) {
      let s;
      try { s = await session.eval(LIVE_PROBE); } catch { await sleep(500); continue; }
      if (firstProbe && !s.cards.length) { await sleep(500); continue; }
      for (const c of s.cards) {
        const key = [c.phase, `endpoint ready ${c.cells['endpoint ready']}`, `serving ${c.cells.serving}`,
          `terminating ${c.cells.terminating}`, c.startup, c.mismatch ? 'MISMATCH' : c.healthy ? 'HEALTHY' : '-'].join(' | ');
        if (last.get(c.pod) !== key) {
          // A Pod already on the page when the window opened is a baseline, not a change. A Pod
          // that appears later, or a card whose endpoint-ready cell changes, is a change.
          const prev = last.get(c.pod);
          const nowReady = `endpoint ready ${c.cells['endpoint ready']}`;
          if (prev && prev.split(' | ')[1] !== nowReady) readyChanges.push(`${stamp()} ${c.pod}: ${prev.split(' | ')[1]} -> ${nowReady}`);
          else if (!prev && !firstProbe) readyChanges.push(`${stamp()} ${c.pod}: appeared with ${nowReady}`);
          last.set(c.pod, key);
          transitions.push(`${stamp()} ${c.pod} | ${key}`);
          console.log(`LIVE ${stamp()} ${c.pod} | ${key}`);
        }
        if (c.mismatch) mismatchPods.add(c.pod);
        if (c.healthy && mismatchPods.has(c.pod)) healthyAfterMismatch.add(c.pod);
      }
      if (/^\d+$/.test(s.q || '') && queueSeen[queueSeen.length - 1] !== s.q) queueSeen.push(s.q);
      const score = (/device-request/.test(s.pend || '') ? 1 : 0) + (s.cards.some((c) => c.mismatch) ? 2 : 0) +
        (/^\d+%$/.test(s.cpu || '') ? 1 : 0) + (/^\d+$/.test(s.q || '') ? 1 : 0) + (Number(s.q) > 0 ? 1 : 0);
      if (LIVE_SHOT && score > best.score) {
        const shot = await session.send('Page.captureScreenshot', { format: 'png' });
        fs.writeFileSync(LIVE_SHOT, Buffer.from(shot.data, 'base64'));
        best = { score, at: stamp(), cpu: s.cpu, rep: s.rep, q: s.q, qs: s.qs, cards: s.cards.map((c) => `${c.pod}: ${c.startup} ${c.mismatch ? 'MISMATCH' : c.healthy ? 'HEALTHY' : ''}`) };
        console.log(`LIVE ${stamp()} screenshot (score ${score}/6) -> ${LIVE_SHOT}`);
      }
      firstProbe = false;
      const inCardChange = readyChanges.some((r) => / -> /.test(r));
      if (healthyAfterMismatch.size && inCardChange && (!LIVE_SHOT || best.score >= 6)) break;
      await sleep(500);
    }
    console.log(`LIVE ready changes: ${JSON.stringify(readyChanges)}`);
    console.log(`LIVE queue-depth values seen: ${JSON.stringify(queueSeen)}`);
    if (LIVE_SHOT) console.log(`LIVE screenshot frame: ${JSON.stringify(best)}`);
    assert.ok(transitions.length > 0, 'the endpoints panel showed no sim Pod at all');
    assert.ok(readyChanges.some((r) => / -> /.test(r)), `no Pod's endpoint ready value changed on its card in the window:\n${transitions.join('\n')}`);
    assert.ok(mismatchPods.size > 0, `no Pod read endpoint ready=true while its startup state was loading:\n${transitions.join('\n')}`);
    assert.ok(healthyAfterMismatch.size > 0, `no flagged Pod reached startup-state=serving in the window:\n${transitions.join('\n')}`);
  });
});

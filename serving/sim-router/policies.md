# sim-router — the three routing policies

Three `EndpointPickerConfig` documents, three keys in one ConfigMap
(`router.yaml`), one live at a time via the EPP's `POLICY` env var. Switching
policy restarts only the router, never the simulator fleet, so the three are
compared against the same endpoints.

**Truth Contract: SIMULATED.** Every latency and cache figure these policies
produce comes from `llm-d-inference-sim`, not from a model server. Nothing here
measures real inference.

---

## Policy 1 — round-robin / random (the CONTROL)

| | |
|---|---|
| Scorer | **none** |
| Picker | `random-picker` |
| Distinguishing observable | Endpoint choice is independent of **both** cache residency and load |

`random-picker` "selects endpoint(s) uniformly at random, ignoring any scores
calculated by scorer plugins". With no scorers configured there is nothing to
ignore, so the pick is uniform over the ready endpoints.

A note on the name, because it matters for what may be claimed on a slide:
`llm-d-router` v0.11.0 ships **uniform random**, not strict round-robin. For a
control the distinction is irrelevant — both are independent of the state under
test — but the course must say *random*, not *round-robin*, when describing what
actually ran.

## Policy 2 — load-aware

| | |
|---|---|
| Scorer | `load-aware-scorer` |
| Picker | `max-score-picker` |
| Feeds | `metrics-data-source` -> `core-metrics-extractor` (the data layer) |
| Distinguishing observable | Endpoint choice tracks **waiting-queue depth**; blind to which pod holds the prefix |

`load-aware-scorer` reads each endpoint's live `WaitingQueueSize` and scores it
in `[0, 0.5]`: an empty queue scores `0.5`, a queue at or beyond the threshold
scores `0.0`, linear in between. The metric reaches it through the data layer —
`metrics-data-source` scrapes each simulator's `/metrics`, `core-metrics-extractor`
maps the vLLM metric names onto endpoint state. This works without a real vLLM
only because the simulator exposes the vLLM-compatible metric subset.

## Policy 3 — prefix-cache-aware (the one SPIKE-03 exists for)

| | |
|---|---|
| Scorer | `prefix-cache-scorer`, weight 10 |
| Producers | `token-producer` (vLLM render backend) -> `precise-prefix-cache-producer` |
| Picker | `max-score-picker` |
| Distinguishing observable | Endpoint choice tracks **ZMQ-reported cache residency** for this request's prefix, and **follows that residency when it moves** |

Pipeline, in dependency order:

1. `token-producer` tokenizes the prompt through the shared vLLM render service
   and publishes `TokenizedPrompt`.
2. `precise-prefix-cache-producer` binds the ZMQ SUB socket, ingests
   `BlockStored` / `BlockRemoved`, **recomputes block keys from each event's
   `token_ids`**, and maintains a per-endpoint block index.
3. `prefix-cache-scorer` scores each endpoint `matchBlocks / totalBlocks`.
4. `max-score-picker` takes the highest.

Two configuration facts that are silent failures rather than errors if missed:

- **`prefixMatchInfoProducerName` is mandatory.** Omit it and the scorer falls
  back to an auto-spawned *approximate* producer that never reads the ZMQ stream.
  The lab then looks fine and tests nothing.
- **Both sides must share one tokenizer.** The router recomputes block keys from
  the event's token ids, so correlation needs the router's token ids for a prompt
  to equal the simulator's. The simulator's fast regex/FNV tokenizer and the
  router's `estimate` byte-packing backend are different algorithms; pairing them
  yields an index that ingests every event and matches nothing. Both therefore
  point at `vllm-render`. See `render.yaml`.

---

## The request set, and what it can and cannot show

`setup.sh replay <policy>` sends an identical set under each policy: **6
recurring prefixes (A-F) x 4, replayed twice = 48 requests**, each prompt 60
words rendering to **369 real Qwen tokens = ~23 blocks** of 16, against a
**64-block per-pod cache**.

**Measured result: this request set does not separate the three policies.** Mean
per-prefix concentration came out 65% for prefix-cache against 67% for the random
control (`planning/lab-tests/raw/spike-03/17-policy-distribution.log`), and an
earlier 4-prefix/120-word version gave 50% against 54%
(`15-policy-distribution-thrashing-set.log`). A seeded variant
(`setup.sh seeded`) was also inseparable from chance at n=6
(`19-seeded-summary.log`).

That null result is mechanical, not a defect, and it is the most transferable
thing this lab learned:

- **Residency saturates.** `prefix-cache-scorer` scores `matchBlocks/totalBlocks`.
  Once every pod holds the prefix, every pod scores 1.0, the scores tie, and the
  picker tie-breaks arbitrarily — making the policy observationally identical to
  the control. A small prefix set aimed at a small fleet reaches that state inside
  the first pass.
- **Measuring spreads residency.** Every request stores its prefix on whichever
  pod served it, so each measurement erodes the unevenness being measured.
- **Too large a working set thrashes instead.** Overshoot the aggregate cache and
  every policy churns, which is what the 4-prefix/120-word version measured.

So a lab that teaches prefix-cache routing by sending a few prefixes repeatedly
and diffing endpoint distributions **will show nothing**, and a course that
published such a comparison would be publishing noise. The honest demonstration
holds residency fixed and varies one thing: `setup.sh asymmetry`.

## The asymmetry experiment — what actually proves consumption

Every cache manipulation is performed **directly against a simulator pod**, so
the only channel by which the router can learn of it is the ZMQ event stream.

1. warm prefix A on pod **P** (direct) -> router index admissions 0 -> 45
2. ask the **router** for A -> picks **P**, scores `{P:10, other:0, Q:0}`
3. warm prefix A on pod **Q** (direct) -> admissions 45 -> 90
4. flood **P** with distinct prefixes (direct) -> evictions 0 -> 461
5. ask the **router** for A again -> picks **Q**, scores `{P:0, other:0, Q:10}`

Byte-identical prompt, unchanged policy, and the scores **invert**. A router not
consuming the events could not produce that, and a tie-break could not produce
inverted scores. Captures: `12-asymmetry-with-counters.log`,
`13-envoy-endpoint-choices.log`.

---

## Latency parameters — citation and declared conditions

The simulator's latency parameters are **not authored by this course** and are
**not tuned**. `sim.yaml` mounts a verbatim copy of:

> `manifests/latency-profiles/small-l40s-edge-per-token.yaml`
> from `llm-d/llm-d-inference-sim` at tag **v0.11.2**
> *"Profile 3: Small (1-3B) model on L40S, low-latency edge (per-token calculator)."*

Values, unaltered: `inter-token-latency 15ms` (sd 2ms) · `prefill-overhead 20ms` ·
`prefill-time-per-token 350us` (sd 3ms) · `kv-cache-transfer-time-per-token 12us`
(sd 500us) · `time-factor-under-load 1.5` · `max-num-seqs 4` ·
`latency-calculator per-token`.

**Declared conditions**, from the profile's own `docs/latency-profiles.md`:
values are *"gathered from publicly available benchmarks of vLLM, MLPerf, and GPU
vendors"*; they *"assume FP16/BF16 weights, batch size 1, and reasonable
production settings (PagedAttention, FlashAttention, no CPU offload)"*; and the
document states they are **approximate**. The target hardware is an **NVIDIA
L40S (48 GB)** serving a **1-3B** model. None of that hardware exists in this
lab.

**One documented override.** `model` is set on the command line to
`Qwen/Qwen2.5-1.5B-Instruct` instead of the profile's
`meta-llama/Llama-3.2-3B-Instruct`, because Qwen2.5-1.5B is **ungated** on
HuggingFace and so the lab needs no token. It is 1.5B, inside the profile's 1-3B
class. The override is applied on the command line rather than by editing the
file, so the mounted profile stays byte-diffable against upstream.

**Capacity knobs are declared, not tuned.** `kv-cache-size=64` blocks (default
1024) and `block-size=16` change how much fits, never how fast anything is
modelled to be, so TRUST-05's no-tuning rule is not engaged. 64 is chosen because
a 1024-block cache cannot be filled by any laptop-scale request set, and an
eviction that never happens cannot be observed. Both values are stated in the
spike record.

**What may therefore be said of any figure from these policies:** it was
*modelled*, *demonstrated* or *showed* — never *measured*. The only measurement
in this spike is the lab's own cold wall-clock, which measures the lab, not a
model.

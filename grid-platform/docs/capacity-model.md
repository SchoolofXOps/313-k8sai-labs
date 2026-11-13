# Capacity model

## Demand inputs

~~~text
model_file=m2/inputs/models/qwen2.5-7b-instruct.conf
accelerators_file=m2/inputs/accelerators.conf
accelerator=l40s
precision_bytes=2
overhead_fraction=0.10
arrival_rate_rps=20
mean_latency_s=8
context_tokens=4096
tokens_per_request=400
tokens_per_second_per_replica=3000
failure_reserve_fraction=0.20
fragmentation_fraction=0.10
~~~

## Fleet recommendation

~~~text
RESULTS (modelled for Qwen2.5-7B-Instruct on NVIDIA L40S):
concurrent_requests=160.0
weights_gb=15.23
kv_gb_per_request=0.235
accelerators_per_replica=1
max_concurrent_requests_per_replica=120
replicas_from_memory=2
replicas_from_throughput=3
replicas_binding=3 (throughput binds)
replicas_with_failure_reserve=4
accelerators_before_fragmentation=4
accelerators_recommended=5

~~~

## Sensitivity

~~~text
SENSITIVITY (each input varied by 25 percent, others held at their stated value):
input                              base_value at_minus25  at_plus25   swing
arrival_rate_rps                           20          4          6       2
mean_latency_s                              8          5          5       0
context_tokens                           4096          5          5       0
tokens_per_request                        400          4          6       2
tokens_per_second_per_replica            3000          6          5       1
failure_reserve_fraction                 0.20          5          5       0
fragmentation_fraction                   0.10          5          5       0
largest_swing=arrival_rate_rps,tokens_per_request (2 accelerators between the two cases)
~~~

## Uncertainty

- Arrival rate is a declared peak, not an observed one. Traffic that doubles for a launch day is outside this model.
- Latency and tokens per second for one replica are declared. Both depend on the engine, its settings and the request mix, and both must come from your own load test.
- Context length is an average. A few very long requests raise the cache need well past the average.
- Failure reserve and fragmentation are fractions chosen by judgement, not derived.
- Units: GB here means 10^9 bytes, as vendors print it. A tool that reports binary units, GiB, shows a smaller figure for the same card: 80 GB is about 74.5 GiB, roughly 6.9 percent less.
- Prices, zone availability and spot interruption are not in this model at all.

## A device request no node can satisfy

```text
NAME             READY   STATUS    RESTARTS   AGE
device-request   0/1     Pending   0          1s
False Unschedulable
0/2 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
```

## A slow-starting server behind a Service with no readiness gate

```text
startup-state=loading (instrumentation: a timed wait of 60s, not a model load)
startup-state=loading elapsed=5s of 60s
startup-state=loading elapsed=10s of 60s
startup-state=loading elapsed=15s of 60s
startup-state=loading elapsed=20s of 60s
startup-state=loading elapsed=25s of 60s
startup-state=loading elapsed=30s of 60s
startup-state=loading elapsed=35s of 60s
startup-state=loading elapsed=40s of 60s
startup-state=loading elapsed=45s of 60s
startup-state=loading elapsed=50s of 60s
startup-state=loading elapsed=55s of 60s
startup-state=loading elapsed=60s of 60s
startup-state=serving (exec llm-d-inference-sim; port 8000 opens once it has started)
I1030 03:19:10.579713       1 config.go:877] "Configuration:" =<
	{
	  "DisplayModelName": "m1-sim",
	  "IP": "",
	  "PodName": "",
	  "PodNameSpace": "",
	  "VllmDevMode": false,
	  "block-size": 16,
	  "data-parallel-rank": -1,
	  "data-parallel-size": 1,
	  "dataset-in-memory": false,
	  "dataset-path": "",
	  "dataset-table-name": "llmd",
	  "dataset-url": "",
	  "default-embedding-dimensions": 384,
	  "ec-transfer-config": "",
	  "enable-kvcache": false,
	  "enable-prefix-caching": false,
	  "enable-request-id-headers": false,
	  "enable-sleep-mode": false,
	  "enforce-eager": false,
	  "event-batch-size": 16,
	  "failure-injection-rate": 0,
	  "failure-types": null,
	  "fake-metrics": null,
	  "fake-metrics-refresh-interval": "100ms",
	  "force-dummy-tokenizer": true,
	  "global-cache-hit-threshold": 0,
	  "hash-seed": "",
	  "image-emission-rate": 0,
	  "inter-token-latency": "15ms",
	  "inter-token-latency-std-dev": "2ms",
	  "kv-cache-size": 1024,
	  "kv-cache-transfer-latency": "0s",
	  "kv-cache-transfer-latency-std-dev": "0s",
	  "kv-cache-transfer-time-per-token": "12µs",
	  "kv-cache-transfer-time-std-dev": "500µs",
	  "kv-events-replay-endpoint": "",
	  "kv-events-replay-queue-size": 1024,
	  "latency-calculator": "per-token",
	  "log-http": false,
	  "lora-modules": [],
	  "max-cpu-loras": 1,
	  "max-loras": 1,
	  "max-model-len": 1024,
	  "max-num-seqs": 4,
	  "max-request-body-size-mb": 4,
	  "max-tool-call-array-param-length": 5,
	  "max-tool-call-integer-param": 100,
	  "max-tool-call-number-param": 100,
	  "max-waiting-queue-length": 1000,
	  "min-tool-call-array-param-length": 1,
	  "min-tool-call-integer-param": 0,
	  "min-tool-call-number-param": 0,
	  "mm-encoder-only": false,
	  "mm-processor-kwargs": "",
	  "mm-render-timeout": "1m0s",
	  "mode": "random",
	  "model": "m1-sim",
	  "object-tool-call-not-required-field-probability": 50,
	  "omni": false,
	  "port": 8000,
	  "prefill-overhead": "20ms",
	  "prefill-time-per-token": "350µs",
	  "prefill-time-std-dev": "3ms",
	  "render-timeout": "30s",
	  "render-url": "",
	  "seed": 1793330350578846500,
	  "self-signed-certs": false,
	  "served-model-name": [
	    "m1-sim"
	  ],
	  "skip-tool-validation": false,
	  "ssl-certfile": "",
	  "ssl-keyfile": "",
	  "startup-duration": "0s",
	  "tensor-parallel-size": 0,
	  "time-factor-under-load": 1.5,
	  "time-to-first-token": "0s",
	  "time-to-first-token-std-dev": "0s",
	  "time-to-generate-image": "0s",
	  "time-to-generate-image-std-dev": "0s",
	  "tool-call-extra-call-probability": 45,
	  "tool-call-not-required-param-probability": 50,
	  "use-vllm-map-event-format": false,
	  "zmq-endpoint": "tcp://127.0.0.1:5557"
	}
 >
I1030 03:19:10.581360       1 tokenizer.go:68] "--force-dummy-tokenizer is deprecated; omit --render-url to use the simulated tokenizer" model="m1-sim"
I1030 03:19:10.585155       1 context.go:216] "No dataset path or URL provided, using random text for responses"
I1030 03:19:10.585308       1 communication.go:65] "Starting communication layer"
I1030 03:19:10.585612       1 simulator.go:242] "Start processing routine"
I1030 03:19:10.587526       1 grpc.go:129] "Server starting" protocol="gRPC" port=8000
I1030 03:19:10.587782       1 http.go:121] "Server starting" protocol="HTTP" port=8000

  50   HTTP/1.1 200 OK
  50 wget: can't connect to remote host (10.96.245.74): Connection refused
```

## An autoscaler watching CPU while the queue grows

```text
vllm:num_requests_running{model_name="m1-sim"} 4
vllm:num_requests_waiting{model_name="m1-sim"} 15
NAME   REFERENCE        TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
sim    Deployment/sim   cpu: 66%/50%   1         4         1          31s
NAME                  CPU(cores)   MEMORY(bytes)   
sim-5f67dd59b-88c22   66m          18Mi            
```

# addon-kueue-kwok layer

KUEUE_IMAGE_ID=registry.k8s.io/kueue/kueue@sha256:20465f0e56a4eed90ec07fa7838866a90f7b6890c0adc84be86aaee307a6744a
SIMULATED_NODES=9
MAPPING: config_group=config.kueue.x-k8s.io/v1beta2 mappings=1 maps_deviceclass=yes quota_resources=example.com/sim-accelerator

OK: addon-kueue-kwok verified on 'grid-core' — 9/9 simulated nodes Ready (FLEET=collision, count from declared lab.sizes.8.kwok_collision_nodes), 1 Kueue Workload(s) of which 1 admitted (first reserving 100m cpu), Configuration in config.kueue.x-k8s.io/v1beta2 with 1 deviceClassMapping(s) naming 'sim-accelerator.example.com', and the running controller on the pinned digest.

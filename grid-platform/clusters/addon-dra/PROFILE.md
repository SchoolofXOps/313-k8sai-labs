# addon-dra layer

DRIVER_IMAGE=registry.k8s.io/dra-example-driver/dra-example-driver@sha256:c1488eb51e086bd6b885a667c7d059382844e54e5917a71bcf734c04edfbb62f
DEVICES_ON_grid-core-worker=8

OK: addon-dra verified on 'grid-core' — 1 ResourceSlice(s) all reporting spec.driver 'sim-accelerator.example.com', DeviceClass 'sim-accelerator.example.com' with a CEL selector naming the same driver, 8 synthetic devices per slice (8 total) each publishing resource.kubernetes.io/pcieRoot, and the running plugin on the pinned digest.

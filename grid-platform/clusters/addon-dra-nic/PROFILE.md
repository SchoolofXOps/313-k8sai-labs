# addon-dra-nic layer

DRIVER_IMAGE_ID=registry.k8s.io/dra-example-driver/dra-example-driver@sha256:c1488eb51e086bd6b885a667c7d059382844e54e5917a71bcf734c04edfbb62f
SYNTHETIC_NICS=4

OK: addon-dra-nic verified on 'grid-core' — 1 ResourceSlice(s) for driver 'sim-nic.example.com' on grid-core-worker, 4 synthetic NICs per slice (4 total) each publishing resource.kubernetes.io/pcieRoot, every root shared with a 'sim-accelerator.example.com' synthetic device on the same node, DeviceClass 'sim-nic.example.com', and the running plugin on the pinned digest.

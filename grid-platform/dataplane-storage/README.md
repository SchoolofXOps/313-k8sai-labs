# `dataplane-storage/` — the data and collective paths

The paths data takes to reach an accelerator, and the secondary network paths a distributed job
needs. Named as one directory because the failure they share is the same one: a device sitting idle
waiting for bytes.

| What lands here | Owning module |
|---|---|
| `StorageClass` manifests for each measured delivery path | M6 |
| the node-local cache tier configuration | M6 |
| checkpoint and shared-volume claims, with their access modes stated | M6 |
| `NetworkAttachmentDefinition` manifests and the secondary-interface wiring | M6 |
| the storage measurement harness configuration, published beside any figure it produced | M6 |

Any throughput figure committed here carries the harness configuration that produced it and the
machine it was produced on. Two measured limits are already on record and constrain what this
directory may claim: on a `kind` cluster the default provisioner is a bind mount rather than a
distinct storage data path, so no comparison between the two is available; and the host's own page
cache cannot be evicted from inside the guest, so no absolute figure here is a disk-performance
claim.

## What does not land here

- Fabric and RDMA configuration that needs real hardware. Those are taught as briefs on the lesson
  page with the hardware requirement stated, and nothing unverifiable is committed as platform
  configuration.
- The vector database's own volume claim. It ships with the database in `datalayer/`.
- Model artifact storage for the serving path. The claim a model server mounts lives in `serving/`
  beside the server that mounts it.
- Device inventory for the network interface. A device class for a NIC is `nodes/`.

## Why the owner is named at all

M7's checkpoint-and-resume proof writes to a shared volume defined here, and M8's cold-start
comparison reads the cache tier defined here. Both depend on this directory; only M6 writes it.

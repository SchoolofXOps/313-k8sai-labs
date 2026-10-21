# `nodes/` — device inventory and the node-side driver

What makes a device requestable at all: the driver that publishes an inventory, the classes that
describe what may be asked for, and the templates a workload's claim is cut from.

| What lands here | Owning module |
|---|---|
| `DeviceClass` manifests, including the CEL attribute selectors a claim matches on | M4 |
| `ResourceClaimTemplate` manifests | M4 |
| the example-driver install values and the pinned driver version used for the synthetic-device labs | M4 |
| the vendor operator's values file used on the rented-hardware track, with its instance type declared | M4 |
| node label and feature-discovery configuration | M4 |
| the device-health signal configuration and the exporter's metric selection | M4 |

The devices the core-path labs allocate here are **synthetic** — published by the upstream example
driver, not by any accelerator. The driver's own output names them in accelerator terms and
advertises a capacity figure that is not memory on any device; where that output appears on screen
it is captioned as synthetic. Nothing in this directory qualifies a vendor driver.

## What does not land here

- Quota, queueing or admission objects. A `DeviceClass` says what a device *is*; a `ClusterQueue`
  says who may have one. Those live in `capacity/` and are written by M5.
- Pod or workload specs that consume a claim. The claim's consumer belongs to the directory of the
  workload that consumes it — `training/`, `serving/` or `datalayer/`.
- Cluster creation. The profile that brings up a node pool is in `clusters/`.
- Dashboards and alert rules built on the health signal. Those are `observability/`, written by M12.

## Why the owner is named at all

M5's `ResourceFlavor`s reference attributes that the classes here define, and M6's co-allocation
lab claims a device and a network interface in one request. Both read this directory; neither
writes it.

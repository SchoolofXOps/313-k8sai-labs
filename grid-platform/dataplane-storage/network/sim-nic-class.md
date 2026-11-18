# The synthetic-NIC device class

Every device behind this class is synthetic: a second release of the upstream example driver on its net profile. There is no network card behind it, and its device names, model string and bandwidth capacity are constants in the driver source.

- DeviceClass: sim-nic.example.com
- Selector: device.driver == 'sim-nic.example.com'
- Synthetic NICs published on the worker: 4
- PCIe roots they publish: pci0000:00, pci0000:80
- Installed by: grid-platform/clusters/addon-dra-nic/create.sh
- Claimed together with a synthetic device by: accel-and-nic-one-root.yaml

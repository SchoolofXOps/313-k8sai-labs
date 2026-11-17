# XID classification

Evidence source: the live dcgm-exporter's DCGM_FI_DEV_XID_ERRORS samples, read on the lab cluster from XIDs injected into mock devices served by NVIDIA's mock NVML library (Mokka nvml-mock 0.7.0). No device failed. The kernel-log lines come from m4/xid-events.txt, a course-authored synthetic fixture.

| XID | Evidence | Class | First action |
|---|---|---|---|
| 48 | the exporter's sample with err_code 48 on mock device 0, carrying its double-bit ECC message; in the fixture, a kernel-log line logged twice for one process | memory error the device could not correct | correlate before acting: check whether it recurs and read the device's memory-error counters, then decide between draining the node and resetting the device |
| 63 | the exporter's sample with err_code 63 on mock device 1, carrying its page-retirement or row-remapping message; in the fixture, a row marked for remapping, active after a reset | memory repair pending | correlate before acting: count remapped rows against the device's limit, then plan a reset at the next drain window |
| 79 | the exporter's sample with err_code 79 on mock device 2, carrying its off-the-bus message; in the fixture, two kernel-log lines saying the same | device lost to the host | correlate before acting: confirm whether the device is still visible on the node and whether other devices on that node report errors, then drain the node and plan a reset or a replacement |

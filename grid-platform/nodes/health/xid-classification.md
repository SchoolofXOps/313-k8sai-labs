# XID classification

Evidence source: m4/xid-events.txt, a course-authored synthetic fixture. No device produced it.

| XID | Evidence | Class | First action |
|---|---|---|---|
| 48 | uncorrectable double-bit memory error, logged twice for one process | memory error the device could not correct | correlate before acting: check whether it recurs and read the device's memory-error counters, then decide between draining the node and resetting the device |
| 63 | a memory row marked for remapping, active after a reset | memory repair pending | correlate before acting: count remapped rows against the device's limit, then plan a reset at the next drain window |
| 79 | the device fell off the bus, followed by a second line saying the same | device lost to the host | correlate before acting: confirm whether the device is still visible on the node and whether other devices on that node report errors, then drain the node and plan a reset or a replacement |

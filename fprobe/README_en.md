# `fountain::fprobe`

The server-monitoring executable: `fprobe agent` runs on every node and periodically
collects host metrics exposed over RPC; `fprobe supervisor` aggregates multiple nodes and
provides alarms, charts, periodic reports and extensible channels. The extension contract
lives in [`fountain::f_probe`](../f_probe/README_en.md).

> This module is still being implemented; commands and configuration will follow the
> `--help` output and upcoming documentation.

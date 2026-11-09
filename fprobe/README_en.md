# `fountain::fprobe`

The server-monitoring executable: `fprobe agent` runs on every node and periodically
collects host metrics exposed over RPC; `fprobe supervisor` aggregates multiple nodes and
provides alarms, charts, periodic reports and extensible channels. The extension contract
lives in [`fountain::f_probe`](../f_probe/README_en.md).

## Commands

```text
fprobe agent                   # node agent, listens on 12323 by default
fprobe supervisor              # console mode (TUI)
fprobe supervisor resident     # resident mode, no terminal initialization
fprobe --help                  # usage
```

## Metrics

| kind | Content |
| --- | --- |
| `cpu` | total usage, `iowait`, 1/5/15-minute load, core count |
| `memory` | `available`, `used`, `swap`, caches and buffers |
| `disk` | space and inode usage per mount; `await` / `util` / IOPS deltas |
| `system` | uptime, process count, TCP connections |
| `network` | throughput, bandwidth, drop/error and TCP retransmit rates |
| `hardware` | IPMI sensors, SNMP sensors, disk SMART |
| `mvc-health` | f_mvc `/health` (`probe_mvcHealthUrl`) |
| `rpc-health` | f_rpc `HealthRPC` (`probe_rpcHealthTargets`) |
| `service` | HTTP/TCP reachability (`probe_serviceTargets`) |
| `topology` | SNMP IF-MIB / LLDP-MIB topology (`probe_snmpDevices`) |

Extensions add new kinds through `f_probe.ProbeRegistry.registerAgent`; duplicate kinds are
rejected.

## Minimal deployment

```bash
# node
fprobe agent --probe_port=12323

# supervisor (resident)
fprobe supervisor resident --probe_nodes='node-a@10.0.0.11:12323,node-b@10.0.0.12:12323'
```

See [`doc/deployment.md`](doc/deployment.md) for systemd units, permissions and the
extension directory.

## Alarms and reports

- Rules: `probe_alarmRules` (JSON array), see [`doc/alarm-rules.md`](doc/alarm-rules.md)
- Channels: `email` by default; alarm mail uses a prominent HTML banner plus a text fallback
- Reports: a non-empty `probe_reportCron` sends HTML summaries and SVG charts periodically
- Advisor: with `probe_llmAgent=true` the agent analyses data and proposes actions; only
  whitelisted actions (`ack` / `mute` / `report` / `none`) are executed, and the allowed
  accounts come from the channel's `replyConf()`

## Configuration

Every key, default and range is listed in [`doc/configuration.md`](doc/configuration.md).
Values can be supplied as `--key=value`, `-key value` or environment variables.

## Documentation

| Document | Content |
| --- | --- |
| [`doc/configuration.md`](doc/configuration.md) | all configuration keys |
| [`doc/alarm-rules.md`](doc/alarm-rules.md) | rules and state machine |
| [`doc/tui.md`](doc/tui.md) | console layout, keys, terminal backend |
| [`doc/deployment.md`](doc/deployment.md) | systemd, permissions, extensions |
| [`doc/rpc.md`](doc/rpc.md) | RPC contract and minimal client |
| [`doc/spec/add-fprobe/`](doc/spec/add-fprobe/) | OpenSpec proposal, design, specs, tasks |

## Layout

```text
fprobe/src/
  main.cj            subcommand dispatch
  config/            agent / supervisor settings and validation
  collect/           collectors (proc, health, hw, net, topology)
  snapshot/          snapshot and read-only store
  rpc/               ProbeRPC server and directed node transport
  supervisor/        poll loop, node state, history
  alarm/             rules, state machine, missing data
  channel/           channel dispatcher and email implementation
  report/            charts, reports, topology rendering, CRON
  llm/               prompt, advice parsing, reply monitor, action whitelist
  tui/               view model, render plan, painter, SupervisorApp
  runtime/           agent / supervisor process assembly
  custom/            dynamic extension loading
```

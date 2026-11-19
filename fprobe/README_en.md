# `fountain::fprobe`

`fprobe` is the server-monitoring executable of fountain. It has two roles:

- **agent** — runs on every monitored node, periodically collects host, service and
  hardware metrics, and exposes them to the supervisor through a single `f_rpc` call;
- **supervisor** — aggregates multiple nodes, runs alarms, charts, periodic reports and
  optional LLM analysis, and offers both console (TUI) and resident modes.

The extension contracts `ProbeAgent` / `AlarmMessageChannel` live in
[`fountain::f_probe`](../f_probe/README_en.md); this module provides the default
implementations, registries and process assembly.

## Features

- **10 built-in metric kinds**: CPU, memory, disk, system, network, hardware, MVC health,
  RPC health, service reachability and network topology — covering compute/IO bottlenecks,
  inode exhaustion, TCP retransmits and hardware sensors.
- **One RPC call per node per tick**: `collect()` returns every metric of that node at once;
  the supervisor never opens one connection per metric.
- **Failure isolation**: a failing probe only marks its own metric with `error`; other
  metrics keep flowing. Missing external tools (`ipmitool`, `smartctl`, `snmpbulkwalk`)
  degrade gracefully instead of blocking startup.
- **Two run modes**: the default TUI shows nodes, metrics, charts and alarms live;
  `resident` skips terminal setup and writes logs only, which suits systemd.
- **Alarm state machine**: sustained duration, cooldown, recovery notifications and rule
  muting, plus automatic alarms for unreachable nodes, missing kinds and probe errors.
- **Multi-channel delivery**: the built-in email channel renders prominent HTML banners with
  a plain-text fallback; extensions can add WeCom, Feishu, DingTalk and other channels.
- **Charts and periodic reports**: the TUI draws multi-line/bar charts with `f_chart.tui`;
  periodic reports are triggered by `f_ticktock` CRON and email an HTML summary with inline
  SVG charts and topology.
- **Optional LLM advisor**: analyses metrics and alarms, proposes causes and remediation,
  and only executes whitelisted actions (`ack` / `mute` / `report` / `none`) from replies.
- **Dynamic extensions**: shared libraries under `custom/` are loaded at startup via
  `std.reflect.PackageInfo.load` and may register new metric kinds and alarm channels;
  duplicate registrations are rejected.
- **Self-contained terminal backend**: `fountain::f_tui` talks directly to POSIX
  `termios`/`ioctl` and does not depend on `crossterm`, `ratatui_backend` or
  `ratatui_widgets`.
- **Fail-fast configuration**: all settings are read and validated at startup; invalid
  values exit with status `2` and every problem is printed at once.

## How it works

```text
┌──────────────── monitored node (fprobe agent) ─────────────┐
│  ProbeRunner ──► SnapshotStore ──► ProbeRPC.collect()      │
│    cpu / memory / disk / system / network / hardware ...   │
└───────────────────────────┬────────────────────────────────┘
                            │ f_rpc (TCP, default 12323)
┌───────────────────────────▼────────────────────────────────┐
│  supervisor: PollLoop ──► NodeStateStore ──► ViewModel/TUI │
│                    │            │                          │
│                    │            ├─► AlarmEngine ─► channels│
│                    │            ├─► NodeHistoryStore       │
│                    │            └─► ReportJob (CRON)       │
│                    └─► unreachable / missing-kind / probe  │
│                        error alarms                        │
└────────────────────────────────────────────────────────────┘
```

Each agent tick produces a `ProbeSnapshot`; every metric is a
`ProbeAgentData { kind, host, dataJson, collectedAt, error }`. `collect()` only reads the
snapshot and never triggers a fresh collection inside the RPC call.

## Quick start

### Build

```bash
cd fprobe
cjpm build --release
./target/release/bin/main --help
```

The artifact is `target/release/bin/main`. Use `cjpm test` for the whole module and
`cjpm test src/tui` for a single package.

### Launcher script

`fprobe.sh` in the module root preloads the complete default configuration of each mode:

```bash
./fprobe.sh agent          # fprobe agent
./fprobe.sh supervisor     # fprobe supervisor (TUI)
./fprobe.sh resident       # fprobe supervisor resident
```

- Options with non-empty defaults are passed as real arguments; options that are unset or
  disabled by default (optional probes, email, reports, LLM) stay commented out.
- Extra arguments are appended after the defaults, so they win:

  ```bash
  ./fprobe.sh agent --probe_port=12324
  ./fprobe.sh resident --probe_nodes='n1@10.0.0.11:12323,n2@10.0.0.12:12323'
  ```

- Binary resolution order: `$FPROBE_BIN` → `./target/release/bin/main` → `fprobe` on `PATH`.

### Single-host trial

With no explicit nodes the supervisor uses `localhost:12323`, so two terminals are enough:

```bash
# terminal 1: node agent
./fprobe.sh agent

# terminal 2: console
./fprobe.sh supervisor
```

### Multi-node resident deployment

```bash
./fprobe.sh resident \
  --probe_nodes='node-a@10.0.0.11:12323,node-b@10.0.0.12:12323' \
  --probe_channel_email_smtpHost=smtp.example.com \
  --probe_channel_email_from=fprobe@example.com \
  --probe_channel_email_receivers=ops@example.com \
  --probe_alarmRules='[{"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"warning"}]'
```

## Commands and exit codes

| Command | Purpose |
| --- | --- |
| `fprobe agent` | Node agent, listens on TCP `12323` by default |
| `fprobe supervisor` | Console mode; standard output must be a TTY |
| `fprobe supervisor resident` | Resident mode; no terminal setup, logs go to stderr |
| `fprobe --help` | Top-level help; `fprobe agent --help` and `fprobe supervisor --help` show per-mode hints |

| Exit code | Meaning |
| --- | --- |
| `0` | Normal exit: help printed, or TUI quit with `q` / `Ctrl+C` |
| `1` | Runtime startup failure, e.g. cannot bind the RPC port or email channel init failed |
| `2` | Usage error, configuration validation failure, or console mode without a TTY |

Configuration errors list every problem at once — invalid ports, malformed nodes, bad rule
JSON, invalid CRON — rather than stopping at the first one.

## Metrics

| kind | Key fields | Source / gate |
| --- | --- | --- |
| `cpu` | `usagePercent`, `iowaitPercent`, `load1`, `load5`, `load15`, `cores` | `/proc/stat`, `/proc/loadavg` |
| `memory` | `totalBytes`, `usedBytes`, `availableBytes`, `freeBytes`, `cachedBytes`, `buffersBytes`, `swapTotalBytes`, `swapUsedBytes`, `swapFreeBytes` | `/proc/meminfo`; `used = MemTotal - MemAvailable` |
| `disk` | `mounts[]`: `path`, `fs`, `totalBytes`, `usedBytes`, `availableBytes`, `usedPercent`, `inodesTotal`, `inodesUsed`, `inodesUsedPercent`; `devices[]`: `device`, `readBytes`, `writeBytes`, `readIops`, `writeIops`, `awaitMs`, `utilPercent` | `df`, `/proc/diskstats` deltas; `probe_diskExcludeFs` filters pseudo filesystems |
| `system` | `uptimeSeconds`, `processCount`, `tcpConnections` | `/proc/uptime`, `/proc`, `/proc/net/tcp` |
| `network` | `interfaces[]`: `name`, `rxBytes`, `txBytes`, `rxBytesPerSec`, `txBytesPerSec`, `bandwidthPercent`, `dropPercent`, `errorPercent`, `tcpRetransPercent` | `/proc/net/dev`, `/proc/net/snmp` deltas |
| `hardware` | `ipmi[]`, `snmp[]`, `smart[]`, each with `available` and `error` | `ipmitool sdr`, SNMP sensors, `smartctl` |
| `mvc-health` | health fields plus `latencyMs`, `statusCode`, `error` | registered when `probe_mvcHealthUrl` is non-empty |
| `rpc-health` | remote `HealthRPC` fields plus `latencyMs`, `error` | registered when `probe_rpcHealthTargets` is non-empty |
| `service` | `targets[]`: `name`, `url`, `reachable`, `latencyMs`, `statusCode`, `error` | registered when `probe_serviceTargets` is non-empty |
| `topology` | `devices[]`, `links[]`, `error` | always registered; empty `probe_snmpDevices` reports an explanatory `error` |

Disk IO fields and network rates/ratios are deltas between consecutive collections, so the
agent warms up first and the initial frame does not emit meaningless zeros.

Every metric is bounded by `probe_httpTimeoutMs` / `probe_commandTimeoutMs`; a timeout never
aborts the whole collection round.

## Configuration

Settings come from two sources, and **command-line arguments override the environment**:

1. environment variables with the same name, e.g. `probe_port=12324`;
2. command line `--key=value` or `-key value`; a bare `--probe_ipmiEnabled` means `true`.

Arrays are comma-separated; booleans accept `true` / `false`. See
[`doc/configuration.md`](doc/configuration.md) for every key, default and range.

### Common agent options

```bash
./fprobe.sh agent \
  --probe_port=12323 \
  --probe_hostId=1 \
  --probe_intervalMs=5000 \
  --probe_customDir=./custom \
  --probe_diskExcludeFs=tmpfs,devtmpfs,overlay,squashfs \
  --probe_serviceTargets='web@http://127.0.0.1:8080,db@tcp://127.0.0.1:3306' \
  --probe_mvcHealthUrl=http://127.0.0.1:8080/health \
  --probe_rpcHealthTargets=svc@127.0.0.1:12321 \
  --probe_networkInterfaces=eth0
```

`probe_hostId` is the cluster-unique protocol node id; `0` is rejected by `f_protocol`.
Every agent and supervisor in a cluster should use a distinct value.

### Common supervisor options

```bash
./fprobe.sh resident \
  --probe_nodes='n1@10.0.0.11:12323,n2@10.0.0.12:12323' \
  --probe_pollIntervalMs=5000 \
  --probe_nodeTimeoutMs=3000 \
  --probe_missingThreshold=2 \
  --probe_historyPoints=60 \
  --probe_alarmCooldownSeconds=300 \
  --probe_alarmRecoverNotify=true \
  --probe_alarmChannels=email \
  --probe_expectKinds=cpu,memory,disk,system,network,hardware,topology
```

`probe_nodes` uses `name@host:port`; names must be unique because they key alarm dedup and
TUI selection.

## Alarms

Rules are read from `probe_alarmRules` as a JSON array:

```json
[
  {
    "name": "cpu-high",
    "kind": "cpu",
    "path": "$.usagePercent",
    "op": "gt",
    "threshold": 85,
    "forSeconds": 60,
    "level": "warning"
  },
  {
    "name": "root-full",
    "kind": "disk",
    "path": "$.mounts[?(@.path == '/')].usedPercent",
    "op": "gte",
    "threshold": 85,
    "forSeconds": 0,
    "level": "critical"
  },
  {
    "name": "root-inode",
    "kind": "disk",
    "path": "$.mounts[?(@.path == '/')].inodesUsedPercent",
    "op": "gte",
    "threshold": 90,
    "forSeconds": 300,
    "level": "warning"
  },
  {
    "name": "web-unhealthy",
    "kind": "service",
    "path": "$.targets[?(@.name == 'web')].statusCode",
    "op": "ne",
    "threshold": 200,
    "forSeconds": 30,
    "level": "critical"
  }
]
```

| Field | Meaning |
| --- | --- |
| `name` | Unique rule name, used for cooldown, mute and recovery pairing |
| `kind` | Metric `kind` |
| `path` | `DataPath` (a JSONPath subset) evaluated on that metric's `dataJson` |
| `op` | `gt` / `gte` / `lt` / `lte` / `eq` / `ne` |
| `threshold` | Comparison threshold |
| `forSeconds` | Seconds the condition must hold before firing; `0` fires immediately |
| `level` | Severity written into messages and mail subjects |

`path` must resolve to a number; boolean and string fields are ignored. `$` is the root,
`.name` selects a member, `[n]` an index and `[?(...)]` filters; when a filter matches
several values the maximum is used.

State machine:

- **Firing**: the first match starts a timer; after `forSeconds` the rule enters firing and
  sends one alarm;
- **Cooldown**: the same rule is not re-sent within `probe_alarmCooldownSeconds`, while the
  state machine keeps advancing;
- **Recovery**: when the condition stops matching the rule leaves firing;
  `probe_alarmRecoverNotify=true` sends a recovery message and clears the cooldown origin, so
  a later match counts as a new alarm;
- **Unreachable node**: alarms after `probe_missingThreshold` consecutive collection
  failures;
- **Missing kind**: alarms when a kind listed in `probe_expectKinds` is not reported;
- **Probe error**: alarms whenever a metric carries a non-empty `error` (missing hardware
  tools take this path);
- **Mute**: the advisor's `mute` action suppresses delivery only and does not change state.

Rules are validated as a whole at startup; missing fields, unknown `op` or invalid JSON exit
with status `2`.

See [`doc/alarm-rules.md`](doc/alarm-rules.md) for details.

## Console mode

`fprobe supervisor` requires standard output to be a TTY. Redirection or CI environments
fail with status `2` and a hint to use `fprobe supervisor resident`.

```text
┌ fprobe ─ node/page ───────────────────────────────────────────┐
│ node list                │ current metric and key values       │
│ > node-a                 │ cpu  usage 12.4%  iowait 0.3%       │
│   node-b                 │ mem  available 6.1 GiB              │
├──────────────────────────┴────────────────────────────────────┤
│ chart / sparkline / alarm summary                              │
└────────────────────────────────────────────────────────────────┘
```

| Key | Action |
| --- | --- |
| `q` | Quit and restore the terminal |
| `r` | Refresh one frame immediately |
| `Tab` | Next page (CPU → memory → disk → network → service → health → topology → alarms) |
| `Shift+Tab` | Previous page |
| `↑` / `↓` | Previous / next node |
| `a` | Jump to the alarm page |

When the chart area is at least 8 rows tall it draws a multi-line chart via
`fountain::f_chart.tui`; otherwise it falls back to a one-line sparkline. CPU/memory/network/
service/health use line charts, disk uses bars, and topology/alarms draw no chart; the
topology page prints device and link rows instead.

On exit the loop stops polling, closes connections and restores raw mode and the cursor;
`q`, `Ctrl+C` and `SIGTERM` share the same hook.

`resident` skips the TUI entirely; its logs contain no ANSI sequences and can go straight to
systemd/journald. See [`doc/tui.md`](doc/tui.md) for layout and terminal internals.

## Charts and periodic reports

- **TUI charts** are fixed per page (see above) and draw only the first series of the page,
  so percentages and bytes never share a Y axis.
- **Periodic reports** are registered through `f_ticktock` when `probe_reportCron` is
  non-empty. CRON has six fields: `second minute hour day month weekday`; for example
  `0 0/5 * * * *` means every five minutes.
- **Report content**: node status, alarm list, key metric charts and topology; the SVG is
  inlined in the HTML body and the mail carries no attachments. The same content is rendered
  as HTML and plain text.
- **Recipients**: `probe_reportReceivers` sets recipients; `probe_reportTmpDir` is deprecated
  and kept only for old configurations — reports no longer write files.
- **Delivery** reuses the enabled alarm channels; one failing channel only logs an error and
  does not affect the others.
- **Rendering fallbacks**: a chart that fails to render degrades to one "metric: current value"
  line without affecting other charts or the body; missing or broken topology shows
  "topology unavailable"; a metric with no history only logs at INFO and produces no empty chart.

An empty `probe_reportCron` disables reports; an invalid CRON fails startup instead of being
silently skipped. Chart types can be overridden with `probe_chart_<metric>`; otherwise
`ChartSelector` picks the default (most metrics are `line`).

## LLM advisor

Disabled by default; enable with `probe_llmAgent=true`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `probe_llmAgent` | `false` | Master switch |
| `probe_llmName` | `deepseek-flash` | Logical model name |
| `probe_llmTrigger` | `alarm` | `alarm` / `interval` / `both` |
| `probe_llmIntervalMs` | `300000` | Interval-analysis period |
| `probe_llmReplyPollMs` | `30000` | Reply polling period |
| `probe_llmMuteSeconds` | `600` | Default mute duration for the `mute` action |
| `probe_replyStateFile` | `./data/reply-state.json` | Processed-reply dedup file |

### Model endpoint and auth key

fprobe has no endpoint or key settings of its own: `probe_llmName` is only a **logical model
name**. Provider, URL and credentials come from a `f_llm` `LLMConf`
(`LLM.chatByName(probe_llmName, ...)`), so `probe_llmName` must match some `LLMConf.llmName`.

| `LLMConf` field | Meaning |
| --- | --- |
| `provider` | Dialect: `deepseek` / `zhipu` / `volcengine` / `aliyun` / `siliconflow`; anything else falls back to standard OpenAI |
| `llmName` | Logical name, matched against `probe_llmName` |
| `actualLlmName` | The `model` sent in the request body; `probe_llmName` is never sent |
| `url` | Base URL up to the version root; `/chat/completions` is appended by default, override with `conf.chatPath` |
| `auth` | Sent verbatim as `Authorization: Bearer <auth>`; plaintext only, `secretRef:` is not resolved |
| `weight` / `enabled` | Needs `weight > 0` and `enabled = true` to become a candidate; several rows with the same `llmName` share traffic by weight |

Inline JSON (containers or a quick trial):

```bash
./fprobe.sh resident \
  --probe_llmAgent=true \
  --probe_llmName=deepseek-flash \
  --probe_llmTrigger=interval \
  --llm_metaStore=legacy \
  --llm_confSource=env \
  --llm_confs='[{"provider":"deepseek","llmName":"deepseek-flash","actualLlmName":"deepseek-flash","url":"https://api.deepseek.com","auth":"sk-xxx"}]'
```

Local JSON file (recommended; keeps the key out of `ps`):

```bash
./fprobe.sh resident --probe_llmAgent=true --llm_metaStore=legacy \
  --llm_confSource=file:/etc/fprobe/llm.json
```

The file is an array of objects whose field names match `LLMConf` members; `conf` is a string
map:

```json
[
  {
    "provider": "deepseek",
    "llmName": "deepseek-flash",
    "actualLlmName": "deepseek-flash",
    "url": "https://api.deepseek.com",
    "auth": "sk-xxx",
    "temperature": -1,
    "enabled": true,
    "weight": 1
  }
]
```

`llm_confSource` accepts `database` (default) / `env` / `file:<path>`; any other value throws.

### Configuration source: `llm_metaStore` wins

Since `f_llm` 1.3, `LLMConfs.holder()` looks at `llm_metaStore` first: for `f_store` (the
default) / `postgres` / `mysql` the configs are always read from the meta store (default
`<executable dir>/data/f_llm-meta`) and `llm_confSource` / `llm_confs` are ignored entirely;
the legacy source is only used when that branch fails to construct.

fprobe is a standalone process with no bean container or ORM wiring, so `database` is unusable;
the `f_store` branch needs no bean and creates its directory on demand, which means a plain
`env` / `file` setup is **silently ignored** — the symptom is one log line per analysis:
`no available llm conf for: deepseek-flash, available: []`.
To actually use `env` / `file`, set `llm_metaStore` to a placeholder outside those three values
(`legacy` in the examples above) so the meta branch is skipped.

### Troubleshooting

| Symptom | Action |
| --- | --- |
| The advisor never replies | Check `probe_llmAgent=true`, that `probe_llmTrigger` fires, and that `probe_llmName` equals `LLMConf.llmName` exactly |
| Log shows `llm conf refreshed, ... source: store` | Configs come from the meta store; `llm_confSource` is not in effect, adjust `llm_metaStore` per the previous section |
| Log shows `llm conf: N record(s) dropped` | Rows with empty `provider` / `actualLlmName` / `url` are dropped |
| Want to verify the chain quickly | Use `--probe_llmTrigger=interval --probe_llmIntervalMs=60000` to shorten the loop; failures are logged only and never stop collection or alarms, and the reply loop additionally needs `probe_channel_email_replyAccount` |

`probe_llmMaxTokens` only appears in `doc/configuration.md` and the launcher comments; it is not
wired up yet.

### Flow

1. On an alarm or an interval tick, node states, alarm events and history points are turned
   into a prompt;
2. The model returns a summary, likely causes and remediation, sent through the alarm
   channels as a message;
3. Authorized accounts reply approve/reject; `ReplyMonitor` polls the channel for replies;
4. `ActionWhitelist` executes only `ack`, `mute`, `report` and `none`; unknown actions return
   `UNSUPPORTED` and arbitrary commands are never executed;
5. Unauthorized senders receive the fixed reply "本账号没有权限指挥智能体" and trigger no
   action.

The allowed accounts come from the channel's `replyConf()`; for email this is
`probe_channel_email_replyAccount`. LLM failures are logged only and never affect
collection, alarms or reports.

## Extensions

The contracts live in `fountain::f_probe`:

- `ProbeAgent`: add a metric kind by implementing `kind`, `host` and `data`;
- `AlarmMessageChannel`: add a channel by implementing `send`, `receive` and `replyConf`,
  optionally overriding `sendRich` to carry HTML and attachments.

Build them as shared libraries and drop them into `probe_customDir` (default `./custom`).
At startup fprobe:

1. scans the directory for shared libraries;
2. loads each with `std.reflect.PackageInfo.load`;
3. registers through `ProbeRegistry.registerAgent` / `AlarmChannelRegistry.registerChannel`;
4. rejects duplicate names; with `probe_customFailFast=true` (the default) any load failure
   aborts startup, while `false` logs a warning and continues.

Custom channels can be enabled directly with `probe_alarmChannels`; custom metric kinds show
up in snapshots and can be used by TUI pages and alarm rules. See
[`f_probe/README_en.md`](../f_probe/README_en.md) and
[`f_probe/doc/contract.md`](../f_probe/doc/contract.md) for examples and registry APIs.

## RPC interface

The agent exposes `fountain::fprobe.rpc.ProbeRPC`:

| Method | Returns | Meaning |
| --- | --- | --- |
| `collect()` | `ProbeSnapshot` | Current snapshot with every metric |
| `kinds()` | `ProbeKinds` | Registered metric kinds |

The supervisor calls `collect()` once per node per tick; the method only reads
`SnapshotStore` and never triggers a new collection. Wire format, `ServiceMeta` and a minimal
client are documented in [`doc/rpc.md`](doc/rpc.md).

## Deployment and permissions

- The agent listens on TCP `12323` (`probe_port`); the supervisor connects out to each node;
- `/proc` metrics need an ordinary user;
- `ipmitool` needs root or the `ipmi` group, `smartctl` usually needs root, SNMP only needs
  access to the device;
- missing tools or permissions never block startup; the affected metric reports
  `available=false` / `error`;
- systemd units, logging and extension directory examples are in
  [`doc/deployment.md`](doc/deployment.md).

## Layout

```text
fprobe/
  fprobe.sh          launcher with per-mode defaults
  src/
    main.cj          subcommand dispatch
    usage.cj         help text
    config/          agent / supervisor settings and validation
    collect/         collectors (proc, health, hw, net, topology)
    snapshot/        snapshot and read-only store
    rpc/             ProbeRPC server and directed node transport
    supervisor/      poll loop, node state, history
    alarm/           rules, state machine, missing data
    channel/         channel dispatcher and email implementation
    report/          charts, reports, topology rendering, CRON
    llm/             prompt, advice parsing, reply monitor, action whitelist
    tui/             view model, render plan, painter, SupervisorApp
    runtime/         agent / supervisor process assembly
    custom/          dynamic extension loading
  doc/               configuration, alarms, TUI, deployment, RPC and OpenSpec artifacts
```

## Documentation

| Document | Content |
| --- | --- |
| [`doc/configuration.md`](doc/configuration.md) | all settings and defaults |
| [`doc/alarm-rules.md`](doc/alarm-rules.md) | rules and state machine |
| [`doc/tui.md`](doc/tui.md) | console layout, keys, terminal backend |
| [`doc/deployment.md`](doc/deployment.md) | systemd, permissions, extensions |
| [`doc/rpc.md`](doc/rpc.md) | RPC contract and minimal client |
| [`doc/spec/add-fprobe/`](doc/spec/add-fprobe/) | OpenSpec proposal, design, specs, tasks |
| [`doc/spec/add-fprobe-tui-charts/`](doc/spec/add-fprobe-tui-charts/) | TUI chart change artifacts |
| [`doc/spec/inline-report-charts/`](doc/spec/inline-report-charts/) | Inline report chart artifacts |

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Exits with `2` and several config errors | Fix the reported port, node, rule JSON or CRON values |
| `standard output is not a TTY` | Use `fprobe supervisor resident`, or run in a foreground terminal |
| Supervisor always shows nodes offline | Check the agent's `probe_port`, firewall rules and `probe_nodes` addresses |
| `hardware` reports `available=false` | Install `ipmitool` / `smartctl` or grant permissions; other metrics are unaffected |
| No mail is delivered | Check `probe_channel_email_smtpHost` and recipients; without smtpHost the channel is not built |
| No report is generated | An empty `probe_reportCron` disables reports; an invalid CRON fails startup |
| The advisor never replies | Check `probe_llmAgent=true` and `probe_llmTrigger`; for endpoint and key see [Model endpoint and auth key](#model-endpoint-and-auth-key) |

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `AdviceParser` (class), `AgentRuntime` (class), `AgentSettings` (class), `Aggregation` (enum), `AlarmEngine` (class), `AlarmEvent` (class), `AlarmEventType` (enum), `AlarmOp` (enum), `public class AlarmRule`, `AppHolder` (class), `ChannelDispatcher` (class), `public class ChannelMessage`, `ChannelReportSender` (class), `public class ChartAxisSpec`, `ChartPanel` (class), `ChartRenderer` (class), `public class ChartSeriesSpec`, `public class ChartSpec`, `ClientTransport` (interface), `Clock` (interface), `CommandResult` (struct), `CommandRunner` (interface), `CpuProbe` (class), `public class CpuSample`, `CustomLoadFailure` (class), `CustomLoadReport` (class), `CustomLoader` (struct), `public class DiskDevice`, `public class DiskMount`, `DiskProbe` (class), `public class DiskSample`, `EmailAlarmChannel` (class), `EmptyHistorySource` (class), `ExitHooks` (interface), `FEmailTransport` (class), `FHttpClientProbe` (class), `FLlmClient` (class), `FNetHealthRpcTransport` (class), `FProcessRunner` (class), `FakeClock` (class), `FixtureCommandRunner` (class), `FixtureProcReader` (class), `FprobePainter` (class), `FrameRenderer` (interface), `HardwareProbe` (class), `public class HealthMetrics`, `HealthRpcResult` (class), `HealthRpcTransport` (interface), `public class HealthSample`, `HistoryRing` (class), `HistorySource` (interface), `HttpProbe` (interface), `HttpProbeResult` (struct), `IntervalCounter` (class), `IpmiProbe` (class), `public class IpmiReading`, `JobScheduler` (interface), `KeyMap` (class), `KeySource` (interface), `public class LlmAdvice`, `LlmClient` (interface), `public class LlmSolution`, `LlmTrigger` (enum), `MailAttachmentSpec` (class), `MailTransport` (interface), `MemoryProbe` (class), `public class MemorySample`, `MetricExtractor` (class), `MetricPage` (enum), `MetricProjection` (class), `MetricSpec` (class), `MissingDataTracker` (class), `MvcHealthProbe` (class), `NetClientTransport` (class), `public class NetworkInterface`, `NetworkProbe` (class), `public class NetworkSample`, `NodeEndpoint` (class), `NodeEvent` (class), `NodeEventType` (enum), `NodeHistoryStore` (class), `NodeRpcTransport` (class), `NodeSource` (interface), `NodeState` (class), `NodeStateStore` (class), `NodeStatus` (enum), `NullPainter` (class), `OutgoingMail` (class), `Painter` (interface), `Panel` (class), `PollLoop` (class), `ProbeAdvisor` (class), `ProbeFactory` (class), `public class ProbeRPCImpl <: ProbeRPC`, `ProbeRunner` (class), `ProbeSnapshotBuilder` (class), `ProcReader` (interface), `ProjectionCatalog` (class), `PromptBuilder` (class), `RealProcReader` (class), `ReceivedMail` (class), `RenderLoop` (class), `RenderPlan` (class), `RenderPlanBuilder` (class), `ReplyDecision` (enum), `ReplyStateStore` (class), `ReportBuilder` (class), `ReportDraft` (class), `ReportSender` (interface), `RpcHealthProbe` (class), `public class RpcHealthSample`, `public class RpcHealthTarget`, `ServiceReachabilityProbe` (class), `public class ServiceSample`, `public class ServiceTargetResult`, `SmartProbe` (class), `public class SmartReading`, `SnmpDevice` (class), `SnmpProbe` (class), `public class SnmpReading`, `SparkSeries` (class), `Sparkline` (class), `StdTcpProbe` (class), `StdTtyDetector` (class), `SupervisorApp` (class), `SupervisorBootstrap` (class), `SupervisorComponents` (interface), `SupervisorRuntime` (class), `SupervisorSettings` (class), `SystemClock` (class), `SystemExitHooks` (class), `SystemProbe` (class), `public class SystemSample`, `Table` (class), `TcpProbe` (interface), `TcpProbeResult` (struct), `TerminalFrameRenderer` (class), `TerminalKeyReader` (interface), `TicktockJobScheduler` (class), `public class TopologyDevice`, `public class TopologyLink`, `TopologyProbe` (class), `TopologyRenderer` (class), `public class TopologySample`, `TtyDetector` (interface), `TtyKeySource` (class), `TuiLayout` (class), `TuiTerminalKeyReader` (class), `UiAction` (enum), `UiKey` (enum), `UnsupportedProcReader` (class), `Usage` (class), `ViewModel` (class), `WhitelistResult` (enum), `public func createProcReader(): ProcReader`, `defaultChartFactory` (func), `get` (func), `interpretHealthResponse` (func), `isEmpty` (func), `iterator` (func), `jsonToData` (func), `next` (func), `parse` (func), `register` (func), `requireTty` (func), `size` (prop), `systemKeySource` (func), `systemPainter` (func), `tryParse` (func)
- `ActionWhitelist`: `apply` (func)
- `AdviceParser`: `static func parse(text: String): LlmAdvice`
- `AgentRuntime`: `prepare` (func), `serve` (func), `snapshot` (func), `stop` (func)
- `AgentSettings`: `apply` (func), `var commandTimeoutMs: Int64 = 3000`, `var customDir: String =`, `var customFailFast: Bool = true`, `var diskExcludeFs: Array<String> = [       ,           ,          ,           ]`, `hostId` (var), `var httpTimeoutMs: Int64 = 2000`, `var intervalMs: Int64 = 5000`, `var ipmiEnabled: Bool = false`, `var mvcHealthUrl: String =`, `var networkInterfaces: Array<String> = []`, `var rpcHealthTargets: Array<NodeEndpoint> = []`, `serviceTargets` (var), `var smartDevices: Array<String> = []`, `var snmpDevices: Array<SnmpDevice> = []`, `validate` (func)
- `Aggregation`: `aggregate` (func), `parse` (func)
- `AlarmEngine`: `evaluate` (func)
- `AlarmEvent`: `let eventType: AlarmEventType`, `format` (func), `isRecovery` (func), `let message: String`, `let rule: String`, `let timestamp: Int64`, `title` (func)
- `AlarmOp`: `matches` (func), `parse` (func)
- `AlarmRule`: `parse` (func)
- `AppHolder`: `var app: ?SupervisorApp = None`
- `ChannelDispatcher`: `dispatch` (func), `dispatchRich` (func)
- `ChartPanel`: `static let MIN_HEIGHT: Int64 = 8`, `static let MIN_WIDTH: Int64 = 20`, `chartJson` (func), `render` (func), `supports` (func)
- `ChartRenderer`: `render` (func)
- `ChartSelector`: `static let SUPPORTED_TYPES = [      ,       ,      ]`, `configKey` (func), `defaultType` (func), `select` (func), `supports` (func)
- `ChartSpec`: `jsonObject` (func)
- `CommandResult`: `let exitCode: Int64`, `let stderr: String`, `let stdout: String`, `succeeded` (func), `let timedOut: Bool`
- `CustomLoadFailure`: `let library: String`, `let message: String`
- `CustomLoadReport`: `let failures: Array<CustomLoadFailure>`, `let loaded: Array<String>`
- `CustomLoader`: `librariesOf` (func), `loadWith` (func)
- `EmptyHistorySource`: `values` (func)
- `FEmailTransport`: `list` (func)
- `FHttpClientProbe`: `get` (func)
- `FNetHealthRpcTransport`: `call` (func)
- `FProcessRunner`: `run` (func)
- `FakeClock`: `advance` (func), `nowMs` (func), `wait` (func)
- `FixtureCommandRunner`: `respond` (func), `run` (func)
- `FixtureProcReader`: `list` (func), `read` (func), `set` (func)
- `FprobePainter`: `draw` (func), `restore` (func), `start` (func), `viewportHeight` (func)
- `HealthMetrics`: `tryFrom` (func), `tryParse` (func)
- `HealthRpcResult`: `let metrics: ?HealthMetrics`, `let timedOut: Bool`
- `HistoryRing`: `append` (func), `let capacity: Int64`, `latest` (func), `size` (func), `values` (func)
- `HttpProbeResult`: `let body: String`, `let timedOut: Bool`
- `IntervalCounter`: `update` (func)
- `KeyMap`: `static func action(key: UiKey): UiAction`
- `LlmTrigger`: `includesAlarm` (func), `includesInterval` (func), `parse` (func)
- `MailAttachmentSpec`: `let filename: String`, `let mediaType: String`
- `MetricExtractor`: `static func primary(kind: String, json: String): ?Float64`
- `MetricPage`: `chartType` (func), `title` (func)
- `MetricProjection`: `let aggregation: Aggregation`, `evaluate` (func), `let unit: String`
- `MetricSpec`: `let label: String`, `let projection: MetricProjection`
- `MissingDataTracker`: `collectRecovered` (func), `raise` (func)
- `NetClientTransport`: `close` (func), `transfer` (func)
- `NodeEndpoint`: `address` (func), `parse` (func)
- `NodeEvent`: `let eventType: NodeEventType`, `let failures: Int64`, `let message: String`, `let timestamp: Int64`
- `NodeHistoryStore`: `observe` (func), `values` (func)
- `NodeRpcTransport`: `static let SERVICE_TYPE =`, `close` (func)
- `NodeState`: `let consecutiveFailures: Int64`, `let snapshot: ?ProbeSnapshot`, `let status: NodeStatus`, `let updatedAt: Int64`
- `NodeStateStore`: `all` (func), `get` (func), `update` (func)
- `NullPainter`: `draw` (func), `restore` (func), `start` (func), `viewportHeight` (func)
- `OutgoingMail`: `let attachments: Array<MailAttachmentSpec>`, `let html: String`, `let receivers: Array<String>`, `let sender: String`, `let subject: String`, `let text: String`
- `Panel`: `draw` (func)
- `PollLoop`: `isRunning` (func), `run` (func), `stop` (func), `tick` (func), `tickCount` (func)
- `ProbeAdvisor`: `analyzeAlarm` (func), `analyzeInterval` (func)
- `ProbeFactory`: `instantiate` (func), `register` (func), `registerProduction` (func)
- `ProbeRPCImpl`: `install` (func), `reset` (func)
- `ProbeRunner`: `snapshot` (func), `tick` (func), `warmup` (func)
- `ProbeSnapshot`: `agents` (prop), `decodeAgents` (func), `encodeAgents` (func)
- `ProbeSnapshotBuilder`: `agentData` (func), `build` (func), `encode` (func)
- `ProjectionCatalog`: `all` (func), `static func specs(page: MetricPage): Array<MetricSpec>`
- `PromptBuilder`: `static func build(states: Array<NodeState>, events: Array<AlarmEvent>`
- `RealProcReader`: `list` (func), `read` (func)
- `ReceivedMail`: `let from: String`, `let html: String`, `let id: String`, `let subject: String`, `let text: String`, `let unread: Bool`
- `RenderLoop`: `renderOnce` (func), `run` (func), `stop` (func)
- `RenderPlan`: `let alarmRows: Array<String>`, `chartHeight` (let), `chartSeries` (let), `chartType` (let), `let metricRows: Array<Array<String>>`, `let nodeRows: Array<String>`, `let note: String`, `let pageTitle: String`, `let selectedIndex: Int64`, `let selectedNode: String`, `let series: Array<SparkSeries>`, `let title: String`
- `RenderPlanBuilder`: `static func build(view: ViewModel, states: Array<NodeState>, history: HistorySource`
- `ReplyMonitor`: `static let UNAUTHORIZED_REPLY =`, `pollOnce` (func)
- `ReplyStateStore`: `isHandled` (func), `markHandled` (func), `size` (func)
- `ReportBuilder`: `build` (func)
- `ReportDraft`: `let html: String`, `let subject: String`, `let text: String`
- `ReportJob`: `static let TASK_NAME =`, `register` (func), `runOnce` (func)
- `SnapshotStore`: `replace` (func)
- `SnmpDevice`: `let community: String`
- `SparkSeries`: `let unit: String`, `let values: Array<Float64>`
- `Sparkline`: `draw` (func)
- `StdTcpProbe`: `connect` (func)
- `StdTtyDetector`: `isTty` (func)
- `SupervisorApp`: `run` (func), `running` (func), `shutdown` (func), `start` (func), `view` (func)
- `SupervisorBootstrap`: `build` (func), `run` (func)
- `SupervisorRuntime`: `close` (func), `start` (func), `stop` (func)
- `SupervisorSettings`: `apply` (func), `var historyPoints: Int64 = 60`, `hostId` (var), `var missingThreshold: Int64 = 2`, `var nodeTimeoutMs: Int64 = 3000`, `var nodes: Array<NodeEndpoint> = []`, `var pollIntervalMs: Int64 = 5000`, `validate` (func)
- `SystemClock`: `nowMs` (func), `wait` (func)
- `SystemExitHooks`: `atExit` (func)
- `Table`: `draw` (func)
- `TerminalFrameRenderer`: `draw` (func), `flush` (func), `restore` (func), `size` (func), `start` (func)
- `TicktockJobScheduler`: `schedule` (func)
- `TopologyRenderer`: `render` (func)
- `TtyKeySource`: `map` (func), `readKey` (func)
- `TuiLayout`: `MIN_CHART_HEIGHT` (let), `chartHeight` (func), `innerHeight` (func)
- `TuiTerminalKeyReader`: `readKey` (func)
- `UnsupportedProcReader`: `list` (func), `read` (func)
- `Usage`: `static func root(): String`
- `ViewModel`: `static let PAGES: Array<MetricPage> = [`, `let alarmCount: Int64`, `empty` (func), `nextPage` (func), `nodes` (let), `page` (func), `pageCount` (func), `let pageIndex: Int64`, `pageNumber` (func), `previousPage` (func), `selectNext` (func), `selectPrevious` (func), `selectedNode` (func), `let selection: Int64`, `showAlarms` (func), `withAlarmCount` (func), `withNodes` (func)

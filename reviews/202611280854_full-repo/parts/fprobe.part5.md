# fprobe 模块审查报告（第 5/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe/`（本部分 20 个文件：`collect/proc/*`、`collect/topology/*`、`config/*`、`custom/*`、`llm/ActionWhitelist.cj`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 本部分所有问题来源均为「存量」
- **审查重点**：采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `<module>_v2.md`）

> 采集调用的线程模型前提（后文多处引用）：`AgentRuntime.cj:87-97` 在 `serve()` 里先主线程 `warmup()+tick()`，随后只 `spawn` **一个**采集线程循环 `store.replace(runner.tick())` + `clock.wait(intervalMs)`；`ProbeRunner.tick()`（`ProbeRunner.cj:77-90`）在**同一线程内按 slot 顺序**取数。因此本部分的探针实例可视为线程封闭，`NetworkProbe` 的可变基线没有数据竞争；代价是任一探针变慢会拖住全部探针（见发现 1）。

## 发现

### [一般][存量] Topology 采集串行且超时可叠加，拖住唯一采集线程

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:118`（设备循环）、`:179`（`runWalk` 调用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.3（并发串行）/ §12.1（采集主路径阻塞）
- **证据**：静态确定 —— `data` 对每台设备顺序执行 2 次 `snmpbulkwalk`，每次最长 `timeoutMs`（默认 3000，`ProbeFactory.cj:70-72` 传入 `settings.commandTimeoutMs`；IF-MIB 与 LLDP-MIB 各一次，`TopologyProbe.cj:119,134`）。结合 `AgentRuntime.cj:92-97` 的单采集线程，单轮最坏耗时 ≈ `2 × N × commandTimeoutMs`（N=10 且全部超时 → 60s，而 `probe_intervalMs` 默认 5s）。
- **描述**：拓扑是慢变量，却按采集主频全量 walk。任一设备不可达就整轮变慢：其余探针的差分窗口被一起拉长（CPU/网络速率按 60s 而不是 5s 求差），快照时间戳与实际采样时刻脱节，且没有总预算、没有并发上限。
- **建议**：给 topology 独立采集周期（或给 walk 结果加 TTL 缓存）；设备间改成“先提交全部 `spawn` 再统一 `get`”并按核数限流；同时把单设备超时收敛到 `总预算/N`。

### [一般][存量] walk 未加 `-On`：装有 MIB 时输出符号 OID，拓扑解析静默丢弃全部条目

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:179`；`IfMibParser.cj:76`；`LldpParser.cj:52,57`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §3（静默失效）
- **证据**：待确认 —— 需确认目标机是否安装 net-snmp MIB：装了则输出 `IF-MIB::ifDescr.1 = STRING: eth0`，不装则是 `.1.3.6.1.2.1.2.2.1.2.1`。代码侧静态确定：`parseIfMib` 只接受以 `1.3.6.1.2.1.2.2.1.2.` 开头的 OID，`parseLldp` 只接受以 `1.0.8802...` 开头。
- **描述**：MIB 可用时两个解析器都返回空数组，`TopologySample` 的 `devices`/`links` 为空且 `error` 仍是空串（`TopologyProbe.cj:173`），监控侧看不到任何异常；同一份 walk 文本在 `hw/SnmpProbe.cj:123-147` 却因为不过滤前缀能正常解析，行为不一致。
- **建议**：`snmpbulkwalk` 参数补 `-On`（强制数字 OID）；或在 `parseIfMib`/`parseLldp` 里同时接受符号前缀并归一化；并把“walk 成功但解析出 0 条”写进 `error`。

### [一般][存量] 网卡白名单全部未命中时静默返回空列表

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:152-157`
- **来源**：存量
- **判据**：review-checklist §3（静默失效）/ §11（错误处理缺失）
- **证据**：静态确定 —— 白名单非空且 `contains` 永假时，循环只执行 `previous[current.name] = current; continue`，`interfaces` 为空；`data` 正常返回 JSON，`ProbeRunner.tick` 只在抛异常时写 `slot.error`（`ProbeRunner.cj:82-89`），因此快照里 `error` 为空串。
- **描述**：`probe_networkInterfaces` 写错一个字符、或容器内网卡改名后，`network` 监控项永久为空数组且无错误、无日志，属于“采集到了 0 条但看起来一切正常”。
- **建议**：白名单非空且本轮命中数为 0 时抛 `ProbeException(ProbeErrorCode.COLLECT, ...)`；或在 `NetworkSample` 增加 `matched` 字段并在采集日志里打命中数。

### [一般][存量] `probe_snmpDevices` 不查重名，TopologyProbe 静默丢弃后一个设备的端口表

- **位置**：`fprobe/src/config/Validation.cj:179-200`（对比同文件 `:160-176` 的 `parseRpcHealthTargets` 有查重）；`fprobe/src/collect/topology/TopologyProbe.cj:142-145`
- **来源**：存量
- **判据**：review-checklist §2（同类校验不一致）/ §11（静默丢弃）
- **证据**：静态确定 —— `parseSnmpDevices` 只校验 `parts.size == 3` 与字符集，不查重名；`TopologyProbe` 用 `known` 按 `device.name` 去重，第二台同名设备的 `host`/`ports` 不进 `discovered`，但它的 LLDP 观察仍进入 `neighbours` 并参与建链（`:146`）。
- **描述**：复制粘贴配置出重名时，输出的设备条目 host/端口来自第一条，链路却可能来自第二条，拓扑自相矛盾且启动不报错（对比：`probe_rpcHealthTargets` 重名会让启动退出 2）。
- **建议**：`parseSnmpDevices` 内用 `HashSet<String>` 查重名并 `errors.add`，与 `parseRpcHealthTargets` 对齐。

### [一般][存量] 远端设备的 `ports` 只保留首个观察到的端口

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:165-169`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 首次发现远端设备时构造 `TopologyDevice(name, name, [observation.remotePort])`，之后 `known.contains` 直接跳过，后续同设备的其它远端端口既不进 `ports` 也不更新；`TopologyDevice` 的字段语义是“设备及其端口”（`TopologyProbe.cj:24`）。
- **描述**：一台交换机在本端 8 个端口被看到时，拓扑里它只有 1 个端口，端口级展示/告警会漏；且 `host` 直接填设备名（不是可解析地址），与配置设备条目形态不同。
- **建议**：先用 `HashMap<String, ArrayList<String>>` 聚合远端设备端口，循环结束后统一构造 `TopologyDevice`；`host` 至少留空或标注来源。

### [一般][存量] Windows 分支引用 `std.env` 但未 import

- **位置**：`fprobe/src/config/AgentSettings.cj:160-166`（`:162 std.env.getVariable("COMPUTERNAME")`）
- **来源**：存量
- **判据**：review-checklist §11（编译期正确性；条件编译分支）
- **证据**：待确认 —— 需在 `os == "Windows"` 目标上 `cjpm build` 验证。旁证：仓内其它使用 `std.env` 的文件全部显式 import（`f_config/src/Config.cj:20`、`fprobe/src/llm/LlmTestSupport_test.cj:19`、`f_base/src/Console.cj:18`），本文件 import 列表（`:18-23`）没有 `std.env`，且该分支在 Linux 目标下从不参与编译，CI 不会暴露。
- **描述**：若未 import 时全限定名不可解析，fprobe 在 Windows 目标上直接编译失败（Linux 目标不受影响）。
- **建议**：补 `import std.env.getVariable`（与既有文件风格一致），顺便消除“同一函数两套条件编译实现”的维护面。

### [一般][存量] SNMP walk 文本解析两份实现且已漂移

- **位置**：`fprobe/src/collect/topology/IfMibParser.cj:46-69`（`parseWalk`）vs `fprobe/src/collect/hw/SnmpProbe.cj:123-147`（同名 `parseWalk`）；`IfMibParser.cj:96-102`（`unquote`）vs `fprobe/src/collect/hw/HardwareParsing.cj:63-72`（`stripQuotes`）
- **来源**：存量
- **判据**：review-checklist §2（近似重复 + 已出现行为漂移）
- **证据**：静态确定 —— 两边流程相同（按 `\n` 切行 → `trimAscii` → 找 `" = "` → 找 `": "` → 去引号）。差异：hw 版保留前导点、拓扑版 `trimLeadingDots`；`stripQuotes` 同时去 `"` 与 `'`，`unquote` 只去 `"`。
- **描述**：同一种 `snmpwalk` 文本两处解析，引号/点号规则不一致：拓扑侧遇到单引号包裹的值会带着引号进 `ports`/`remotePort`，进而影响 `edgeKey` 去重与 TUI 展示；今后改一处必漂移。
- **建议**：把“OID = TYPE: value”的 token 化抽到 `hw/HardwareParsing.cj`（拓扑包已依赖 `hw.CommandRunner`/`SnmpDevice`，不会引入反向依赖），两边共用同一实现 + `stripQuotes`。

### [轻微][存量] `Settings_test.cj` 两个 import 未使用

- **位置**：`fprobe/src/config/Settings_test.cj:22`（`import ...hw.SnmpDevice`）、`:23`（`import ...rpc.NodeEndpoint`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 全文件搜 `SnmpDevice`/`NodeEndpoint` 只命中这两行 import 与函数名 `invalidSnmpDeviceIsRejected`（`:353`，标识符不是类型引用）；断言只用到 `settings.snmpDevices[0].name`、`settings.rpcHealthTargets[0].port` 等成员访问，不需要类型名在作用域内。
- **描述**：无用导入会掩盖“断言是否真的用到了该类型”的意图，也会让后续重构误判依赖关系，属可维护性噪音。
- **建议**：删除这两行 import。

### [轻微][存量] `NetworkProbe.previous` 网卡基线表没有淘汰

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:113`（定义）、`:154`（白名单分支写入）、`:183`（正常分支写入）
- **来源**：存量
- **判据**：review-checklist §5（无界容器）/ §7（缩短生命周期）
- **证据**：静态确定 —— key 取自 `/proc/net/dev` 的网卡名，只写不删；网卡消失后条目常驻（每项 `String + 8×Int64`，约 100–150B，量级小，短期不构成 OOM）。
- **描述**：在 veth/网桥频繁增删的主机上，表会按“历史出现过的网卡名”单调增长；同名网卡重建时沿用旧基线（`nonNegativeDelta` 会把负差钳成 0，不产生错误数值，但首帧速率为 0）。
- **建议**：每轮记录本轮出现的名字集合，循环结束后 `previous.remove(name)` 掉未出现的 key。

### [轻微][存量] `parseMeminfo` 假定所有值都是 kB，且任一非数字字段让整个探针失败

- **位置**：`fprobe/src/collect/proc/MemoryProbe.cj:97-120`（`:115 value * 1024`、`:116` 抛 `COLLECT`）
- **来源**：存量
- **判据**：review-checklist §11（边界/单位假设）
- **证据**：静态确定 —— `/proc/meminfo` 中 `HugePages_Total`/`HugePages_Free`/`HugePages_Rsvd`/`HugePages_Surp` 是页数（无 `kB` 后缀），同样被乘 1024；当前只消费 MemTotal/MemAvailable/MemFree/Cached/Buffers/Swap*（均为 kB），故暂无错误输出。
- **描述**：单位被当常量写进解析层；将来消费 HugePages 字段会得到放大 1024 倍的错值；反过来，内核新增一行非数字格式会让 `memory` 探针整条失败（每轮都是 error）。
- **建议**：解析时保留第二列单位（`kB` 才乘 1024，页数原样保留），非数字行 `continue`，必须字段再用 `requireValue` 单独校验。

### [轻微][存量] `parseSnmp` 对缺失表返回 `(0,0)` 并据此建立基线

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:279-301`（`:297-299` 返回 `SnmpCounters(0, 0)`）；`retransPercent` 在 `:219-232`
- **来源**：存量
- **判据**：review-checklist §11（空值/缺失处理）
- **证据**：静态确定 —— `readOptional`（`:239-244`）把缺失文件变成空串，`parseSnmp` 解析失败即返回 `(0,0)`；`retransPercent` 第一个样本就把 `hasSnmpBaseline=true` 且 `previousSnmp=(0,0)`。
- **描述**：`/proc/net/snmp` 暂时不可读（容器 mask、权限）时，恢复后的第一帧用“自开机累计”当增量，输出的是生命周期平均重传率而不是区间值，且数值落在合理区间，很难被发现。
- **建议**：`parseSnmp` 返回 `?SnmpCounters`，缺失时**不**建立/更新基线；把“表缺失”计入 `error` 或额外字段。

### [轻微][存量] `splitWhitespace` 只按空格切分，与“按空白切分”的注释不符

- **位置**：`fprobe/src/collect/proc/ProbeParsing.cj:26-35`（`:28 line.split(" ")`）
- **来源**：存量
- **判据**：review-checklist §13（注释与实现不符）/ §11
- **证据**：静态确定 —— 只用 `' '` 分割再 `trimAscii`，不含 `\t`；现有 `/proc/*` 与 `df -P` 均为空格分隔，所以当前用例都通过。
- **描述**：遇到 tab 分隔输入（某些 `df` 变体、手工 fixture、后续新增的 `/proc` 类文件）整行只会得到一个 token，列号错位 → `requireNetInt` 抛错或解析出错误值。
- **建议**：同时按 `' '` 与 `'\t'` 切分，并把函数注释改成“按空格与制表符切分”。

### [轻微][存量] SNMP community 通过命令行参数传递

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:179`
- **来源**：存量
- **判据**：安全性（凭据暴露面）/ `fountain-baseline.md` §6
- **证据**：静态确定 —— `snmpbulkwalk ... -c <community>` 使 community 进入子进程 argv，同机任意用户可读 `/proc/<pid>/cmdline`；`hw/SnmpProbe.cj:85` 同源（本部分范围外，一并提示）。
- **描述**：community 等价于 SNMP 读（部分设备可写）口令，fprobe 通常以 root 运行，暴露面比必要的大。
- **建议**：改用 net-snmp 配置文件（`snmp.conf` 的 `defCommunity` + `SNMPCONFPATH`）或进程内实现 GETBULK；至少确保 community 不进错误日志/`CommandResult.error`。

### [轻微][存量] 同包内 `readOptional` 两份实现

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:239-244`（私有自由函数）vs `fprobe/src/collect/proc/DiskProbe.cj:196-201`（私有成员方法）
- **来源**：存量
- **判据**：review-checklist §2（只改位置不改语义）
- **证据**：静态确定 —— 函数体逐行相同（`reader.read` → `Some` 取值 / `None` 返回 `""`），同属 `fountain::fprobe.collect.proc`。
- **描述**：同一语义两处拷贝，未来调整“读失败是否记录原因”会漏改一处。
- **建议**：下沉到 `ProbeParsing.cj` 作为包内函数，`DiskProbe` 的成员方法改为调用它。

### [轻微][存量] 安全字符校验、时间换算与默认端口在多处重复

- **位置**：`config/Validation.cj:271-280` 与 `collect/hw/HardwareParsing.cj:52-61`（`hasWhitespace`/`hasShellMeta` **逐字相同**）；`config/Validation.cj:82-93`、`:216-234`、`:250-268` 与 `collect/proc/SystemProbe.cj:139-150`（4 份 rune 白名单循环）；`collect/Clock.cj:38`、`collect/proc/DiskProbe.cj:257`、`collect/proc/NetworkProbe.cj:236`（`DateTime.now().toUnixTimeStamp().toMilliseconds()` 3 份）；`config/AgentSettings.cj:32` 与 `config/SupervisorSettings.cj:84`（默认端口 `12323` 两处）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换算复制）
- **证据**：静态确定 —— 逐条比对函数体：`hasWhitespace`/`hasShellMeta` 完全一致；4 个字符校验函数只有“允许字符集 + 前缀”不同；时间换算表达式一字不差；端口默认值两处同为 12323（agent 监听端口与 supervisor 默认节点端口必须保持一致，改一处会断）。
- **描述**：安全字符集扩充时（`hasShellMeta` 加字符）两处会漂移，配置校验与执行前校验的边界不再一致；端口常量漂移会让 supervisor 默认连不上本机 agent。
- **建议**：`hasWhitespace`/`hasShellMeta` 收进共享 util（或 `hw/HardwareParsing.cj` 供两包使用）；字符白名单抽成 `isSafeChars(name, extra: Array<Rune>)`；时间统一走 `SystemClock.nowMs()`；默认端口提成 `DEFAULT_AGENT_PORT` 常量（`AgentSettings` 引用、`SupervisorSettings` 引用）。

### [轻微][存量] `ActionWhitelist.apply` 对 ack/mute 不校验 rule 非空

- **位置**：`fprobe/src/llm/ActionWhitelist.cj:76-93`（`:80-86`）
- **来源**：存量
- **判据**：review-checklist §11（契约：返回值承诺“已执行”）
- **证据**：静态确定 —— 调用方 `runtime/SupervisorRuntime.cj:424-429` 在操作员只发“同意 mute”时把 `rule` 置为 `""`；`apply` 仍调用 `mute("", until)` 并返回 `MUTED`，`ack("")` 同理。
- **描述**：回执显示 `MUTED`/`ACKED`，实际 `AlarmEngine.mute("")` 匹配不到任何规则，属于“报告成功但无副作用”的静默失败；`muteSeconds` 也没有正负校验（配置 `probe_llmMuteSeconds` 直接传入）。
- **建议**：`ack`/`mute` 分支在 `rule.isEmpty()` 时返回 `UNSUPPORTED`（或新增 `INVALID`）；`muteSeconds <= 0` 时退化为 `NONE` 或报错。

## 优化可行性方案

> 不是缺陷，是“还能更好”。本节全部**无基线**，只能作为下一轮补数据的候选，不进 `todo.md` / `tasks.md`。

### [CPU] topology 采集与主采集周期解耦

- **现状**：`TopologyProbe.data`（`TopologyProbe.cj:107-175`）每轮对每台设备跑 2 次完整 walk，无缓存；调用频率 = `probe_intervalMs`（默认 5000ms）。
- **方案**：给 `TopologyProbe` 增加内部结果 TTL（如 60s）或独立采集线程/周期；`data` 在 TTL 内直接返回上次结果。同时把 walk 改成“先提交全部设备、再按 `commandTimeoutMs` 汇合”的有界并发。
- **预期**：拓扑类设备数量 N 越大，采集线程占用越低；端到端收益取决于 N 与设备可达性，需实测。
- **代价**：拓扑新鲜度下降；并发 walk 会同时占用更多子进程与网络带宽，需要并发上限。
- **验证**：`cjprof record/report` 对比改前改后采集线程 self time；分段计时 `tick()` 总耗时（N=10/50，设备全可达与全超时两种分布）；`cjpm bench -O2` 不可行，改用运行时埋点中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 解析中间容器改为复用/预分配

- **现状**：`splitWhitespace`（`ProbeParsing.cj:26-35`）每行 `new ArrayList()` + `toArray()`；`parseNetDev`/`parseSnmp`/`parseMeminfo` 每轮各建若干 `ArrayList`/`HashMap`，生命周期 = 单次 `data()` 调用，规模为几十~几百个短字符串。
- **方案**：`splitWhitespace` 改为两趟扫描直接填 `Array<String>`（先计数再填充），或返回 `ArrayList` 视图避免 `toArray()` 复制；`parseMeminfo` 复用成员级 `HashMap` 并 `clear()`（注意 `clear()` 不还内存）。
- **预期**：每轮减少 O(行数) 次容器分配与一次数组复制；峰值收益量级为 KB，需测。
- **代价**：可读性下降；复用的 map 必须保证线程封闭（当前成立）。
- **验证**：10 分钟稳态负载下 `getAllocatedHeapSize()` 增量、GC 次数、`RSS` 中位数对照（改前/改后，同 SDK、`-O2`、同输入）。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | topology walk 占采集线程自耗时的主要部分（N≥10 时） | `topology/TopologyProbe.cj:118-147` | 单轮 `tick()` 内 topology 段耗时占比 | 在 `data` 前后打时间戳，N=10 与 N=50、可达/全超时各跑 100 轮取中位数；`cjprof record` 交叉验证 |
| 2 | `splitWhitespace`/`parse*` 的容器分配是 network 探针的主要分配源 | `proc/ProbeParsing.cj:26-35`、`proc/NetworkProbe.cj:246-270` | 每轮分配字节数占比 | 埋点统计每轮分配量，或用 `cjprof heap` 采样对比 |
| 3 | `NetworkProbe` 每帧 `HashMap.get` + `readSpeed` 文件读取是大头 | `proc/NetworkProbe.cj:191-217` | 单帧 `readSpeed` 的 syscall 次数与耗时占比 | 网卡数 2/16 两种场景下分段计时；`strace -c` 统计 `/sys/class/net/*/speed` 打开次数 |
| 4 | 拓扑 `error` 字符串（含 stderr 全文）在设备多、异常多时放大快照体积 | `topology/TopologyProbe.cj:187-189`、`:212-221` | 单帧快照 JSON 字节数随 N 的变化 | 构造 N=50 且全部 exitCode!=0 的 fixture，测量 `error` 字段长度与快照大小 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/collect/proc/MemoryProbe.cj` | .cj | ✅ | 见发现「parseMeminfo 单位假设」 |
| 2 | `src/collect/proc/MemoryProbe_test.cj` | .cj | ✅ | 覆盖 used=total-available、缺 MemTotal/MemAvailable 两条错误路径 |
| 3 | `src/collect/proc/NetworkProbe.cj` | .cj | ✅ | 见发现 3/9/10/11/12 |
| 4 | `src/collect/proc/NetworkProbe_test.cj` | .cj | ✅ | 两帧差分/白名单/带宽缺失/畸形行 4 条用例 |
| 5 | `src/collect/proc/ProbeParsing.cj` | .cj | ✅ | `splitWhitespace` 见发现「只按空格切分」 |
| 6 | `src/collect/proc/ProcReader.cj` | .cj | ✅ | `read` 全异常转 `None` 属文档化契约；`list` 默认实现有注释 |
| 7 | `src/collect/proc/ProcReader_test.cj` | .cj | ✅ | 真实 reader 用例依赖 Linux `/proc` |
| 8 | `src/collect/proc/SystemProbe.cj` | .cj | ✅ | 计数逻辑与注释一致；字符校验见「零散重复」 |
| 9 | `src/collect/proc/SystemProbe_test.cj` | .cj | ✅ | 4 条用例覆盖缺表/缺目录 |
| 10 | `src/collect/topology/IfMibParser.cj` | .cj | ✅ | 见发现「walk 解析两份实现」「-On」 |
| 11 | `src/collect/topology/LldpParser.cj` | .cj | ✅ | OID 列号 .7/.9 与 LLDP-MIB 一致；见「-On」 |
| 12 | `src/collect/topology/TopologyProbe.cj` | .cj | ✅ | 见发现 1/2/4/5，优化方案 1 |
| 13 | `src/collect/topology/TopologyProbe_test.cj` | .cj | ✅ | 覆盖去重链路/空配置/工具失败 |
| 14 | `src/config/AgentSettings.cj` | .cj | ✅ | 见发现「Windows 分支未 import std.env」 |
| 15 | `src/config/Settings_test.cj` | .cj | ✅ | 配置全局态有 `restore`/`withKeys` 兜底，无泄漏；`:22-23` 两个未使用 import |
| 16 | `src/config/SupervisorSettings.cj` | .cj | ✅ | 默认端口 12323 见「零散重复」 |
| 17 | `src/config/Validation.cj` | .cj | ✅ | 见发现 4，重复见「零散重复」 |
| 18 | `src/custom/CustomLoader.cj` | .cj | ✅ | 插入排序 O(n²)（n 为扩展库数，可忽略）；`load` 结果被调用方丢弃（范围外提示） |
| 19 | `src/custom/CustomLoader_test.cj` | .cj | ✅ | 覆盖排序/failFast/非 failFast/重名注册 |
| 20 | `src/llm/ActionWhitelist.cj` | .cj | ✅ | 见发现「rule 未校验」 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单无 `.md`，README/doc 覆盖由同模块其它部分负责）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 2（远端端口聚合、snmp 重名）、设计 1（topology 周期与主采集耦合）、安全性 1（community 进 argv）；语言特性上 `@When` 两分支、`?T` 用法与仓内惯例一致，未见误用 |
| §1 死代码 | 1 | 逐个搜索：`parseMeminfo/requireValue/networkNowMs/readOptional/parseNetDev/requireNetInt/parseSnmp/snmpValue/parseUptime/countSocketRows/startsWithDigit/isNumericName/observationKey/localPortIndex/edgeKey/joinErrors/defaultHost/isLibrary/withoutExtension/validServiceTarget/isValidFsName/isSafeDevicePath/isSafeInterfaceName/hasWhitespace/hasShellMeta` 在 `fprobe`+`f_probe` 内均有调用者；`splitWhitespace/joinFrom/tryInt64/tryFloat64/clampPercent/nonNegativeDelta/parseWalk/parseIfMib/trimLeadingDots/unquote` 为包内 internal 且有跨文件使用；`WalkEntry/WalkResult/NetCounters/SnmpCounters/LldpObservation/IfPort` 均在包内被实例化或读取；`IF_MIB_WALK_OID/LLDP_MIB_WALK_OID/ProcReader 及三个实现/CustomLoader/MemoryProbe 等` 顶层 public 对外可达，按硬原则一不判；命中 1 条：`Settings_test.cj:22-23` 两个未使用 import；无 `return/throw/break/continue` 之后的同层语句 |
| §2 重复逻辑 | 3 | 已两两比对 20 个文件内全部函数体摘要，命中 3 条合并项：walk 解析（含 `unquote`/`stripQuotes` 漂移）、`readOptional`×2、零散复制（`hasWhitespace/hasShellMeta`、4 份字符白名单、时间换算×3、默认端口×2）；其余（`MemoryProbe.data`/`SystemProbe.data`/`NetworkProbe.data` 的 “读→解析→建模” 骨架）差异在解析对象与错误消息，不合并 |
| §3 空实现 | 1 | 唯一疑似：`NetworkProbe` 白名单全不命中时返回空集合且无 error（已计入发现）；`ProcReader.list` 默认 `None`、`ActionWhitelist` 默认空回调都有文档说明，属有意的 Null Object，不判 |
| §4 栈溢出 | 0 | 无递归：`parseMeminfo/parseNetDev/parseSnmp/parseWalk/parseLldp/countSocketRows` 全为单层循环；`CustomLoader.librariesOf` 用 `Directory.walk` 回调（非自递归）；无自引用结构 |
| §5 OOM | 1 | `NetworkProbe.previous` 无淘汰（量级小，已按轻微报）；`TopologyProbe` 每轮缓冲单台设备的 walk 输出，规模随端口数线性，未见按不可信长度预分配 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；所有疑似热点（topology 串行、`splitWhitespace` 分配、`readSpeed` 每帧读文件）已写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁（全模块只读代码，无 `synchronized`/`Mutex`）；采集线程串行问题记在 §6.3 |
| §6.3 并发串行 | 1 | `TopologyProbe` 串行 walk + 单采集线程（发现 1）；未发现 `spawn` 后立刻 `get` 的伪并发 |
| §6.4 低效算法 | 0 | `snmpValue` 线性查表（列数 ~15）、`trimLeadingDots` 循环去点（≤2 次）、`CustomLoader.sort` 插入排序（扩展库个数为个位数）均未达需优化规模；`previous` 的 `HashMap` 查找为 O(1) |
| §7 降堆内存方案 | 1 | 解析中间容器复用（优化方案，无基线） |
| §8 降 CPU 方案 | 1 | topology 周期解耦 / 有界并发（优化方案，无基线） |
| §9 local mode 可行性 | 0 | `fprobe/cjpm.toml` 为 `-O2 --dy-std`，未启用 local mode；本部分临时对象都是几十~几百个小字符串，无“函数内大对象 + 峰值内存”证据，收益无法证明，写不出前后峰值对照 |
| §11 现有代码的 BUG（存量） | 12 | 16 条发现中 12 条为存量逻辑/边界/契约缺陷（另 3 条重复逻辑记 §2、1 条未使用 import 记 §1）。逐函数核对：`NetworkProbe` 计数下标（0..3 / 8..11）与 `/proc/net/dev` 布局一致，`SystemProbe` 表头判定、`LldpParser` OID 列号（.7/.9）与 LLDP-MIB 一致，未误判 |
| §12 并发安全与锁粒度 | 1 | 已列出共享点：`NetworkProbe` 的 `previous/hasBaseline/lastNowMs` 与 `previousSnmp` 是实例可变状态，唯一调用方为 `AgentRuntime` 的单个采集线程（线程封闭），无同步但当前安全；若将来并行化 `ProbeRunner.tick` 会立刻退化为数据竞争，建议在类注释里写明“非线程安全” |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；`TopologyProbe` 的 `error` 字段、`MemoryProbe` 的 `usedBytes` 口径、`ActionWhitelist` 的白名单动作均已接线（`ProbeFactory.cj:44-72`、`SupervisorRuntime.cj:358-373`），未见“注册未使用/开关只判一处”；README 覆盖核对归同模块其它部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无文档文件，§13 文档一致性留待模块 README 所在部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分代码的整体质量偏上：解析函数短小、错误统一收敛为 `ProbeException(COLLECT/LOAD)`、每个探针都有对应 `_test.cj` 且覆盖了差分首帧、缺表、畸形行等关键路径；采样口径（`usedBytes=MemTotal-MemAvailable`、`drop/error` 以包数比、`nonNegativeDelta` 处理计数器回绕）注释与实现一致。

主要风险集中在 **topology 子系统**，且都是“可用性/静默失效”类而非崩溃类：

1. 阻塞项（建议排期优先）：topology 每轮串行 2N 次 walk、超时可叠加，直接拖慢唯一采集线程（发现 1）；`-On` 缺失导致装有 MIB 的环境下拓扑静默为空（发现 2）。这两条决定 topology 监控项在生产是否可信。
2. 次优先：网卡白名单全不命中静默返回空（发现 3）、`probe_snmpDevices` 重名不报错（发现 4）、远端设备端口只留首个（发现 5）——都是“没数据也不报错”，排查成本高。
3. 编译面：`AgentSettings` 的 Windows 分支缺 `std.env` import（发现 6，待 Windows 目标确认），Linux 侧不受影响。
4. 维护面：SNMP walk 解析两份实现已出现引号/前导点漂移（发现 7），加上 `hasWhitespace/hasShellMeta`、字符白名单、时间换算、默认端口的多处复制，是本模块后续最容易产生行为分歧的地方。

本部分**无严重问题**；发现均为存量，默认只报不修，是否纳入修复请用户决定。性能与内存部分无任何基线数据，优化方案全部标为“无基线”，不得进 `tasks.md`。

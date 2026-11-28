# fprobe 模块审查报告（第 4/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe/src/collect/{hw,proc,net,health}`（本部分 20 个源文件；本部分无 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源为「存量」
- **审查重点**：采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并为 `fprobe_v2.md`；与同日抽样版 `<module>.md` 无覆盖关系）

## 发现

> 编号索引（正文与「覆盖自检」用 F 编号引用）：F1 SMART 缺 `smart_status`→FAILED｜F2 `df -Pi` 的 `-` 导致整项失败｜F3 磁盘基线残留｜F4 TCP 域名/IPv6 恒不可达｜F5 connect 异常泄漏 socket｜F6 硬件采集串行｜F7 命令输出无上限｜F8 IPMI 单位/数值｜F9 参数白名单缺口｜F10 死代码｜F11 重复逻辑（跨包）｜F12 重复逻辑（DiskProbe 内）｜F13 静默吞 terminate 失败。

### [一般] SMART JSON 缺 `smart_status` 时被上报为 FAILED（假告警）

- **位置**：`fprobe/src/collect/hw/SmartProbe.cj:57`（`SmartctlSmartStatus.passed = false` 默认值）、`fprobe/src/collect/hw/SmartProbe.cj:166`（`fromJson` 把 `passed` 直接映射 PASSED/FAILED）
- **来源**：存量（快照模式，无 diff 可比）
- **判据**：review-checklist §11（语义与命名 / 注释不符、错误处理缺失）+ §13 契约一致性
- **证据**：静态确定 —— `DataObject.populate` 只按 **源 JSON 里出现的字段** 调用 `set`（`f_data/src/base/DataObject.cj:194-207`），缺失字段保留类型默认值 `false`；`fromJson` 不区分「字段不存在」与「字段为 false」，也不看 `available`。
- **描述**：`smartctl -A -j` 在设备不支持 SMART、USB/SATA 桥接、部分虚拟盘上不会输出 `smart_status`，但退出码为 0。此时 `parseJson` 成功、`available=true`、`error=""`，`health` 却是 `FAILED`，形成磁盘健康假告警。同一文件文本回退路径（`parseText`）在 health 缺失时留空串，两条路径对「未知」的表达不一致。
- **建议**：把 `SmartctlSmartStatus` 字段改为可空（`?SmartctlSmartStatus`，缺字段即 `None`），`fromJson` 在 `None` 时输出 `UNKNOWN` 并保持 `available=true`，或额外返回 `statusKnown: Bool`；同时与文本路径的「未知」表达统一。

### [一般] `df -Pi` 的 IUse% 为 `-` 时整个 `disk` 项采集失败，且排除过滤救不回来

- **位置**：`fprobe/src/collect/proc/DiskProbe.cj:302`（inode 行 `requireInt/requirePercent`）、`fprobe/src/collect/proc/DiskProbe.cj:315`（`requirePercent`）；排除过滤在解析之后才执行（`fprobe/src/collect/proc/DiskProbe.cj:186-189`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 空值未处理、错误处理缺失）
- **证据**：静态确定 —— `requirePercent` 只接受可被 `Float64.tryParse` 解析的串，`"-"` 直接抛 `ProbeException`；`parseInodeDf` 在 `mergeMounts` 之前调用，`probe_diskExcludeFs` 的过滤发生在解析之后，无法避免该行。触发面（哪些文件系统的 `df -i` 打印 `-`，如 vfat/exFAT 这类无 inode 统计的挂载）需实测确认。
- **描述**：一旦主机存在一个 inode 统计不可用的挂载点，`parseInodeDf` 抛 `COLLECT`，`disk` 监控项整项进 error（`ProbeRunner` 保留上一帧），mounts 与 devices 全部不再更新。这是「一行合法但特殊的输出 → 丢整项指标」，与同文件 `parseSpaceDf` 的 fail-fast 用例（针对垃圾输入）不是同一类。
- **建议**：把 `-`（以及空串）视为「该挂载点无 inode 信息」，`DfInodeRow` 用可空字段或 `inodes=0` 表示，`mergeMounts` 已有的 `case None` 分支（`:376-378`）可直接复用；仅对真正无法解析的行 fail-fast。

### [一般] 磁盘消失后 `previous` 基线残留，重新出现时 IOPS/await 按单区间放大

- **位置**：`fprobe/src/collect/proc/DiskProbe.cj:163`（`previous` 只增不减）、`fprobe/src/collect/proc/DiskProbe.cj:228-251`（差分与写回）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 语义与命名不符）、§5（无界容器，长期持有）
- **证据**：静态确定 —— 每帧只遍历 `counters`，从不删除 `previous` 中不在本帧的键；`elapsed` 取全局 `lastNowMs`（`:217-221`），不含设备缺席时长。
- **描述**：设备（USB 盘、`loopN`、容器 `dm-*`）消失若干帧后重新出现时，`current - last` 累积了缺席期间的全部计数，却除以本帧的 `elapsed`（默认 5s）⇒ `readIops/writeIops/utilPercent` 被放大数倍到数十倍，`awaitMs` 也失真，容易触发磁盘 IO 告警。同时这些残留条目永不清理，属于慢速无界增长（每条约 100–200 字节，设备频繁增删的宿主机长期运行会积累）。
- **建议**：每帧结束后剔除本帧未出现的键（或给 `DeviceCounters` 加 `seenAt`，间隔超过 2×`intervalMs` 时按首帧处理）；写回 `previous` 时同时记录该设备自己的采样时刻。

### [一般] TCP 探针不做域名解析，域名/IPv6 目标恒报「不可达」

- **位置**：`fprobe/src/collect/net/TcpProbe.cj:46`（`IPSocketAddress(host, port)`）、`fprobe/src/collect/net/ServiceReachabilityProbe.cj:116`（把 `parseTarget` 解析出的 host 原样传入）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§10（边界 / 外部输入）
- **证据**：静态确定 —— `std.net` 文档 `net_package_api/net_package_classes.md:1602-1617`：`IPSocketAddress(address: String, port)` 的 `address` 必须是 **IP 地址字符串**，非法即抛 `IllegalFormatException`；`TcpSocket` 不做名称解析。`parseTarget`（`ServiceReachabilityProbe.cj:138-185`）对 host 不做任何 IP 校验。
- **描述**：`probe_serviceTargets='db@tcp://db.internal:3306'` 这类配置会稳定得到 `reachable=false, error="连接失败: ..."`，把「服务不可达」误报为故障；`[::1]:8080` 形式（`splitAuthority` 用 `lastIndexOf(':')`，host 带方括号）同样解析失败。README 示例用的是 `127.0.0.1`，所以问题只在用域名/IPv6 时暴露（触发面待确认，机制静态确定）。
- **建议**：先用 `IPAddress.resolve(domain)`（`net_package_api/net_package_classes.md:210-238`）解析出地址再建 `IPSocketAddress`，或在 `parseTarget` 阶段就把 host 归一化为 IP 并给出明确错误；IPv6 去掉方括号后传入。

### [一般] `connect` 抛异常时 socket 未关闭（异常路径资源不释放）

- **位置**：`fprobe/src/collect/net/TcpProbe.cj:45-52`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称：打开未关）
- **证据**：静态确定 —— `socket` 在 `try` 块内构造，`close()` 只在成功路径（`:48`）执行；`catch` 分支（`:50-52`）无法访问该局部变量。`Resource` 接口只在 `try-with-resource` 上下文自动释放（`core_package_interfaces.md:1343-1354`），这里没有使用。
- **描述**：连接被拒绝、超时、地址非法时每次探测泄漏一个 fd，直到 GC 回收（文档不保证 GC 关闭）。`probe_serviceTargets` 里被墙/宕机的 TCP 目标每轮都会走到异常分支，长跑会持续抬高 fd 占用。
- **建议**：改用 `try (socket = TcpSocket(...)) { ... }`（`Resource` + try-with-resource），或在 `catch` 前把 socket 提到块外并在 `finally` 关闭。

### [一般] 硬件探针串行执行外部命令，单轮耗时随设备数×超时线性叠加

- **位置**：`fprobe/src/collect/hw/HardwareProbe.cj:55-61`（三个子采集器顺序调用）、`fprobe/src/collect/hw/SmartProbe.cj:100-106`（逐设备 `collectDevice`）、`fprobe/src/collect/hw/SnmpProbe.cj:79-101`（逐设备 `runner.run`）
- **来源**：存量
- **判据**：review-checklist §6.3（并发串行：批内逐个等待）、§5（有界性）
- **证据**：静态确定 —— 三处都是普通 `for` 循环里同步 `run(...)`，每次最多阻塞 `timeoutMs`（默认 `commandTimeoutMs=3000`，README:151/525）。最坏一轮 = `(1 + N_smart + M_snmp) × 3000ms`；10 块盘 + 5 台 SNMP 设备即 48s，而默认 `intervalMs=5000`。
- **描述**：`ProbeRunner.tick()` 是单线程串行遍历探针（`fprobe/src/collect/ProbeRunner.cj:77-100`），`AgentRuntime` 的采集循环是 `tick()` 之后才 `clock.wait(intervalMs)`（`fprobe/src/runtime/AgentRuntime.cj:92-95`）。因此一台工具卡住会把整轮采集（含 cpu/memory 等快探针）推到 3s 的整数倍，快照间隔被拉长、告警窗口被吃掉；`smartctl` 在坏盘上卡满超时是常见现象。
- **建议**：对 `SmartProbe`/`SnmpProbe` 内设备级采集使用有界并发（固定窗口 + 先提交后统一 `get`，窗口 = 核数或配置项），或在 `HardwareProbe` 层把 ipmi/snmp/smart 三路并发；同时给单轮总预算（超预算即返回已完成部分并标 `error`）。

### [一般] 外部命令输出全量读入且无上限，SNMP 对端可放大内存

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:71-76`（`waitOutput()` 一次性返回 stdout/stderr）、`fprobe/src/collect/hw/SnmpProbe.cj:123-146`（`split("\n")` + 每条建 `SnmpReading`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化、无拒绝路径）
- **证据**：静态确定 —— 读取侧没有任何字节上限；`String.fromUtf8(stdout)` 再复制一份，`split` 生成整行数组，`parseWalk` 再为每行建对象，峰值约为原始输出的 2–3 倍。触发规模需实测（受 3s 超时约束）。
- **描述**：`ipmitool`/`df`/`smartctl` 是本机可信工具，但 `snmpbulkwalk` 的输出由远端设备决定：恶意/异常 agent 返回超大 OID 表时，3s 内即可读入数十 MB 并放大数倍，fprobe 常驻进程（还会跑 TUI/告警）可能 OOM。
- **建议**：给 `CommandRunner` 增加输出上限（如 4 MiB，超限截断并置 `error`/`timedOut=false` 的显式错误位），或改为分块读取 + 边读边解析；`parseWalk` 亦可对行数设上限。

### [一般] IPMI 读数单位与数值语义错误：华氏被标成摄氏、离散量填 0

- **位置**：`fprobe/src/collect/hw/IpmiProbe.cj:127`（`normalizeUnit` 把任何含 `degree` 的单位映射为 `C`）、`fprobe/src/collect/hw/IpmiProbe.cj:113-122`（非数字读数按 `0.0` 保留）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名 / 注释不符、数值错误）、§13（单位契约）
- **证据**：静态确定 —— `lower.contains("degree")` 同时命中 `degrees C` 与 `degrees F`，返回值恒为 `"C"`，数值原样保留；`classifySensor` 因此把华氏传感器归为 `Temperature`。`tryFloat("0x01")` 为 `None` 时，`Power Supply` 分支写入 `0.0` 且 `available=true`。
- **描述**：某传感器输出 `150 degrees F`（≈65.6°C）时上报 `value=150, unit="C"`，直接触发过温告警；`PS1 Status | 0x01` 这类离散量上报 `value=0`，若告警规则含「电源值 ≤0」则误报。规格要求包含电源传感器（`IpmiProbe.cj:47-52`），但离散量没有「无连续值」的表达。
- **建议**：`normalizeUnit` 区分 `degree(s) c` 与 `degree(s) f`，华氏按 `(v-32)*5/9` 换算后统一为 `C`（或保留 `F` 并在字段上体现）；离散量用 `value` 可空 / `unit="discrete"` 表示，不要用 0 冒充读数。

### [轻微] 外部命令参数白名单有缺口：`-` 开头可当选项、`..` 可逃出 `/dev`

- **位置**：`fprobe/src/collect/hw/SnmpProbe.cj:110-121`（只拒空白与 shell 元字符）、`fprobe/src/collect/hw/SmartProbe.cj:221-238`（`..` 与 `/` 都在允许集合内）、同源校验 `fprobe/src/config/Validation.cj:188-190`、`:216-234`
- **来源**：存量
- **判据**：review-checklist §10（安全性：外部输入未校验）、§11（注释承诺 A、实现做 B）
- **证据**：静态确定 —— `unsafeReason` 未检查首字符 `-`，`argv[4]` 会被 `snmpbulkwalk` 当选项解析（如 `host="-V"`、`community="-m"`）；`isSafeDevice` 允许 `.` 与 `/` 的任意组合，注释与 README/错误文案却写「只允许 /dev/ 下的字母、数字与 ._-/」。
- **描述**：两处都不会造成 shell 注入（参数数组直传、无空白），但选项注入能改变工具行为（输出格式、协议版本、甚至 `-e` 引擎 ID），`/dev/../../etc/xxx` 也会被当成「合法设备路径」交给 `smartctl`。
- **建议**：拒绝首字符 `-`（或统一加 `--` 结束符）；`isSafeDevice` 额外拒绝包含 `..` 的路径段（按 `/` 切段后判 `..`/`.`），并让注释与实现一致。

### [轻微] 死代码：`SmartctlDeviceInfo` / `SmartctlReport.device` 从未读取，`DiskProbe` 有未使用 import

- **位置**：`fprobe/src/collect/hw/SmartProbe.cj:49-54`（`SmartctlDeviceInfo`）、`fprobe/src/collect/hw/SmartProbe.cj:72`（`SmartctlReport.device`）、`fprobe/src/collect/proc/DiskProbe.cj:23`（`import ... {CommandRunner, CommandResult}`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 未使用的 import；非公共顶级声明里的成员无使用）
- **证据**：静态确定 —— 全仓 `grep SmartctlDeviceInfo` 只命中定义与 `SmartctlReport.device` 的字段声明；`report.device` 在 `fromJson`/`collectDevice` 中无任何读取（`device` 参数来自配置）。`CommandResult` 在 `DiskProbe.cj` 只出现在 import 行，函数体内类型由 `runner.run` 推断。
- **描述**：`DataAssist` 的 `SILENCE` 策略会忽略未声明字段，删除这两个声明不影响 JSON 解析与上报；`device` 字段的 JSON 子结构本来就没被使用（模型/健康/温度都在顶层的 `model_name`/`smart_status`/`temperature`）。
- **建议**：删除 `SmartctlDeviceInfo` 与 `SmartctlReport.device`（保留 `model_name/smart_status/temperature`），删除 `CommandResult` import。

### [轻微] 重复逻辑（1）：同一套文本/校验工具在 `collect/hw`、`collect/proc`、`config` 各写一遍

- **位置**：`fprobe/src/collect/hw/HardwareParsing.cj:22` ≡ `fprobe/src/collect/proc/ProbeParsing.cj:26`（`splitTokens` / `splitWhitespace`）；`HardwareParsing.cj:34` ≡ `ProbeParsing.cj:38`（`joinTokens` / `joinFrom`）；`HardwareParsing.cj:52` ≡ `fprobe/src/config/Validation.cj:271`（`hasWhitespace`）；`HardwareParsing.cj:57` ≡ `Validation.cj:276`（`hasShellMeta`）；`fprobe/src/collect/hw/SmartProbe.cj:221-238` ≡ `Validation.cj:216-234`（`isSafeDevice` / `isSafeDevicePath`）；`TcpProbe.cj:56-58` ≡ `fprobe/src/collect/health/RpcHealthTransport.cj:103-105`（`elapsedMillis`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件/跨层复制，只改类型名或文件位置）
- **证据**：静态确定 —— 逐行比对 6 组函数体，唯一差异是函数名与包名；`splitTokens` 与 `splitWhitespace` 连「按 `" "` 切分 + `trimAscii` + 丢空」的实现与注释都一致，`hasShellMeta` 的字符集合完全一致。
- **描述**：同一规则已有 2–3 份副本，任一处收紧（例如补 `-` 前导校验、补 `..` 判断）都会漂移：`Validation.cj` 与 `SmartProbe.cj` 现在就各自漏了同一类路径校验，`hasShellMeta` 在两个包里的字符集合同步维护。
- **建议**：把 `splitTokens`/`joinTokens`/`hasWhitespace`/`hasShellMeta`/`isSafeDevicePath`/`elapsedMillis` 收敛到模块内共享包（建议 `fprobe/src/collect/TextParsing.cj`，`package fountain::fprobe.collect`，`proc`/`hw` 均已是其子包），`config` 与 `health` 改为引用；合并时保留现有签名，行为不变（需附「含空格挂载点」「含 `\t` 参数」两类等价用例）。

### [轻微] 重复逻辑（2）：`DiskProbe` 内 `df -Pk`/`df -Pi` 行解析与整数校验各写一份

- **位置**：`fprobe/src/collect/proc/DiskProbe.cj:260-282`（`parseSpaceDf`）vs `:284-306`（`parseInodeDf`）；`:308-313`（`requireInt`）vs `:403-409`（`requireStat`）
- **来源**：存量
- **判据**：review-checklist §2（同文件内输入-输出-副作用相同的实现）
- **证据**：静态确定 —— 两个 `parse*Df` 的「跳过空行 → 首行 `Filesystem` 表头判断 → `splitWhitespace` → `size < 6` 抛错 → 列解析」逐句一致，差异只有结构体类型、`source` 列是否保留与错误文案里的 `-Pk`/`-Pi`；`requireInt` 与 `requireStat` 都是「`tryInt64` 成功取值、失败抛 `COLLECT`」，只差消息前缀。
- **描述**：列索引与表头判定被复制两份，`df` 输出格式变化（例如新增列、`-` 占位）需要同步改两处；本次 F2 的 `-` 处理缺失也出现在其中一份里（`df -Pi`），另一份（`df -Pk`）没有同类占位符，属于「近似重复导致边界漂移」。
- **建议**：抽一个 `parseDfRows(text, label, withSource) -> Array<DfRow>`（`DfRow` 已具备 `source`，inode 行可置空串），两个调用点只传 `-Pk`/`-Pi`；`requireStat` 合并进 `requireInt(token, label)`，消息由调用方拼。

### [轻微] 超时路径静默忽略 `terminate` 失败，可能残留子进程与等待线程

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:77-84`（`catch (_: Exception) { () }`）
- **来源**：存量
- **判据**：review-checklist §3（`catch {}` 静默吞异常）
- **证据**：静态确定 —— `process.terminate(force: true)` 失败被完全丢弃，函数直接返回 `timedOut=true`，`spawn {=> process.waitOutput() }` 的线程与子进程没有任何后续处置。
- **描述**：`terminate` 失败（权限、进程已进入不可中断状态）时，子进程继续运行、等待线程被占用，下一轮又起新进程；`hardware` 每轮固定起 3 个以上进程，长时间会积累。
- **建议**：`terminate` 失败时写入 `CommandResult.error`（供上层标记降级），并记录一次告警日志；或对 `pending` 增加超时后的补偿等待/取消路径。

> 存量 13 条（严重 0 / 一般 8 / 轻微 5），是否纳入修复待用户决定。

## 优化可行性方案

### [CPU] 硬件探针设备级采集有界并发化

- **现状**：`SmartProbe.collect` 与 `SnmpProbe.collect` 对每个设备同步 `runner.run`，最坏 `(1+N+M)×3s`；设备数由 `probe_smartDevices`/`probe_snmpDevices` 配置决定（默认 0–数块盘）。
- **方案**：固定窗口并发（窗口 = `min(设备数, 4)`），先提交全部任务再统一 `get`，总预算 = `commandTimeoutMs`；单个失败仍按现有 `available=false` 语义记录。
- **预期**：最坏单轮从 `(1+N+M)×3s` 降到约 `3s × ceil((1+N+M)/4)`；不改变单设备结果。
- **代价**：同时最多 4 个子进程（fd/内存小幅上升），需要线程池或 `spawn` + 有界信号量；顺序不再稳定（结果按设备索引回填即可保持输出顺序）。
- **验证**：`cjpm bench` 无法覆盖外部命令，用分段计时：固定 8 个设备（其中 2 个注入 3s 超时），对比改前/改后单轮耗时的中位数与 P95，`-O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `RpcHealthTransport` 每次探测重建 `f_net.Client`

- **现状**：每个目标每次采集都 `Client.builder(...).build()`（带 30s 检查周期与 ping 检查器线程），用完 `close()`；`probe_rpcHealthTargets` 有几个目标就建几条连接。
- **方案**：按 `NodeEndpoint` 缓存长连接（含 `close` 时的统一回收），失败时重建；或把健康调用改走已有的 `RPCClient` 但显式指定目标。
- **预期**：省掉握手 + 每轮线程创建/销毁；具体收益需分段计时（建链 vs `transfer`）。
- **代价**：长连接需要失效检测与重连（现有 `checkDuration` 可复用），并新增「agent 停止时关闭全部缓存连接」的清理点。
- **验证**：5 个目标、5s 间隔跑 10 分钟，对比每轮 `call` 耗时中位数与线程数峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CpuProbe` 对 `/proc/stat` 两次全量切分

- **现状**：`data` 里 `parseAggregate(stat)` 与 `countCores(stat)` 各 `split("\n")` 一次并逐行 `splitWhitespace`（`CpuProbe.cj:71-75`、`:109-172`），每 tick 两遍 O(行数)。
- **方案**：单趟遍历同时累计汇总行与核数，返回 `(total, idle, iowait, cores)`。
- **预期**：字符串切分与临时 `ArrayList` 分配减半（每 tick 少一次整文件 split + N 次行 split）；绝对收益取决于 `/proc/stat` 行数（核数×1 行）。
- **代价**：低（一个函数合并，语义不变）。
- **验证**：`cjprof record` 跑 1s 间隔 10 分钟，看 `parseAggregate`/`countCores` 自耗时占比；若合计 <1% 则不做。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 给外部命令输出加硬上限并复用读取缓冲

- **现状**：每次 `run` 由 `waitOutput()` 返回完整 stdout/stderr 字节数组，随后 `String.fromUtf8` 复制、`split("\n")` 再物化整行数组（`CommandRunner.cj:71-76`、`SnmpProbe.cj:125`）；上限只受 3s 超时约束。
- **方案**：`CommandRunner` 增加 `maxOutputBytes`（默认 4 MiB）：读取到上限即截断并返回 `error="输出超过上限"`；`SnmpProbe`/`SmartProbe` 对截断结果降级为 `available=false`，不解析半行。
- **预期**：把单次命令的峰值内存从「对端可控」变为常量级（≤2×4 MiB + 行数组）。
- **代价**：极端情况下（合法的超大 `snmpbulkwalk` 表）会截断数据，需要配置项与文档说明。
- **验证**：构造 8 MiB 假输出各跑 100 次，对比 `getAllocatedHeapSize()` 峰值与 RSS；同时确认 4 MiB 内的正常输出结果不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 硬件探针单轮耗时被外部命令主导（串行），是采集间隔拉长的主因 | `SmartProbe.cj:100-106` / `SnmpProbe.cj:79-101` | 单轮 `ipmi/snmp/smart` 各自耗时与占比 | 分段计时（每设备起止时间戳），配 8 块盘 + 2 个 SNMP 设备跑 30 分钟，给中位数/P95 |
| 2 | 每目标重建 `Client` 的建链开销占 `rpc-health` 主要耗时 | `RpcHealthTransport.cj:57-62` | 建链 vs `transfer` 分段耗时 | 在 `build()` 前后与 `transfer` 前后打点，5 目标 × 10 分钟 |
| 3 | `CpuProbe` 双次解析 `/proc/stat` 的 CPU 占比可忽略 | `CpuProbe.cj:71-75` | `cjprof` self time 占比 | `cjprof record` 1s 间隔 10 分钟，看 `parseAggregate`/`countCores` |
| 4 | 首帧 200ms 差分窗口使 `disk` IOPS 抖动明显大于稳态 | `DiskProbe.cj:216-221` + `ProbeRunner.cj:63-74` | 首帧与稳态 IOPS 分布 | 同一负载下连跑 20 轮，对比首帧与后续帧的 IOPS 均值/方差 |
| 5 | 每 tick 两次 `df`（`-Pk`/`-Pi`）的 fork/exec 开销可被单次 `df` + 解析合并抵消 | `DiskProbe.cj:184-185` | 两次命令耗时与比例 | 分段计时，统计 `df` 占 `disk` 项耗时比例；注意 `df -Pk`/`-Pi` 列不同，合并需 `-P` 一次取全字段并实测兼容性 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/src/collect/health/RpcHealthProbe_test.cj` | .cj | ✅ | 用例覆盖 ERROR/RESP/None 三条映射，无断言缺口 |
| 2 | `fprobe/src/collect/health/RpcHealthTransport.cj` | .cj | ✅ | 见 F4 关联（`elapsedMillis` 重复）、O2 |
| 3 | `fprobe/src/collect/hw/CommandRunner.cj` | .cj | ✅ | 见 F7、F13、F11 |
| 4 | `fprobe/src/collect/hw/CommandRunner_test.cj` | .cj | ✅ | 依赖 `/bin/echo|false|sleep`，Linux/WSL 环境下有效 |
| 5 | `fprobe/src/collect/hw/HardwareParsing.cj` | .cj | ✅ | 见 F11（与 proc/config 重复） |
| 6 | `fprobe/src/collect/hw/HardwareProbe.cj` | .cj | ✅ | 见 F6 |
| 7 | `fprobe/src/collect/hw/HardwareProbe_test.cj` | .cj | ✅ | 三路聚合与降级用例齐全 |
| 8 | `fprobe/src/collect/hw/IpmiProbe.cj` | .cj | ✅ | 见 F8 |
| 9 | `fprobe/src/collect/hw/IpmiProbe_test.cj` | .cj | ✅ | 未覆盖 `degrees F` 与离散量 0（F8 缺用例） |
| 10 | `fprobe/src/collect/hw/SmartProbe.cj` | .cj | ✅ | 见 F1、F10、F11 |
| 11 | `fprobe/src/collect/hw/SmartProbe_test.cj` | .cj | ✅ | 未覆盖「JSON 无 smart_status」分支（F1 缺用例） |
| 12 | `fprobe/src/collect/hw/SnmpProbe.cj` | .cj | ✅ | 见 F6/F7/F9/F11 |
| 13 | `fprobe/src/collect/hw/SnmpProbe_test.cj` | .cj | ✅ | 未覆盖 `-` 开头 host（F9 缺用例） |
| 14 | `fprobe/src/collect/net/ServiceReachabilityProbe.cj` | .cj | ✅ | 见 F4；`parseTarget` 边界已逐条核对（IPv6/端口越界/空 authority） |
| 15 | `fprobe/src/collect/net/ServiceReachabilityProbe_test.cj` | .cj | ✅ | 本地监听端口用例通过；`refusedPortIsUnreachable` 依赖端口 1 无监听者 |
| 16 | `fprobe/src/collect/net/TcpProbe.cj` | .cj | ✅ | 见 F4、F5 |
| 17 | `fprobe/src/collect/proc/CpuProbe.cj` | .cj | ✅ | 见 O3；`requireFile` 被 4 个探针复用 |
| 18 | `fprobe/src/collect/proc/CpuProbe_test.cj` | .cj | ✅ | 差分公式与核数断言正确 |
| 19 | `fprobe/src/collect/proc/DiskProbe.cj` | .cj | ✅ | 见 F2、F3、F10、F12 |
| 20 | `fprobe/src/collect/proc/DiskProbe_test.cj` | .cj | ✅ | 覆盖首帧 0 值、挂载点含空格；未覆盖 `IUse%="-"`（F2 缺用例） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：F1（健康状态映射）、F2（`-` 占位符）、F3（差分基线）、F4（地址解析）、F5（异常路径资源）、F8（单位/数值）；安全性：F9。设计/可读性无独立命中（`requireFile` 放在 `CpuProbe.cj` 但被 4 个探针共用，属共享 helper 落点问题，收益低，记此一句不作发现） |
| §1 死代码 | 1 | 已对 20 个文件逐个扫：每个 `private` 符号全仓搜、每个 `internal` 符号搜本包及子包、`public` 先判对外可达性（`HardwareProbe`/`DiskProbe`/`CpuProbe`/`SnmpDevice`/`CommandRunner` 等对外可达不判）；仅 F10 命中。`FixtureCommandRunner`/`Stub`/`Fake*` 属测试辅助，按硬原则一不作死代码 |
| §2 重复逻辑 | 2 | F11（6 组跨文件/跨包副本，逐行比对函数体后确认）、F12（同文件 2 组）。另两两比对了 `parseMountTypes`/`splitAuthority`/`authorityOf`/`valueAfterColon`/`oidName`/`stripQuotes`/`firstNumber`，输入-输出语义不同，不合并 |
| §3 空实现 | 1 | F13（`catch { () }` 吞掉 terminate 失败）。`SmartProbe.parseJson` 的 `catch → None` 有文本回退兜底，`IpmiProbe`/`SnmpProbe` 的 `case None => ()` 属可选分支，未计 |
| §4 栈溢出 | 0 | 本部分无递归：`parseSdr`/`parseWalk`/`parseMountTypes`/`parseDiskstats` 均为单层 `for`；唯一按结构深度递归的路径在 `f_data` 的 JSON 解析/转换，深度由 `smartctl -j` 的固定子结构决定（`SmartctlReport` ≤3 层），不成立 |
| §5 OOM | 1 | F7（命令输出无上限）；F3 的 `previous` 残留已在描述里量化（每条约 100–200 字节），不单列 |
| §6.1 热点瓶颈 | 0 | 本模块无 `cjprof`/`cjpm bench` 数据，按铁律不把「串行/重复解析」写成热点，全部进「待验证假设」#1–#5 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁对象，临界区讨论不适用 |
| §6.3 并发串行 | 1 | F6（设备级串行 + 单轮预算缺失），已给计算式 `(1+N+M)×timeout` |
| §6.4 低效算法 | 0 | 逐函数看了复杂度：解析均为单趟 O(行数)；`HashMap` 查找 O(1)；无 `remove(at: 0)`/循环内 `contains`/平方级拼接。`joinTokens` 的 `+=` 在 ≤10 元素规模上不构成 O(n²) 热点 |
| §7 降堆内存方案 | 1 | O4（命令输出上限 + 缓冲复用）；`clear()` 不还内存、`gc()` 不保证归还的口径已排除，不作为方案依据 |
| §8 降 CPU 方案 | 3 | O1（设备级有界并发）、O2（复用 Client）、O3（单趟解析 `/proc/stat`）；均为 `无基线` |
| §9 local mode 可行性 | 0 | 本部分热点函数（`parse*`/`collect*`）的临时对象随 `data` 返回值逃逸（`JsonObject`/`Array<Reading>` 直接返回或写入快照），不满足逃逸检查；且无峰值内存数据，无法证明收益 |
| §11 现有代码的 BUG（存量） | 8 | 逐函数核对了边界/空值/错误处理/资源/契约：F1、F2、F3（边界与基线）、F4（API 语义）、F5（资源）、F8（单位）、F9（校验缺口）、F13（静默吞异常）。`parseTarget` 的端口上下界、`authorityOf` 的 `/?#` 截断、`splitAuthority` 空端口默认值均核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 已定位唯一采集路径：`AgentRuntime.serve` 在主线程 `warmup()`+首帧 `tick()`，随后单线程 `spawn` 循环调用 `runner.tick()`（`AgentRuntime.cj:84-101`），`ProbeRunner.tick` 串行遍历探针（`ProbeRunner.cj:77-100`）⇒ `CpuProbe`/`DiskProbe` 的跨帧状态（`hasBaseline`/`last*`/`previous`）为线程封闭，无共享写者。注意：`ProbeAgent.data` 契约未声明非线程安全，若将来外部并发调用同一实例会产生数据竞争，建议在接口注释补一句（不单列发现） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 README/doc 文件；按 `fprobe/README.md:139-151` 的监控项表逐字段核对：`disk`/`cpu`/`hardware`/`service` 的字段名、来源、差分语义与实现一致；`ipmiEnabled`/`smartDevices`/`snmpDevices`/`serviceTargets` 均已在 `ProbeFactory.cj:44-67` 接线，无「注册但未使用」的配置项 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完；本部分不含 `.md`，§13 文档一致性无对象（相关承诺在 README，已在上行按需核对） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 8 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

## 总评

本部分代码整体结构清晰：探针「一个 kind 一个类」、失败按项降级（`available=false` + `error`）、外部命令参数数组直传并做空白/元字符过滤、每个 `.cj` 均带版权头，`FProcessRunner` 的超时与退出码语义也和测试对齐。没有发现严重级缺陷，也没有锁、共享可变集合或递归热路径。

主要风险集中在「外部输入形状假设过强」与「有状态采集的边界」两类：

1. **阻塞项（建议本轮就定级）**：F2 —— `df -Pi` 出现 `IUse%="-"`（vfat/exFAT 等无 inode 统计的挂载）时 `disk` 整项永久进 error。机制是静态确定的，但触发面需要在真实主机上确认；若确认常见，应升级为严重。F1（缺 `smart_status` → FAILED）同样会直接制造假告警，属于告警可信度问题。
2. **可排期**：F3（设备重插后 IOPS 放大）、F4/F5（域名目标恒不可达 + 失败即泄漏 fd）、F6（串行超时叠加拖长整轮采集）、F7（远端 SNMP 输出无上限）。这些都不会让进程崩溃，但会在长跑中累积成「数据不可信」或「句柄/内存缓慢上涨」。
3. **清理项**：F10 死代码、F11/F12 重复逻辑（6 组跨包副本 + 2 组同文件副本）成本低、风险低，建议与上述修复同批处理，避免下次修 `-`/`..` 校验时再漏一处。

所有性能类结论（设备级并发、复用 `Client`、单趟解析、输出上限）都缺改前基线，只写入「优化可行性方案 / 待验证假设」，未当作缺陷；`disk` 首帧 200ms 差分窗口导致的速率噪声也未定性，留待假设 #4 补数据。

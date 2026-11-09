# Tasks

> 每个任务按 Red-Green-Refactor：先写用例并确认因「功能未实现」失败，再写最小实现，`cjpm test` 跑绿才勾选。禁止在项目外建单文件测试；所有用例放在对应模块的 `src/**/*_test.cj`。

## 1. 模块骨架与登记

- [x] 1.1 新建 `f_probe/`：`cjpm.toml`（`output-type="dynamic"`、`src-dir="src"`、依赖 `f_base`/`f_data`、版本与仓库一致）、`src/`、`README.md`/`README_en.md` 占位；验证：`cd f_probe && cjpm build` 通过。
- [x] 1.2 新建 `fprobe/`：`cjpm.toml`（`output-type="executable"`、`src-dir=""`、`include=["src","doc"]`、Linux `-ldl`）、`src/main.cj`、`src/usage.cj`；验证：`cd fprobe && cjpm build` 生成可执行文件，`--help` 返回 0。
- [x] 1.3 `.modules` 的 `[include]` 增加 `f_probe`、`fprobe`；验证：根目录 `cjpm build` 仍通过，两个模块被纳入工作区。
- [x] 1.4 根 `README.md` 模块清单补两节（中英对应）；验证：与 `.modules` 条目一一对应。

## 2. `f_probe` 契约与注册表

- [x] 2.1 `ProbeAgent` 接口：`kind`、`host`（默认 `''`）、`data: JsonObject`；验证：用例实现只覆写 `kind`/`data`，断言 `host == ""`。
- [x] 2.2 `AlarmMessageChannel` 接口：三方法原样 + `sendRich` 默认退化为 `send`；验证：用例实现三方法，调用 `sendRich` 断言收到纯文本且附件被忽略。
- [x] 2.3 `ProbeException` + `ProbeErrorCode`（`DUPLICATE`/`CONFIG`/`LOAD`/`COLLECT`）；验证：四类构造断言错误码与消息包含对象名。
- [x] 2.4 `ProbeRegistry`：注册/枚举/查找/重名拒绝/并发；验证：4 条用例（正常、重复、多线程注册、查找不存在返回 None）。
- [x] 2.5 `AlarmChannelRegistry`：同构；验证：注册两个渠道、重复拒绝、并发注册。
- [x] 2.6 `f_probe/doc/contract.md`（接口语义、`kind` 稳定性、回复消息 JSON、错误码）与 `extension-guide.md`（实现 + 注册 + 构建 `.so` + 复制到 `custom/`）；验证：示例代码可编译（放入 `src/` 下的测试辅助或文档校验清单，不引入真实 `.so`）。

## 3. 入口分发与配置

- [x] 3.1 `dispatch(args)`：`agent` / `supervisor` / `supervisor resident` / `--help` / 未知命令返回 2；验证：注入假工厂，断言各分支返回码与调用次数（参照 `fmq/src/main.cj`）。
- [x] 3.2 `AgentSettings`：读取 `probe_*`，默认端口 12323、间隔 5000、custom 目录 `./custom`；验证：`Config.set` 覆盖后断言字段；端口 0/65536/非数字分别报错。
- [x] 3.3 `SupervisorSettings`：`probe_nodes` 解析为 `NodeEndpoint`，空值默认 `localhost@127.0.0.1:12323`；验证：合法多项、缺 `@`、端口非法、重复节点名各一条用例。
- [x] 3.4 配置校验聚合：一次返回全部错误而不是只报第一条；验证：同时给两个非法项，断言两条消息。
- [x] 3.5 agent 启动前把 `probe_port` 写入 `rpcServer_port`；验证：用例断言 `Config.getValue<UInt16>("rpcServer_port")` 等于配置端口。

## 4. 采集基础设施

- [x] 4.1 `ProcReader` 接口 + `FixtureProcReader`；验证：fixture 返回指定内容，读取不存在文件返回 None。
- [x] 4.2 `RealProcReader`（Linux）与 `UnsupportedProcReader`（非 Linux）；验证：非 Linux 分支返回 unsupported 的 `ProbeException`。
- [x] 4.3 `CommandRunner` + `FProcessRunner`：参数数组、超时、退出码、stdout/stderr；验证：假命令成功/非零退出/超时三态；含空白参数被拒绝。
- [x] 4.4 `IntervalCounter`：保存上次计数，按间隔算速率；间隔 0 返回 None；验证：3 条用例（正常、零间隔、计数回绕不产生负值）。
- [x] 4.5 `MetricProjection`：kind → 指标名 → `DataPath` + 聚合（first/max/sum/avg）+ 单位；验证：数组取 max、求和、空数组返回 None。

## 5. 内置探针

- [x] 5.1 `CpuProbe`：`/proc/stat` 差分 + `/proc/loadavg`；验证：fixture 两帧，断言 `usagePercent`、`iowaitPercent`、load1/5/15、cores。
- [x] 5.2 `MemoryProbe`：`/proc/meminfo`，`used = total - available`；验证：fixture 断言全部字段与 swap。
- [x] 5.3 `DiskProbe` 空间/inode：`df -Pk` + `df -Pi` 解析、按挂载点合并、`probe_diskExcludeFs` 过滤；验证：正常 fixture、带空格挂载点、坏输出、排除 tmpfs。
- [x] 5.4 `DiskProbe` I/O：`/proc/diskstats` 差分；验证：两帧 fixture，断言 readBytes/writeBytes/readIops/writeIops/awaitMs/utilPercent。
- [x] 5.5 `SystemProbe`：`/proc/uptime`、进程目录计数、`/proc/net/tcp` + `tcp6`；验证：fixture 断言 uptime、processCount、tcpConnections。
- [x] 5.6 `IpmiProbe` / `SnmpProbe` / `SmartProbe`：命令模板、JSON/文本解析、工具缺失降级；验证：假 runner 覆盖成功、非零退出、ENOENT、超时；`smartctl` JSON 与文本各一条。
- [x] 5.7 `NetworkProbe`：`/proc/net/dev` 差分、`/sys/class/net/<if>/speed`、`/proc/net/snmp` 重传率；验证：两帧 fixture，断言速率、带宽占比、drop/error/retrans 百分比；白名单过滤。
- [x] 5.8 `MvcHealthProbe`：HTTP 200/500/超时；验证：假 `HttpProbe`，断言 `statusCode`、`latencyMs`、字段映射；不连外网。
- [x] 5.9 `RpcHealthProbe`：定向调用 `HealthRPC.health()`；验证：假传输返回 `HealthData`，断言字段与耗时；ERROR 响应映射为探针错误。
- [x] 5.10 `ServiceReachabilityProbe`：HTTP/HTTPS/TCP；验证：本地临时 TCP 监听测连通与拒绝；HTTP 用假 `HttpProbe` 测 200/500/超时。
- [x] 5.11 `TopologyProbe`：IF-MIB/LLDP-MIB walk 解析、邻接去重；验证：两份 walk 文本 fixture 生成设备与无向链路；空配置返回 `error`。

## 6. 采集运行与快照

- [x] 6.1 `ProbeRunner`：周期 tick、单探针异常隔离、失败保留上次成功数据；验证：假时钟 + 两个探针（一好一坏），断言快照字段。
- [x] 6.2 CPU 预热：首帧前做一次短差分；验证：假时钟推进 200ms，断言首个 `usagePercent` 非 0。
- [x] 6.3 `SnapshotStore`：整体替换、`collect()` 只读；验证：并发读写 100 次无异常，读到的快照字段自洽（node/host/timestamp 同批）。
- [x] 6.4 `ProbeSnapshotBuilder`：`dataJson` 为 `JsonValue.from(agent.data).toString()`；验证：往返 `JsonValue.fromStr` 后与原对象等价。

## 7. RPC 与定向传输

- [x] 7.1 `ProbeRPC` 接口 + `ProbeKinds` DTO；验证：接口可被 `@RPCStub` 展开（编译通过），DTO JSON 往返。
- [x] 7.2 `ProbeRPCImpl`（`@RPCSkeleton`）：`collect()` 读 `SnapshotStore`，`kinds()` 读注册表；验证：直接实例化调用，断言与 store 一致。
- [x] 7.3 `NodeRpcTransport`：每节点 `Client<RPCMessage>`、`ServiceMeta('*', ...)`、`Message.consume`、超时、RESP/ERROR 映射、失败重连；验证：假 `ClientTransport` 覆盖一次 collect、超时、ERROR、重连后成功。
- [x] 7.4 `ProbeSnapshot`/`ProbeAgentData`/`ProbeKinds` 的 RPC 编解码往返；验证：构造含中文与特殊字符的 `dataJson`，往返后逐字段相等。

## 8. 自定义扩展加载

- [x] 8.1 `CustomLoader.librariesOf`：目录不存在、只收 `.so/.dll/.dylib`、排序；验证：临时目录 3 个文件（含 README），断言结果顺序。
- [x] 8.2 `CustomLoader.load`：调用 `PackageInfo.load`（用可注入的 loader 函数替身）；验证：替身记录调用顺序；失败时 `failFast=true` 抛 `LOAD`，`false` 继续。
- [x] 8.3 重名拒绝：内置 `cpu` 先注册，扩展再注册同名；验证：抛 `DUPLICATE`，注册表仍指向内置工厂。

## 9. supervisor 拉取与历史

- [x] 9.1 `PollLoop`：每 tick 对每节点一次 collect；验证：假 transport 断言调用次数 = 节点数 × tick 数。
- [x] 9.2 节点失败计数与恢复：连续失败达 `probe_missingThreshold` 产生不可达事件，恢复产生恢复事件；验证：假 transport 按脚本返回成功/失败序列。
- [x] 9.3 `HistoryRing`：容量 60、追加、丢弃最旧；验证：61 次追加后首尾值符合预期。
- [x] 9.4 `NodeStateStore`：并发更新与读取；验证：2 个写线程 + 1 个读线程跑 1000 次无异常，最终状态为最后一次写入。
- [x] 9.5 渲染异常隔离：`PollLoop` 在告警评估抛错后仍继续下一 tick；验证：注入抛错的 alarm engine，断言 tick 计数继续增长。

## 10. 告警引擎

- [x] 10.1 `AlarmRule` DTO + `probe_alarmRules` 解析；验证：合法数组、非数组、缺字段、非法 op 各一条；非法时启动错误含序号。
- [x] 10.2 六种比较 + `DataPath` 取值；验证：表驱动用例覆盖 gt/gte/lt/lte/eq/ne 与嵌套路径。
- [x] 10.3 `forSeconds` 状态机；验证：假时钟推进 30s/60s，断言只在 60s 触发一次。
- [x] 10.4 冷却与恢复；验证：冷却内第二次命中不发送；恢复发送一次；冷却后再次命中视为新告警。
- [x] 10.5 数据缺失告警：节点失败、探针 error、缺 kind；验证：三类各一条，断言事件类型与描述。
- [x] 10.6 静音：`mute(rule, until)` 期间不发送，到期恢复；验证：假时钟跨越静音窗口。

## 11. 渠道与邮件

- [x] 11.1 `ChannelDispatcher`：多渠道路由、单渠道失败隔离、未知渠道启动失败；验证：假渠道一成功一抛错，断言成功者收到、日志记录失败。
- [x] 11.2 `EmailAlarmChannel.send`：HTML 告警横幅 + 表格 + 纯文本；验证：断言 HTML 含 `background`、节点名、规则名、当前值、阈值；文本含关键字段。
- [x] 11.3 恢复邮件：绿色横幅与「已恢复」；验证：断言颜色语义与标题。
- [x] 11.4 `sendRich`：HTML 正文 + 多个 `application/octet-stream`/`image/svg+xml` 附件；验证：假 `MailTransport` 记录附件名与媒体类型。
- [x] 11.5 `receive()`：列出最近邮件、取未读、正文映射、无消息返回空串；验证：假 transport 返回 2 封（1 未读），断言 JSON 字段；不连 IMAP。
- [x] 11.6 `replyConf()` 返回配置键；验证：断言值为 `probe_channel_email_replyAccount`。

## 12. `f_tui` 终端后端与登记

- [x] 12.1 新建 `f_tui/`：`cjpm.toml`（`output-type="dynamic"`、`src-dir=""`、依赖 `f_base` 与钉死版本的 `ratatui_core` / `ratatui_style` / `ratatui_text` / `ratatui_layout` / `ratatui_buffer`，**不含 `crossterm`、`ratatui_backend`、`ratatui_terminal`、`ratatui_widgets`**）、`src/`、`README.md`/`README_en.md` 占位；验证：`cd f_tui && cjpm build` 通过，直接依赖只有 `f_base` 与上述五个 ratatui 基础包。
- [x] 12.2 登记：`.modules` 的 `[include]` 增加 `f_tui`；根 `README.md` 模块清单补 `f_tui` 一节（中英对应）；验证：与 `.modules` 条目一致，根目录 `cjpm build` 仍通过。
- [x] 12.3 POSIX FFI 封装 `PosixFfi`：`termios` 结构体、`tcgetattr`/`tcsetattr`、`ioctl(TIOCGWINSZ)`、`read`/`write`、`isatty`、`SIGWINCH` 常量；验证：结构体布局与常量按目标平台编译期断言，用例只调用假实现，不触碰真实终端。
- [x] 12.4 `RawMode`：保存快照 → 进入 raw mode → 恢复；验证：假 `PosixFfi` 断言调用顺序，`restore()` 连续两次无额外调用。
- [x] 12.5 `TerminalSize`：`ioctl` 成功、失败回退、`0x0` 未知；验证：假 `SizeProvider` 与假 ioctl 各覆盖一态；窗口变化后重新读取。
- [x] 12.6 `AnsiRenderer` + `ScreenBuffer`：备用屏进出、光标显隐、清屏、SGR、差分帧；验证：假 `TerminalWriter` 断言序列与最小差异输出；中文宽字符占两列；控制字符被替换。
- [x] 12.7 `KeyReader` + `EscapeParser`：方向键、`Tab`、`Shift+Tab`、`q`/`r`/`a`、独立 `ESC`、UTF-8、拆包、超时/EOF；验证：假 `ByteSource` 表驱动，断言 `TerminalKey` 与未完成序列保留。
- [x] 12.8 `BufferRenderer`：接收 `ratatui_buffer.Buffer`，把单元格字符、前景/背景色与修饰符翻译为 ANSI，支持差分帧、`size`、`clear` 与光标；验证：构造含样式与中文的 `Buffer`，断言 ANSI 输出、差分只重写变化行、单次 flush；不实现 `ratatui_backend.Backend`。
- [x] 12.9 终端生命周期：初始化中途失败按逆序回滚、写 stdout 失败降级、`restore()` 幂等、`atExit` 覆盖正常/异常/信号；验证：注入失败的假 writer/假 ffi，断言状态与调用序列。
- [x] 12.10 `f_tui/doc/terminal-backend.md`：平台范围、raw mode/尺寸/按键/ANSI 契约、`TerminalKey` 映射表、测试替身用法；验证：文档中的接口签名与源码一致。

## 13. TUI 装配

- [x] 13.1 `ViewModel`：节点列表、选中、分页、`Tab`/`Shift+Tab`、`↑/↓`、`a` 告警页；验证：纯函数用例断言选中项与页索引。
- [x] 13.2 `RenderPlan`：由 ViewModel + store 生成顶部/左侧/右侧/底部区域；验证：断言行数、列数、Sparkline 数据长度 = 历史点数。
- [x] 13.3 `TtyDetector`：非 TTY 报错并提示 resident；验证：假 detector 返回 false，断言错误消息。
- [ ] 13.4 `FprobePainter`（基于 `f_tui::BufferRenderer`）：用 ratatui 基础类型构建 `Buffer`，自绘 panel、table、sparkline 最小组件，把 `RenderPlan` 映射为顶部/左/右/底一帧；验证：先跑通「进入 alternate screen → 绘制 → 退出恢复」冒烟；注入假 renderer 断言 Buffer 单元格、绘制调用与 flush 次数；依赖树无 `ratatui_widgets`。
- [x] 13.5 `KeyMap`：`q` 退出、`r` 刷新、`Tab`、`Shift+Tab`、方向键、`a`；验证：表驱动断言映射结果。
- [x] 13.6 渲染线程与拉取线程分离：渲染慢不影响拉取；验证：假 painter 睡眠 200ms，断言 tick 间隔仍符合配置（允许误差）。
- [ ] 13.7 `TtyKeySource`：把 `f_tui::TerminalKey` 映射为 `UiKey`；验证：表驱动覆盖全部 `TerminalKey` 分支，未知值落 `UiKey.Unknown`。
- [ ] 13.8 `SupervisorApp` 装配：TTY 模式下 `f_tui` backend `init/restore`、按键线程、非 TTY 拒绝；验证：假 backend 断言 `init`/`restore` 顺序与未调用次数；`q` 退出后 `restore` 被调用。

## 14. resident 模式

- [x] 14.1 `supervisor resident` 不初始化 TUI；验证：注入假 painter，断言 `painter.init` 未被调用。
- [x] 14.2 信号退出：`ExitCallbacks.toExitGracefully()` + `atExit` 停止 PollLoop、关闭连接；验证：假 signal 触发后 `running=false`，连接 close 被调用。
- [x] 14.3 日志是唯一输出；验证：捕获 stdout，断言没有 ANSI 控制序列。

## 15. 图表与报告

- [ ] 15.1 `ChartSelector`：默认类型、自定义类型、未知类型回退；验证：4 条用例（cpu/memory/disk/network + 未知）。
- [ ] 15.2 `ChartSpec` DTO → `JsonValue` → `Chart.draw`；验证：SVG 非空、可被 `f_svg.SvgParser.parse` 解析、`series[0].data` 点数 = 历史点数。
- [ ] 15.3 `ReportBuilder`：HTML 摘要（在线状态、告警统计、关键指标）+ 附件清单；验证：断言摘要包含节点名与「无数据」文案。
- [ ] 15.4 附件命名与清理：`<node>-<metric>.svg`、发送后临时目录删除；验证：临时目录中文件存在后被删除；节点名含 `/` 时被清洗。
- [ ] 15.5 `ReportJob`：CRON 为空不注册、非法 CRON 启动失败、`runOnce()` 生成并发送；验证：假 Ticktock 断言注册次数；假 dispatcher 断言收到报告。
- [ ] 15.6 `TopologyRenderer`：确定性布局、设备/链路 SVG；验证：同输入两次输出完全一致；空拓扑返回 None。

## 16. LLM 智能体

- [ ] 16.1 `PromptBuilder`：节点摘要 + 告警 + 最近 N 点；验证：断言提示词包含节点名、阈值、历史长度。
- [ ] 16.2 `AdviceParser`：合法 JSON、带 ```json 围栏、纯文本兜底；验证：3 条用例，断言 `summary/problems/solutions`。
- [ ] 16.3 `ProbeAdvisor`：开关关闭不调用 LLM；`alarm`/`interval`/`both` 触发；LLM 抛错不影响其它组件；验证：假 LLM 记录调用次数。
- [ ] 16.4 `ReplyMonitor`：逐渠道 receive、非法消息跳过、未授权固定回复；验证：假渠道返回未授权发件人，断言回复文案与不执行动作。
- [ ] 16.5 `ActionWhitelist`：`ack/mute/report/none` 执行，`restart-service` 不执行；验证：表驱动；`mute` 调用 alarm engine 并带 `probe_llmMuteSeconds`。
- [ ] 16.6 `ReplyStateStore`：已处理 id 落盘、重启不重复、文件损坏按空集合、最多 1000 条；验证：临时目录 4 条用例。

## 17. 文档

- [ ] 17.1 `fprobe/README.md` + `README_en.md`：能力、子命令、最小部署、systemd 示例、配置索引；验证：与 `--help` 输出逐项一致。
- [ ] 17.2 `fprobe/doc/configuration.md`：全部 `probe_*` 键、默认值、取值范围。
- [ ] 17.3 `fprobe/doc/alarm-rules.md`：规则 JSON、`path` 写法、`forSeconds`/冷却/恢复示例。
- [ ] 17.4 `fprobe/doc/tui.md`：布局、按键、非 TTY 处理、终端后端来自 `f_tui` 的说明。
- [ ] 17.5 `fprobe/doc/deployment.md`：agent/supervisor 的 systemd 单元、日志、扩展目录。
- [ ] 17.6 `fprobe/doc/rpc.md`：RPC 线协议表与最小客户端示例（`typeName`/方法/命令）。
- [ ] 17.7 `f_probe/README.md` + `README_en.md`、`doc/contract.md`、`doc/extension-guide.md`：契约、注册、回复消息格式、最小扩展。
- [ ] 17.8 `f_tui/README.md` + `README_en.md`、`doc/terminal-backend.md`：平台、能力边界、`TerminalKey`、`Buffer → ANSI` 渲染器、可测试接口。

## 18. 回归与冒烟

- [ ] 18.1 `cd f_probe && cjpm test` 全绿；验证：输出贴入交付说明。
- [ ] 18.2 `cd f_tui && cjpm test` 全绿；验证：输出贴入交付说明，且用例不要求真实 TTY。
- [ ] 18.3 `cd fprobe && cjpm test` 全绿；验证：同上。
- [ ] 18.4 回归 `f_rpc`、`f_email`、`f_chart`、`f_ticktock` 的 `cjpm test`；验证：四个模块均通过（本变更不改其源码）。
- [ ] 18.5 依赖校验：`fprobe` 与 `f_tui` 的依赖树中无 `crossterm`、`ratatui_backend`、`ratatui_terminal`、`ratatui_widgets`；验证：构建日志与依赖清单均无命中，若五个 ratatui 基础包任一传递引入则停下报告。
- [ ] 18.6 端到端冒烟（本机回环）：启动 `fprobe agent`（临时端口）→ 启动 `fprobe supervisor resident`（`probe_nodes` 指向该端口）→ 断言拉取成功、历史有点、告警规则命中并写入日志；验证：一条脚本化用例或手工记录，不依赖外网。
- [ ] 18.7 非 TTY 冒烟：`fprobe supervisor` 在重定向环境中报错并提示 resident；验证：退出码非 0，stderr 含提示。
- [ ] 18.8 终端恢复冒烟（人工）：交互模式进入后分别用 `q`、`Ctrl+C` 退出，确认光标、回显与 `stty -a` 状态恢复；验证：两次退出后终端行为一致，无残留 raw mode。

## Workflow follow-up

- `opsx:verify` 校验实现与 spec 场景逐条对应；`opsx:archive` 归档变更。
- 每次修改四份产物后，同步覆盖 `fprobe/doc/spec/add-fprobe/` 镜像，保证 proposal / design / specs / tasks 与 `openspec/changes/add-fprobe/` 完全一致。
- 提交拆分建议：`f_probe` 契约与注册表 → `f_tui` 终端后端 → agent 采集/RPC → supervisor 拉取/告警/渠道 → TUI 装配 → 报告 → LLM → 文档与登记；每个提交都必须带通过的单元测试。

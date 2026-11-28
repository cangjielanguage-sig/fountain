# fprobe 模块审查报告（第 9/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe/src/tui/**`、`fprobe/src/usage.cj`（本部分 13 个源文件，全部 `.cj`）
- **基线**：工作区快照（`git status` 对 `fprobe/src` 无改动；全部问题来源记「存量」）
- **审查重点**：采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑（本部分覆盖 TUI 组件、视图模型、TTY/按键适配、用法文本）
- **报告版本**：v1-part9（分部分报告，由主 Agent 合并进 `fprobe_v2.md`；文件覆盖 / 覆盖自检 / 模块统计只统计本部分）

## 发现

### [一般][存量] Sparkline 用整段序列的最大值归一化，离屏点会长期压平可见窗口

- **位置**：`fprobe/src/tui/widgets/Sparkline.cj:36-44`（max 计算）、`:49-54`（可见窗口裁剪）、`:57`（比值）
- **来源**：存量（工作区快照无基线；`git log` 该文件最后修改在 2026-11-09 的 TUI 装配提交）
- **判据**：review-checklist §11（边界 / 非有限值未处理；归一化口径与「窗口」语义不符）
- **证据**：静态确定 —— 只读代码即可确定 `maximum` 在裁剪之前对全部 `values` 求，且 `visible`/`start` 在之后才计算
- **描述**：`values` 是 `probe_historyPoints` 窗口（默认 60 点），实际可画宽度由调用方给出：80 列终端下右栏 inner 宽约 52（`FprobePainter.cj:143-159`），`paintSeries` 再预留 8 列标签 + 1 列间隔（`FprobePainter.cj:273-290`），sparkline 只剩约 43 格，即约 17 个点被裁掉。若被裁掉的旧点里有一个尖峰，`maximum` 仍按它归一化，之后每个可见帧的所有方块都贴近 `▁`，直到该尖峰滚出 60 点环形缓冲。这让「当前窗口的趋势」被判读为「几乎为零」。
  次要边界：全 NaN 时 `maximum` 保持 0 → 改成 1.0，`ratio` 为 NaN，`Int64(ratio * 7.0 + 0.5)`（`:64`）对 NaN 的转换结果仓颉文档未定义（本地文档 `cangjie-doc/md/doc/core.md:16` 只说明 Float 含 `NaN`，未定义 Float→Int 的 NaN 语义）；`+Inf` 时 `ratio = Inf/Inf = NaN`。作为对照，`fprobe/src/tui/ChartPanel.cj:44-53` 至少会剔除全 NaN 序列，Sparkline 完全没有非有限值判断。
- **建议**：先算 `start`/`visible`，只在 `[start, values.size)` 上求 max；用标准库的 `isNaN()` / `isInf()`（`cangjie-doc/.../core_package_intrinsics.md:1384`、`:1425`）过滤非有限值点（或整段跳过后按 0 绘制）；与 `ChartPanel` 的 NaN 策略保持一致。

### [一般][存量] usage 文本声称支持「配置文件」不存在，agent 帮助又漏列多节点必需的 `probe_hostId`

- **位置**：`fprobe/src/usage.cj:35`（配置文件）、`:46-52`（agent 关键配置项）
- **来源**：存量
- **判据**：review-checklist §13（配置源与源码不符）、§14.2（帮助文本未覆盖关键配置）
- **证据**：静态确定 —— `f_config` 的 `static init()` 只读环境变量与命令行（`f_config/src/Config.cj:62-89`），没有任何配置文件入口；`README.md:157` 明写「配置只来自两个地方」，`doc/configuration.md:3` 也只列 `--key=value` / `-key value` / 环境变量
- **描述**：`Usage.root()` 的「可通过配置文件、环境变量或 `--key=value` 传入」把不存在的配置源写进了帮助，用户会去找配置文件。另外 `probe_hostId` 要求集群内唯一、`0` 会被 `f_protocol` 拒绝（`README.md:180`、`doc/configuration.md:13`），`fprobe.sh` 会默认注入，但 `fprobe agent --help` / `fprobe supervisor --help` 都没列这一项；按帮助部署多节点时所有进程都会沿用默认值 1。
- **建议**：删除「配置文件」表述（或实现后再写）；agent / supervisor 两段帮助各加一行 `probe_hostId`（默认 1，多节点必须各不相同）。

### [轻微][存量] TTY 前置校验与 `f_tui` 的终端契约重复且不一致

- **位置**：`fprobe/src/tui/TtyDetector.cj:26-27`（`STDOUT_FILENO`）、`:34`（`isatty(1)`）、`:44-49`（`requireTty`）
- **来源**：存量
- **判据**：review-checklist §2（同一策略两处实现）、§10（绕过既有抽象层）、§11（错误路径文案不一致）
- **证据**：静态确定
- **描述**：
  1. `requireTty` 只检查 stdout（fd 1），而 `f_tui` 的 `Terminal.start()` 要求 stdin 与 stdout **都**是 TTY（`f_tui/src/render/Terminal.cj:111-112`），raw mode 与按键都走 stdin（同文件 `:95`、`:98`；`fprobe/src/tui/TtyKeySource.cj:90` 用 `STDIN_FILENO`）。`stdout` 是 TTY、stdin 被重定向（如 `fprobe supervisor < /dev/null`）时前置校验放行，随后抛 `standard input/output is not a tty`，日志变成 `TUI 初始化失败: ...`，既没有 `doc/tui.md:14` 承诺的「标准输出不是 TTY」，也没有 resident 指引。
  2. `TtyDetector.cj:27` 重新声明 `STDOUT_FILENO = 1`，而 `f_tui/src/term/PosixFfi.cj:21` 已公开同名常量（`FprobePainter.cj:22` 就是 import 用的）；同时直接调 `std.posix.isatty`，绕过 `doc/tui.md:62` 声明的「`isatty` 唯一出口」`PosixFfi.isTty`（`PosixFfi.cj:221-223`）。
- **建议**：`requireTty` 改为同时检查 in/out（或直接复用 `Terminal.start()` 的前置判断并把 `TuiException` 翻译成带 resident 指引的 `ProbeException`）；常量改为 import `f_tui` 的 `STDOUT_FILENO`；TTY 判定走 `PosixFfi.isTty`。

### [轻微][存量] 图表最小高度 8 在同包与 `f_chart` 各写一份

- **位置**：`fprobe/src/tui/TuiLayout.cj:26`（`MIN_CHART_HEIGHT = 8`）vs `fprobe/src/tui/ChartPanel.cj:31`（`MIN_HEIGHT = 8`）；`f_chart/src/tui/TuiFrame.cj:71` 又硬编码 `height < 8.0 || width < 20.0`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换算复制）
- **证据**：静态确定 —— 同包两个类各声明一份「图表最小高度」，`ChartPanel.chartJson`（`:41`）还独立用 `MIN_WIDTH`、`MIN_HEIGHT` 再判一次
- **描述**：回退策略（高度 < 8 不画多行图）由 `TuiLayout.chartHeight` 与 `ChartPanel` 各自判定。任一处调阈值，另一处不会跟随：把 `TuiLayout` 降到 6 会让 6/7 行的预算交给 `ChartPanel`，后者仍返回 `None` 走回退；把 `ChartPanel` 升到 10 则 8/9 行预算一定回退。`doc/tui.md:42` 的「20 列 × 8 行」实际分散在三处（`TuiLayout` 只有高度，宽度只在 `ChartPanel` / `f_chart`）。
- **建议**：`TuiLayout` 直接引用同包 `ChartPanel.MIN_HEIGHT` / `MIN_WIDTH`（或抽出 `TuiLimits`），`f_chart` 的下限如需独立，提取为 `f_chart` 公共常量供引用。

### [轻微][存量] `MetricPage.kind()` 的 TOPOLOGY / ALARMS 分支在实际调用点不可达，且与 `RenderPlan` 的 `"topology"` 字面量重复

- **位置**：`fprobe/src/tui/ViewModel.cj:65-76`；调用点 `fprobe/src/tui/RenderPlan.cj:206-220`
- **来源**：存量
- **判据**：review-checklist §2（重复映射，只改控制流/字面量）
- **证据**：静态确定 —— `RenderPlanBuilder` 先处理 `ALARMS`、再 `else if (page == MetricPage.TOPOLOGY)` 并硬编码 `"topology"`，只有剩余页才调用 `page.kind()`；`kind()` 是 public 方法（不判死代码），但这两个分支生产路径取不到
- **描述**：`kind()` 的注释称「与 `ProbeAgent.kind` 对应的键」，可拓扑页并不用它，改 `kind()` 的命名对拓扑页无效；告警页的 `""` 也无调用者。外观上是「唯一映射」，实际有两份真相。
- **建议**：拓扑分支改成 `page.kind()`（或把 `kind()` 收窄为只管有 `kind` 的页，`RenderPlan` 显式用常量），并在 `kind()` 注释里写明哪几页有值。

### [轻微][存量] `ViewModel` 的四个导航方法两两同构，`selectNext` 多出的空判断不改变结果

- **位置**：`fprobe/src/tui/ViewModel.cj:138-155`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑，差异只有 ±1 与一个无效果分支）
- **证据**：静态确定 —— `selectNext` / `selectPrevious` 只差 `selection ± 1`，`nextPage` / `previousPage` 只差 `pageIndex ± 1`；`selectNext` 的 `nodes.isEmpty() → this` 去掉后构造器 `clampSelection(1, 0)` 返回 0，`selectedNode()` 仍是 `None`，可观察结果不变（`selectPrevious` 就没有该判断）
- **描述**：四份几乎相同的「构造新实例」代码，加上一个只在一侧存在的空判断，会让读者以为空列表下两个方向的语义不同；后续加「首尾不循环」之类规则时要改四处。
- **建议**：合并为 `moveSelection(delta)` / `movePage(delta)`（内部走构造器夹取），空判断要么两处都留、要么都删。

### [轻微][存量] README 公开 API 索引漏 `MetricPage.kind` / `Usage.agent` / `Usage.supervisor`

- **位置**：`README.md:559`（`MetricPage` 只列 `chartType`、`title`）、`README.md:612`（`Usage` 只列 `root`）；源码 `fprobe/src/tui/ViewModel.cj:65`、`fprobe/src/usage.cj:39`、`:55`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化；`README.md:519` 自称未展开的 public 声明都在此列出）
- **证据**：静态确定 —— 在 README / `doc/**` 检索 `MetricPage.kind`、`Usage.agent`、`Usage.supervisor` 均无命中（`grep -rn` 空结果）
- **描述**：三个 public 成员在正文与索引里都不存在；`kind()` 还是 `RenderPlan` 取监控项键的入口，读者无法从文档知道页面与 `ProbeAgent.kind` 的对应关系。
- **建议**：补进索引（`kind` 加一句「页面 → `ProbeAgent.kind`，拓扑/告警页为空」），或把 `kind` 收窄为包内可见后从对外契约中移除。

### [轻微][存量] `Table` 在 2 列极窄区域会以 0 宽度写到区域右边界之外一列

- **位置**：`fprobe/src/tui/widgets/Table.cj:64-67`（值列写入），宽度推导见 `:36-46`
- **来源**：存量
- **判据**：review-checklist §11（边界差一）
- **证据**：待确认 —— 需确认 `ratatui_buffer.Buffer.setStringn` 在 `maxWidth == 0` 且 `x == area.right()` 时是否先做范围裁剪（依赖包只有 `.cjo`，仓内无源码）
- **描述**：`width = totalWidth / 2`，`totalWidth = 2` 时 `width = 1`，`start = area.x + 2`（正好等于 `area.right()`），`maxWidth = totalWidth - width - 1 = 0`。`FprobePainter.paintMetrics`（`:212`）只要右栏 inner 宽落到 2（约 12 列终端：left 8 + 边框 2 + 右栏 4）就会走到这里。若 `Buffer` 未在写入前裁剪，这是越界写；若已裁剪则只是一次无效调用。
- **建议**：把条件收紧为 `width + 1 < totalWidth` 再画值列（或先判 `totalWidth - width - 1 >= 1`）。

## 范围外提示

- `r` 键无动作：`TtyKeySource.cj:69-70` 把 `r` 映射为 `UiKey.Refresh`，`KeyMap.cj:75` 映射为 `UiAction.Refresh`，但 `SupervisorApp.cj:200-201` 的 `Refresh` 分支只 `return true`，渲染线程固定 500 ms（`SupervisorRuntime.cj:186`）；与 `README.md:291`、`doc/tui.md:49` 的「立即刷新一帧」不符，建议由 `SupervisorApp` 部分确认是接线缺失还是文档应删。
- `systemPainter()`（`FprobePainter.cj:340-345`）仓内零引用，生产装配 `SupervisorBootstrap.createPainter()`（`SupervisorBootstrap.cj:57-61`）重复了同一段 `Terminal` 组装但没传 `PassiveExitHook`；两处易漂移。另 `FprobePainter.cj:328-331` 注释称 `SystemExitHook`「覆盖」`f_base.ExitCallbacks` 的处理器，与 `std.runtime` 文档不符：`registerSignalHandler` 对同一信号是**累加、FIFO 执行**，返回 `true` 才截断后续（本地文档 `cangjie-doc/md/doc/doc/cangjie_runtime-main-stdlib-doc-libs/stdlib/doc/libs/std/runtime/runtime_package_api/runtime_package_funcs.md:472-480`），因此 f_base 的退出回调仍会先执行。

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分只有 1 条，且无改前基线。

### [CPU] 面板/表格/sparkline 每帧逐格 `setString` 与标题插值

- **现状**：每帧每个 panel 构造一次 `" ${title} "` 字符串（`Panel.cj:56`），边框与竖线逐格 `setString`（`Panel.cj:36-52`）；`Table` 每行 2 次 `setStringn`（`Table.cj:62-66`）；`Sparkline` 每格 1 次 `setString`（`Sparkline.cj:71`）。80×24 终端、500 ms 一帧，单帧约 2×(80+24) 次边框写 + 每序列 ≤ 43 次写。
- **方案**：panel 的上/下边框用一次 `setStringn` 批量写（横向整行串），标题串随 `RenderPlan.pageTitle` 预拼好；sparkline 可按相同档位合并连续单元格后一次写。
- **预期**：无法量化（无基线）。
- **代价**：批量写依赖 `Buffer` 对超宽字符串的裁剪语义；标题缓存需处理 title 变化。
- **验证**：`cjprof record` 跑 TUI 稳态 5 分钟（同 80×24、500 ms 帧间隔），对比 `FprobePainter.paint`/`Panel.draw` 的 self time 与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 面板边框逐格写 + 标题插值是渲染线程的主要分配/CPU 来源之一 | `fprobe/src/tui/widgets/Panel.cj:36-57` | self time 占比、每帧分配字节数 | `cjprof record` 跑 TUI 5 分钟（80×24，500 ms 帧），按函数聚合 |
| 2 | Sparkline 每帧 O(n) 归一化 + 逐格写在 60 点窗口下可忽略 | `fprobe/src/tui/widgets/Sparkline.cj:36-73` | 单帧耗时与占比 | 在 `RenderLoop.renderOnce` 分段计时（build / draw），稳态 10 分钟取中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/src/tui/SupervisorApp_test.cj` | .cj | 是 | 测试替身与生命周期用例；无缺陷 |
| 2 | `fprobe/src/tui/TtyDetector.cj` | .cj | 是 | 见发现 #3 |
| 3 | `fprobe/src/tui/TtyDetector_test.cj` | .cj | 是 | 覆盖非 TTY 报错与提示文案 |
| 4 | `fprobe/src/tui/TtyKeySource.cj` | .cj | 是 | 映射表与 `TerminalKey` 全分支一致 |
| 5 | `fprobe/src/tui/TtyKeySource_test.cj` | .cj | 是 | 表驱动覆盖 8 个分支 |
| 6 | `fprobe/src/tui/TuiLayout.cj` | .cj | 是 | 见发现 #4 |
| 7 | `fprobe/src/tui/TuiLayout_test.cj` | .cj | 是 | 高度预算边界有断言 |
| 8 | `fprobe/src/tui/ViewModel.cj` | .cj | 是 | 见发现 #5、#6，可见性建议 |
| 9 | `fprobe/src/tui/ViewModel_test.cj` | .cj | 是 | 分页/选择/图表类型映射覆盖完整 |
| 10 | `fprobe/src/tui/widgets/Panel.cj` | .cj | 是 | 边框与标题绘制，无独立用例 |
| 11 | `fprobe/src/tui/widgets/Sparkline.cj` | .cj | 是 | 见发现 #1 |
| 12 | `fprobe/src/tui/widgets/Table.cj` | .cj | 是 | 见发现 #8 |
| 13 | `fprobe/src/usage.cj` | .cj | 是 | 见发现 #2、#7 |

合计：`.cj` 13 个 / `.md` 0 个 / 共 13 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | Sparkline 归一化（#1）；usage 与实现不符（#2）。无外部输入拼 SQL、无凭据、无注入面 |
| §1 死代码 | 0 | 逐个核查本部分符号：`STDOUT_FILENO`/`CHROME_HEIGHT`/`BLOCKS`/`clampSelection`/`normalizePage`/`alarmPageIndex`/`Panel.put` 均有引用；测试替身的 `public` 成员全为接口实现（豁免）；本部分没有 `internal`/`protected` 顶层声明。对外可达 public 不判：`TuiLayout.MIN_CHART_HEIGHT`、`ViewModel.pageNumber/pageCount` 仓内仅自用/仅测试用，列入「可见性建议」 |
| §2 重复逻辑 | 4 | TTY 校验与 fd 常量（#3）、图表最小高度（#4）、`kind()` 与 `"topology"` 字面量（#5）、四组导航方法（#6）。另已排查：测试替身重复（`FalseTtyDetector`/`FakeTtyDetector`）属测试准备代码，按误报边界不报；`MetricPage/UiKey/UiAction` 三处手写 `==` 是仓内既定做法（`Equatable` 成员需显式实现，见 `.autocode/tmp/probe_equatable/p1.cj`），不计为重复逻辑 |
| §3 空实现 | 0 | 本部分无空函数体、无 TODO/占位、无 `catch {}`；`Panel`/`Table`/`Sparkline` 的早返回都是显式的尺寸保护，返回值语义与调用方一致 |
| §4 栈溢出 | 0 | 本部分无递归（`ViewModel`/`TuiLayout`/widgets 全为单层循环），无自引用结构 |
| §5 OOM | 0 | 无按不可信长度预分配；`ViewModel.nodes` 来自配置且长度有界；`PAGES`/`BLOCKS` 为固定常量 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/bench 数据，逐格写与插值只作为「待验证假设」与「优化方案（无基线）」 |
| §6.2 大粒度锁 | 0 | 本部分不含锁；`SupervisorApp` 的锁在另一部分 |
| §6.3 并发串行 | 0 | 无 `spawn`/`get`；渲染与按键线程职责分离在 `SupervisorApp`/`RenderLoop` |
| §6.4 低效算法 | 0 | `Sparkline` 的 O(n) 归一化 n ≤ 60，`alarmPageIndex` 扫 8 项；均无测量数据，不判低效 |
| §7 降堆内存方案 | 0 | 单帧对象仅为行/列规模的临时 String 与 `Rect`，随帧结束释放；无可量化收敛目标 |
| §8 降 CPU 方案 | 1 | 面板/表格/sparkline 批量写（无基线，见优化方案） |
| §9 local mode 可行性 | 0 | 函数内临时对象都很小且会进入 `Buffer`（跨对象存储），不满足「函数内用完」，改造成本高于收益 |
| §11 现有代码的 BUG（存量） | 2 | Sparkline 归一化边界（#1）、`Table` 极窄宽度写入（#8，待确认） |
| §12 并发安全与锁粒度 | 0 | `ViewModel` 字段全为 `let`，每次迁移构造新实例，经 `SupervisorApp.viewLock` 发布；`TuiLayout`/widgets 无状态，`Buffer` 由渲染线程独占；`PAGES` 无写入者（可变数组暴露面列入「可见性建议」） |
| §14 功能完备性与 README 覆盖 | 2 | help 漏 `probe_hostId`（#2）、README API 索引漏 3 个 public 成员（#7）；本部分 public 声明与文档已逐项对照，`requireTty`/`systemKeySource`/`Panel`/`Table`/`Sparkline`/`TuiLayout` 均已接线 |
| 文件覆盖（§13 等） | 13/13 | 无缺失；本部分无 `.md` 文件，文档一致性以 README / `doc/tui.md` / `doc/configuration.md` 为参照取证 |

### 可见性建议

- `ViewModel.pageNumber()` / `pageCount()`（`ViewModel.cj:130-136`）：仅 `ViewModel_test.cj:30-31` 使用，状态栏/标题（`RenderPlan.cj:235`）没有展示页码；若近期不接页码，建议收窄为包内可见或删除，并同步移除 `README.md:613` 的条目。
- `TuiLayout.MIN_CHART_HEIGHT`（`TuiLayout.cj:26`）：仓内只有 `chartHeight` 自用；与 #4 合并处理，收敛为单一常量后不必对外。
- `ViewModel.PAGES`（`ViewModel.cj:86`）：`public static let` 只固定了绑定，`Array` 元素仍可被外部改写；一旦被改，`normalizePage`/`page()` 的下标假设失效。建议改为包内可见 + 只读访问器（或每次返回副本）。当前仓内无写入者。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

本部分是一层小而清晰的 TUI 支撑代码：`ViewModel` 做成纯函数式迁移、TTY/按键/布局都用接口隔离、widgets 只碰 `Buffer` 不承担业务语义，测试对按键映射、分页回绕、布局预算、TTY 报错都有分支级断言；没有递归、无界容器、共享可变状态的写入，也没有锁与 I/O 混在热路径里，整体质量良好。

真正值得排期的是两条：`Sparkline` 的归一化窗口（会让运维把「有尖峰刚滚出窗口」误读成「指标接近 0」，属于会误导判断的显示逻辑错误）与 `usage` 文本失真（把不存在的配置文件写进帮助，同时漏掉多节点必需的 `probe_hostId`）。其余为重复常量/重复映射、极窄窗格边界与 README 索引遗漏，可按维护窗口顺手处理；`r` 键无动作与 `systemPainter` 未接线已在「范围外提示」标注，交对应部分确认。

存量 8 条（2 一般 + 6 轻微），是否纳入修复待用户决定。

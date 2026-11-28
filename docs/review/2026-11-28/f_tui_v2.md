# f_tui 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_tui`（26 个文件：23 个 .cj + 3 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_tui.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] 未完成的 CSI 序列会吞掉下一次按键

- **位置**：`f_tui/src/input/EscapeParser.cj:111-126`（`parseCsi`）、`f_tui/src/input/KeyReader.cj:48-58`（超时后保留 pending）
- **来源**：存量（`git blame` 全部指向 `d061ff0e71`，2026-11-09）
- **判据**：review-checklist §11（边界 / 语义与注释不符）
- **证据**：静态确定 —— `parseCsi` 只在遇到 `0x40..0x7E` 的终止字节时 `consume`；字节不足时 `return None` 且**不动** `bytes`。`KeyReader.readKey` 超时后调 `finishPending()`，而 `flushEscape()` 只清「单个 ESC」，因此 `ESC [` 永久留在缓冲区
- **描述**：用户按下 `ESC` 后紧跟 `[`（或粘贴被截断的转义序列），25 ms 内没有终止字节时，`ESC [` 留在解析器里；下一次按下的任意 `>= 0x40` 字符（例如 `q` = 0x71）会被当作 CSI 终止字节消费，`mapCsi` 返回 `Unknown` —— **该按键直接丢失**。若后续字节持续落在 `0x20..0x3F`（例如粘贴一串数字），则持续累积（见下一条 OOM 面）。文档 `doc/terminal-backend.md:92-94` 承诺「未完成序列保留，下一次读取继续拼装」，但没说清「超时后残留的半个序列会吃掉下一个键」
- **建议**：在 `EscapeParser` 里记录序列起始位置与已等待次数；超时（或在 `readKey` 连续 N 次取不到后续字节）后整段丢弃 pending 并返回 `Unknown`；`parseCsi` 遇到非法字节（`< 0x20`、`0x7F`）也应立即丢弃而不是继续累积

### [一般][存量] `writeBytes` 无短写 / EINTR 重试，读侧把 EINTR 当超时

- **位置**：`f_tui/src/term/PosixFfi.cj:345-356`（`writeBytes`）、`f_tui/src/term/PosixFfi.cj:321-343`（`readByte`）、`f_tui/src/term/PosixFfi.cj:332`（`poll`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §11（错误处理缺失）+ 本模块重点「短写 / EINTR」
- **证据**：静态确定 —— 只有一次 `write`，判定式是 `n == IntNative(bytes.size)`，没有任何循环；`n` 为 `-1`（含 `EINTR`）时直接返回 `false`。`read` 侧 `ready <= 0` 与 `n != 1` 都归并为 `None`
- **描述**：
  1. 帧输出可达数十 KB（`AnsiRenderer` 一次 `write` 整帧），tty / pipe 出现短写（写入少于请求字节数）时，剩余字节被丢弃且函数返回 `false` → `AnsiRenderer.emit` 置 `broken = true`（`AnsiRenderer.cj:212-225`），**此后该终端再也不会刷新**，宿主只看到画面冻结；
  2. `EINTR`（注册了 `SIGINT` / `SIGTERM` 处理器后并非不可能）同样被判失败，后果同上；
  3. 读侧 `poll` / `read` 返回 `-1` 时与「超时」不可区分，按键读取静默退化为「没有按键」；`poll` 返回 `POLLHUP` / `POLLERR` 时也会盲读一次。
- **建议**：写侧改成 `while (written < size)` 循环，`n < 0 && errno == EINTR` 继续，`n <= 0` 才失败；读侧区分 `EINTR` 与 EOF，`poll` 后检查 `revents & (POLLIN | POLLHUP | POLLERR)`。另外 `AnsiRenderer` 的 broken 是**单向**的，一次短写就永久停写，建议对「可重试错误」不置 broken
- **备注**：短写在真实 tty 上的发生频率属 `需实测`，但「没有重试路径」是静态确定

### [一般][存量] 退出回调表与 `restore()` 在信号线程与渲染线程间无同步

- **位置**：`f_tui/src/render/Terminal.cj:26-37`（`F_TUI_EXIT_CALLBACKS` / `fTuiDispatchExit` / `fTuiSignalHandler`）、`f_tui/src/render/Terminal.cj:52-60`（`register`：`add` + `installed` 读-判-写）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入）
- **证据**：静态确定 —— 全局 `ArrayList` 无锁、无原子量、无快照替换；`installed` 是 `private static var` 的朴素「读-判-写」。`std.runtime.registerSignalHandler` 的回调由运行时在信号分发路径执行（`std/runtime/runtime_package_api/runtime_package_funcs.md:507`：同一信号多函数按 FIFO 执行，返回 `true` 停止后续；示例 `:573-578` 显示回调执行后仍走默认动作），与主线程并行
- **描述**：两条并发路径：A = 渲染线程 `BufferRenderer.flush → AnsiRenderer.render` 读写 `previous` / `cursorVisible` / `broken` 并调 `writer.write`；B = 信号路径 `fTuiDispatchExit → Terminal.restore → renderer.reset()` + `rawMode.restore()`。二者没有任何互斥，`previous`（整屏 `ScreenBuffer` 引用）、`cursorVisible`、`altActive` 可能被交错修改；若信号恰在 `register()` 的 `F_TUI_EXIT_CALLBACKS.add()` 期间到达，遍历与写入并发会导致容器状态未定义。后果集中在退出阶段（恢复序列交错 / 终端停留在备用屏），不涉及业务数据，故判一般
- **建议**：`installed` 用 `AtomicBool` + CAS；回调表改为「不可变快照 + 原子替换」（`register` 复制-追加-发布），或加 `Mutex`；信号路径只置一个 `AtomicBool` 请求标记，由渲染线程在安全点执行 `restore()`，避免在信号上下文里改渲染状态

### [一般][存量] `EscapeParser` 的 pending 缓冲区无上限

- **位置**：`f_tui/src/input/EscapeParser.cj:24-39`（`bytes` + 两个 `feed`）、`f_tui/src/input/EscapeParser.cj:111-126`
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §5（无界容器 / 按不可信长度累积）
- **证据**：静态确定 —— `bytes` 只增不减，唯一的消费点是解析成功时的 `consume`
- **描述**：`EscapeParser` 是公开类型，`feed(values: Array<UInt8>)` 接受任意长度的整块数据；只要输入满足「`ESC [` 之后全是 `0x20..0x3F`」，`parseCsi` 就一直不终止，缓冲区持续增长。量化：`ArrayList<UInt8>` 单元素至少 1 B（含扩容冗余约 1–2 B），1 MB 此类输入 → 1–2 MB 常驻；要到 GB 级输入才可能 OOM，因此不作为严重缺陷，但**没有任何拒绝路径**（无长度上限、无丢弃策略）
- **建议**：给 pending 设上限（例如 64 字节，远超真实 CSI / UTF-8 序列长度），超限即清空并返回 `Unknown`；或在 `feed` 时截断

### [一般][存量] `version()` 与仓库版本不一致

- **位置**：`f_tui/src/package.cj:7-9`（返回 `"1.3.17"`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §14.1（版本与依赖漂移）+ §2（字面量复制）
- **证据**：静态确定 —— `f_tui/cjpm.toml:21` 为 `version = "1.3.2021"`；`f_version/src/FountainVersion.cj:21` 为 `public const Version = "1.3.2021"`；全仓只有此处硬编码 `"1.3.17"`
- **描述**：对外 API `version()` 报的是上一个发布版本，宿主用它做版本门禁会得到错误结论；同时这是全仓唯一一处硬编码版本串（其余模块走 `f_version`）
- **建议**：`f_tui` 依赖 `f_version` 并 `return Version`；或删掉 `version()`（`public` 对外可达，删前需用户确认契约影响）

### [一般][存量] `package.cj` 缺版权头，注释与「不实现 Backend」的约定矛盾

- **位置**：`f_tui/src/package.cj:1-4`
- **来源**：存量（`d061ff0e71`）
- **判据**：`fountain-baseline.md` §3（每个 `.cj` 必须有 Apache 2.0 头且位于 `package` 之前，缺失按一般报）；review-checklist §13（注释与实现不符）
- **证据**：静态确定 —— 文件前两行是普通 `//` 注释，没有 License 头；第 2 行写「ratatui Backend 全部收敛在本模块内」，而 `README.md:9`、`README_en.md:9`、`doc/terminal-backend.md:14` 都明确「`BufferRenderer` 不实现 `ratatui_backend.Backend`」；本模块 `cjpm.toml` 也没有 `ratatui_backend` 依赖
- **描述**：缺头违反工程基线；过期注释会让后来者误以为模块对外提供 `Backend` 实现
- **建议**：补 2026 年版权头（`package` 之前），把注释改为「终端能力收敛在本模块内，不实现 ratatui Backend」

### [一般][存量] README 公开 API 覆盖不足，`Termios` 只列 macOS 布局

- **位置**：`f_tui/README.md:47-72`、`f_tui/README_en.md:47-72`（两版内容同构，问题相同）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §14.2（公开 API 未文档化）+ §13（API / 配置与源码不符）
- **证据**：静态确定，逐符号对照：
  - 缺 `AnsiRenderer.render`（`AnsiRenderer.cj:127`，唯一的出帧入口，「Other public API」的 `AnsiRenderer` 行只列了 clear / enterAltScreen / exitAltScreen / hideCursor / isBroken / reset / setCursor / showCursor）；
  - 缺 `RawMode.restore`（`RawMode.cj:61`，README 只列 enter / isActive / snapshot）；
  - `BufferRenderer` 只列 clear / isBroken / setCursor / size，`start` / `restore` / `draw` / `flush`（`BufferRenderer.cj:41,48,80,120`）仅出现在被注释掉的示例里；
  - 完全未列全部 `public const`：`STDIN_FILENO` / `STDOUT_FILENO` / `TCSANOW` / `SIGWINCH` / `TERMIOS_CC_COUNT` / `TIOCGWINSZ` / `ICANON` / `ECHO` / `IEXTEN` / `ISIG` / `ICRNL` / `IXON` / `OPOST` / `CS8` / `BRKINT` / `INPCK` / `ISTRIP` / `VMIN` / `VTIME`（`PosixFfi.cj:19-150`）、`MODIFIER_*` 九个与 `AnsiSequence` 的固定序列常量（`AnsiSequence.cj:21-118`）；
  - `Termios` 字段只列 macOS 变体（`c_cc: VArray<UInt8, $20>`、全 `UInt64`），而 Linux / 鸿蒙是 `UInt32` 标志 + `c_cc: VArray<UInt8, $32>` 且多一个 `c_line`（`PosixFfi.cj:167-196`，两套 `@When` 分支）
- **描述**：`doc/terminal-backend.md:41-43` 写对了平台差异，README 直接照抄 macOS 版结构体。宿主按 README 写 `Termios` 字段类型/长度，在默认 Linux 目标上编译不过；`AnsiRenderer.render` 缺失意味着「不用 BufferRenderer 的自定义帧」这条路径没有文档
- **建议**：README 两个版本同步补 `render` / `RawMode.restore` / `BufferRenderer` 四个入口；`Termios` 段改写为「按平台两套布局，见 doc §2」；公开常量按组增加一行清单（或用「见 `PosixFfi.cj` 顶部常量区」+ 指向文档）

### [一般][存量] `displayWidth` 缺常用 emoji / 旗帜区间，宽字符判定与终端不一致

- **位置**：`f_tui/src/ansi/ScreenBuffer.cj:81-97`（`isWide`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §11（语义与契约不符：`displayWidth` 注释是「符号的显示宽度」）
- **证据**：静态确定 —— 区间表覆盖 `1F300-1F64F`、`1F900-1F9FF`，但缺 `1F680-1F6FF`（🚀 U+1F680、🚄、🚀 等交通/表情）、`1F1E6-1F1FF`（区域指示符 / 国旗）、`1F004`、`1F0CF`、`1FA70-1FAFF`（🩰 等）。这些码位 `runeWidth` 返回 1
- **描述**：终端普遍按 2 列渲染上述字符，`ScreenBuffer.set` 因此不会给第二列打 `skip`，`AnsiRenderer` 会把下一列内容当作紧随其后的字符输出 → 该行后续内容整体左移 1 列（或宽字符覆盖下一格）。测试 `AnsiRenderer_test.cj:147-159`、`BufferRenderer_test.cj:143-155` 只覆盖了「中」这类 CJK，发现不了
- **建议**：用 East Asian Width（W/F）+ `Emoji_Presentation` 生成区间表，而不是手写；把该表抽成单一常量数组便于后续维护

### [一般][存量] 宽字符落在最后一列时既不跳过也不替换，触发终端自动换行

- **位置**：`f_tui/src/ansi/ScreenBuffer.cj:163-169`、`f_tui/src/render/BufferRenderer.cj:106-110`
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §11（边界 / 越界处理缺失）
- **证据**：静态确定 —— `if (!value.skip && displayWidth(symbol) >= 2 && x + 1 < columns)`：`x + 1 < columns` 不成立时既不标 skip、也不把 symbol 换成单列字符，宽字符原样写入 `cells[x]`；`BufferRenderer.draw` 只按源 buffer 宽度跳下一列，同样不检查目标列是否是最后一列
- **描述**：`width = 80` 时在 `x = 79` 写入「中」，终端在最后一列输出双宽字符会先换行/滚动再显示，整屏错位一格；下一帧的差分又认为该格没变化，错位会一直保留
- **建议**：最后一列遇到宽字符时替换为 `" "`（或截断成单列字符），并在 `doc/terminal-backend.md` §6 写明该裁剪规则

### [一般][存量] 帧缓冲按终端上报尺寸直接分配，没有上限与拒绝路径

- **位置**：`f_tui/src/ansi/ScreenBuffer.cj:124-129`（`Array<ScreenCell>(width * height)`）；入口 `f_tui/src/render/BufferRenderer.cj:87-90`、`f_tui/src/term/TerminalSize.cj:56-66`（`IoctlSizeProvider`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §5（按不可信长度预分配、无拒绝路径）
- **证据**：静态确定（尺寸上限来自 `WinSize` 的 `UInt16` 字段，`ioctl(TIOCGWINSZ)` 的返回值不做范围校验）
- **描述**：`width`/`height` 均为 `UInt16`，最坏 `65535 × 65535 ≈ 4.29e9` 个 `ScreenCell`；按 `ScreenCell`（`String` + 两个 `AnsiColor` 各 5 字段 + `Int64` + `Bool`）≥ 40 B 估算 ≈ 170 GB，必然 OOM；即使 4096×4096（16.7M 单元格）也 ≈ 0.7–1 GB，且 `BufferRenderer.draw` 每帧都会新建一份、`AnsiRenderer` 还会 `clone` 一份（见优化 #1）。真实终端不会给出这种尺寸，但 pty 主端可以任意设置窗口大小，属不可信输入
- **建议**：加尺寸上限常量（例如 1000×1000）并在 `IoctlSizeProvider` / `ScreenBuffer.init` 处拒绝（抛 `TuiException(TuiErrorCode.Size, …)` —— 该枚举值目前从未使用，见 #18）；分配失败时降级为跳过绘制而不是让 `Array` 抛出

### [一般][存量] 重复逻辑：同一单元格被清洗/测宽两次，`sameCell` 与 `sameAsPrevious` 同义

- **位置**：`f_tui/src/render/BufferRenderer.cj:105,108` 与 `f_tui/src/ansi/ScreenBuffer.cj:158,163`；`f_tui/src/ansi/ScreenBuffer.cj:188-190` 与 `f_tui/src/ansi/AnsiRenderer.cj:205-210`
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §2（跨层复制 / 只改类型名）
- **证据**：静态确定 ——
  1. `draw` 先 `sanitizeSymbol(source.symbol())` 再 `next.set(...)`，`ScreenBuffer.set` 内部又 `sanitizeSymbol(value.symbol)`；`displayWidth(symbol)` 在 `draw:108` 与 `set:163` 各算一次。同一字符串每帧被清洗两遍、测宽两遍；
  2. `ScreenBuffer.sameCell(x, y, other)` = `get(x,y).equals(other.get(x,y))`，与 `AnsiRenderer.sameAsPrevious` 的 `cell.equals(old.get(x, y))` 判定完全相同（后者绕开了 `sameCell`），两处对「同格」的定义将来会漂移；
  3. 三份同构的录制 writer：`AnsiRenderer_test.cj:24-55`（`RecordingWriter`）、`BufferRenderer_test.cj:27-58`（`RenderWriter`）、`Terminal_test.cj:70-93`（`LifecycleWriter`）字段与方法逐行一致，只差类名；
  4. 两份同构的 `winSize`：`FakePosixFfi_test.cj:76-81`（internal）与 `Terminal_test.cj:62-67`（private 方法）；
  5. 跨模块：`ScreenBuffer.cj:52-97`（完整宽度表）与 `f_chart/src/tui/TuiText.cj:21-36`、`f_chart/src/ChartScale.cj:116`、`f_chart/src/OrgChart.cj:274` 的 `>= 0x2E80 → 2` 粗略规则并存；`AnsiSequence.cj:105-155` 与 `f_chart/src/tui/TuiColor.cj:24-31` 各写一份 SGR 字面量（f_chart 三处属**范围外提示**，但 `README.md:4` 明确「终端相关代码只允许出现在本模块」）
- **描述**：1、2 在热路径上（每帧 × 每单元格），3、4 是测试维护成本，5 是同一语义两套精度：同一字符串在 `f_tui` 渲染与 `f_chart` 布局下宽度可能不同（`>= 0x2E80` 之外的全角/emoji 两侧判定不一致），对齐会错
- **建议**：`draw` 只把原始 symbol 交给 `ScreenCell`，由 `ScreenBuffer.set` 统一清洗与测宽（或让 `set` 返回「宽度 ≥ 2」供调用方跳列）；`sameCell` 与 `sameAsPrevious` 保留其一；测试 writer 抽到模块内共享 test util（`src/**/_test_support.cj` 之类）；`f_chart` 改为复用 `f_tui.ansi.displayWidth`（需用户确认跨模块依赖方向）

### [轻微][存量] `doc/terminal-backend.md` 与实现/测试三处不符

- **位置**：`f_tui/doc/terminal-backend.md:176`（`FakeSizeProvider`）、`:92-94`（`KeyReader` 超时描述）、`:9-10`（`SystemExitHook` 在 Windows 的行为）、`:19-26`（可注入边界表）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §13
- **证据**：静态确定 —— 实际测试替身是 `FixedSizeProvider`（`BufferRenderer_test.cj:60`）、`LifecycleSizeProvider`（`Terminal_test.cj:95`），全仓没有 `FakeSizeProvider`；`KeyReader.cj:55` 对**所有**后续字节都用 `escapeTimeoutMs`，不止 ESC 分支；`SystemExitHook` 的 Windows 版（`Terminal.cj:63-77`）只注册 `atExit`，不返回/抛出任何「unsupported」；表里列了四个接口，实际还有第五个可注入接口 `ExitHook`（`Terminal.cj:40-43`，`Terminal.init` 的 `exitHook!` 参数）
- **建议**：把替身名改为实现里的真实名字（或补一句「名称以测试文件为准」）；超时描述改为「首字节按调用方超时，后续字节一律 `escapeTimeoutMs`」；`SystemExitHook` 的 Windows 行为改成「只注册 atExit，无信号处理」；边界表补 `ExitHook` 一行

### [轻微][存量] 死代码：`FakePosixFfi.written` 只写不读

- **位置**：`f_tui/src/term/FakePosixFfi_test.cj:30`（字段）、`:70`（`written.add(bytes)`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §1 硬原则二 —— `FakePosixFfi` 是非 `public` 顶层 `class`，其 `public` 成员在全项目无使用即死代码
- **证据**：静态确定 —— 全仓 `grep -rn "written" f_tui/src` 只有定义与 `add` 两处，没有任何读取点
- **建议**：删除该字段，或让 `PosixFfi_test` / `TerminalWriter` 相关用例断言写入字节（顺便补上 `writeBytes` 的失败路径覆盖：`writeOk` 也从未被置为 `false`）

### [轻微][存量] `KeyReader.readKey` 结尾的 `None` 不可达

- **位置**：`f_tui/src/input/KeyReader.cj:48-60`
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §1（`return` 之后的同层语句 / 不可达语句）
- **证据**：待确认 —— `while (true)` 内的所有出口都 `return`，第 60 行的 `None` 在语义上取不到；但本次不构建，无法确认仓颉的「函数必须以 return/throw 结束」检查是否把它当作必需的兜底
- **建议**：确认后删除，或把循环改成带显式条件的 `while (parser.pendingCount() > 0)` 并保留末尾 `None`

### [轻微][存量] `AnsiColor.kind` 为非法值时生成空 SGR 参数

- **位置**：`f_tui/src/ansi/AnsiSequence.cj:126-155`（`styleFor`）+ `:79-94`（`foregroundParams` / `backgroundParams`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §11（边界 / 契约与实现不符）
- **证据**：静态确定 —— `AnsiColor.kind` 是 `public var`，可构造 `kind = 3`；此时 `isDefault()` 为 `false` 而 `foregroundParams()` 走 `case _ => ""`，`params.add("")` 后拼出 `ESC[0;;…m`（空参数等价 0 → 复位），样式静默丢失
- **建议**：`styleFor` 只在 `kind == 1 || kind == 2` 时加参数；或在 `AnsiColor.init` 里把非法 `kind` 归一为 0

### [轻微][存量] 未使用的 import

- **位置**：`f_tui/src/render/Terminal_test.cj:19`（`import fountain::f_tui.ansi.AnsiRenderer`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 该文件除 import 行外没有出现 `AnsiRenderer`（用的是 `Terminal` / `BufferRenderer`）
- **建议**：删除该行

### [轻微][存量] 状态标志先翻转后写入，失败时与终端实际状态相反

- **位置**：`f_tui/src/ansi/AnsiRenderer.cj:55-61`（`altActive = true` 之后才 `emit`）、`:74-80`（`cursorVisible = false` 之后才 `emit`）
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §10（正确性 / 状态一致性）
- **证据**：静态确定 —— `emit` 返回 `false`（写失败）时标志已经翻转；`built` 的 `broken` 掩盖了多数后果，但 `Terminal.start` 的回滚路径（`Terminal.cj:115-123`）会据此再发一次本不该发的序列，且状态记录（`isBroken` 之外）与终端不一致
- **建议**：改成「先 `emit`，成功后置标志」，或在失败时回滚标志

### [轻微][存量] `TuiErrorCode.Size` / `TuiErrorCode.Write` 全模块未接线

- **位置**：`f_tui/src/TuiException.cj:19-47`
- **来源**：存量（`d061ff0e71`）
- **判据**：review-checklist §14.1（接线缺失；对外 `public enum` 值，属非死代码）
- **证据**：静态确定 —— 全仓只有 `TuiErrorCode.Init` / `Unsupported` 被抛出（`Terminal.cj:112,117,122`、`RawMode.cj:51,55`），`Size` / `Write` 从未构造
- **描述**：这两个分类是对外契约里承诺的「尺寸不可用」「写失败」，但当尺寸非法（#11）与写失败（#2）时实际都走「静默返回 / broken」，宿主无法按分类降级
- **建议**：在 #11 的尺寸拒绝与 #2 的写失败路径使用它们，或在文档里注明「保留未用」

<!-- 第 2 部分 -->

### [严重][存量] `write(2)` 的短写与 EINTR 没有重试：截断被当成失败，`AnsiRenderer` 随后永久停写

- **位置**：`f_tui/src/term/TerminalWriter.cj:37-39`（`StdoutTerminalWriter.write` 直接返回 `ffi.writeBytes`）；根因在 `f_tui/src/term/PosixFfi.cj:345-356`（`writeBytes` 只比较 `n == IntNative(bytes.size)`，不循环、不区分 errno）；后果放大在 `f_tui/src/ansi/AnsiRenderer.cj:212-226`（`emit` 收到 `false` 即 `broken = true`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失 / 静默失效」、§3「失败路径当成功」；本模块专项「短写 / EINTR」
- **证据**：静态确定 —— `write(2)` 的合法返回值是 `0..count`，`n < count` 时剩余字节需要再次写出；`PosixFfi.cj:352` 只用等号判定，短写与 `-1`（EINTR / EAGAIN）一律归为 `false`，且没有重试。`AnsiRenderer.emit`（216-219）把一次 `false` 转成进程级 `broken`，之后 `render`（第 141-143 行）直接返回 `false`，不再尝试写终端
- **描述**：`TerminalWriter.write` 的语义是「写出一段文本，失败返回 `false`」，但实现并不保证「整段写出」：一帧全屏重绘（含真彩 SGR）可达数十 KB，超过 pty 输出队列时 `write` 会部分成功，余下字节被丢弃；写期间被信号打断则返回 `-1`。两种情况下 `AnsiRenderer` 都把整帧判为失败并永久置 `broken`，宿主只拿到一个 `Bool`，界面从此停在半帧、且截断点可能落在 CSI 序列中间（例如 `ESC[38;5` 被截断），后续 shell 输出会被终端当作该序列的续体吞掉。宿主不感知、无日志、无法恢复，属静默失效
- **建议**：`writeBytes` 改为 `while` 循环写满，`n < 0` 时用 `errno` 区分 `EINTR`（重试）、`EAGAIN`（`poll` 等待可写或返回「暂不可写」）与 `EPIPE` / `EBADF`（返回 `false`）；`TerminalWriter.write` 的注释写明「整段写完或返回 false」；`FakePosixFfi` 增加按字节数截断与 `EINTR` 注入开关，补 `TerminalWriter` / `writeBytes` 的短写用例。触发频率需实测（见待验证假设 4），但缺少重试循环本身是静态事实，一旦触发后果即上述永久停写

### [一般][存量] `RawMode.restore` 丢弃 `tcsetattr` 返回值并先清 `active`，恢复失败后无法重试

- **位置**：`f_tui/src/term/RawMode.cj:61-69`（第 66 行忽略 `ffi.setTermios` 返回值，第 68 行无条件 `active = false`）；调用侧 `f_tui/src/render/Terminal.cj:132-139`（`initialized = false` 同样无条件）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失（返回值被忽略）/ 契约与实现不符」；`doc/terminal-backend.md:52` 承诺「按启动快照写回」，`:66-69` 承诺退出钩子覆盖正常 / 异常 / 信号三条路径
- **证据**：静态确定 —— `setTermios` 返回 `Bool`（`PosixFfi.cj:229`），`restore` 的 `if (let Some(value) <- saved) { ffi.setTermios(fd, value) }` 丢弃该值，随后把 `active` 置假；`Terminal.restore` 随之把 `initialized` 置假，`atExit` / `SIGINT` 回调再次触发时在第 133 行直接返回。`FakePosixFfi.setTermios` 恒返回 `true`（`f_tui/src/term/FakePosixFfi_test.cj:48-52`），该失败分支零覆盖
- **描述**：`tcsetattr` 失败（fd 已关闭、`EIO`、stdin 被重定向等）时，终端仍停留在 raw 模式（无回显、无行缓冲、`OPOST` 关闭），而代码认为已恢复，且后续所有恢复入口都已短路 —— 用户 shell 只能靠 `reset` / `stty sane` 救回。若宿主把 `restore` 当无条件成功调用（README 快速使用 `:37-39` 的 `finally` 正是如此），失败完全无痕
- **建议**：`restore` 返回 `Bool`（或失败抛 `TuiException(Init)`），仅在写回成功时清 `active`；`Terminal.restore` 汇总并向上传递失败，退出钩子路径至少 `warn` 一次；`FakePosixFfi` 增加 `setTermiosOk` 开关，补「restore 失败保持 active / 可重试」用例

### [轻微][存量] `enter` 失败时快照已写入 `saved`，`snapshot()` 与实际状态不一致

- **位置**：`f_tui/src/term/RawMode.cj:53-56`（53 行 `saved = Some(current)`，54 行才写回）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」；`RawMode.cj:39` 注释为「进入 raw mode 前保存的原始设置」
- **证据**：静态确定 —— `setTermios` 失败抛异常后 `active` 为假、`saved` 为 `Some`，`snapshot()`（40-42）此时返回「看似已进入 raw」的快照
- **描述**：诊断与「是否可安全重试」的判断若以 `snapshot().isSome()` 为依据会误判；`RawMode_test.cj:78-92` 只覆盖 `tcgetattr` 失败，未覆盖 `tcsetattr` 失败，因此该状态无人验证
- **建议**：把赋值移到 `setTermios` 成功之后（先算 `raw`，写成功再 `saved = Some(current)`），或把 `saved` / `active` 合并为一个 `Option<Termios>` 状态机，消除「有快照但未激活」的组合

### [轻微][存量] 「任一维为 0 即未知尺寸」在 5 处重复判定

- **位置**：`f_tui/src/term/TerminalSize.cj:59-63`（`IoctlSizeProvider` 手写 `ws_col == 0 || ws_row == 0`）、`f_tui/src/term/TerminalSize.cj:31-33`（`TuiSize.isUnknown`）、`f_tui/src/term/TerminalSize.cj:80-90`（`TerminalSize.size` 再判一次）；同语义还出现在 `f_tui/src/render/Terminal.cj:152-158` 与 `f_tui/src/render/BufferRenderer.cj:75-78`
- **来源**：存量
- **判据**：review-checklist §2「同一判定散落多处，语义漂移风险」
- **证据**：静态确定 —— 三处判据文字相同；对 `IoctlSizeProvider` 而言 `TerminalSize.size` 的 `isUnknown` 分支恒不成立（provider 已返回 `None`），只因为 `SizeProvider` 允许多实现才保留
- **描述**：若要调整「未知」口径（例如允许单维为 0、改用 `UInt16.max` 作哨兵），需要同步改 5 处，漏改即出现「一处过滤、一处不过滤」的漂移；`TerminalSize_test.cj:58-63` 只测了 `(0,0)`，「任一维」这一半语义无用例
- **建议**：`IoctlSizeProvider.size` 只做 `WS → TuiSize` 转换，未知判定统一收敛到 `TuiSize.isUnknown`；`Terminal` / `BufferRenderer` 复用 `isUnknown()`，不再手写比较；补 `(0,24)`、`(80,0)` 两个用例

### [轻微][存量] 「最近一次成功尺寸」有两套缓存且语义不同；`TerminalSize` 未接入生产路径

- **位置**：`f_tui/src/term/TerminalSize.cj:70-95`（`last` / `lastKnown`）vs `f_tui/src/render/BufferRenderer.cj:33,58-63`（`lastSize`）
- **来源**：存量
- **判据**：review-checklist §2「同一缓存语义两处实现」、§10 设计合理性（两套尺寸入口）
- **证据**：静态确定 —— `BufferRenderer.size` 把 `Some(0,0)` 也写入 `lastSize`，`TerminalSize.size` 过滤 `0x0`（82 行），同一 API 面给出两种「上次尺寸」语义；`Terminal.size`（`Terminal.cj:152-159`）走 `BufferRenderer`，全仓 grep `TerminalSize` 只有测试与 README/doc 引用，`src/` 无生产引用
- **描述**：宿主要么用 `Terminal`（内含 `BufferRenderer` 的缓存），要么直接用 `TerminalSize`，两者对「窗口暂时报 0 时 `lastKnown` 返回什么」回答相反；`doc/terminal-backend.md:88` 只说「每次重新读取」，没有说明失败时缓存是否保留
- **建议**：收敛为一处（`BufferRenderer` 内部持有 `TerminalSize`，或让 `TerminalSize` 只做 `SizeProvider` 的薄包装并被 `BufferRenderer` 使用），文档补「未知不覆盖 last」的明确口径。`TerminalSize` / `lastKnown` 属对外可达 `public`，若要收窄或删除需用户确认下游依赖，本报告不判死代码

### [轻微][存量] README 公开 API 清单漏掉本部分的 3 个成员

- **位置**：`f_tui/README.md:60`（`RawMode` 只列 `enter` / `isActive` / `snapshot`，漏 `restore`）、`f_tui/README.md:65`（`StdoutTerminalWriter` 只列 `write`，漏 `flush`）、`f_tui/README.md:71`（`TuiSize` 漏 `toString`）；`f_tui/README_en.md:60,65,71` 同
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化」
- **证据**：静态确定 —— `RawMode.restore`（`RawMode.cj:61`）、`StdoutTerminalWriter.flush`（`TerminalWriter.cj:41`）、`TuiSize.toString`（`TerminalSize.cj:35`）均为 `public`，README 同段落中 `IoctlSizeProvider`、`TerminalSize` 的方法都逐条列出，属遗漏而非取舍
- **描述**：`restore` 是 `RawMode` 唯一的恢复入口，`doc/terminal-backend.md:52` 有专门说明，README 漏列会让只想读 README 的宿主以为进入 raw mode 后只能靠进程退出恢复；`flush` 是 `TerminalWriter` 接口成员，实现为空操作，漏列后自定义 writer 不知道需要实现它
- **建议**：补齐三处（若清单由脚本生成，改生成器/模板而不是手改）。README 文件本身属第 1 部分覆盖范围，此处只就已审源码列出缺口，合并时按一条去重

### [轻微][存量] `RawMode` 的可变状态无同步，且存在跨线程调用路径（待确认）

- **位置**：`f_tui/src/term/RawMode.cj:26-27`（`saved` / `active` 普通字段）、`:45-69`（`enter` / `restore` 读改写）
- **来源**：存量
- **判据**：review-checklist §12.1「共享可变状态无保护」
- **证据**：待确认 —— 共享路径已存在：`Terminal` 把 `{=> this.restore()}` 注册到 `atExit` 与 `SIGINT` / `SIGTERM`（`Terminal.cj:34-37,125-128`），若 `registerSignalHandler` 的回调在独立线程执行，则 `RawMode.restore` 与主线程的 `restore` / `enter` 会并发读写 `saved` / `active`，两者都是普通字段，没有原子或锁。缺的信息是该运行时的回调执行线程模型
- **描述**：现有最坏情形是两次 `tcsetattr` 写同一快照（幂等，影响小）；真正的风险是「`enter` 与退出回调交错」——`active` 被置假但终端仍为 raw，与发现 #2 的后果叠加。稳态运行期间没有并发写入，因此不定为严重
- **建议**：用一把 `Mutex` 包住 `enter` / `restore`（只在生命周期边界调用，代价可忽略），或在文档与注释中明确「`RawMode` 非线程安全，由 `Terminal` 独占，退出钩子只允许在读线程空闲时触发」

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 以下均为「还能更好」，不是缺陷。全部无改前基线，故都标 `无基线（待验证，不进 tasks）`。

### [堆内存] 每帧两次整屏 `ScreenBuffer` 分配 + 一次整屏拷贝

- **现状**：`BufferRenderer.draw` 每帧 `ScreenBuffer(width, height)` 新建一份（`BufferRenderer.cj:90`）；`AnsiRenderer.render` 每帧 `previous = Some(frame.clone())` 再整屏拷贝一份（`AnsiRenderer.cj:198`）。80×24 = 1920 个 `ScreenCell`（每个含 1 个 `String` 引用 + 2 个 `AnsiColor` + `Int64` + `Bool`，按 ≥ 40 B 估 ≈ 77 KB/帧），两块合计 ≈ 150 KB/帧；60 fps 下 ≈ 9 MB/s 的短生命周期分配
- **方案**：`draw` 复用上一次的 `ScreenBuffer`（尺寸不变时原地写，只有尺寸变化才重建）；`render` 用「双缓冲 + 交换引用」代替 `clone()`（保留两块，写前按需 `copyFrom` 或直接整块覆盖）
- **预期**：稳态下每帧少一次整屏分配 + 一次整屏拷贝；GC 压力随帧率线性下降（量级按上面的估算，需实测确认）
- **代价**：`draw` 的「全量覆盖」语义要显式保证（当前靠「新建即全空格」），漏写某格会残留上一帧内容；需要一条「每帧都覆盖全屏」的等价性用例
- **验证**：`cjprof heap` / `getAllocatedHeapSize()` 在 60 fps、80×24、固定帧内容下对比改前改后；同时校验渲染输出逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 输出路径两次整屏字节拷贝

- **现状**：`AnsiRenderer.render` 末段 `emit(builder.toString())` 把 `StringBuilder` 转成 `String`（一次整屏拷贝），`StdoutTerminalWriter.write` 再 `text.toArray()`（`TerminalWriter.cj:38`）转成 UTF-8 字节数组（第二次整屏拷贝；`String.toArray` 语义见 `std/core/core_package_api/core_package_structs.md:8209`）。一帧几十 KB → 每帧多两份等长缓冲
- **方案**：给 `TerminalWriter` 增加 `writeBytes(Array<UInt8>)` 或让实现直接消费 `StringBuilder`；`AnsiRenderer` 内部维护可复用的 `Array<UInt8>` 缓冲，`render` 直接写字节
- **预期**：每帧少 2 次整屏拷贝与 2 个临时对象；峰值内存与分配量同步下降
- **代价**：`TerminalWriter` 是公开接口（`public interface`），加方法属对外契约变更；`ansi` 包目前不依赖 `term` 之外的东西，改动要保证 `ansi` 不反向依赖 `render`
- **验证**：同 #1 的 `cjprof heap` 对照 + 输出字节一致性校验
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `AnsiSequence.styleFor` 每个变化单元格一套临时对象

- **现状**：`styleFor` 每次调用新建 `ArrayList<String>`（最多 11 个元素）、每个颜色参数一次字符串插值（`"38;5;${index}"` 等）、再建一个 `StringBuilder`（`AnsiSequence.cj:126-155`）。全屏重绘 80×24 = 1920 个单元格 → 每帧约 1920 组临时对象；差分帧按变化单元格数线性增长
- **方案**：把 `(fg, bg, modifier)` 压成一个可比较的整型键（`AnsiColor` 已是 5 个定长字段），键相同就复用上一段已写出的 SGR；需要输出时直接把参数追加到帧级 `StringBuilder`，不建中间 `ArrayList` / 子 `StringBuilder`
- **预期**：全屏重绘时 `styleFor` 的分配从 O(单元格数) 降到 O(不同样式数)（通常 < 20）；端到端收益取决于 `styleFor` 在帧渲染中的自耗时占比（**未测**）
- **代价**：样式键编码要保证不碰撞（5 个字段打包进 `Int64` 需评估位宽），或退化为结构体比较；可读性下降
- **验证**：`cjprof record` 取 `styleFor` 自耗时占比（改前/改后，同输入 80×24×1000 帧，`-O2`，取中位数）；先证明占比 ≥ 5% 再动手
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `draw` 每帧两次 `size()` + 重复清洗/测宽

- **现状**：`BufferRenderer.cj:81-82` 连续调两次 `size()`，每次 `sizeProvider.size()` 在 `IoctlSizeProvider` 下就是一次 `ioctl(TIOCGWINSZ)` 系统调用；`sanitizeSymbol` 与 `displayWidth` 在 `draw` 与 `ScreenBuffer.set` 中各执行一次（见发现 #12）
- **方案**：`draw` 只取一次尺寸；把清洗/测宽收敛到 `ScreenBuffer.set` 一处（或让 `set` 返回宽度供调用方跳列）
- **预期**：每帧少一次 `ioctl`、每单元格少一次字符串清洗与一次宽度扫描（单元格数为 1920 量级时是 1920 次 `sanitizeSymbol` + 1920 次 `runes()` 遍历）
- **代价**：`ScreenBuffer.set` 的返回值语义要扩展（`Unit` → 宽度或 `Bool`），属公开 API 变更
- **验证**：`strace -c` 看 `ioctl` 次数、`cjprof` 看 `sanitizeSymbol` / `displayWidth` 自耗时；两者都需改前基线
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `EscapeParser.consume` 用 `remove(at: 0)` 逐字节搬移

- **现状**：`consume(count)` 循环 `bytes.remove(at: 0)`（`EscapeParser.cj:153-159`），每次移除都搬移剩余元素 → 移除 k 个字节是 O(k²)。真实按键序列 k ≤ 6，代价可忽略；只有发现 #4 的异常累积场景才会退化
- **方案**：改成「读游标 + 批量 `remove(0, count)`」（一次性搬移），或在解析结束后 `bytes = ArrayList(slice)` 重建
- **预期**：单次解析的搬移从 O(k²) 降到 O(k)；在正常输入下收益低于噪声，只有异常输入才有意义
- **代价**：游标状态要与 `pendingCount` / `isLoneEscape` 的语义对齐，容易引入边界 bug
- **验证**：`cjpm bench -O2` 对 1e6 次 `feed+next` 取中位数；若耗时差 < 5% 建议不做
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

### [堆内存] 每帧整帧 `String → Array<UInt8>` 拷贝

- **现状**：`AnsiRenderer` 每帧用 `StringBuilder` 组装整帧文本并 `toString()`（`f_tui/src/ansi/AnsiRenderer.cj:160-211`），`StdoutTerminalWriter.write` 再 `text.toArray()` 复制成 `Array<UInt8>`（`f_tui/src/term/TerminalWriter.cj:38`）才能进 CFFI。80x24 纯文本约 2–5 KB/帧，200x60 全屏真彩约 30–60 KB/帧；按 30 fps 估算约 1–2 MB/s 的短命大对象，生命周期只到 `write` 返回，全部是「活过一帧即死」的 promotion 候选
- **方案**：让字节视图直接进 CFFI（避免中间 `Array`；具体能否取 `String` 的 UTF-8 内部字节需按 SDK 1.3.0 的 `std.core` String API 核对，`acquireArrayRawData` 只对 `Array` 有效）；或 `StdoutTerminalWriter` 持有一个按需扩容、不收缩的复用 `Array<UInt8>`，`write` 内拷入后复用
- **预期**：每帧少一次与帧大小等长的堆分配；`getAllocatedHeapSize` 增速按「帧字节数 × 帧率」线性下降，老年代晋升压力同比减少
- **代价**：复用缓冲给 writer 引入可变状态（与 `AnsiRenderer` 的单写者假设绑定，多线程写同一 writer 会串帧）；依赖字符串内部表示则对 SDK 版本敏感
- **验证**：同一 TUI 场景（全屏重绘 200x60，30 fps）跑 10 分钟，对比改前/改后 `getAllocatedHeapSize()` 增速、GC 次数、P99 帧耗时；`-O2`、同机、同输入
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 帧字节的多次整体复制

- **现状**：一帧数据至少经历「`StringBuilder` 扩容拷贝 → `toString` → `toArray`」三次整体拷贝（`AnsiRenderer.cj:160-211` + `TerminalWriter.cj:38`）；没有 `cjprof` 数据，自耗时占比未知，`flush()` 为空操作所以无额外 syscall
- **方案**：`AnsiRenderer` 把 `StringBuilder` 内容写入一个可复用字节缓冲并直接交给 `write`；或 `TerminalWriter` 增加接收 `StringBuilder` / 字节视图的写入口，由 `AnsiRenderer` 按需选择
- **预期**：纯拷贝路径的 CPU 时间下降，量级取决于帧大小与帧率；端到端收益在拿到 profile 前无法估计
- **代价**：`ansi` 与 `term` 两层接口同时改动，需要同步改测试替身（`RecordingWriter` 等）
- **验证**：`cjprof record` 跑「全屏重绘 200x60 × 1000 帧」，看 `toString` / `toArray` / `memcpy` 的 self time 占比，再决定是否值得改
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 帧渲染的热点在 `AnsiSequence.styleFor` 与 `StringBuilder.append` 链路 | `f_tui/src/ansi/AnsiSequence.cj:126-155`、`AnsiRenderer.cj:138-202` | 自耗时占比（%）、调用次数 | `cjprof record` 跑 80×24 全屏重绘 1000 帧（`-O2`），取 `styleFor` self time |
| 2 | `ScreenBuffer` 双缓冲是主要分配源（占每帧分配量大头） | `BufferRenderer.cj:90`、`AnsiRenderer.cj:198` | 每帧分配字节数、GC 次数 | `cjprof heap` + 60 fps 稳态 30 s，统计 `getAllocatedHeapSize()` 增量 |
| 3 | 每帧两次 `ioctl(TIOCGWINSZ)` 在低延迟场景可观测 | `BufferRenderer.cj:81-82` | 单次 ioctl 耗时、帧预算占比 | `strace -c` 统计调用次数与耗时；对照「取一次尺寸」的实验版本 |
| 4 | 信号路径 `restore()` 与渲染线程的竞争在真实使用中可观测（终端偶发停留在备用屏） | `Terminal.cj:26-37,132-139` | 复现步骤、失败率 | 渲染循环里持续发 `SIGTERM`，重复 100 次统计「退出后仍处于备用屏 / echo 未恢复」的比例 |
| 5 | `EscapeParser` 在真实终端输入下会出现「超时残留 CSI 吞键」 | `EscapeParser.cj:111-126` | 触发频率 | 用 pty 注入 `ESC [` + 25 ms 停顿 + `q`，100 次统计丢键次数（逻辑上应 100% 丢，需实测确认终端时序） |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `text.toArray()` 每帧分配占进程分配量的大头，是 GC 停顿的主要来源 | `f_tui/src/term/TerminalWriter.cj:38` | 分配量与 GC 占比 | `cjprof heap` 跑 30 fps 全屏重绘 10 分钟，对比 `getAllocatedHeapSize` 增速 |
| 2 | `TerminalSize.size()` 每次 `ioctl(TIOCGWINSZ)` 是一次系统调用；若宿主每帧调用，syscall 开销可测 | `f_tui/src/term/TerminalSize.cj:79-90` | 调用频次与单次耗时 | 宿主侧分段计时 + `strace -c` 统计 `ioctl` 次数 |
| 3 | 信号回调在独立线程执行，`RawMode` 的 `saved` / `active` 存在真实数据竞争 | `f_tui/src/term/RawMode.cj:26-27` | `std.runtime.registerSignalHandler` 的线程模型 | 查 SDK 1.3.0 `std.runtime` 文档；并发压测（主线程反复 enter/restore + 触发 SIGINT） |
| 4 | 高负载 pty 下短写 / EINTR 真实发生（决定发现 #1 的严重度是否维持） | `f_tui/src/term/PosixFfi.cj:350-355` | `n < size` 与 `n == -1` 的发生比例 | 在 `write` 前后埋点统计返回值分布，跑大帧 + 慢消费者 pty |

## 文件覆盖

> 与 `files/f_tui.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_tui/README.md` | .md | ✅ | — |
| 2 | `f_tui/README_en.md` | .md | ✅ | — |
| 3 | `f_tui/doc/terminal-backend.md` | .md | ✅ | — |
| 4 | `f_tui/src/TuiException.cj` | .cj | ✅ | — |
| 5 | `f_tui/src/ansi/AnsiRenderer.cj` | .cj | ✅ | — |
| 6 | `f_tui/src/ansi/AnsiRenderer_test.cj` | .cj | ✅ | — |
| 7 | `f_tui/src/ansi/AnsiSequence.cj` | .cj | ✅ | — |
| 8 | `f_tui/src/ansi/ScreenBuffer.cj` | .cj | ✅ | — |
| 9 | `f_tui/src/input/EscapeParser.cj` | .cj | ✅ | — |
| 10 | `f_tui/src/input/KeyReader.cj` | .cj | ✅ | — |
| 11 | `f_tui/src/input/KeyReader_test.cj` | .cj | ✅ | — |
| 12 | `f_tui/src/input/TerminalKey.cj` | .cj | ✅ | — |
| 13 | `f_tui/src/package.cj` | .cj | ✅ | — |
| 14 | `f_tui/src/render/BufferRenderer.cj` | .cj | ✅ | — |
| 15 | `f_tui/src/render/BufferRenderer_test.cj` | .cj | ✅ | — |
| 16 | `f_tui/src/render/Terminal.cj` | .cj | ✅ | — |
| 17 | `f_tui/src/render/Terminal_test.cj` | .cj | ✅ | — |
| 18 | `f_tui/src/term/ByteSource.cj` | .cj | ✅ | — |
| 19 | `f_tui/src/term/FakePosixFfi_test.cj` | .cj | ✅ | — |
| 20 | `f_tui/src/term/PosixFfi.cj` | .cj | ✅ | — |
| 21 | `f_tui/src/term/PosixFfi_test.cj` | .cj | ✅ | — |
| 22 | `f_tui/src/term/RawMode.cj` | .cj | ✅ | — |
| 23 | `f_tui/src/term/RawMode_test.cj` | .cj | ✅ | — |
| 24 | `f_tui/src/term/TerminalSize.cj` | .cj | ✅ | — |
| 25 | `f_tui/src/term/TerminalSize_test.cj` | .cj | ✅ | — |
| 26 | `f_tui/src/term/TerminalWriter.cj` | .cj | ✅ | — |

合计：`.cj` 23 个 / `.md` 3 个 / 共 26 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 5（#1 #9 #10 #15 #17）、设计/边界 2（#11 #2）、规范与可读性 3（#6 #16 #18）；安全性未命中：无外部字符串拼命令/SQL/路径，输出前统一 `sanitizeSymbol` 过滤 ESC，未发现注入面 |
| §1 死代码 | 3 | 逐个 `private` / `internal` 符号搜过引用（`consume` / `parseCsi` / `parseUtf8` / `utf8Length` / `mapCsi` / `mapSs3` / `sameAsPrevious` / `emit` / `toAnsiColor` / `indexOf` / `runeWidth` / `isWide` / `POLLIN` / `fTuiDispatchExit` / `fTuiSignalHandler` / `F_TUI_EXIT_CALLBACKS` 均有调用者）；命中 `FakePosixFfi.written`（非 public 类的 public 成员，全项目无读取）、`KeyReader.cj:60` 不可达 `None`、`Terminal_test.cj:19` 未用 import。对外可达的 `public`（`SIGWINCH`、`sameCell`、`isPlain`、`TuiErrorCode.Size/Write` 等）按硬原则一不判死代码，只在 #18 记为接线缺失 |
| §2 重复逻辑 | 1（合并 6 组） | 已把 20 个文件的函数体逐对比较：`sanitizeSymbol`/`displayWidth` 双跑、`sameCell`↔`sameAsPrevious`、三份录制 writer、两份 `winSize`、跨模块宽度表、跨模块 SGR 字面量，合并为 #12；`AnsiColor.foregroundParams`/`backgroundParams` 前缀不同（38 vs 48），判为可接受的数据差异不合并 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `throw UnsupportedException` 占位；`parseUtf8` 的 `catch (e: Exception) { Some(Unknown) }` 有明确降级语义（非法 UTF-8 → Unknown），且与文档 §5 一致；`BufferRenderer.size()` 的 `case None => ()` 是有意的「沿用上次尺寸」，有注释 |
| §4 栈溢出 | 0 | 全部分析路径无递归：`EscapeParser` 用循环 + 显式索引，`ScreenBuffer.clone` 双循环，`AnsiRenderer.render` 三层循环；`ScreenCell.equals`/`ScreenBuffer.sameCell` 只比较一层字段，不自引用 |
| §5 OOM | 2 | #4（pending 无上限，量化 1 MB 输入 → 1–2 MB）、#11（按 `UInt16` 尺寸分配，最坏 ≈ 170 GB） |
| §6.1 热点瓶颈 | 0 | 仓库内没有 f_tui 的 `cjprof` / `cjpm bench` 数据，热点结论不成立；疑似点全部进「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 模块内没有锁（`Mutex`/`synchronized` 零出现），并发问题按 §12 报在 #3 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无批处理窗口；`KeyReader` 的单线程阻塞读是接口设计（`ByteSource` 单字节），不属并发串行热点 |
| §6.4 低效算法 | 0 | `consume` 的 `remove(at: 0)` 是 O(k²) 但 k ≤ 6（真实按键序列），不构成算法瓶颈，只写进优化 #5；`render` 差分是 O(宽×高) 单遍扫描，符合差分渲染的最低要求 |
| §7 降堆内存方案 | 2 | 双缓冲（优化 #1）、输出双拷贝（优化 #2） |
| §8 降 CPU 方案 | 3 | `styleFor` 分配（#3）、`draw` 重复 `size()`/清洗（#4）、`consume` 搬移（#5） |
| §9 local mode 可行性 | 0 | 不成立：`styleFor` 的返回值会逃逸到帧 `StringBuilder`/`String`（不能 `@ local!` 返回）；`ScreenBuffer`/`ScreenCell` 是帧级长生命周期对象，不属「函数内创建即释放」；`EscapeParser.parseUtf8` 的 `Array<UInt8>` 只有 2–4 B/键，无峰值收益。且无前后峰值数据，按清单只能是待验证假设，故不单列 |
| §11 现有代码的 BUG（存量） | 18 | 本轮 18 条发现全部为存量（`git blame` 均为 `d061ff0e71`），已逐条核对边界（空数组 / 空串 / 0×0 尺寸 / 最后一列 / `EINTR` / `UInt16` 上限） |
| §12 并发安全与锁粒度 | 1 | 共享点只有 `F_TUI_EXIT_CALLBACKS`（全局 `ArrayList`）与 `SystemExitHook.installed`（`private static var`），另加信号线程调 `restore()` 触碰渲染状态，合并为 #3；`AnsiRenderer` / `ScreenBuffer` / `EscapeParser` 均为宿主单线程持有的可变对象，未发现跨线程共享路径（宿主多线程复用同一 `Terminal` 属调用方契约，模块未声明线程安全） |
| §14 功能完备性与 README 覆盖 | 3 | #5（`version()` 与仓库版本漂移）、#7（README 缺 `render` / `RawMode.restore` / 常量 / Termios 平台布局）、#18（`TuiErrorCode.Size/Write` 未接线）；承诺源与缺失证据均已成对给出；`SIGWINCH` 常量导出但仓内无 resize 事件 API 属信息（文档 §4 明确是轮询 `size()`，不算缺失） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；3 个 `.md` 均逐行读过并按 §13/§14 对照实现 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1/#2、设计 #5（两套尺寸入口）、可读性 #3；语言特性无问题（`struct` 值语义、`Option` 均按惯用法使用）；安全性无外部输入拼接，无注入面 |
| §1 死代码 | 0 | 逐个符号搜引用：`RawMode.ffi/fd/saved/active` 均在 `enter/restore` 内使用；`TerminalSize.last` 被 `lastKnown` 读取；`saved`/`active` 之外的 private 字段无残留。`snapshot`、`lastKnown`、`TuiSize.toString`、`IoctlSizeProvider` 全仓仅测试 / README 引用，但所属顶层声明均为 `public` 且对外可达，按硬原则一不判死代码，仅记「仓内无生产引用」；测试文件内的 `FakeSizeProvider`（`internal` 类）成员被同类测试使用，不算死代码；无未使用 import |
| §2 重复逻辑 | 2 | 未知尺寸判定 5 处（#4）；「最近一次成功尺寸」缓存两套且语义相反（#5）。同文件内 `TuiSize` 的 3 个函数体两两比对无语义重合；`PosixFfi_test` 与 `RawMode_test` 的准备代码属测试豁免 |
| §3 空实现 | 0 | `StdoutTerminalWriter.flush` 返回 `true` 属「无用户态缓冲」的 Null Object，`TerminalWriter.cj:27` 注释与 `doc/terminal-backend.md:138` 均有说明，不判空实现；本部分无 `TODO`、无空 `catch` |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构；`TuiSize.toString` 只拼两个数值 |
| §5 OOM | 0 | 无全量物化、无按不可信长度预分配、无全局容器；`text.toArray()` 的大小上界是一帧（由 `ScreenBuffer` 尺寸约束），属分配优化而非 OOM 面 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / bench 数据，任何热点结论不成立；帧拷贝与 `ioctl` 频率已列入待验证假设 1/2 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn`、无批处理；单写者 `TerminalWriter` 是接口语义，不是并发串行热点 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热路径 `contains`、无 `remove(at: 0)`；`IoctlSizeProvider.size` 为 O(1) |
| §7 降堆内存方案 | 1 | 每帧 `toArray` 全帧拷贝，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 帧字节多次整体复制，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 帧字节缓冲必须逃逸到 CFFI 调用 / writer 成员，`@local` 不成立；无峰值内存数据，不做改造建议 |
| §11 现有代码的 BUG（存量） | 7 | #1 短写/EINTR 永久停写、#2 restore 失败被吞、#3 快照残留、#4 未知尺寸判定重复、#5 两套 last 缓存、#6 README 漏项、#7 状态无同步（待确认） |
| §12 并发安全与锁粒度 | 1 | #7：`RawMode` 字段无同步、退出钩子跨线程可达；`StdoutTerminalWriter` 无状态，`TerminalSize.last` 无生产共享路径 |
| §14 功能完备性与 README 覆盖 | 1 | #6：`restore` / `flush` / `toString` 三个 public 成员未进 README；`SizeProvider` / `TerminalWriter` 接口本身按既有清单惯例不单列，不算遗漏；模块级能力（raw mode、尺寸、writer）均已接线，无半成品 |
| 文件覆盖（§13 等） | 6/6 | 本部分清单 6 个文件全部读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 12 |
| 轻微 | 12 |
| 其中存量 | 25 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分是 f_tui 的「字节流 + 渲染管线」核心：`term/PosixFfi` 的 FFI 边界、`input` 的增量解析、`ansi` 的帧缓冲与差分、`render` 的生命周期与 `Buffer → ANSI` 翻译。整体结构清楚、职责划分与 README 的分层一致，测试全部走可注入替身、不碰真实 TTY，公开 API 的注释密度也高于仓库平均。没有发现阻塞级缺陷：无递归、无锁、无外部输入拼接、无未捕获的 `Option` 丢弃，`ScreenCell` 的差分比较与宽字符 `skip` 机制在常见输入下是正确的（测试也覆盖了这些路径）。

真正需要排期的是三处「终端可靠性」问题，它们都在错误路径上，正常帧渲染跑不到：

1. `PosixFfi.writeBytes` 没有短写 / `EINTR` 重试，而 `AnsiRenderer` 的 `broken` 是单向的 —— 一次短写就让画面永久冻结，这是本模块最值得先修的一条；
2. 退出钩子表与 `restore()` 在信号路径上没有同步，终端恢复与帧写入可能交错；
3. `EscapeParser` 对残缺 CSI 没有超时丢弃策略：既会吞掉下一个按键，缓冲区也没有上限。

文档侧的问题集中且好修：README 的「其他公开 API」漏了 `AnsiRenderer.render`、`RawMode.restore` 与全部 `public const`，`Termios` 只抄了 macOS 布局（Linux 按 README 写会编译不过），`doc/terminal-backend.md` 有三处与实现/测试名不符；`version()` 还停在 1.3.17，与 `cjpm.toml` / `f_version` 的 1.3.2021 不一致。这些都属于「对外契约写错」，建议与代码修复一起在本轮收掉。

性能方面本部分没有任何测量数据（仓库没有 f_tui 的 profile / bench），因此只给了 5 条无基线的优化方案与 5 条待验证假设：最值得先测的是每帧两次整屏 `ScreenBuffer` 分配（`draw` 新建 + `render` `clone`）与 `styleFor` 的每单元格临时对象 —— 它们决定 60 fps 下的分配速率与 GC 抖动，但在拿到 `cjprof` 数据前不应当作结论，也不应进 `tasks.md`。

**第 2 部分**：`src/term` 这 6 个文件结构小而清晰：系统调用全部收敛在 `PosixFfi`，`RawMode` / `TerminalSize` / `TerminalWriter` 三个职责边界干净，测试通过注入假实现覆盖了 enter/restore 幂等、ioctl 失败、尺寸变化重读等主路径，整体质量良好。风险集中在「失败路径」而非主路径：一是 `write(2)` 的短写与 EINTR 没有重试，被 `AnsiRenderer` 放大成进程级永久停写，且截断点可能污染终端状态（#1，唯一阻塞项）；二是 `restore` 把 `tcsetattr` 失败吞掉并清掉重试机会，可能把用户终端留在 raw 模式（#2）。其余是重复判定 / 双份缓存 / README 漏项这类维护性问题，可随下一次改动顺带收敛。性能上唯一值得量化的是每帧整帧 `toArray` 拷贝，但没有改前基线，只能作为待验证假设。存量缺陷 7 条（含 1 条待确认），是否纳入修复待用户决定。

范围外提示（不计入本部分统计）：`PosixFfi.cj:332-342` 的 `poll` / `read` 把 `EINTR` 统一当超时返回 `None`，与 #1 同源但属第 1 部分；`README.md:69` 的 `Termios` 字段按 macOS 布局（`UInt64` / `$20`）列出，与 Linux 构建的 `UInt32` / `$32` 不一致。

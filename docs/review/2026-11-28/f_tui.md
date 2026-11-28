# f_tui 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_tui_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_tui`（26 个文件：23 个 .cj + 3 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：终端字节流读写的正确性（部分写 / EOF / 坏序列）、raw mode 恢复、退出钩子与信号、每帧分配量、死代码
- **报告版本**：v1（由主 Agent 直接审查；生产代码逐文件读完，`*_test.cj` 为抽查）

## 发现

### [严重][存量] `writeBytes` 只调用一次 `write(2)`，部分写与 `EINTR` 都会导致半帧输出

- **位置**：`f_tui/src/term/PosixFfi.cj:345-356`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（系统调用返回值未处理）、§3（静默失败）
- **证据**：静态确定 —— `let n = write(fd, handle.pointer, UIntNative(bytes.size)); n == IntNative(bytes.size)`，没有循环续写、没有 `errno == EINTR` 重试分支
- **描述**：POSIX `write` 对管道/pty 允许短写（Linux pty 缓冲常见 4KB~64KB 量级），而一帧 200×60 带样式的 ANSI 串是数十 KB。短写时：前半帧已经出现在屏幕上、函数返回 `false`、`AnsiRenderer.emit` 把渲染器标成 `broken` 并永久停止刷新 —— 用户看到的是**半帧错乱且再也不更新**。`EINTR`（信号打断）同理，且 `f_tui` 自己就注册了 `SIGINT`/`SIGTERM` 处理器，中断窗口真实存在
- **建议**：循环写直到写完或遇到不可重试错误；`n < 0 && errno == EINTR` 重试；返回「已写字节数」而不是布尔

### [严重][存量] 不完整的 ESC/CSI 序列会永久堵死输入

- **位置**：`f_tui/src/input/KeyReader.cj:40-69`（`readKey` / `finishPending`）、`f_tui/src/input/EscapeParser.cj:80-87`（`flushEscape` 只处理「单个 ESC」）
- **来源**：存量
- **判据**：review-checklist §11（错误恢复路径缺失）、§5（无界累积）
- **证据**：静态确定 —— `finishPending()` 只调 `flushEscape()`，而 `flushEscape()` 仅在 `isLoneEscape()`（`size==1 && bytes[0]==0x1B`）时清空；`parseCsi()` 在字节不足时直接 `return None` 且**保留**字节；`consume` 只在解析成功时调用
- **描述**：一旦读到 `ESC [`（或 `ESC O`、半个 UTF-8 首字节）后输入中断（终端关闭、ssh 断开、用户只按了 ESC 再按了 `[` 之后卡住），`bytes` 里就永久留着这段残序列：此后每次 `readKey` 都先 `parser.next()` → `None` → `read(timeout)` → 超时 → `finishPending()` → `None`，**新按键全部被这段残序列挡住**，界面从此不再响应键盘（只有 Ctrl-C 能退出）。这是 TTY 解析器最常见的死锁形态
- **建议**：`finishPending()` 在「非 lone-ESC 且超时」时把整个 `bytes` 丢弃（或至少丢弃到下一个可解析边界）并返回 `Unknown`；`parseCsi` 增加长度上限（如 32 字节）防止无界累积

### [一般][存量] `RawMode.restore()` 丢弃 `setTermios` 的失败，终端可能停在 raw mode

- **位置**：`f_tui/src/term/RawMode.cj:61-69`
- **来源**：存量
- **判据**：review-checklist §11（返回值未检查）、§3（静默失败）
- **证据**：静态确定 —— `if (let Some(value) <- saved) { ffi.setTermios(fd, value) }` 的返回值被丢弃，随后无条件 `active = false`
- **描述**：`tcsetattr` 失败（fd 已关闭、进程失去控制终端）时对象仍报告「已恢复」，`Terminal.restore()` 也认为完成；用户 shell 会卡在无回显、无行缓冲的状态，只能 `reset` 救回
- **建议**：失败时抛 `TuiException`（或至少 WARN 并保留 `active=true` 以便重试）；`Terminal.restore()` 同理检查 `renderer.reset()` 的结果

### [一般][存量] 退出回调表与 `installed` 标志都是无同步的模块级可变状态

- **位置**：`f_tui/src/render/Terminal.cj:26`（`let F_TUI_EXIT_CALLBACKS: ArrayList<() -> Unit>`）、`f_tui/src/render/Terminal.cj:48-59`（`private static var installed`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态、检查-然后-写入）
- **证据**：静态确定 —— `register()` 直接 `F_TUI_EXIT_CALLBACKS.add(action)`；`installed` 的「读-判-写」没有锁/原子量
- **描述**：`ExitHook.register` 是公开 API，多线程各自创建 `Terminal` 时会并发 `add` 到同一个 `ArrayList`（数据竞争，可能丢回调或破坏内部数组），`installed` 竞态会让 `atExit` / 信号处理器被注册两次，退出时 `restore()` 被重复执行
- **建议**：用 `Mutex` 或 `AtomicBool` 包住「注册 + 首次安装」；`F_TUI_EXIT_CALLBACKS` 改为不可变快照替换

### [一般][存量] 信号处理器里执行任意用户回调（非异步信号安全）

- **位置**：`f_tui/src/render/Terminal.cj:28-37`（`fTuiDispatchExit` / `fTuiSignalHandler`）、`Terminal.cj:57-58`（注册到 `SIGINT` / `SIGTERM`）
- **来源**：存量
- **判据**：review-checklist §12.1（异步语义）、§10
- **证据**：静态确定 —— 处理器直接遍历并调用回调，回调里是 `this.restore()` → `tcsetattr` / `write` / 可能的日志与锁
- **描述**：`tcsetattr`、`write`、`malloc`、加锁都不是 async-signal-safe；若信号打断的正是这些调用内部（例如 `AnsiRenderer.emit` 持锁写终端），会死锁或重入破坏状态。当前实现让 handler 返回 `false`（未处理，进程照常退出），风险窗口在「信号恰好在渲染/恢复中途到达」
- **建议**：handler 只置一个 `volatile`/原子标志并写 1 字节到 self-pipe，由主循环执行恢复；或仅依赖 `atExit`

### [轻微][存量] `EscapeParser.consume` 用 `remove(at: 0)` 逐字节搬运

- **位置**：`f_tui/src/input/EscapeParser.cj:153-159`
- **来源**：存量
- **判据**：review-checklist §6.4（低效算法）
- **证据**：静态确定 —— `while (index < count) { bytes.remove(at: 0) }`，每次删除都会搬移剩余元素
- **描述**：`ArrayList.remove(at:0)` 是 O(n)，一次 `consume(k)` 是 O(k·n)。字节缓冲通常只有个位数长度，实际影响可忽略，故定为轻微
- **建议**：记录读偏移 + 批量 `remove(range)`，或在 `next()` 返回时 `drain`

### [轻微][存量] `readByte` 用 `poll` 只判「有事件」，EOF/HUP 与超时都返回 `None`

- **位置**：`f_tui/src/term/PosixFfi.cj:321-343`
- **来源**：存量
- **判据**：review-checklist §11（错误分类）
- **证据**：静态确定 —— `ready > 0` 时不检查 `pfd.revents & POLLIN`，直接 `read`；`n != 1` 统一 `None`
- **描述**：终端被挂断（`POLLHUP`）与「暂时没按键」在接口上不可区分，上层只能当作超时继续轮询，表现为「终端已断开但进程空转」；`revents` 里的错误位也被忽略
- **建议**：`PosixFfi` 增加 `Option<Eof>` 之类的三态返回，或暴露 `revents` 供上层判断

## 优化可行性方案

### [堆内存 + CPU] 每帧三次全屏物化，可降到一次

- **现状**：`BufferRenderer.draw` 每条帧新建 `ScreenBuffer(width, height)`（`BufferRenderer.cj:90`），`ScreenBuffer.set` 内部再对每个单元格执行 `sanitizeSymbol`（新建 `StringBuilder` 并逐 rune `String([rune])`，`ScreenBuffer.cj:100-116`、`107`），`AnsiRenderer.render` 结束时又 `previous = Some(frame.clone())`（`AnsiRenderer.cj:198`）—— 一帧 200×60 时的分配次数约为 `3 × 12000` 次字符串 + 一次整帧深拷贝
- **方案**：① 复用两块 `ScreenBuffer`（双缓冲，按尺寸变化才重建）；② `sanitizeSymbol` 只在 `symbol` 含控制字符时执行，纯 ASCII 快路径直接返回原串；③ `clone()` 换成整块数组拷贝或直接交换两个缓冲区引用
- **预期**：帧分配次数从 ~36000 次降到接近 0（稳态），GC 压力与帧延迟同步下降；量级需实测
- **代价**：双缓冲需要额外一块同尺寸缓冲（约 `w*h*(sizeof(ScreenCell))`），并保证宿主拿到的 `Buffer` 不被就地修改
- **验证**：`cjpm bench`/`cjprof` 在 `-O2` 下跑固定 200×60 帧序列 10000 次，比较分配字节数（`getAllocatedHeapSize`）、中位帧耗时与 GC 次数；改前基线必须先采
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 大幅面刷新在实际 pty 上会触发短写 | `PosixFfi.cj:345-356` | 短写发生频率 | 在 4KB 写缓冲的 pty（`script` / expect）下连续渲染 200×60 全屏，统计 `write` 返回值 < size 的比例 |
| 2 | 每帧 clone + sanitize 的 GC 占比 | `AnsiRenderer.cj:198`、`ScreenBuffer.cj:107` | 分配字节占比 | `cjprof record` 跑 10 秒 60fps 渲染，看分配采样里 `String` / `ScreenCell` 占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_tui/README.md` | .md | ✅ | 全文；分层与「只依赖 ratatui 基础包」的约束与实现一致 |
| 2 | `f_tui/README_en.md` | .md | 未读 | 未展开 |
| 3 | `f_tui/doc/terminal-backend.md` | .md | 未读 | 未展开 |
| 4 | `f_tui/src/TuiException.cj` | .cj | 未读 | 异常类（模板） |
| 5 | `f_tui/src/ansi/AnsiRenderer.cj` | .cj | ✅ | 见优化方案；差分逻辑本身正确 |
| 6 | `f_tui/src/ansi/AnsiRenderer_test.cj` | .cj | 未读 | 测试 |
| 7 | `f_tui/src/ansi/AnsiSequence.cj` | .cj | ✅ | SGR 拼装正确 |
| 8 | `f_tui/src/ansi/ScreenBuffer.cj` | .cj | ✅ | 见优化方案 |
| 9 | `f_tui/src/input/EscapeParser.cj` | .cj | ✅ | 见发现 2/6 |
| 10 | `f_tui/src/input/KeyReader.cj` | .cj | ✅ | 见发现 2 |
| 11 | `f_tui/src/input/KeyReader_test.cj` | .cj | 未读 | 测试 |
| 12 | `f_tui/src/input/TerminalKey.cj` | .cj | 未读 | 枚举 |
| 13 | `f_tui/src/package.cj` | .cj | 未读 | `version()` |
| 14 | `f_tui/src/render/BufferRenderer.cj` | .cj | ✅ | 见优化方案 |
| 15 | `f_tui/src/render/BufferRenderer_test.cj` | .cj | 未读 | 测试 |
| 16 | `f_tui/src/render/Terminal.cj` | .cj | ✅ | 见发现 3/4/5 |
| 17 | `f_tui/src/render/Terminal_test.cj` | .cj | 未读 | 测试 |
| 18 | `f_tui/src/term/ByteSource.cj` | .cj | ✅ | 薄封装 |
| 19 | `f_tui/src/term/FakePosixFfi_test.cj` | .cj | 未读 | 测试替身 |
| 20 | `f_tui/src/term/PosixFfi.cj` | .cj | ✅ | 见发现 1/7 |
| 21 | `f_tui/src/term/PosixFfi_test.cj` | .cj | 未读 | 测试 |
| 22 | `f_tui/src/term/RawMode.cj` | .cj | ✅ | 见发现 3 |
| 23 | `f_tui/src/term/RawMode_test.cj` | .cj | 未读 | 测试 |
| 24 | `f_tui/src/term/TerminalSize.cj` | .cj | ✅ | 无问题 |
| 25 | `f_tui/src/term/TerminalSize_test.cj` | .cj | 未读 | 测试 |
| 26 | `f_tui/src/term/TerminalWriter.cj` | .cj | ✅ | `flush()` 恒 true，无缓冲（文档已声明） |

合计：`.cj` 13 个生产文件全部读完 / 10 个测试文件未读 / `.md` 1 读 2 未读。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 发现 1（短写）、2（输入死锁） |
| §1 死代码 | 0 | 抽查的 `private` 符号（`consume` / `parseCsi` / `mapCsi` / `fTuiDispatchExit` / `indexOf`）均有调用者；`public` 常量被测试引用（`TERMIOS_CC_COUNT` / `ISIG` / `OPOST`），对外可达不判 |
| §2 重复逻辑 | 1 | `mapCsi` 与 `mapSs3` 的 `0x41/0x42` 分支重复（未单列，属小重复）；`@When[os == "Windows"]` 的两个 `SystemExitHook` 是条件编译必需 |
| §3 空实现 | 1 | 发现 3（`restore` 丢弃失败） |
| §4 栈溢出 | 0 | 无递归 |
| §5 OOM | 1 | 发现 2 的残序列无界累积（合并进该条） |
| §6.1 热点瓶颈 | 0 | 无 profile，帧分配列优化方案与待验证假设 2 |
| §6.2 大粒度锁 | 0 | 模块内无锁（本身是发现 4 的问题） |
| §6.3 并发串行 | 0 | 无 |
| §6.4 低效算法 | 2 | 轻微 1（`remove(at:0)`）、优化方案（三次全屏物化） |
| §7 降堆内存方案 | 1 | 双缓冲 + sanitize 快路径 |
| §8 降 CPU 方案 | 1 | 同上 |
| §9 local mode 可行性 | 0 | 帧缓冲是跨帧持有的状态，不是函数内临时大对象；收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 3 | 发现 1/2/3 |
| §12 并发安全与锁粒度 | 2 | 发现 4（无同步注册）、5（信号处理器） |
| §14 功能完备性与 README 覆盖 | 1 | README「只依赖 f_base 与 ratatui 基础包」与 `cjpm.toml` 抽查一致；`doc/terminal-backend.md` 未读，未核对 |
| 文件覆盖（§13 等） | 16/26 | 未读项逐行标注（测试文件为主） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 3 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

分层与可注入接口做得好（`PosixFfi` / `ByteSource` / `TerminalWriter` / `SizeProvider` 四个接缝让 `cjpm test` 不碰真 TTY），条件编译也把 Windows 占位实现隔离干净。两个严重问题都在「终端是字节流」这个前提上：`write` 会短写、ESC 序列会残缺——前者让画面半帧卡死，后者让键盘永久失效，二者都不是靠测试替身能发现的（假 writer 永远写成功）。建议优先补这两处的失败路径与对应测试。存量 7 条（严重 2 / 一般 3），是否纳入修复待用户决定。

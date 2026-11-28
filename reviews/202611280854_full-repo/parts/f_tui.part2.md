# f_tui 模块审查报告（模块第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_tui`（本部分 6 个 `.cj` + 0 个 `.md`，共 6 个文件；全部位于 `src/term/`，第 1 部分为 README / doc / ansi / input / render 及 `PosixFfi.cj`、`ByteSource.cj`、`FakePosixFfi_test.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空；本部分全部记为「存量」）
- **审查重点**：终端字节流读写（短写 / EINTR / 残缺序列）、raw mode 恢复、退出钩子与信号、每帧分配；另按公共指令机械过死代码与重复逻辑
- **报告版本**：v1（仅本部分，最终 `<module>.md` 由主 Agent 合并）

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `text.toArray()` 每帧分配占进程分配量的大头，是 GC 停顿的主要来源 | `f_tui/src/term/TerminalWriter.cj:38` | 分配量与 GC 占比 | `cjprof heap` 跑 30 fps 全屏重绘 10 分钟，对比 `getAllocatedHeapSize` 增速 |
| 2 | `TerminalSize.size()` 每次 `ioctl(TIOCGWINSZ)` 是一次系统调用；若宿主每帧调用，syscall 开销可测 | `f_tui/src/term/TerminalSize.cj:79-90` | 调用频次与单次耗时 | 宿主侧分段计时 + `strace -c` 统计 `ioctl` 次数 |
| 3 | 信号回调在独立线程执行，`RawMode` 的 `saved` / `active` 存在真实数据竞争 | `f_tui/src/term/RawMode.cj:26-27` | `std.runtime.registerSignalHandler` 的线程模型 | 查 SDK 1.3.0 `std.runtime` 文档；并发压测（主线程反复 enter/restore + 触发 SIGINT） |
| 4 | 高负载 pty 下短写 / EINTR 真实发生（决定发现 #1 的严重度是否维持） | `f_tui/src/term/PosixFfi.cj:350-355` | `n < size` 与 `n == -1` 的发生比例 | 在 `write` 前后埋点统计返回值分布，跑大帧 + 慢消费者 pty |

## 文件覆盖

> 与 `files/f_tui.part2.txt` 一一对应，6 行全部读完。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_tui/src/term/PosixFfi_test.cj` | .cj | ✅ | 布局 / 常量断言到位；`fakeFfiIsInjectable` 调用计数 6 与实现一致；`layoutMatchesPlatform` 的 `else` 分支在 Windows 上也会按 Linux 布局断言（桩实现下恒真，无实际校验力） |
| 2 | `f_tui/src/term/RawMode.cj` | .cj | ✅ | 恢复返回值被丢弃（#2）、失败后 `saved` 残留（#3）、状态无同步（#7） |
| 3 | `f_tui/src/term/RawMode_test.cj` | .cj | ✅ | enter / restore 幂等覆盖完整；缺 `tcsetattr` 失败与 restore 失败用例（#2/#3） |
| 4 | `f_tui/src/term/TerminalSize.cj` | .cj | ✅ | 未知尺寸判定三处重复（#4）、两套 last 缓存且未接生产（#5） |
| 5 | `f_tui/src/term/TerminalSize_test.cj` | .cj | ✅ | 成功 / 失败 / 变化重读覆盖完整；缺单维为 0（#4） |
| 6 | `f_tui/src/term/TerminalWriter.cj` | .cj | ✅ | 短写 / EINTR 无重试（#1）；`flush` 空操作有注释与文档支撑，不算空实现；全仓无该类的单元测试 |

合计：`.cj` 6 个 / `.md` 0 个 / 共 6 个，全部读完。

## 覆盖自检

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
| 一般 | 1 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

`src/term` 这 6 个文件结构小而清晰：系统调用全部收敛在 `PosixFfi`，`RawMode` / `TerminalSize` / `TerminalWriter` 三个职责边界干净，测试通过注入假实现覆盖了 enter/restore 幂等、ioctl 失败、尺寸变化重读等主路径，整体质量良好。风险集中在「失败路径」而非主路径：一是 `write(2)` 的短写与 EINTR 没有重试，被 `AnsiRenderer` 放大成进程级永久停写，且截断点可能污染终端状态（#1，唯一阻塞项）；二是 `restore` 把 `tcsetattr` 失败吞掉并清掉重试机会，可能把用户终端留在 raw 模式（#2）。其余是重复判定 / 双份缓存 / README 漏项这类维护性问题，可随下一次改动顺带收敛。性能上唯一值得量化的是每帧整帧 `toArray` 拷贝，但没有改前基线，只能作为待验证假设。存量缺陷 7 条（含 1 条待确认），是否纳入修复待用户决定。

范围外提示（不计入本部分统计）：`PosixFfi.cj:332-342` 的 `poll` / `read` 把 `EINTR` 统一当超时返回 `None`，与 #1 同源但属第 1 部分；`README.md:69` 的 `Termios` 字段按 macOS 布局（`UInt64` / `$20`）列出，与 Linux 构建的 `UInt32` / `$32` 不一致。

# f_process 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_process`（2 个源文件 + 2 个 README）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；无 diff，全部问题按「存量」处理）
- **审查重点**：进程管理正确性、资源泄漏、死代码、空实现、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] 管道 `|` 用同步 `pipe` 搬运且从不关闭下游 stdin，多段管道读不到 EOF

- **位置**：`f_process/src/process.cj:141`（同源位置：`104-108` 逐段串联、`126-131` 两个 `String |` 运算符、`56-57`、`64`、`72` 的 `link`）
- **来源**：存量（`git blame -L 120,147` → `4be871f2fd`，2026-10-02，快照内无本次改动）
- **判据**：review-checklist §11（契约与实现不符 / 资源不对称）、§6.3（并发串行）
- **证据**：静态确定 —— `SubProcess | SubProcess` 只有一句 `pipe(input: this.stdOutPipe, output: next.stdInPipe)`（`process.cj:141`），而 `f_io.pipe` 的实现是 `while (let len <- input.read(buf) && len > 0) { output.write(buf[0..len]) }`（`f_io/src/f_io.cj:36-41`），读到 EOF 后直接 `return`，**全仓无任何对 `output` 的 `close`/关闭动作**（`grep stdInPipe` 只命中本模块 5 处读/写，无 close）。下游子进程的 stdin 写端仍由调用方持有的 `SubProcess.stdInPipe` 保持打开，因此下游永远读不到 EOF。
- **描述**：三种后果，同一根因：
  1. `'ls -l' | 'grep .cj'`（README:74-75 的示例）——`ls` 退出后 `pipe` 返回，`grep` 仍在等 stdin EOF，`p.wait()`（README:75）永久阻塞。README 只用「大输出量时注意死锁风险」（README:92）描述，低估为偶发。
  2. 三段及以上 `'a | b | c'`：循环在 `cur` 推进到 `b` 时就同步搬运 `a → b`（`process.cj:104-108`），必须等 `a` 退出才继续启动 `c`；而 `b` 因 stdin 无 EOF 不退出、`stdOutPipe` 也无数据，`b → c` 的搬运在 `read` 上永久阻塞。同时中间段输出超过管道缓冲（Linux 64 KiB）时 `b` 写阻塞 → 不再读 stdin → `a → b` 写阻塞，形成确定性互锁。
  3. `piped(... stdIn: InputStream, stdOut: OutputStream)`（`process.cj:51-58`）：`asyncPipe` 同样只 copy 不关流（`f_io/src/f_io.cj:43-48`），输入流 EOF 后子进程（如 `cat`）仍等 stdin EOF；`stdIn: ProcessRedirect = Pipe` 的默认值（`process.cj:61`、`77`）也把没人写、没人关的 stdin 管道留给子进程。
- **建议**：`|` 不要用阻塞 `pipe` 连接两段。改为「`launch` 时把上游 `stdOut: Pipe`、下游 `stdIn` 设为上游的管道」并由库持有两端句柄，或在搬运结束后显式关闭下游 `stdInPipe`（并在关闭前 `flush`）；`asyncPipe` 路径同样要在 EOF 后关闭目标流。若标准库未暴露 `close`，则需要在本模块新增「关闭子进程标准流」的封装，而不是让调用方猜。
- **复核方式**：`'ls -l' | 'grep .cj'` 后仅 `p.wait()`，观察是否退出；再用 `'seq 1 200000 | wc -l'` 验证中间段缓冲区满时的表现。

### [一般][存量] 子进程句柄只返回一端或全部丢弃，僵尸进程与等待错对象

- **位置**：`f_process/src/process.cj:65`（返回 `tuple[0]`）、`f_process/src/process.cj:73`（返回 `tuple[1]`）、`f_process/src/process.cj:51-58`（返回 `Unit`，两个句柄全部丢弃）
- **来源**：存量（`git blame` → `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §11（资源不对称）、§12.1（异步语义）
- **证据**：静态确定 —— 标准库 `SubProcess` 文档明确「调用 `launch` 创建子进程后，需要调用 `wait` 或 `waitOutput`，否则子进程结束后成为的僵尸进程的资源不会被回收」；而 `piped` 的各重载要么只返回 `(first, last)` 中的一端，要么 `Unit`。
- **描述**：
  - 多段命令下 `piped(stdOut: OutputStream)` 返回 **第一个** 子进程，但输出来自 **最后一个**：调用方 `wait()` 拿到的是上游退出码（通常 0），末端进程仍在跑，读 `stdOut` 的下游可能拿到截断数据；被丢弃的末端句柄无人 `wait`，成为僵尸。
  - `piped(stdIn: InputStream)` 反向只返回最后一个，第一个（真正消费输入的那个）丢弃。
  - 单段命令时 `first == last`，问题被掩盖，这也是 README 示例看起来正常的原因。
  - `Unit` 重载（`51-58`）两个句柄都丢弃；README:91 承认「丢弃两个 `SubProcess` 句柄」，但未说明僵尸累积，也未给出替代手段（因为替代手段本身在多段时也是错的）。
- **建议**：统一返回两端（`(first, last)` 或一个持有全部段的句柄对象），并在类型上提供 `waitAll()`/`close()`；`Unit` 重载要么删掉，要么内部 `wait` 完毕再返回（明确是同步语义）。

### [一般][存量] 空命令与空管道段导致数组越界 `command[0]`，且已启动的段泄漏

- **位置**：`f_process/src/process.cj:120`（`command[0]`）、`f_process/src/process.cj:83-114`（逐段切分，`cur == idx` 时产生空段）、`f_process/src/process.cj:56`、`64`、`72`（`getOrThrow`）
- **来源**：存量（`git blame` → `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §11（边界 / 空串未处理、缺少边界校验）
- **证据**：静态确定 —— `" ".trimAscii().split(' ', removeEmpty: true)` 得到空数组，`command[0]` 直接越界；`"|ls"` / `"a || b"` 经 `cmd.indexOf("|", cur) ?? s` 会得到 `cur == idx` 的空段，同样走到空数组。
- **描述**：`"".exec()` 抛 `ArrayIndexOutOfBoundsException` 而不是明确的参数异常；`"|ls".piped()` 在当前段之前的段已经 `launch` 之后才抛异常，前面的子进程只存在于局部变量 `last` 里，异常退栈后无人 `wait` → 泄漏。另一种形态：`"".piped()` 直接返回 `(None, None)`（循环一次都不进），调用方 `tuple[0].getOrThrow()`（`process.cj:56/64/72`）抛 `NoneValueException`，语义与实现不符（签名承诺是「成功必有进程」）。
- **建议**：`exec` 在切分后判空并抛 `IllegalArgumentException`（带原始命令）；`piped` 在切分阶段先做一次全量段校验（非空段计数），校验通过再 `launch`，避免半启动；返回类型从 `(?SubProcess, ?SubProcess)` 收窄为非可选元组。

### [一般][存量] README 的管道语义与示例低估实现风险

- **位置**：`f_process/README.md:7`（"用 `|` 把子进程串成管道"）、`f_process/README.md:48`（"同步把 this 的 stdOutPipe 搬运到 next 的 stdInPipe"）、`f_process/README.md:74-75`、`83-84`（示例）、`91-92`（注意事项）；`f_process/README_en.md:7`、`48`、`74-75`、`91-92` 同
- **来源**：存量（快照，README 与源码同批提交）
- **判据**：review-checklist §13（示例不能用 / 文档过期）、§14（README 承诺能力与实现不符）
- **证据**：静态确定 —— 承诺源 README:7/48 与实现 `process.cj:141` 对照；示例 README:74-75 在 `pipe` 不关闭下游 stdin 的前提下无法返回（见第 1 条）。
- **描述**：
  - README:48 只说「搬运」，未说明**下游永远不会收到 EOF**；README:92 把死锁限定为「大输出量」，实际是「下游读至 EOF 即挂起」。
  - 示例 README:74-75 直接挂起；README:79 的 `'git status --short'.piped(stdOut: w, ...)` 丢弃返回的 `SubProcess`，示例本身就在制造僵尸；README:83 的 `let (first, last)` 中 `first` 从未使用。
  - `README_en.md` 与中文版逐句对应，同样继承了错误描述，未出现「中英不同步」问题。
- **建议**：把 README:91-92 改成准确的三条限制：下游 stdin 不会自动关闭（需自行 `close`）、`String | String` 是**串行**搬运且会挂起、任何 `launch` 出来的进程必须 `wait`；示例改成「拿两端 → 读完 → 关流 → `wait`」的完整闭环。

### [轻微][存量] 无用依赖 `fountain::f_regex` 与注释残留 import

- **位置**：`f_process/cjpm.toml:4`、`f_process/src/CurrentProcess.cj:22`
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §1（未使用的 import / 读了不用）、§14.1（接线缺失）
- **证据**：静态确定 —— `f_process/src` 下无 `f_regex` 的 `import`，全模块搜 `f_regex` 只在 `cjpm.toml:4` 命中；`CurrentProcess.cj:22` 是整行被注释掉的旧 import（`// import cangjie_tpc::charset4cj.{...}`）。
- **描述**：`f_regex` 被声明为编译依赖但从未使用，会把该模块拉进 `f_process` 所有下游（`fmq`、`fleet`）的解析图；注释残留会让读者误以为存在循环依赖问题。
- **建议**：删除 `cjpm.toml:4` 依赖与 `CurrentProcess.cj:22` 注释行。

### [轻微][存量] 三个单流 `piped` 重载结构重复，差异未参数化

- **位置**：`f_process/src/process.cj:51-58`、`59-66`、`67-74`（另有 `39-41` 的 `link` 纯转发）
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §2（同文件函数体两两比对：输入-输出-副作用）
- **证据**：静态确定 —— 三者摘要相同：「调 `(first,last)` 重载 → `link` 一端 → 返回另一端」，差异只有「link 哪一端」和「返回 tuple 的哪个下标」；而这两个差异恰好没有被参数化，直接导致第 2 条的返回端不一致。`link` 只是把 `asyncPipe` 换了个名字，无额外语义。
- **建议**：抽一个内部函数 `runWithLinks(cmd, links: (stdInLink?, stdOutLink?)) -> (first, last)`，三个重载只声明各自接管哪一端，返回端由同一处决定；`link` 可以直接去掉，调用 `asyncPipe`。

### [轻微][存量] `enviromentVariables` 拼写错误扩散到公开签名默认值与 README

- **位置**：`f_process/src/process.cj:42`（定义）、`52`、`60`、`68`、`76`、`117`（默认值引用）；`f_process/README.md:19`、`23`、`27`、`31`、`35`；`f_process/README_en.md:19`、`23`、`27`、`31`、`35`
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §10（命名 / 可读性）
- **证据**：静态确定 —— `enviroment` 正确拼写为 `environment`。
- **描述**：虽然是 `private prop`，但它出现在全部 5 个公开函数的默认参数文本里，README 又逐字抄了一遍，使用者按文档理解参数来源时会困惑；同文件里还有正确拼写的 `environment!` 形参，两个词并存。
- **建议**：改名 `environmentVariables`，同步更新 10 处 README 引用。

## 优化可行性方案

### [堆内存] 默认 `environment` 改为 `None`，不复制整份进程环境

- **现状**：`piped`/`exec` 的默认参数是 `enviromentVariables`（`process.cj:42-50`），每次调用都 `new HashMap` 并把 `getVariables()` 全量复制一遍；一次调用一个小对象 + O(环境变量数) 的字符串引用数组，生命周期到 `launch` 返回为止。调用频次低（一个进程创建对应一次），绝对量不大。
- **方案**：默认值改为 `None`，把 `launch` 的 `environment!: ?Map<String,String> = None` 直接透传（`None` 语义即继承父进程环境，与本模块现有默认行为等价，只是不再复制）。
- **预期**：每次启动少一次全量环境复制（O(n_env) 分配）；量级小，不改变吞吐。
- **代价**：需确认调用方是否有「改 `std.env.setVariable` 后期望子进程看到旧快照」的依赖——按 std 文档 `None` 为继承，行为差异仅在父进程运行期改环境变量时体现。
- **验证**：`cjpm bench` 对 1000 次 `'true'.exec()` 的分配量（`getAllocatedHeapSize()` 差值）与耗时中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `pipe` 同步搬运使 `String \| String` 的端到端耗时等于各段耗时之和（无重叠执行） | `f_process/src/process.cj:141` | 分段计时 | 对 `'seq 1 100000 \| wc -l'` 用 `time` 对比「本模块管道」与「`sh -c` 原生管道」的 wall time，各 10 轮取中位数 |
| 2 | `SubProcess.stdInPipe` 是否在包装对象被 GC 时才关闭 fd（决定第 1 条是「必然挂起」还是「偶发挂起」） | `f_process/src/process.cj:141` | 标准库 stream 生命周期语义 | 只调 `wait()` 不 close，分别在 `gc()` 前/后观察子进程是否退出；或查 `cangjie_runtime` std 源码 |
| 3 | `piped(Unit)` 下僵尸进程随调用次数线性累积 | `f_process/src/process.cj:51-58` | 进程表样本 | 循环调用 1000 次 `'true'.piped(stdOut: w)`，每 100 次 `ps -eo stat` 统计 `Z` 状态数量 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_process/README.md` | .md | ✅ | 见「发现」第 4 条（管道语义与示例）、第 7 条（拼写）；其余 API 段与实现一致 |
| 2 | `f_process/README_en.md` | .md | ✅ | 与中文版逐节对应，无缺节；同样继承第 4 条的错误描述 |
| 3 | `f_process/src/CurrentProcess.cj` | .cj | ✅ | 5 个公开函数实现与 README 一致；第 22 行注释残留见第 5 条 |
| 4 | `f_process/src/process.cj` | .cj | ✅ | 2 个公开接口 + 2 个 extend，第 1/2/3/6/7 条均在此 |

合计：`.cj` 2 个 / `.md` 2 个 / 共 4 个，全部读完（与 `files/f_process.txt` 4 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：第 1、3 条；设计：第 2 条（句柄所有权不清晰）；可读性：第 7 条；安全性：不经 shell（README:9 与 `launch` 直接传 argv 一致），`split(' ')` 不构成注入面，无硬编码凭据，无敏感数据进日志 |
| §1 死代码 | 1 | 逐个核对：`private func link`（`process.cj:39`）有 4 处调用；`private prop enviromentVariables`（`:42`）被 5 处默认值引用；两个 `extend` 的 `public` 成员均实现接口方法（接口实现豁免）；5 个顶层 `public` 函数（另 2 个 `public` 接口）对外可达（`getAbsoluteCommandDir` 被 `fmq/src/config/MQConfig.cj:23`、`fleet/src/server/FleetServerConfig.cj:19` 引用，其余仓内无引用但属对外契约，不判死代码）；无未使用 import。命中的 1 条是 `cjpm.toml:4` 的无用依赖 + 注释残留 import。 |
| §2 重复逻辑 | 1 | 已把 7 个函数体（`link`、`enviromentVariables.get`、4 个 `piped`、`exec`、2 个 `|` 运算符）压成「输入→输出→副作用」两两比对：三个单流 `piped` 同语义（第 6 条）；两个 `|(next: String)` 是 `this \| next.exec()` 且分属两个接口，属接口对称不合并。 |
| §3 空实现 | 0 | 7 个函数体均有实现，无 `TODO`/`FIXME`/`throw UnsupportedException`，无 `catch {}`（模块内无 `try`）。`asyncPipe` 丢弃 `Future` 导致搬运异常不可见的问题归入第 1、2 条，不单列。 |
| §4 栈溢出 | 0 | 全部函数无自调用与间接递归，`startup()` 是循环体内的一个嵌套函数、只调用 `exec`；管道段数由输入字符串长度上界约束，不存在递归展开。 |
| §5 OOM | 0 | 无全局容器、无按报文长度预分配（`bufSize` 由调用方传入且默认 4096，非不可信输入）、无 `readToEnd`/全量物化；唯一的按量分配是 `f_io.pipe` 的 `Array<Byte>(bufferSize)`，上界由调用方控制。 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，无法给自耗时占比与调用路径，管道串行化只作为线索写入「待验证假设 #1」，不作缺陷。 |
| §6.2 大粒度锁 | 0 | 模块内无锁、无 `synchronized`、无共享可变状态，临界区不存在。 |
| §6.3 并发串行 | 1 | `piped` 循环里逐段 `p \| startup()`（`104-108`）同步搬运，第 n 段必须等第 n-1 段退出才启动 → 管道并行度上限为 1，已并入第 1 条。 |
| §6.4 低效算法 | 0 | `indexOf("|", cur)` 从游标推进，整体 O(len)；无嵌套循环、无热点 `contains`、无 `remove(at: 0)`。 |
| §7 降堆内存方案 | 1 | 环境变量全量复制（见「优化可行性方案」）。 |
| §8 降 CPU 方案 | 0 | 唯一候选（环境复制 + 每次 `getWorkingDirectory()` 求值）与 §7 同源，已合并；其余无 profile 数据，不单列。 |
| §9 local mode 可行性 | 0 | 函数内临时对象只有 `piped` 拼装的 `String` 段（随命令长度线性，几 KB 级），且 `SubProcess`/流对象都会逃逸出函数；改造成本与峰值收益不成比例，不成立。 |
| §11 现有代码的 BUG（存量） | 3 | 第 1 条（管道挂起）、第 2 条（句柄/僵尸）、第 3 条（空命令越界）；另核对了 `stdReader/stdOutWriter/stdErrWriter`（流所有权交给调用方，未私自关闭）、`getAbsoluteCommand`（`canonicalize` 对相对 argv[0] 的解析结果依赖启动方式，属 `待确认`，未达缺陷门槛）、`enviromentVariables` 遍历写入无空键风险。 |
| §12 并发安全与锁粒度 | 1 | 共享可变状态：无（全部函数只读 `std.env` 快照，`SubProcess` 为局部对象）。命中的是异步语义：`Unit` 重载 `spawn` 出的搬运协程异常被丢弃、子进程无人 `wait`，调用方无法感知失败（并入第 2 条）。锁粒度：无锁可谈。 |
| §13 文档一致性 | 1 | 第 4 条（README:48/92 与 `process.cj:141` 不符、示例不可用）；其余段落（`exec` 空格切分、不经 shell、默认 `stdErr: Inherit`、`(first, last)` 返回语义）与源码逐项核对一致；`README_en.md` 与中文版无缺节。 |
| §14 功能完备性与 README 覆盖 | 1 | 逐个对照 7 个公开符号（`ExtendProcess`、`ExtendSubProcess`、`stdReader`、`stdOutWriter`、`stdErrWriter`、`getAbsoluteCommand`、`getAbsoluteCommandDir`）与 7 个公开方法，README 均有文档，无「未文档化」；命中项是 README:7 承诺「用 `\|` 把子进程串成管道」而实现无法闭环（第 1、4 条）。模块已登记进根 `README.md:327`、`README_en.md:297`、`cjpm.toml:30`、`skills/*/references/module-index.md:51`，无接线缺失。 |
| 文件覆盖（§13 等） | 4/4 | 无遗漏；`.cj` 2 个、`.md` 2 个全部读完。 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量 7 条（本快照无 diff，全部计入存量），是否纳入修复待用户决定。

## 总评

模块很小（2 个文件、7 个公开符号），`CurrentProcess.cj` 的五个函数干净、与 README 一致；`process.cj` 的接口划分（`ExtendProcess` / `ExtendSubProcess`）也合理。**风险集中在 `process.cj` 的管道实现**：把「进程连接」建模成「在调用线程里同步 copy 字节」，既没有关闭下游 stdin，也没有保留两端句柄，于是 README 的主示例（`'ls -l' | 'grep .cj'` + `wait()`）在语义上就站不住，多段命令还会串行化甚至互锁。这是本模块唯一的阻塞项，且属于对外契约级缺陷——按 README 用会挂住。

其余问题：僵尸进程/句柄泄漏（第 2 条）、空命令越界（第 3 条）都与管道实现同源，建议与第 1 条一并重构为「显式持有两端 + 结束即 `wait`/`close`」的模型；三处轻微项（无用依赖、拼写、重复重载）可随同一次改动清掉。文档侧的第 4 条必须跟着代码一起改，否则修订后的行为仍无法从 README 读出。

补充（不计入统计）：模块零测试文件（`find f_process -name "*_test.cj"` 为 0），上述三条正确性问题都缺回归用例；建议重构时至少补「单段/多段管道 + 空命令 + 未 `wait` 的僵尸计数」四组用例。范围外提示：第 1 条的根因有一半在 `f_io/src/f_io.cj:36-48`（`pipe`/`asyncPipe` 不关闭目标流），该文件不在本轮范围，未展开审查。

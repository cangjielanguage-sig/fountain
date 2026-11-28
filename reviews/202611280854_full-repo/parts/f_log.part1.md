# f_log 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_log`（全模块 33 个 `.cj` + 2 个 `.md`；**本报告为模块第 1/2 部分**，覆盖 `f_log.part1.txt` 的 18 个 `.cj` + 2 个 `.md`；`src/impl/*`（8）、`src/output/*`（6）、`src/log.cj`（1）及 2 个 `*.macrocall` 属第 2 部分，未纳入本报告统计）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」，blame 均为 `4be871f2fd 2026-10-02`）
- **审查重点**：日志链路正确性与性能、异步/缓冲与丢失、大粒度锁、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

### [严重][存量] `SyncQueueOutputStream.write` 直接取 `bytes[0]`：空字符串写入必抛 `IndexOutOfBoundsException`，`log.error(ex)` 等 6 个公开 API 必然命中

- **位置**：`f_log/src/base/AsyncLogger.cj:152-168`（`write`，`bytes[0]` 在 `:162`）；触发源 `f_log/src/base/Logger.cj:460-477`（`fatal/error/warn/info/debug/trace(ex)` 全部传 `String.empty`）、`f_log/src/base/LogPattern.cj:167`、`:174`（`%app`/`%appver` 为空串时）
- **来源**：存量（`git blame -L 160,170 f_log/src/base/AsyncLogger.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界 / 空集合未处理）；§10 正确性
- **证据**：静态确定 —— 写入链路逐段可查：
  1. `AbstractLogger.doAppend`（`AbstractLogger.cj:127-130`）→ `pattern.generate(...)`；`MessageLogPart.generate`（`LogPattern.cj:192-194`）执行 `writer.writeString(message.toString())`。
  2. `LogWriterImpl.writeString`（`src/output/LogWriterImpl.cj:40-42`）是 `writer.write(v.toArray())`——**不做非空判断**。
  3. `SyncQueueOutputStream.write` 第一句分支就是 `if(bytes[0] == b'\0')`，`bytes` 为空数组时 `Array` 下标越界，抛 `IndexOutOfBoundsException`。
  4. `Logger.error(ex)`（`Logger.cj:463-465`）→ `append(ERROR, String.empty, ex)` → 消息闭包返回 `""` → 默认 pattern 含 `%m`（`LogPattern.cj:35`）→ 空数组写入。
  5. 同样路径也命中 `%app`/`%appver`：`AppLogPart.app`、`AppVersionLogPart.version` 在 `AppVersion.set` 之前取值就是 `""`（见「一般」第 8 条）。
  6. 抛出的异常穿过 `doLock` 与 `AbstractLogger.log` 的 `try/finally`（`:107-110` 只有 `finally` 没有 `catch`），直接抛给业务调用方。
- **描述**：所有 `AsyncLogger` 子类（`console`/`file`/`tcp`/`udp`/`unix`/`unixDatagram` 六种 appender 都是异步的）在收到「空字符串片段」时崩溃。触发方式包括：`log.error(ex)`、`log.info("")`、日志字段值为空串（`Attr` 值为 `""`）、pattern 含 `%app`/`%appver` 而 `AppVersion.set` 尚未执行（当前模块加载顺序下恒成立）。异常发生在业务线程的日志调用点，等于「打日志把业务打崩」。
- **建议**：`write` 开头加 `if (bytes.isEmpty()) { return }`；并把 `\0` 哨兵从「首字节判定」改为显式 API（如 `flush()` 或 `writeSentinel()`），避免消息正文以 `\0` 开头时被误当分隔符；补 `log.info("")`、`log.error(ex)`、`%app` 三条用例。

### [严重][存量] `AsyncLogger` 引用计数每次构造 +2、关闭只 -1：关闭时永不等待队列排空，直接关输出，尾部日志丢失

- **位置**：`f_log/src/base/AsyncLogger.cj:69`（`super(..., confirmDummy(output, queueTag), ...)`）+ `:74`（`queueStream(output, queueTag)`）→ `:105-111`（`fetchAdd(1)` 各一次）；关闭侧 `:85`（`fetchSub(1) == 1`）、`:91-96`（等待/关闭输出）
- **来源**：存量（`git blame -L 84,98` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（资源释放不对称 / 逻辑错误）；§12.1
- **证据**：静态确定 —— 构造一个 `AsyncLogger` 会调用两次 `queueStream`：一次在 `super(...)` 的实参 `confirmDummy(output, tag)` 里（`:102-104` → `queueStream(...).output`），一次在 `:74`。`queueStream` 每次都 `q.refCount.fetchAdd(1)`（`:109`），因此 `refCount` 从 0 直接变 2；`doClose` 只 `fetchSub(1)` 一次（`:85`），首次关闭返回的是旧值 2，`2 == 1` 为假 → 整个 `wait(q.queue)` 与 `sleep(100µs)` 被跳过，随后 `:94-96` 直接 `r.close()` 关掉真实输出。
- **描述**：`doClose` 设计的「等队列排空 → 再等 100µs → 关文件」顺序从不生效。后果：① logger/appender 被关闭时（`LoggerParams.register` 对配置里移除的 appender 置 `closable` 并关闭，`LoggerWrapper` 的 `atExit` 关闭 facade），消费者线程还在 `writeTo` 写最后几个缓冲块，输出就被关闭，尾部日志丢失或写入抛异常（被 `:48-50` 的 `catch` 打成栈）；② `refCount` 永远回不到 0，`:97` 的 `queueMap.remove(tag)` 变成「无条件删除」，与「一般」第 2 条叠加造成 tag 生命周期错乱。
- **建议**：`confirmDummy` 不再走 `queueStream`（直接 `queueStream` 一次后复用），或把计数改为「按 output 实例」只在真正创建/销毁时增减；关闭时用「提交一个哨兵任务 + `Future.get()`」或 `notify` 替代 `while(size>0) sleep(0)`，确认真实刷完再关输出。

### [一般][存量] 二级缓冲队列满时无限阻塞业务线程，且默认 `Discard` 策略因 `timeout=Duration.Max` 形同虚设；阻塞点还在 `doLock` 临界区内

- **位置**：`f_log/src/base/AsyncLogger.cj:163`（`queue.add(buf)`，无超时）；`:124-132`（一级队列 `add(fn, timeout)`）；`f_log/src/base/LoggerConfig.cj:105-110`（默认 `Duration.Max`）、`:112-122`（默认 `Discard`）
- **来源**：存量
- **判据**：review-checklist §12.1（有界性 / 异步语义）；§6.2（锁内阻塞）；§13（与 README 承诺相反）
- **证据**：静态确定 —— ① 标准库文档 `collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:206-215`：`add(element)` 是「阻塞的入队操作，如果队列已满，则阻塞等待」；`SyncQueueOutputStream.queue` 容量是 `bufSize*10`（`:39`），写满后 `:163` 无超时阻塞。② 一级队列 `add(fn, timeout)` 的 `timeout` 默认 `Duration.Max`（`LoggerConfig.cj:109`），等于永不超时，`Discard` 分支（`:128`）永远走不到。③ 阻塞点位于 `AbstractLogger.append` 的 `doLock{...}` 内：`AbstractLogger.cj:133-136` → `:123-126` → `writer.writeString('\0')` → `write` → `queue.add(buf)`。
- **描述**：README.md:86 / README_en.md:86 承诺「队列满时会按策略丢弃而不是阻塞业务线程」，实现是「一级队列满且未配置 `loggerAsyncTimeout` 时无限等待；二级缓冲队列满时无限等待」。当 sink 变慢（TCP/UDP 对端不回读、磁盘打满、轮转卡住）时，超过 `10240` 条缓冲后业务线程在**持有该 logger 的 Mutex** 的情况下挂起，同 tag 的所有日志线程一起排队，请求链路被日志拖死。
- **建议**：二级队列改 `if (!queue.tryAdd(buf)) { 计数丢弃 }`；一级队列默认超时给有限值（如 `Duration.Zero` 或 5ms）而不是 `Max`，让 `Discard` 真正生效；丢弃次数做成计数器暴露，避免「静默」。阻塞调用一律移到锁外。

### [一般][存量] tag → 队列的生命周期无人负责：`queueMap.remove(tag)` 无条件删除、每个 tag 一条 `while(true)` 消费线程且永不退出、`LoggerAppenderFacade.close` 绕过基类关闭

- **位置**：`f_log/src/base/AsyncLogger.cj:97`（无条件 `queueMap.remove`）、`:43-53`（`spawn { while(true) { queue.remove()() } }`）；`f_log/src/base/LoggerAppenderFacade.cj:56-66`（`close`）
- **来源**：存量
- **判据**：review-checklist §12.1（跨线程资源 / 有界性）；§11（资源不对称）
- **证据**：静态确定 ——
  1. `doClose` 里 `queueMap.remove(tag)` 在 `if(refCount==1)` 之外，任何一次 close 都会把该 tag 的条目删掉，而 tag 是**按输出目标共享**的（`FileLoggerAppender` 的 tag 是 `file:///<path>`，见 `src/impl/FileLoggerAppender.cj:25-30`）——同一个文件路径被多个 logger 名共用时，其中一个关闭就删掉了所有人的条目；之后同 tag 再构造会 `computeIfAbsent` 出**新的** `SyncQueueStream`（新输出句柄 + 新消费线程），两个消费线程对同一文件并发写。
  2. `SyncQueueStream.remove` 里 `spawn` 的循环没有任何退出条件，`close` 不通知、不打断；每个新 tag（每个 logger 名一个 `f_log.LoggerAppenderFacade_<name>`，每个文件路径一个）都会永久留下一条线程，随 logger 数量单调增长。
  3. `LoggerAppenderFacade.close` 没有调 `super.close()`，即 `AsyncLogger.doClose` 从不执行：facade 自己的 `refCount` 永远不减、`queueMap` 条目与消费线程永不回收。
  4. `close` 先 `this.appenders.store([])`（`:58`）再关子 appender，已入队但尚未执行的任务在 `loadAppenders()`（`:44`）时读到空数组 → 直接丢弃。
- **描述**：整套异步链没有任何「谁最后关闭谁负责清理」的所有者。正常运行期表现为线程/条目泄漏；关闭与配置刷新期表现为「尾部日志丢弃 + 可能双写同一文件」。
- **建议**：给 `SyncQueueStream` 加 `stopped` 标志与 `stop()`（投递哨兵，消费线程收到后退出）；`remove(tag)` 只在计数归零时执行；`LoggerAppenderFacade.close` 先停止接收、等待队列排空，再 `super.close()`。

### [一般][存量] 关闭路径用忙等 + 固定 100µs 代替同步

- **位置**：`f_log/src/base/AsyncLogger.cj:86-93`
- **来源**：存量
- **判据**：review-checklist §12.1（条件等待）；§6.2
- **证据**：静态确定 —— `func wait(q){ while(q.size > 0) { sleep(Duration.Zero) } }`：循环体只有一个零时长 `sleep`，没有任何阻塞原语或让出保证；`q.size` 本身在文档里明确「不保证并发场景下的原子性」（`collection_concurrent_class.md:78-84`）。随后的 `sleep(Duration.microsecond * 100)` 是「猜」消费者已经写完，不是同步。
- **描述**：关闭期间该线程持续空转抢占 CPU（正是 `:88` 注释想避免的事），且 100µs 在多核/慢盘/大缓冲下并不足够，最后一个缓冲块仍可能没写完就被 `r.close()` 关掉（与严重 #2 叠加）。若消费线程因输出异常反复失败，`while(size>0)` 可能长时间不退出。
- **建议**：改为「投递结束哨兵 + 等待消费线程 `Future.get()`」，或给队列加 `Condition` 由消费者在 `size==0` 时 `notify`；至少把 `sleep(Duration.Zero)` 换成 `sleep(1ms)` 并加上限与超时告警。

### [一般][存量] 线程缓冲池在异常路径不归还、`ThreadLocal` 不清理：池被逐步耗尽后全部日志静默丢弃

- **位置**：`f_log/src/base/AsyncLogger.cj:152-161`（取池 / 归还判定）、`:190-192`（`returnBuffer`）
- **来源**：存量
- **判据**：review-checklist §5（长期持有 / 有界容器被耗尽）；§11（资源不对称）
- **证据**：静态确定 —— 缓冲只在这条路径归还：`write` 收到 `\0` 哨兵 → `queue.add(buf)` → 由消费者 `writeTo` 的 `finally` 调 `returnBuffer(queue.remove())`（`:184-188`）。`buffer.set(buf)` 之后任何异常（严重 #1 的越界、格式化异常、`MessageLogPart` 里用户 `toString()` 抛异常）都会让该线程永久持有这块缓冲：`buffer` 是 `ThreadLocal`，没有 `finally` 清理，`pool` 也不会再收到它。
- **描述**：`pool` 是**全局静态**、容量只有 `loggerAsyncBufsize`（默认 1024）（`:139-146`），而「线程 × tag」组合数远大于它。每发生一次异常就永久损失一块缓冲；累积到池空后，`pool.remove(5ms)` 超时 → 打印 `AsyncLogger.SyncQueueOutputStream.EmptyPool` 并 `return`（`:158-161`），此后**所有日志被静默丢弃**，而且每丢一条就往 stdout 打一行，形成二次放大。并发线程数超过 1024 时也会直接走到这条丢弃分支。
- **建议**：`write` 用 `try/catch` 或 `defer` 保证异常时把缓冲归还并 `buffer.set(None)`；池耗尽改为计数 + 采样告警而不是逐条 `Console.writeln`；在 README 里写清「缓冲池上限 = 并发写线程数」，或按需扩容到线程数。

### [一般][存量] `LoggerWrapper.refresh` 失败后无限重试，且 `replaced` 恒真 / CAS 冗余

- **位置**：`f_log/src/base/LoggerWrapper.cj:42-61`
- **来源**：存量
- **判据**：review-checklist §12.1（异步语义 / 有界性）；§11（错误处理）
- **证据**：静态确定 —— `while (!replaced)` 中 `replaced` 只在 `:55` 由 `replaced_` 赋值，而 `doLock` 的两个分支都返回 `true`（`:50`、`:52`），所以正常路径只循环一次；一旦 `LoggerConfig.createFacade(name)`（`:47`）抛出（配置里 appender kind 非法、`getPatternConf` 解析异常等），`catch`（`:57-59`）只打栈不复位也不退出，`replaced` 仍为 `false` → 立即重试，形成「打印栈 + 重建 facade」的忙循环，配置不变就永不停止。另外 `doLock` 已经串行化了 refresh，`compareAndSwap` 分支（`:52` 返回未安装的新实例、由 `:56` 关掉）实际不可达。
- **描述**：配置热刷新（`LoggerConfig.static init` 注册的 `Config.refresher`）遇到一次坏配置，就会把 CPU 打满并刷屏，同时不断新建/关闭 facade。
- **建议**：`catch` 里 `break` 或有限次重试后放弃并保留旧 facade（记录错误）；删掉 `replaced`/CAS 双重结构，直接 `doLock { old = facade.load(); facade.store(new) }` 后 `old.close()`。

### [一般][存量] 配置解析缺校验：`getAppenders` 不 trim、`convertLevel` 静默降级 INFO、`getAsyncBufSize` 不校验 >0

- **位置**：`f_log/src/base/LoggerConfig.cj:56-62`、`:102-104`、`:162-173`
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 / 静默失败）；§10 正确性
- **证据**：静态确定 ——
  1. `getAppenders` 只做 `appenders.split(",")`：`logger_appender_file=a, b` → 第二个名字是 `" b"`，后续 `logger_appender_ b_level` 查不到 → 该 appender 静默用默认级 INFO/默认 pattern。
  2. `convertLevel` 的 `case _ => LogLevel.INFO`：`level=INF`、`level=WARN `（尾空格，`toAsciiUpper` 不 trim）都会静默变 INFO，没有任何告警。
  3. `getAsyncBufSize` 直接返回配置值，被 `ArrayBlockingQueue<...>(size)`（`AsyncLogger.cj:35`、`:142`）使用；文档 `collection_concurrent_class.md:108-112` 明确容量 ≤0 抛 `IllegalArgumentException`。`loggerAsyncBufsize=0` 会让 `SyncQueueOutputStream` **静态初始化失败**，整个日志模块不可用，且异常发生在类初始化而不是配置读取处。
- **描述**：三处都是「配置写错不报错、行为悄悄变」或「配置写错直接炸在类初始化」，排障成本高。
- **建议**：`split` 后 `trim`；`convertLevel` 未命中时抛 `LogException`（或至少打印一次警告）；`getAsyncBufSize` 校验 `> 0`，非法时回退默认值并告警。

### [一般][存量] `LoggerAppenderCreator.register` 用 `ConcurrentHashMap.add` 静默覆盖同名 kind

- **位置**：`f_log/src/base/LoggerAppenderCreator.cj:26-28`
- **来源**：存量
- **判据**：fountain 基线 §4（同名注册必须启动失败，不做隐式优先级）；review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 标准库文档 `collection_concurrent_class.md:1082-1097`：`ConcurrentHashMap.add(k,v)` 在 key 已存在时「旧值将被替换」并返回 `Some(old)`。这里返回值被丢弃，重复 `register("file", ...)` 不会有任何提示，后注册者静默生效。
- **描述**：任何模块重复注册同名 kind（例如两个扩展都想接管 `file`），行为取决于注册顺序，且没有任何日志；排查「为什么我的 appender 没生效」只能靠读代码。
- **建议**：`if (creators.addIfAbsent(kind, creator).isSome()) { throw LogException("appender kind ${kind} already registered") }`，在启动期失败。

### [一般][存量] 占位符解析：`%appver` 被 `%app` 前缀截断、`%app`/`%appver` 值在类初始化时被快照、`%d` 结尾不识别

- **位置**：`f_log/src/base/LogPattern.cj:67-74`（`%app` 判断在 `%appver` 之前）、`:167`、`:174`（`private let app = AppVersion.name` 在部件构造时取值）、`:95`（`%d` 的 `i + 3 < size` 守卫）
- **来源**：存量
- **判据**：review-checklist §11（语义与文档不符 / 边界）；§13
- **证据**：静态确定 ——
  1. `compile` 的判断顺序是 `app`（`:67`，`i+3<size && pattern[i+1..=i+3]=="app"`）在 `appver`（`:71`）之前；`"%appver"` 的前 4 个字符正好匹配 `app`，于是产出 `appLogPart` + 字面量 `"ver"`，`appVersionLogPart` 永远不可达。README.md:19 / README_en.md:19 承诺 `%appver` 记录 `AppVersion.version`。
  2. `AppLogPart`/`AppVersionLogPart` 的字段是 `private let app = AppVersion.name`（`:167`）、`version = AppVersion.version`（`:174`），而这两个部件是 `LogPattern` 的 `private static let`（`:26-27`）——在 `LogPattern` 类初始化时构造一次。`AppVersion.set` 只在 `f_app/src/App.cj:412` 的模块级 `let _` 里调用；`f_log` 自己的 `global.cj:21` 在模块加载期就 `LoggerFactory.getLogger(...)`（→ `LoggerWrapper` → `LogPattern.default`）触发了类初始化，早于 `f_app`。因此 `%app`/`%appver` 在现行加载顺序下恒为空串（并进一步触发严重 #1 的越界）。
  3. `%d` 分支要求 `i + 3 < size`（`:95`），pattern 以 `%d` 结尾时（如 `"%m %d"`，`i+3` 已越过 `size-1`）守卫为假 → 不识别，原样输出字面量 `%d`；`"%d{}"` 会产出 `TimeLogPart("")`，`DateTime.format("")` 的行为未定义。
- **描述**：三个占位符缺陷叠加，README 里宣传的 `%app`/`%appver` 既拿不到值又会崩（严重 #1），`%d` 在合法位置失效。
- **建议**：把长占位符（`appver`）判断放到短占位符（`app`）之前；`AppLogPart.generate` 改成每次调用 `AppVersion.name`（或缓存 + 失效），不要在部件构造时快照；`%d` 的守卫改为按剩余长度精确判断，空格式直接拒绝。

### [一般][存量] `doLock` 把用户 `message` 闭包、模板编译与全部格式化包在 Mutex 内

- **位置**：`f_log/src/base/AbstractLogger.cj:131-137`（`doLock { append(level, message(), now, tid, ex) }`）、`:138-143`（`doLock`）、`:80-111`（`log(record)` 的整段属性序列化也在锁内）
- **来源**：存量
- **判据**：review-checklist §12.2（缩小临界区 / 锁内调用外部回调）；§6.2
- **证据**：静态确定 —— 临界区包含：`message()`（用户提供的闭包，可能做字符串拼接、`toString()`、甚至 `DataObject.fields()` 反射，见 `Logger.cj:56-76`）、`LogPattern.generate` 的全部部件写出、异常栈 `printStackTrace`（`AbstractLogger.cj:118-122`）、以及可能无限阻塞的 `queue.add(buf)`。`locks` 还是**实例级** `ConcurrentHashMap<String, Mutex>`（`:27`），每个 logger 一个实例键，等价于「一把实例锁」。
- **描述**：同一 logger 的多线程日志被完全串行化，锁持有时间 = 消息构造 + 格式化 + 可能的 I/O 等待。锁内执行用户回调还有另一个后果：`Mutex` 按 `sync/sync_package_api/sync_package_classes.md:8919-8930` 是**可重入**的，不会自锁，但同一线程在 `message()` 里再打一条日志时，内层整行会写进外层未结束的线程缓冲（内层哨兵先到），外层一行被拆成两段。
- **建议**：锁内只做「按序写入线程缓冲 + 搬入队列」，把 `message()` 求值与 pattern 格式化移到锁外（先生成本行字节，再入锁追加）；或直接去掉实例锁，用每线程缓冲 + 单写者队列保证顺序（`SyncQueueOutputStream` 已经是每线程缓冲）。

### [一般][存量] README / README_en 与实现不符：`closable` 配置项不存在、`unix` 用 `path` 不是 `host/port`、队列「丢弃不阻塞」与实现相反、`%appver` 失效

- **位置**：`f_log/README.md:19`、`:72-78`、`:86`；`f_log/README_en.md:19`、`:72-78`、`:86`；对照 `f_log/src/impl/UnixLoggerAppender.cj:83`、`UnixDatagramLoggerAppender.cj:78`、`f_log/src/base/AsyncLogger.cj:163`
- **来源**：存量
- **判据**：review-checklist §13（文档与代码一致性）；§14.2
- **证据**：静态确定 ——
  1. README.md:72 把 `closable` 写成 console 的专有配置字段，但全模块没有任何一处读取 `..._closable`（`grep -rn '"closable"' f_log/src` 无命中，`closable` 只作为 `AbstractLogger` 的 `mut prop` 由 `LoggerParams.cj:59` 程序内设置）。
  2. README.md:74-75 写 `unix`/`unixDatagram` 的字段是 `host`/`port`，实现读的是 `LoggerConfig.getUnixPath(appender)`（`UnixLoggerAppender.cj:83`、`UnixDatagramLoggerAppender.cj:78`，即 `..._path`），另有 `writeTimeout`/`bufSize` 未写入文档；`udp` 的 `sendTimeout`、`tcp` 的 `bufSize` 同样未文档化。
  3. README.md:86「队列满时会按策略丢弃而不是阻塞业务线程」与 `AsyncLogger.cj:163` 的无超时 `add` 相反（见「一般」第 1 条）。
  4. README.md:19 的 `%appver` 因解析顺序失效（见「一般」第 8 条），`%app` 为空时还会崩。
  5. 另外 `%tname`、`%fver`（`LogPattern.cj:83`、`:79` 支持）与配置项 `loggerAsyncTimeout`、`loggerAsyncTimeoutPolicy`（`LoggerConfig.cj:106`、`:113`）在 README 中完全没有出现。
- **描述**：按 README 配置 unix 日志会配不上（写 host/port 不生效，必须写 path）；按 README 理解队列语义会以为不会阻塞；文档承诺的 `%appver` 输出错误。中文版与英文版同步错了同样的内容。
- **建议**：按实现修正 appender 字段表与注意事项；`%tname`/`%fver`/两个超时配置补进文档；`closable` 要么实现为配置项要么从表里删掉。

### [轻微][存量] 死代码 4 项：`isEmpty`、`NoneLogAppender.register`、`NoneLogAppender` 的 4 参空 `append`、`log.cj` 纯注释

- **位置**：`f_log/src/base/LoggerAppenderFacade.cj:33-35`；`f_log/src/base/NoneLogAppender.cj:28-41`；`f_log/src/base/log.cj:1-87`
- **来源**：存量
- **判据**：review-checklist §1（无调用者 / 注册了但永不触发 / 读了不用）
- **证据**：静态确定 ——
  1. `LoggerAppenderFacade.isEmpty()` 是 internal，在 `f_log` 全包（含子包）grep 只命中定义行。
  2. `NoneLogAppender.register()` 全仓 0 调用；即使调用，它注册的 creator 返回 `[instance]`，而 `LoggerAppenderCreator.create:32` 明确 `where !(logger is NoneLogAppender)` 过滤掉——注册了也永远不生效（各 appender kind 的 creator 已用 `NoneLogAppender.instance` 作「该 kind 未配置」的占位，见 `src/impl/LoggerParams.cj:33-39`）。
  3. `NoneLogAppender.append(_: LogLevel, _: String, _: DateTime, _: Option<Exception>)` 是 4 参，不匹配基类 `AbstractLogger.append(level, message: () -> String, now, tid, ex)`（5 参 `open`），**不构成 override**；全仓 0 引用。类本身不是 `open`，按硬原则二判死代码。实际生效的是构造里的 `LogLevel.OFF`（`:25`），该空函数只起误导作用。
  4. `log.cj` 87 行全部是注释掉的 ANSI 颜色表，没有任何声明，属于该删的残留文件。
- **描述**：死代码本身不产生错误，但第 2、3 项会让人误以为「none kind 可用」「空 append 已屏蔽输出」，排查日志不输出时会走错方向（真正原因是 `level=OFF` 与 `create` 的过滤）。
- **建议**：删除 `isEmpty`、`log.cj`；`NoneLogAppender` 若要保留 null 语义，删掉 `register` 与那个 4 参函数，并把「靠 `LogLevel.OFF` 屏蔽」写进类注释。

### [轻微][存量] 重复逻辑：`LoggerConfig` 三对 host/port/bufSize getter，`Logger.append` 的 4 个 Map 变体闭包

- **位置**：`f_log/src/base/LoggerConfig.cj:90-101`、`:144-161`；`f_log/src/base/Logger.cj:81-156`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复）
- **证据**：静态确定 ——
  1. `getTcpHost/getUdpHost`、`getTcpPort/getUdpPort` 函数体逐行相同（都是 `getString(appenderKeyPart(appender), "host"/"port") ?? ""`）；`getTcpSendBufSize/getUnixBufSize` 只有日志文案不同。可合并为 `getHost(appender)` / `getPort(appender)` / `getBufSize(appender, kind)`。
  2. `Logger.append<T>(HashMap|ConcurrentHashMap|TreeMap|LinkedHashMap, ex)` 四个闭包是同一段「遍历 → `filter.filter(n, v.toString())` → 填 `HashMap<String,String>` → `TextTemplate.compile(...).format<String>(map)`」，差异只有容器类型与遍历写法（`for ((n,v) in args)`）。可抽一个 `private func formatMap<K, V>(args: ...)` 或先转成统一视图。
- **描述**：两处都在日志主路径上，重复的代价是「改一处漏一处」：例如将来给 filter 增加 Trim/脱敏规则，要同步改 4 个闭包。差异点（错误文案、容器类型）不构成业务差异，可以安全抽取。
- **建议**：按上面两处抽取；`Logger.cj` 的 12 个 level × 7 种重载属对外 API 面，保持原样。

### [轻微][存量] `getLogger(typeInfo)` 把 `std.reflect.TypeInfo.get("…")` 表达式当作日志名

- **位置**：`f_log/src/base/LoggerFactory.cj:51-53`（注释在 `:48-50`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）；§14.2
- **证据**：静态确定 —— `getLogger('std.reflect.TypeInfo.get("${typeInfo.qualifiedName}")', attrs)` 生成的 key 是字面量 `std.reflect.TypeInfo.get("fountain::f_a2a.A2aServer")`，注释却写「把 typeInfo 的全限定名作为日志实例的唯一标识」。`%name`（`NameLogPart`，`LogPattern.cj:158-163`）原样打印这个 key。
- **描述**：所有用 `getLogger<T>()` 的调用点（`f_a2a/src/server/A2aServer.cj:112` 等）日志前缀都会变成 `[INFO-std.reflect.TypeInfo.get("…")]`，既长又不像类名；同一类型若既用 `getLogger<T>()` 又用 `getLogger("全限定名")`，会得到两个互不相干的 logger 实例与两条 facade。
- **建议**：直接用 `typeInfo.qualifiedName` 作 key；若担心与手写名冲突，加固定前缀（如 `type://<qualifiedName>`）并在 README 说明 `%name` 的取值规则。

### [轻微][存量] `AbstractLogger.locks` 是「单键 ConcurrentHashMap 包一个 Mutex」；`output` setter 全仓未使用

- **位置**：`f_log/src/base/AbstractLogger.cj:27`、`:138-143`、`:45-53`
- **来源**：存量
- **判据**：review-checklist §1（可简化结构）；§8（每条日志一次哈希查找）
- **证据**：静态确定 —— 每个 `AbstractLogger` 实例只有一个 `tag`（`:33`），`locks.computeIfAbsent(tag)` 永远命中同一个键，等价于 `private let lock = Mutex()`；`output` 的 `set` 分支（`:49-52`）全仓无赋值点（`grep "\.output ="` 只命中 `AsyncLogger.cj:36` 的结构体字段同名初始化）。
- **描述**：多一层哈希表没有换来任何隔离收益，反而让每条日志多一次查找；`output` setter 是 `public abstract class` 的 `protected` 扩展点（不判死代码），但没有任何路径使用它，容易被误认为「可以在运行期换输出」。
- **建议**：改成单个 `Mutex` 字段；若要保留运行期换输出的能力，与 `AsyncLogger.actualOutput` 统一，否则删掉 setter 并在注释里说明输出不可替换。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下均无改前基线，只能作为待验证方向。

### [CPU] 每条日志两次异步入队（Facade 队列 + appender 队列）

- **现状**：`LoggerAppenderFacade.log`（`LoggerAppenderFacade.cj:42-48`）把「遍历所有 appender」包成一个闭包入队，队列消费者再调每个 `appender.log(record)`，而每个 appender 本身又是 `AsyncLogger`，于是**每个 appender 再入一次队**：一条日志 = 1 次 Facade 入队 + N 次 appender 入队 + N+1 个闭包对象。
- **方案**：Facade 只做「同步分发」，把异步下沉一层即可（appender 已经是异步的）；或反过来让 Facade 成为唯一异步点，appender 改成同步写。
- **预期**：每条日志少 1 次 `ArrayBlockingQueue.add`、少 1 个闭包分配、少一次跨线程唤醒（未测）。
- **代价**：分发语义要保证 `close` 期间不丢记录；需要并发压力用例验证顺序。
- **验证**：`cjpm bench -O2` 对「10 万条 INFO 日志、3 个 appender」做改前后对照，给中位数与离散度；`cjprof record` 看 `append`/`add` 自耗时占比。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 每条日志的多次小数组分配与每行一次哈希查找

- **现状**：`LogWriterImpl.writeString` 对每个 pattern 部件都 `v.toArray()` 新建一个 `Array<Byte>`（`src/output/LogWriterImpl.cj:40-42`）；默认 pattern 至少 5 段 + 消息 + 换行 = 7 次分配，再 `buf.addLast(bytes)` 入双端队列。`doLock` 每条日志还要 `locks.computeIfAbsent(tag)`（`AbstractLogger.cj:139`）做一次哈希查找。
- **方案**：`SyncQueueOutputStream` 直接暴露「追加一段 UTF-8 到当前缓冲」的接口，让 `LogWriterImpl` 写入线程内缓冲而不是先分配数组；`locks` 换成单个 `Mutex` 字段（每个 logger 实例本来就是一把锁）。
- **预期**：每条日志少 6~8 次小对象分配与一次哈希查找；高日志量下降低 GC 频率（未测）。
- **代价**：`LogWriter` 是 `stdx.log` 接口，不能改签名；需要在 `OutputStream` 层做聚合（`write(Array<Byte>)` → 追加写）。
- **验证**：`cjpm bench -O2` + `getAllocatedHeapSize()` 对比「每秒 10 万条」场景的分配量与 GC 次数。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 缓冲池容量与线程数耦合

- **现状**：`pool` 为 `ArrayBlockingQueue`，容量 `loggerAsyncBufsize`（默认 1024），每个同时写日志的线程独占一块 `ArrayDeque`；`SyncQueueStream` 另建 `bufSize*10` 的缓冲队列（`AsyncLogger.cj:39`），每个 tag 一份。
- **方案**：把「线程缓冲」改成「每 tag 一个小环形缓冲 + 自旋/锁」，或把池容量与 `Thread` 数解耦（按需创建、用 `WeakRef` 回收），并把 `bufSize*10` 改为可配置的背压阈值。
- **预期**：峰值内存从「1024 块常驻 + tag 数 × 10240 槽位」变成有界稳态；同时消除「并发线程 > 1024 就丢日志」。
- **代价**：需要重新审视严重 #1/#2 的修复，改的是同一段代码，建议合并做。
- **验证**：2000 线程持续打日志 10 分钟，采样 `getUsedHeapSize()`、RSS 与丢弃计数是否达到有界稳态。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 双层异步入队 + 每行 7 次小数组分配占日志端到端耗时的大头 | `f_log/src/base/LoggerAppenderFacade.cj:42-48`、`src/output/LogWriterImpl.cj:40-42` | 各段自耗时占比、每秒可处理条数 | `cjprof record` 跑 3 appender + 10 万条/秒，取 self time；`cjpm bench -O2` 对照 |
| 2 | `doLock` 的实例级 Mutex 在 32 线程同 logger 下成为串行段 | `f_log/src/base/AbstractLogger.cj:138-143` | 锁等待时长与 BLOCKED 线程占比 | 32 线程各打 10 万条，采线程状态 + 分段计时（锁等待 vs 格式化） |
| 3 | 关闭路径的 `while(size>0) sleep(0)` 在关闭瞬间占满一个核 | `f_log/src/base/AsyncLogger.cj:86-93` | 关闭期间该线程 CPU 占比 | 队列积压 1 万条时调 `close()`，`top -H` / `cjprof` 采样该线程 |
| 4 | 1024 的缓冲池在高并发下被耗尽导致日志静默丢弃 | `f_log/src/base/AsyncLogger.cj:139-161` | 池耗尽次数 / 丢弃条数 | 起 2000 个线程各打 100 条，统计 `EmptyPool` 打印次数与期望条数差 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_log/README.md` | .md | ✅ | 见「一般」第 10 条：`closable`、unix `host/port`、队列不阻塞、`%appver`、未文档化配置项 |
| 2 | `f_log/README_en.md` | .md | ✅ | 与中文版逐节对应，同样问题（`:19`、`:72-78`、`:86`），无额外缺失 |
| 3 | `f_log/src/base/AbstractLogger.cj` | .cj | ✅ | 严重 #1 的抛出点；一般 #9（锁内闭包与格式化）；轻微 #4（`locks` 单键 map / `output` setter 未用） |
| 4 | `f_log/src/base/AsyncLogger.cj` | .cj | ✅ | 严重 #1、#2；一般 #1、#2、#3、#4 |
| 5 | `f_log/src/base/AsyncTimeoutPolicy.cj` | .cj | ✅ | 纯枚举 3 值，无逻辑；`Abort` 分支抛 `LogException` 进业务线程，属设计选择，已在一般 #1 说明 |
| 6 | `f_log/src/base/LogFilter.cj` | .cj | ✅ | 接口默认实现 + `DummyLogFilter` 空单例，有意的 Null Object，不计 §3 |
| 7 | `f_log/src/base/LogLevel.cj` | .cj | ✅ | `extend LogLevel.text`，`TRACE`/`OFF`/`ALL` 走 `toString()`，与 `convertLevel` 对应，无缺陷 |
| 8 | `f_log/src/base/LogPattern.cj` | .cj | ✅ | 一般 #8（`%appver` 顺序、静态快照、`%d` 边界）；`compile` 的重复分支见轻微 #2 |
| 9 | `f_log/src/base/LogPattern_test.cj` | .cj | ✅ | 1 条用例覆盖 `%level/%name/%d/%%m` 与字面量；未覆盖 `%app`/`%appver`/`%tid`（正是缺陷所在） |
| 10 | `f_log/src/base/Logger.cj` | .cj | ✅ | 严重 #1 的必然触发源（`error(ex)` 等传 `String.empty`）；轻微 #2（4 个 Map 变体闭包重复） |
| 11 | `f_log/src/base/LoggerAppenderCreator.cj` | .cj | ✅ | 一般 #7（重名静默覆盖）；`create` 遍历全部 creator 依赖各实现自过滤，属设计约束 |
| 12 | `f_log/src/base/LoggerAppenderFacade.cj` | .cj | ✅ | 一般 #2（`close` 绕过基类、先清空再关）；轻微 #1（`isEmpty` 无引用）；优化方案第 1 条 |
| 13 | `f_log/src/base/LoggerConfig.cj` | .cj | ✅ | 一般 #1（默认 `Duration.Max`）、#6（解析缺校验）；轻微 #2（`getTcp*/getUdp*` 两两同体） |
| 14 | `f_log/src/base/LoggerFactory.cj` | .cj | ✅ | 轻微 #3（`getLogger(typeInfo)` 名称是表达式字面量）；`loggers`/`globalAttrMap` 按名常驻，仓内名均为字面量 |
| 15 | `f_log/src/base/LoggerWrapper.cj` | .cj | ✅ | 一般 #5（refresh 无限重试、CAS 冗余） |
| 16 | `f_log/src/base/NoneLogAppender.cj` | .cj | ✅ | 轻微 #1（`register` 零调用且产物被 `LoggerAppenderCreator.create:32` 过滤；4 参 `append` 不构成 override 且零引用） |
| 17 | `f_log/src/base/global.cj` | .cj | ✅ | 模块级 `setGlobalLogger`，正是它让 `LogPattern` 类初始化早于 `AppVersion.set`（一般 #8） |
| 18 | `f_log/src/base/log.cj` | .cj | ✅ | 87 行全部为注释掉的 ANSI 颜色表，无任何声明 → 轻微 #1 |
| 19 | `f_log/src/base/logger_test.cj` | .cj | ✅ | `*_test.cj` 只在测试构建编译；`Test1/Test2LogAppender` 注册的 creator 不做配置过滤，仅测试期存在，不计缺陷 |
| 20 | `f_log/src/exception/LogException.cj` | .cj | ✅ | 4 个构造器转发 `BaseException`，无逻辑；`LogException()` 无参构造仓内未用到，但属对外可达 public API，不判死代码 |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 4（严重 #1/#2、一般 #8/#1）；设计 3（一般 #2 生命周期、#7 注册冲突、#10 文档契约）；语言特性 1（`as`/`getOrThrow` 与 `ThreadLocal` 使用，见轻微 #4）；可读性 1（`log.cj` 纯注释、`Logger.cj` 巨量重载）；安全性 0（无外部输入拼串、无凭据；日志内容默认不过滤但 `LogFilter` 已提供扩展点） |
| §1 死代码 | 4 | 逐个检查结果：① `LoggerAppenderFacade.isEmpty()`（internal，本包及子包 grep 仅命中定义）；② `NoneLogAppender.register()`（全仓 0 调用，且其 creator 产物被 `create:32` 的 `!(logger is NoneLogAppender)` 过滤，注册了也永不生效）；③ `NoneLogAppender.append(LogLevel,String,DateTime,Option)` 是 4 参新重载，不覆盖基类 5 参 `open` 版本、全仓 0 引用，且所属 `public class` 非 `open`，按硬原则二判死代码；④ `log.cj` 整文件 87 行注释无声明。其余：`AsyncLogger`/`SyncQueueOutputStream`/`AbstractLogger`/`LoggerConfig`/`LogPattern` 的 private 成员均有调用者；`protected` 成员中 `AbstractLogger.new`、`output`、`append` 属 `public abstract class` 扩展点，豁免；对外可达的 public（`Logger` 全部日志方法、`LoggerConfig.get*`、`LogPattern` 等）不判 |
| §2 重复逻辑 | 2 | ① `LoggerConfig.getTcpHost/getUdpHost`、`getTcpPort/getUdpPort`、`getTcpSendBufSize/getUnixBufSize` 三对函数体逐行相同（仅异常文案不同），可合并为 `getHost/getPort/getBufSize(appender, kind)`；② `Logger.append<T>(HashMap/ConcurrentHashMap/TreeMap/LinkedHashMap)` 四个闭包是同一段「过滤字段→标量化→模板格式化」，只有容器类型不同，可抽 `formatMap<K,V>(args)`。另比对：`Logger.cj` 的 12 个 level × 7 种重载属刻意的 API 面，不算重复；`LogPattern.compile` 的 10 个 `appendOrigin(); patterns.add(x); i += n` 是同一形状展开，可读性可接受，未单列 |
| §3 空实现 | 2 | `NoneLogAppender` 的空 `append`（轻微 #1，且它并未覆盖基类，实际靠 `level=OFF` 生效）；`AbstractLogger.new(name)` 返回 `this` 的占位默认实现（`public abstract class` 扩展点，不判缺陷，仅记录）。有意的 Null Object 不判：`DummyLogFilter`、`DummyOutputStream.THROW_ON_ACCESSING` 分支、`LogFilter` 接口默认实现 |
| §4 栈溢出 | 0 | 本部分无递归：`LogPattern.compile` 是显式下标循环；`SyncQueueOutputStream.writeTo` 是 `while + peek/removeFirst` 迭代；`LoggerFactory/LoggerConfig` 全为静态转发。无自引用结构遍历 |
| §5 OOM | 1 | 二级缓冲 `buf.addLast(bytes)`（`AsyncLogger.cj:166`）在异常路径上可跨日志累积且不归还池（一般 #4）；`LoggerFactory.loggers`/`globalAttrMap` 按日志名只增不减，但仓内日志名全为字面量，不构成实际增长面；其余队列均有容量上界（`loggerAsyncBufsize`、`bufSize*10`） |
| §6.1 热点瓶颈 | 0 | 本轮无 `cjprof` / `cjpm bench` 数据，`doLock` 串行、双层入队、每行多次分配三处只写进「待验证假设」1~4，未计入发现、未定严重度 |
| §6.2 大粒度锁 | 2 | 结构命中：① 临界区内含可能无限阻塞的 `queue.add`（一般 #1）；② 临界区含用户 `message()` 闭包、模板编译与格式化（一般 #9）。单次持有时长与竞争线程数无测量数据，故按结构问题定「一般」，不上调严重 |
| §6.3 并发串行 | 0 | 单消费者队列是异步日志的设计前提（每 tag 一条消费线程），无 `spawn(...).get()`、无并发度配 1 的错误用法；`LoggerFactory.refresh` 串行遍历 logger 属配置期操作，量级可忽略 |
| §6.4 低效算法 | 1 | `SyncQueueOutputStream.writeTo` 用 `peek()` + `remove()` 两次取队首（`AsyncLogger.cj:175-187`），单消费者下多余但非热点；已并入优化方向，不单列为缺陷 |
| §7 降堆内存方案 | 1 | 缓冲池容量与线程数耦合（方案第 3 条，无基线） |
| §8 降 CPU 方案 | 2 | 双层入队（方案第 1 条）、每行多次小数组分配 + 每行哈希查找（方案第 2 条） |
| §9 local mode 可行性 | 0 | 本部分没有函数内创建的大临时对象：pattern 部件是长生命周期静态单例，缓冲块是池化复用对象（跨函数逃逸），日志行字节数组会进队列（逃逸到消费线程）。改造需要重写 `OutputStream` 写入协议且 `getAllocatedLocalObjectSize()` 会暂停所有仓颉线程，收益无法用峰值内存证明，判「不可行」 |
| §11 现有代码的 BUG（存量） | 12 | 严重 2 + 一般 10 全部为存量；逐函数核对过 `AbstractLogger.log/append/doLock`、`AsyncLogger` 构造/append/close、`SyncQueueOutputStream` 全部方法、`LogPattern.compile/generate`、`LoggerConfig` 全部 getter、`LoggerWrapper.refresh`、`LoggerAppenderFacade` 全部方法、六个 level 的 API 族 |
| §12 并发安全与锁粒度 | 6 | 并发安全 4（严重 #2 计数与关闭竞态、一般 #1 阻塞、#2 生命周期/多消费线程、#4 池竞态）；锁粒度 2（一般 #9 锁内用户回调与格式化、#1 锁内阻塞）。核对后未发现问题的点：`LoggerFactory.loggers`/`globalAttrMap` 走 `ConcurrentHashMap` 原子接口；`AbstractLogger.level` 是普通 `var` 但只存不可变枚举，陈旧读可接受；`LoggerAppenderFacade.appenders` 用 `AtomicReference<Box<Array>>` 整块替换，读者拿快照 |
| §14 功能完备性与 README 覆盖 | 3 | ① `loggerAsyncTimeout`/`loggerAsyncTimeoutPolicy`/`sendTimeout`/`writeTimeout`/`bufSize` 五个配置项实现存在但 README 无文档（一般 #10）；② `%tname`/`%fver` 两个占位符实现存在但未文档化；③ `NoneLogAppender.register()` 注册的 `none` kind 实际无效（轻微 #1）。承诺源与缺失证据均已给出文件:行号 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

轻微条目明细（编号与正文引用一致）：**轻微 #1** 死代码 4 项；**轻微 #2** 重复逻辑 2 组；**轻微 #3** `getLogger(typeInfo)` 的日志名；**轻微 #4** `locks` 单键 map 与 `output` setter。逐条见「发现」。

## 总评

`f_log` 的异步链路是「两级队列 + 线程本地缓冲 + 池化」的组合，代码量不大但并发状态机没有任何单元测试覆盖（两个测试文件只验证了 pattern 解析和「能打日志不报错」），因此本部分的缺陷集中在**关闭与异常两条路径**上，而且都是读代码即可判定的确定性问题。

阻塞项有两个，都建议在下一个迭代修掉：

1. **空字符串写入即崩**（严重 #1）。`SyncQueueOutputStream.write` 用 `bytes[0]` 判哨兵，没有空数组保护，而 `log.error(ex)` 这一族公开 API 恰好传的是 `String.empty`，`%app` 在 `AppVersion.set` 之前也是空串。这是「调用公开 API 直接抛异常」，必须最先修。
2. **关闭时尾部日志必丢**（严重 #2）。构造 `+2`、关闭 `-1` 的引用计数让「等队列排空再关输出」的分支永远进不去，配置刷新/进程退出时消费者还在写就被关了输出。

其余「一般」可分为三组，按修复成本递增：

- **配置与注册**（#6、#7、#10）：都是「写错了不报错」，改动小、收益直接，建议顺手一起修。
- **队列生命周期与背压**（#1、#2、#3、#4）：改的是同一段 `AsyncLogger`/`SyncQueueOutputStream`，需要一起重构成「有停止信号、有丢弃计数、无锁内阻塞」的形态；单独修任何一条都会与另外几条打架。
- **占位符解析与锁粒度**（#8、#9）：`%appver` 前缀截断与 `%app`/`%appver` 静态快照是小改动（调换判断顺序、改成每次取值）；`doLock` 包住用户闭包是设计层面的问题，建议在引入「先格式化到线程缓冲、再入队」时一并去掉实例锁。

文档面问题不多但每条都会误导使用者：unix appender 的字段写错（写 `host/port` 配不上）、`closable` 配置项不存在、`%appver` 失效、以及「队列满不阻塞」与实现相反——这几条应与代码修复同步更新中英文两版。

存量缺陷共 16 条（严重 2 / 一般 10 / 轻微 4），是否纳入修复由用户决定；本轮只读代码，未改任何源码、未跑构建。所有性能结论均无测试数据，只停留在「优化可行性方案」与「待验证假设」，不作为收益承诺。

（范围外提示：`src/impl/*` 的六个 appender 全部继承 `AsyncLogger`，因此严重 #1/#2 与一般 #1/#2/#3/#4 会通过它们直接影响所有线上日志；`FileLoggerAppender` 的 tag 是 `file:///<path>`（`src/impl/FileLoggerAppender.cj:25-30`），多个 logger 名共用同一路径时正好命中一般 #2 的「无条件 `queueMap.remove`」，这部分留待第 2 部分展开。`f_app/src/App.cj:412` 用模块级 `let _` 调 `AppVersion.set`，是 `%app` 恒空的另一个必要条件，属 `f_app` 模块。）

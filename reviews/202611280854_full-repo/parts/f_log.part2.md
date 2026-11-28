# f_log 模块审查报告（模块第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_log`（本部分 15 个源文件，全部 `.cj`；模块合计 33 个 `.cj` + 2 个 `.md`，`.md` 与 `base/` 属第 1 部分）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 基线；`git log` 最新提交 `97507061b`）
- **审查重点**：日志链路正确性与性能、异步/缓冲与丢失、大粒度锁、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（本文件仅为分报告，模块报告由主 Agent 合并产出）

## 发现

### [严重][存量] 轮转锁不覆盖实际写入，定时轮转线程可关闭正在写的句柄

- **位置**：`f_log/src/output/RotatableFile.cj:310`（`write`）、`:207`（`fileLock`）、`:208`（`rotateFileIfNeed`）、`:123`（定时器回调）
- **来源**：存量（`git blame -L 300,315` → `4be871f2fd 2026-10-02`；快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）、§11（并发正确性）
- **证据**：静态确定 —— `write()` 在锁内只做「判断+可能轮转」，`file.load()?.write(buffer)` 在 `synchronized(fileLock)` 之外执行；`rotateFileIfNeed` 内部会 `this.close()`（`:218`）并 `rename`（`:223`）后 `file.store(File(originPath, Append))`（`:232`）。定时器线程（`:123`→`:124`）与日志消费线程同时进入这两个函数。
- **描述**：写线程执行序列是「加锁判定 → 解锁 → `file.load()` → `write`」。若定时轮转在这两步之间执行，`load()` 已取到旧 `File`，随后被 `close()`/`rename`：向已关闭句柄写入抛异常（该条日志丢失，异常经 `AsyncLogger` 消费端 `catch` 打到 stderr），极端情况下 fd 被系统复用后写到别处。触发条件：轮转定时点（如 `rotateDuration=DAY` 的每日 0 点、或 `rotateSize` 临界）与写入并发。
- **建议**：把 `file.load()?.write(buffer)` 移入同一个 `synchronized(fileLock)` 临界区（写入本身是顺序追加，临界区不长）；或用「句柄引用计数 + 写锁」：轮转先置「轮转中」标记，等在途写入结束后再 close/rename。

### [严重][存量] 压缩失败仍无条件删除原始轮转日志

- **位置**：`f_log/src/output/RotatableFile.cj:294`（`finally`）、`:297`（`removeIfExists(path)`）、`:259`（`fsize == 0` 提前 `return`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（错误处理缺失 / 资源不对称）、§3（失败路径按成功处理）
- **证据**：静态确定 —— `doCompress` 的 `finally` 无论压缩是否成功都执行 `removeIfExists(path)`；`f = File(path, Read)` 抛异常时 `fsize` 取 `?? 0` 后 `return`，同样走 `finally`。
- **描述**：`compress ≠ NonCompression` 时，轮转后的日志先被改名成 `xxx.<time>`，再交给后台压缩。只要压缩链路任一步失败（源文件打不开、`CompressOutputStream` 构造/写入失败、磁盘满），`finally` 仍删除源文件，只留下残缺的 `.gz`/`.lz`——**已成功落盘的日志被永久删除**，且没有任何补偿或重命名保留。这是日志模块最不可接受的失效形态。
- **建议**：仅在压缩成功（`compressedFile` 正常关闭且大小 > 0）时删除源文件；失败时保留源文件并把压缩文件删掉（或改名 `.failed`），并记一条 error 日志。

### [严重][存量] URL 形式构造在缺少 `compressFormat=` 时切片越界崩溃

- **位置**：`f_log/src/output/RotatableFile.cj:82`（`?? fileInfo.size`）、`:83`（`if (idx > 0)`）、`:85`（`fileInfo[idx + 15..end]`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界/越界、错误处理缺失）
- **证据**：静态确定 —— 与上两个分支（`:67`、`:74` 用 `?? -1`）不一致：`indexOf("compressFormat=")` 未命中时 `idx = fileInfo.size`，`idx > 0` 恒成立，于是切片区间为 `[size+15, size)`。std 文档 `core_package_structs.md:9380-9403`：字符串切片「超过原字符串边界」抛 `IndexOutOfBoundsException`。
- **描述**：只要 `url` 带查询串但没写 `compressFormat=`（例如 `file:///tmp/a.log?rotateSize=100000000`，这是最自然的用法），`RotatableFile(url, params)` 构造即抛异常 → `FileLoggerParams.newAppender` 失败 → `LoggerAppenderCreator.create` 失败 → 启动失败。另外同一段还叠了两个问题：`url` 前缀未校验（`:60` 直接 `url["file://".size..]`，传普通路径会截掉前 7 字节），`rotateSize` 走 `Int64.parse`（`:70`）而不支持 `computeBytes` 的 `10M` 写法，与配置项语义不一致。
- **建议**：三处统一 `?? -1`；`url` 必须以 `file://` 开头否则抛明确异常；`rotateSize` 改调 `computeBytes`；建议补一条 `RotatableFile(url)` 的用例覆盖 `?rotateSize=`、`?rotateDuration=`、`?compressFormat=` 与组合。

### [严重][存量] unixDatagram 的本地 bind 地址与发送目标被设为同一路径

- **位置**：`f_log/src/output/UnixDatagramStream.cj:25`（`newSocket`）、`:27`（`UnixDatagramSocket(bindAt: path)`）、`:38`（`UnixSocketAddress(path)` 作为 `addr`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（接线缺失/功能不可用）
- **证据**：静态确定 —— std 文档 `net_package_classes.md:9094-9107`：`UnixDatagramSocket(bindAt:)` 是**本地绑定**地址，`bind()` 后 `sendTo(addr, payload)` 发往 `addr`。本实现用同一个 `path` 同时作为 `bindAt` 与 `addr`。同文件 `:25` 保留的默认值 `'/tmp/${SERIAL.fetchAdd(1)}'` 恰恰说明「本地地址应是唯一路径」，但 `:38` 永远显式传 `path`，该默认值从不生效。
- **描述**：两种结果都不对：① 采集端已经在该路径 `bind` 时，客户端 `bind()` 直接 `EADDRINUSE` → appender 构造失败/启动失败；② 采集端尚未 bind 时，客户端自己占住该路径，`sendTo` 的报文投递给自己，无人读取 → 接收缓冲区满后 `sendTo` 失败，**unixDatagram 日志全部丢失**，同时采集端再也无法绑定该路径。`close()`（`:47-49`）只关 fd，不 unlink 该 socket 文件，进一步导致重启后必然命中 ①。
- **建议**：`init(path:)` 里 `bindAt` 用唯一本地路径（`/tmp/fountain-log-<pid>-<serial>`，把已有的 `SERIAL` 用起来），`addr` 用 `path`；`close()` 后 `removeIfExists(本地路径)`。

### [严重][存量] tcp / unix appender 从不调用 `connect()`，socket 始终未连接

- **位置**：`f_log/src/impl/TcpLoggerAppender.cj:50-57`（`createSocket`）、`f_log/src/impl/UnixLoggerAppender.cj:45-52`（`createSocket`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（功能不可用）
- **证据**：静态确定 —— std 文档 `net_package_classes.md:6772-6784`：`TcpSocket(address: String, port: UInt16)`「创建一个未连接的套接字」；`:11872-11889`：`UnixSocket`「实例创建后应调用 `connect()` 接口创建连接」。两个 `createSocket` 都只设 `keepAlive`/超时/缓冲区就返回，全文件检索无 `connect()`。对照同仓 `UnixStream.cj:22-27` 的写法（`UnixSocket(addr)` 后 `sock.connect()`）可确认这是遗漏而非新语义。具体抛点（设属性还是首次 `write` 失败）待实测，不影响「连接从未建立」这一结论。
- **描述**：`append` 首次写时向未连接的 socket 写 → `SocketException`；`isClosed()` 只反映「是否显式 `close` 过」（std 文档 `net_package_classes.md:11570-11575`），未连接不会让它返回 `true`，因此 `append` 里的 `if (sock.isClosed())` 重连分支永不触发 → 该 appender 永久不可用，每条日志都丢失并在 `SyncQueueStream` 消费端打印一次栈（错误信息本身也在刷屏）。TCP 与 Unix 两个 appender 同时受影响（`udp`/`unixDatagram` 是无连接协议，不受此影响，但后者另有 bind 缺陷）。
- **建议**：`createSocket` 内显式 `sock.connect()`；连接失败按策略处理（启动期直接失败，或静默重试 + 退避并记一条 error）；`append` 捕获写异常后 `close()`旧 socket，让下次写入能重建并重连。

### [一般][存量] UDP 端口判断恒真：未配 `port` 时启动抛异常，`host:port` 写法成死分支

- **位置**：`f_log/src/impl/UdpLoggerAppender.cj:89`（`if (let p <- LoggerConfig.getUdpPort(appender))`）、`:90-92`、`:93-95`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（恒真分支）、§11（边界/空值）、§13 对照
- **证据**：静态确定 —— `LoggerConfig.getUdpPort` 返回 `String`（`f_log/src/base/LoggerConfig.cj:99`，缺省 `""`），非 `Option`；对非 Option 值用 `let p <- ...` 是不可反驳的绑定模式，条件恒为真。对照 TCP 的同一处（`TcpLoggerAppender.cj:92`）写的是 `&& !p.isEmpty()`。
- **描述**：① 配置里只写 `host` 不写 `port` 时 `p == ""`，`UInt16.tryParse("")` 返回 `None`，`getOrThrow` 抛 `LogException` → `newParams` 在 `BaseLoggerParams.register` 的临界区内抛出 → UDP appender 创建失败、进程启动失败；文件里的默认值 `var port = 65534u16`（`:85`）永远用不上。② `:93` 的 `else if (let Some(idx) <- host.indexOf(':'))`（从 `host` 里拆 `host:port`）永远走不到，配置形态少一种却不报错。
- **建议**：改成 `if (let p <- ... && !p.isEmpty())`（与 TCP 对齐），再补 `host:port` 的用例；或让 `getUdpPort`/`getTcpPort` 返回 `Option<String>`，从签名上消除这类恒真判断。

### [一般][存量] `url` 配置键少一段前缀，README 承诺的 url 配置静默失效

- **位置**：`f_log/src/impl/FileLoggerAppender.cj:60`（`LoggerConfig.getString(appender, 'url')`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §14.1（配置项被读取却从不生效）、§13（文档与实现不符）
- **证据**：静态确定 —— `getString(appender, item)` 拼的是 `${confPrefix}_${appender}_${item}` = `logger_<appenderName>_url`；同文件其余字段都走 `appenderKeyPart(appender)`（`LoggerConfig.cj:63-65`）得到 `logger_appender_<appenderName>_<item>`。README（第 1 部分文件，仅作交叉核对）`:73` 把 `url` 列为 file appender 的专有字段。
- **描述**：按 README 配 `logger_appender_FDemoFile_url=...` 读不到值，`url` 恒为 `''`，`FileLoggerParams.newAppender` 永远走 `RotatableFile(params)` 分支（`:82-86`）——「用 URL 指定路径+轮转参数」这条能力对外不可达，且没有任何告警。
- **建议**：改 `LoggerConfig.getString(appenderKeyPart(appender), 'url')`（或新增 `getLogFileUrl`），并在 README 里补 `file://` + 查询参数的语法说明。

### [一般][存量] 压缩任务入队在 `fileLock` 内且无超时，压缩慢时写日志线程被阻塞

- **位置**：`f_log/src/output/RotatableFile.cj:301`（`queue.add(...)`）、`:227`（调用点在 `synchronized(fileLock)` 内）、`:51`（`ArrayBlockingQueue(1)`）、`:118-122`（消费线程）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §6.2 / §12.2（锁内做 O(输入) 的阻塞动作）
- **证据**：静态确定 —— std 文档 `collection_concurrent_class.md:206-210`：`ArrayBlockingQueue.add(element)` 是「队列已满则阻塞等待」的无超时入队。队列容量为 1，压缩线程同一时刻只处理一个文件。
- **描述**：轮转发生时（写日志线程或定时器线程）持 `fileLock` 调 `compressAndDeleteOld`；若上一个轮转文件还在压缩（`BestCompression` + 大文件可到秒级），`add` 阻塞，`fileLock` 一直被占 → 同一文件的所有日志写入排队，日志链路从「异步」退化为「等压缩」。因为 `SyncQueueStream` 的缓冲池有限，长时间阻塞还会反压到业务线程（`AsyncLogger.append` 的策略为 `AlwaysWaiting` 时会一直等）。
- **建议**：临界区内只做「生成任务 + 决定轮转」，把入队移到锁外；队列容量给足（如 4~8）或改用 `add(task, timeout)` + 失败降级（保留未压缩文件，记一条 warning），保证日志写入路径永不等压缩。

### [一般][存量] rename 失败后不重开文件，此后所有写入落在已关闭句柄上

- **位置**：`f_log/src/output/RotatableFile.cj:222-226`（`rename` 失败只打印）、`:231-233`（仅当源文件不存在才 `store` 新句柄）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（错误处理缺失、资源不对称）
- **证据**：静态确定（「不重开」路径）+ 待确认（`File.info` 在已关闭句柄上的具体行为，决定能否自愈）
- **描述**：`close()` 成功后 `rename` 失败（目标名已存在、权限、跨设备）时源文件仍在，`if (!exists(originPath))` 为假 → `this.file` 继续指向已关闭的 `File` → 后续每次 `write` 抛异常（每条日志丢失 + 每次打印栈）。下一次 `rotateFileIfNeed` 的 `needRotate` 先读 `this.file.load().getOrThrow().info`（`:238-239`），对已关闭句柄读元数据同样会失败，轮转无法自愈，直到进程重启。目标名冲突恰恰由 `genTime` 的 SECOND 格式缺陷（见下条）放大。
- **建议**：`close`/`rename` 之后**无条件** `this.file.store(File(originPath, Append))`（rename 成功则新建，失败则复用原文件路径），并在 `needRotate` 里对 `info` 读取失败做「重开 + 跳过本轮轮转」的兜底。

### [一般][存量] `genTime` 的 SECOND 分支把「分钟」写成「月」，轮转文件名错误且可能重名

- **位置**：`f_log/src/output/RotatableFile.cj:203`（`format("yyyyMMddHHMMss")`）
- **来源**：存量（blame `-L 200,205` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（语义与命名不符 / 边界）
- **证据**：静态确定 —— std 时间格式表（`time_package_overview.md:19-40`）：`M` 是月份、`m` 是分钟、`H` 是 24 小时制小时、`s` 是秒。该串展开为「年(4)月(2)日(2)时(2)月(2)秒(2)」，月份出现两次、分钟缺失；同函数其余分支（`:196-202`）都用 `HHmm`。
- **描述**：`rotateDuration=SECOND` 时文件名形如 `x.log.20261128101145`（第二个 `11` 是月份而非分钟），与真实时间不符；同一小时内两次同秒轮转会得到同一个目标名，`rename(..., overwrite: false)` 抛异常，进而落入上一条「rename 失败不重开文件」的严重路径。若格式化器按解析规则拒绝重复字母，则该分支每次轮转都直接抛异常（两种结果的修复方式相同）。
- **建议**：改为 `"yyyyMMddHHmmss"`；`WEEK` 分支（`:199` 的 `yyyyMMddWW`）建议改用基于周的年 `Y` 或加注释说明用的是日历年。

### [一般][存量] `RotatableFile` 没有停止机制：定时器、消费线程、atExit 回调都只增不减

- **位置**：`f_log/src/output/RotatableFile.cj:109-111`（`close` 只关文件）、`:118-122`（`spawn` 死循环消费）、`:123-128`（`Timer` + `env.atExit`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1（有界性）、§11（资源不对称）、§7（生命周期偏长）
- **证据**：静态确定 —— `close()` 不含 `timer.cancel()`、不含队列终止信号；`while (let fn <- queue.remove())` 中 `remove(): E` 永不返回 `None`（std 文档 `collection_concurrent_class.md:561-593`），循环无出口；`env.atExit(timer.cancel)` 只在进程退出时生效。配置热更新路径确实会重建实例：`LoggerConfig` 注册了 `Config.refresher("logger", LoggerFactory.refresh)`（`LoggerConfig.cj:38-40`）→ `LoggerWrapper.refresh` → 新 facade，旧 appender 被标记 `closable` 后关闭（`LoggerParams.cj:55-62`）。
- **描述**：每次轮转参数变化（改 `rotateSize`/`compressFormat`/`path`）都会新建一个 `RotatableFile`，旧的只关文件：其定时器继续按周期触发 `rotateFileIfNeed`，对已关闭句柄读 `info` 抛异常（异常在定时器线程里反复打印）；其消费线程、队列、atExit 回调永久驻留。长时间运行 + 多次改配置会累积线程与回调（每次泄漏 1 线程 + 1 定时器 + 1 回调 + 1 队列）。
- **建议**：`close()` 里 `timer.cancel()`、给队列投一个哨兵任务让消费线程退出、并把 atExit 注册改成「进程级单例统一关闭」（`LoggerWrapper` 已有 atExit，可把轮转定时器登记到同一注册表里，删除时同步注销）。

### [一般][存量] 数据报 appender 按「片段」发送，一条日志被拆成多个数据报

- **位置**：`f_log/src/output/UdpOutputStream.cj:39-41`（`write` 一次 `sendTo`）、`f_log/src/output/UnixDatagramStream.cj:40-42`；写入粒度来自 `f_log/src/output/LogWriterImpl.cj:40-42`（每个片段一次 `write`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（功能完备性）
- **证据**：静态确定 —— `AbstractLogger.doAppend` 用 `pattern.generate(...)` 逐片段写 `writer`，`SyncQueueOutputStream` 按片段入缓冲、消费端 `writeTo` 逐片段 `output.write(bytes)`（`AsyncLogger.cj:174-189`），因此 UDP 传输层收到的是一次一条片段，不是一条日志。记录边界（`'\0'`）只在缓冲层被消费掉。
- **描述**：UDP/unixDatagram 是报文语义，接收端拿到的是 `[LEVEL-name]`、时间、`|tid;`、消息体、属性和异常栈分别成报；既无法按条解析，也无法丢弃半条。另外 `sendTo` 对超过 64KB 的报文会抛 `SocketException`（std 文档 `net_package_interfaces.md:16-19,107-123`），一条超长日志（长栈/大报文）在 UDP 上必然整条丢失且每次抛异常。
- **建议**：给 `OutputStream` 加记录边界语义（如 `LogWriter` 层暴露 `endRecord()`，或让 datagram appender 持有 `ArrayDeque<Array<Byte>>` 攒到记录结束再 `sendTo` 一次）；同时对单条长度设上限，超限截断并计数。

### [一般][存量] socket appender 重连时无同步写入 `actualOutput`，与 close/isClosed 并发

- **位置**：`f_log/src/impl/TcpLoggerAppender.cj:63-67`、`f_log/src/impl/UdpLoggerAppender.cj:60-64`、`f_log/src/impl/UnixLoggerAppender.cj:58-62`、`f_log/src/impl/UnixDatagramLoggerAppender.cj:53-57`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1（可见性 / 发布逸出）
- **证据**：静态确定 —— `super.actualOutput` 是 `AsyncLogger` 的普通 `protected var`（`AsyncLogger.cj:60`），写方是日志消费线程（`append` 里重建 socket 后赋值），读方是 atExit / 配置刷新线程（`AsyncLogger.close()`、`isClosed()`）。
- **描述**：没有锁也没有原子发布：`close()` 可能读到旧 socket 并关闭它，同时写线程已切换到新 socket → 新 socket 永不关闭（fd 泄漏）；`isClosed()` 也可能读到过期引用。触发条件是「断连重连」与「进程退出/配置刷新」时间重叠，概率低但属于无同步的共享可变状态。
- **建议**：`actualOutput` 换成 `AtomicReference<OutputStream>`（或把所有访问收进 `doLock`），重连时用 CAS 替换并对旧值做 `close()`。

### [一般][存量] `RotatableFileParams` 用可变字段做 Map 键并缓存 hashCode

- **位置**：`f_log/src/output/RotatableFile.cj:31-47`（`public var path/fileSize/timeunit/compress`、`:41-47` 缓存 `h`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符：`Hashable & Equatable` 的可变键）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `hashCode()` 首次计算后写入 `private var h`，之后字段变更不再重算；`==` 又同时比较 `h` 与字段（`:37-40`）。该类实例被 `FileLoggerParams`（`hashCode` 里 `append(params)`）与 `BaseLoggerParams.register` 的 `ConcurrentHashMap` 直接当键（`LoggerParams.cj:41,47,52,64`）。
- **描述**：先取过一次 `hashCode` 再改字段（`RotatableFileParams` 是 public 且有 `public var`，`FileLoggerParams` 的构造参数也是 public）会让 `==` 与 `hashCode` 不自洽：字段相等的两个对象可能 `hashCode` 不同 → `appenderMap.get(params)` 落空 → 重复创建 appender/文件句柄/定时器（叠加前一条泄漏）；反向（字段已改但 hash 未变）会命中错误的 appender。`h == 0` 当「未计算」哨兵也让真实 hash 为 0 的对象每次重算。
- **建议**：字段改 `let`（构造期定值）并去掉缓存；确需可变则提供 `copy()` 生成快照后再入 Map，或用 `Option<Int64>` 表示「未计算」。

### [一般][存量] appender 注册的静态锁把 socket 连接与文件创建包在临界区内

- **位置**：`f_log/src/impl/LoggerParams.cj:28`（`private static let mutex`）、`:40-67`（`synchronized(mutex)`）、`:46-54`（锁内调 `new`/`newAppender`）、`:55-62`（锁内 `removeIf` + 改 `closable`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §6.2 / §12.2（锁内 I/O、锁内调用外部代码）
- **证据**：静态确定 —— 临界区内依次做：读配置（`:36`）、建 `HashMap`、`params.newAppender(name)`（`:50`，内含建目录/开文件/建 socket）、`appenderMap.removeIf{ ... v.closable = true }`（`:55-62`）。`mutex` 是 `BaseLoggerParams<T>` 的静态字段，同一 params 类型的全部 appender 创建共用。
- **描述**：每个 appender 的建目录 / `File(path, Append)` / 建 socket（`TcpSocket(...)` 含地址解析，`UnixSocket(...)` 含 socket 文件操作）都在锁内完成，锁被持有到所有 appender 建完；TCP 对端不可达或 DNS 慢时，其他 appender（甚至另一种 params 类型的注册）创建被拖住。`removeIf` 在容器遍历回调里改外部对象的 `closable`，把 appender 的关闭语义耦合进 map 的遍历过程（关闭动作发生在锁外，但标记在锁内，见 `AsyncLogger.doClose` 的读取点）。当前只发生在启动与配置刷新路径，不进请求主路径，故定「一般」。
- **建议**：把 I/O（`newAppender`/connect）移到锁外，锁内只做 `appenderMap` 的查/放与「待关闭列表」收集；随后在锁外对旧 appender 置 `closable` 并关闭。

### [一般][存量] 4 个 socket appender 与 6 个 params 类近乎逐行重复

- **位置**：`append` 覆写四份 —— `TcpLoggerAppender.cj:62-69`、`UdpLoggerAppender.cj:59-66`、`UnixLoggerAppender.cj:57-64`、`UnixDatagramLoggerAppender.cj:52-59`；`new(name)` 四份 —— `Tcp:46-49`、`Udp:48-50`、`Unix:42-44`、`UnixDatagram:45-47`；`appenderMap + register` 六份 —— `Console:29-31`、`File:39-42`、`Tcp:58-61`、`Udp:55-58`、`Unix:53-56`、`UnixDatagram:48-51`；`operator ==` 六份 —— `Console:44-46`、`File:54-57`、`Tcp:82-85`、`Udp:79-82`、`Unix:77-80`、`UnixDatagram:72-75`；`newAppender` 六份；`host:port` 解析两份 —— `Tcp:96-98` 与 `Udp:93-95`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2（只改类型名的复制 / 字面量复制）
- **证据**：静态确定 —— 四段 `append` 除被 cast 的类型外逐字相同（`getOrThrow` → `isClosed` → `createSocket` → `super.actualOutput = sock` → `super.append`）；两段 `host:port` 解析把同一段 `indexOf(':')`/`trimAscii`/`UInt16.parse` 抄了两遍，连错误文案都写成 `"param port of SocketLoggerAppender..."`（`Udp:91` 里类型名也没改）。
- **描述**：这是「换类型名」的重复：任何一处修复（如上一条的原子发布、重连退避、`isEmpty` 校验）都必须同步改 4 份，实际已经漂移——`Udp/Unix/UnixDatagram` 的 `new` 写成 `public`，`Tcp/File/Console` 写成 `protected`；UDP 少了 `isEmpty` 校验；`sendTimeout`/`writeTimeout` 两个名字指同一件事。§2 要求点名差异：这里差异只有「socket 类型、地址参数名、默认端口」，属于可参数化而非业务差异。
- **建议**：抽 `protected abstract class SocketAppender<S> <: AsyncLogger`（持有 `host/path`、`createSocket()`、统一的 `append` 重连 + 原子替换），四个实现只提供 `createSocket` 与 tag；params 侧抽 `SocketLoggerParams<T>`（`==`/`newAppender` 模板），`host:port` 解析收敛到 `f_net` 或 `f_util` 的一个函数。合并时保持 `new` 的可见性一致。

### [轻微][存量] 死代码：未使用类型/构造/字段与注释残留

- **位置**：`f_log/src/output/UnixStream.cj:21-47`（`UnixOutputStream` 整类，全仓除定义外 0 引用；`UnixLoggerAppender` 直接用 `UnixSocket`）、`f_log/src/output/UdpOutputStream.cj:31-38`（`init(addr:sendTimeout:)`，全仓 0 引用）、`f_log/src/output/UnixDatagramStream.cj:23,25`（`SERIAL` 与默认 path 形参：唯一调用点 `:38` 永远显式传 `path`）、`f_log/src/output/RotatableFile.cj:52`（`rotateTimer` 字段只写不读，仅 `:95/:104` 赋值）、`f_log/src/impl/imports.cj:30`（注释掉的 `internal import fountain::f_exception.*`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（非 public 顶层类型/B 类成员无使用、读了不用、兼容残留）
- **证据**：静态确定 —— 检索命令：`grep -rn "UnixOutputStream" --include=*.cj --exclude-dir=.worktrees .` 仅命中定义与自身构造；`grep -rn "UdpOutputStream(" ...` 仅命中 `UdpLoggerAppender.cj:52`（走 `init(addr:port:sendTimeout:)`）；`grep -rn "rotateTimer" ...` 仅 3 处（声明 + 2 次赋值）。`UnixOutputStream`/`UdpOutputStream`/`RotatableFile` 都是 `protected` 顶层类型，不属于「对外可达 public」豁免。
- **描述**：`UnixOutputStream` 与 `UdpOutputStream` 的第二个构造是重构残留（`Udp` 那个还会走 `IPSocketAddress.parse`）；`SERIAL` 的存在暗示 unixDatagram 本应用唯一本地地址，与上面「bind == 目标」缺陷同源；`rotateTimer` 字段无用（定时器已在 `createRotateTimer` 内 `atExit` 取消）。
- **建议**：删除 `UnixStream.cj` 或让 `UnixLoggerAppender` 改用它；删除 `UdpOutputStream` 的无用构造与 `SERIAL`/默认 path（或按缺陷修复真正启用）；删 `rotateTimer` 字段与注释掉的 import。

### [轻微][存量] `computeBytes` 的 trim 结果未使用、空串越界、溢出未校验

- **位置**：`f_log/src/output/RotatableFile.cj:163-192`（`:164` 的 `b`、`:166` 的 `ne = bytes.size`、`:167,170` 的 `bytes[ne - 1]`、`:179-182` 的乘法）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（读了不用）、§11（边界/空值）
- **证据**：静态确定 —— `let b = bytes.trimAscii()` 之后所有下标仍基于 `bytes`，`b` 只在错误文案里出现；`bytes` 为空串时 `bytes[ne - 1]` 即 `bytes[-1]` 抛异常；`Int64.tryParse(...) * 1024 ** n` 无上限校验。
- **描述**：配置写 `"10 M"`（带空格）时 trim 形同虚设，`tryParse("10 ")` 失败，报错文案却提示「不是合法字节描述」，排查方向被误导；`computeBytes` 是 `public static`（模块内可达），空串调用直接崩。
- **建议**：解析统一基于 `b`（`ne = b.size`），空串先判 `isEmpty` 返回明确异常；乘法前用 `Int64.Max / factor` 校验溢出。

### [轻微][存量] `createDirIfNeed` 仅按 `/` 切目录，相对路径会把文件名当目录

- **位置**：`f_log/src/output/RotatableFile.cj:130-136`（`:131` `path[0..(path.lastIndexOf("/") ?? path.size)]`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— `lastIndexOf("/")` 为 `None` 时整串被当目录名
- **描述**：`path = "app.log"`（无目录部分）时 `Directory.create("app.log", recursive: true)` 创建一个**目录**，随后 `File("app.log", Append)` 失败；Windows 风格 `C:\logs\a.log` 同理（仓颉 `File` 也接受 `Path`，文档 `fs_package_classes.md:557-580` 有 `init(path: Path, mode:)` 重载）。默认配置带目录所以主路径不触发。
- **建议**：用 `Path(path).parentDirectory` 判断并创建；无父目录时用当前目录。

### [轻微][存量] `RotatableFileTest` 无断言、无清理，不能回归轮转/压缩

- **位置**：`f_log/src/output/RotatableFile_test.cj:23-41`（`:33-38` 死循环写、`:39` 固定 sleep 5s、`:40` 注释掉的 `throw Exception()`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（空实现/占位）、§11（测试不成立）
- **证据**：静态确定 —— 无用例断言、无文件清理、`path` 硬编码 `/tmp/test.log`
- **描述**：这条用例只证明「5 秒内没崩」，上面与 `RotatableFile` 相关的缺陷（锁竞争、压缩失败删文件、URL 解析、rename 失败、SECOND 格式）它一个都测不出来；末尾注释掉的 `throw Exception()` 说明作者原本想用它看异常。
- **建议**：改成有断言的用例：写满 → 断言产生 `.gz`、源文件被删、新文件继续写；再补一个 `url=` 与 `compressFormat` 非法值的用例（当前会崩）。

### [轻微][存量] 有意 no-op 缺注释；`CompressLevel` 比较被重复实现

- **位置**：`f_log/src/output/UdpOutputStream.cj:42`（`flush() {}`）、`f_log/src/output/UnixDatagramStream.cj:43`、`f_log/src/impl/ConsoleLoggerAppender.cj:32-37`（`closable` setter 空体）；`f_log/src/output/RotatableFile.cj:324-331`（`eq`）与 `:340-346`（`compressLevelString`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（有意的 no-op 必须有注释）、§2（同一组枚举值的 match 写两遍）
- **证据**：静态确定 —— `eq`/`compressLevelString` 是对 `CompressLevel` 三个构造器的两份手写分支，`CompressLevel` 是 enum（自带 `==`/`toString`）
- **描述**：no-op 本身正确（UDP 无缓冲、stdout 不可关），但没有一行注释说明「为什么可以空」，容易被后来者当缺陷改掉；枚举 match 两份会在新增压缩级别时漏改（漏改 `eq` 会让 `==` 恒假，比漏改 `toString` 更危险）。
- **建议**：加一行「// UDP 无用户态缓冲，无需 flush」类注释；`eq` 直接用 `x == y`，`toString` 用 `${x}`，删除两份手写 match。

## 优化可行性方案

> 本部分未提供任何 profile / bench 数据，以下全部为「待验证假设」级别的改动建议，**不进 tasks**。

### [CPU] 每次日志写入都要取锁 + 取时间 + 读文件元数据

- **现状**：`RotatableFile.write`（`:310-313`）每条日志（更准确地说每个缓冲片段）都会：`synchronized(fileLock)`（`:209`）→ `DateTime.now()`（`:210`）→ `file.info`（`:238-240`，读元数据）→ 可能 `rename`。调用路径：`AbstractLogger.log` → `AsyncLogger.append` → 队列 → 消费线程 `SyncQueueOutputStream.writeTo` → `RotatableFile.write`；输入规模 = 每秒日志条数 × 每条记录的片段数（片段数由 pattern 决定，一条记录通常被拆成多个片段）。
- **方案**：把「是否轮转」的判定降频：用 `AtomicInt64` 累计已写字节，只在 `累计 >= 阈值` 或定时器到点时进锁复核；`DateTime.now()` 只在定时器/阈值边界取一次，不在每次写取。
- **预期**：每次写入少一次锁获取 + 一次时钟读取 + 一次 stat；端到端收益取决于日志量占比，当前无法量化。
- **代价**：`fileSize` 轮转的判定从精确变为「最多滞后一条记录」；需要保证 `needRotate` 的 `creationTime` 语义不变。
- **验证**：`cjpm bench -O2` 同输入（每秒 10k 条、10 个片段/条）对照写吞吐与 P99；`cjprof record` 看 `rotateFileIfNeed`/`DateTime.now` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU/GC] `LogWriterImpl.writeString` 每片段一次 `toArray` 分配

- **现状**：`LogWriterImpl.cj:40-42` 每个字符串片段 `v.toArray()` 分配一个 `Array<Byte>`（UTF-8 编码）；`writeInt/writeFloat/writeDateTime` 还要先 `toString()` 再进 `writeString`，即字段值本身占 2 次分配。日志量大时这是稳定的小对象分配源，直接抬高 GC 频率。
- **方案**：在 `LogWriterImpl` 内复用一个 `Array<Byte>`（`ByteBuffer` 式扩容），或在 `SyncQueueOutputStream.write` 的缓冲层直接追加字节；`writeInt` 用定长栈缓冲格式化（仓颉可用 `StringBuilder` 复用或 `Int64.toString` 到复用缓冲）。
- **预期**：每片段减少 1~2 次堆分配；GC 次数与 `getAllocatedHeapSize()` 可测下降，比例待测。
- **代价**：需要处理 `Array<Byte>` 生命周期（复用缓冲不能逃逸到队列，否则数据被覆盖）；`OutputStream.write(Array<Byte>)` 语义是「立即消费」，复用需要确认实现方不持有引用（`RotatableFile.write`/`socket.write` 都是同步写，成立）。
- **验证**：同负载下 `getAllocatedHeapSize()` 增量、GC 次数、写吞吐中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 压缩缓冲与轮转中间对象

- **现状**：`doCompress` 每次分配 `Array<Byte>(min(fsize, 1MiB))`（`:271-275`），压缩期间常驻；`needRotate` 每次写都会构造一次 `FileInfo`（`:239`，含 path 等字段），`RotatableFileParams` 每次配置解析新建一份。
- **方案**：压缩缓冲改为按固定 64KiB 复用（同一压缩任务内循环使用，不按文件大小一次分配）；压缩任务串行执行（容量 1 已保证），可共用一个进程级缓冲。
- **预期**：单次压缩峰值从 1MiB 降到 64KiB（对象数 1 个，字节量 -94%），对整体 RSS 影响 <1MiB，主要收益是峰值确定性。
- **代价**：压缩循环从「一次大 read」变「多次小 read」，CPU 略增；需要确认 `CompressOutputStream.write` 的拷贝语义。
- **验证**：`getUsedHeapSize()` 峰值 + RSS 对照，同一轮转文件（100MB）压缩前后。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 写日志路径上 `file.info` 每次写都触发一次 stat 系统调用，是 CPU/系统调用热点 | `f_log/src/output/RotatableFile.cj:238` | 单次写耗时拆分、stat 调用次数 | `strace -c -f` 跑 10 分钟稳态日志，统计 `fstat/newfstatat` 次数；`cjprof record` 看 `needRotate` 自耗时占比 |
| 2 | `fileLock` 在日志高峰已成为串行段（写线程 + 定时器 + 压缩入队） | `RotatableFile.cj:207-236` | 锁等待时长、BLOCKED 线程数 | 线程 dump / `cjprof` 线程状态采样（CPU profile 看不到锁竞争），并发 8 线程各写 1k 条/秒 |
| 3 | 每条日志 5~10 个片段导致 UDP 报文数放大，接收端丢包率上升 | `UdpOutputStream.cj:39`、`LogWriterImpl.cj:40` | 单条日志片段数、报文数与丢包率 | 埋点统计 `write` 调用次数/条，接收端统计报文数；对比按记录合并后的丢包率 |
| 4 | 配置热更新反复重建 `RotatableFile`，线程数与 atExit 回调数单调增长 | `RotatableFile.cj:117-129` | 每次 refresh 后的线程数/回调数 | 连续改 10 次 `rotateSize` 后采样 `Thread` 数量与 RSS |
| 5 | `LogWriterImpl` 的 `toArray` 分配占 GC 分配量的显著比例 | `LogWriterImpl.cj:41` | 分配量按调用点拆分 | 同负载下 `getAllocatedHeapSize()` 前后对照 + 分配采样 |

## 文件覆盖

> 与 `files/f_log.part2.txt` 一一对应（15 行，全部读完）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/impl/ConsoleLoggerAppender.cj` | .cj | ✅ | 见「有意 no-op 缺注释」；`closable` 恒 false 与 stdout 语义一致 |
| 2 | `src/impl/FileLoggerAppender.cj` | .cj | ✅ | 见 `url` 配置键缺陷、`toPath` 硬编码 `file:///` |
| 3 | `src/impl/LoggerParams.cj` | .cj | ✅ | 注册临界区含 I/O（见 §6.2 说明），`removeIf` 内改 `closable` |
| 4 | `src/impl/TcpLoggerAppender.cj` | .cj | ✅ | 见「从不 connect」严重项；与 UDP/Unix 重复；`actualOutput` 无同步 |
| 5 | `src/impl/UdpLoggerAppender.cj` | .cj | ✅ | 见 UDP port 恒真分支 |
| 6 | `src/impl/UnixDatagramLoggerAppender.cj` | .cj | ✅ | 底层 stream 见 `UnixDatagramStream.cj` 严重项 |
| 7 | `src/impl/UnixLoggerAppender.cj` | .cj | ✅ | 见「从不 connect」严重项；直接用 `UnixSocket`，`UnixOutputStream` 成死代码 |
| 8 | `src/impl/imports.cj` | .cj | ✅ | 注释残留 import；其余 `internal import` 用于模块内重导出 |
| 9 | `src/log.cj` | .cj | ✅ | 仅 `public import impl.*`，无逻辑 |
| 10 | `src/output/LogWriterImpl.cj` | .cj | ✅ | 每片段 `toArray`；`writeException` 分支正确 |
| 11 | `src/output/RotatableFile.cj` | .cj | ✅ | 本部分主要缺陷集中地（轮转/压缩/URL/死代码） |
| 12 | `src/output/RotatableFile_test.cj` | .cj | ✅ | 无断言测试 |
| 13 | `src/output/UdpOutputStream.cj` | .cj | ✅ | 无用构造（`:31-38`）；超 64KB 无校验 |
| 14 | `src/output/UnixDatagramStream.cj` | .cj | ✅ | bind 地址 == 发送目标；`SERIAL` 未生效 |
| 15 | `src/output/UnixStream.cj` | .cj | ✅ | 整类无引用（死代码） |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（模块的 2 个 `.md` 与 `src/base/**` 属第 1 部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 15 | 正确性 10（轮转竞态、压缩删源、URL 越界、bind 冲突、tcp/unix 未 connect、UDP 端口、rename 失败、SECOND 文件名错、数据报碎片、无停止机制）；设计 4（重复实现、两处锁内 I/O、`RotatableFile` 职责过多：文件+轮转+压缩+定时器）；可读性 1（重复代码与错误文案漂移）。安全性：无凭据/注入面，日志内容由 `LogPattern` 控制，未发现敏感字段硬编码 |
| §1 死代码 | 1 | 已逐个 `private`/`internal`/`protected` 符号全仓检索：`UnixOutputStream`、`UdpOutputStream.init(addr:)`、`UnixDatagramOutputStream.SERIAL`+默认 path、`RotatableFile.rotateTimer`、`imports.cj` 注释 import 共 5 处，合并为 1 条；其余 `protected` 成员均为父类抽象/接口实现（豁免），顶层 `public`（`RotatableFileParams`、`LogFileCompressFormat`、各 `*LoggerParams`）对外可达，不判死代码；未使用的局部 `let`（`computeBytes` 的 `b`）并入该条 |
| §2 重复逻辑 | 2 | 已把 15 个文件里 60+ 个函数体压成「输入→输出→副作用」摘要两两比对：4 份 socket `append`/`new`、6 份 `appenderMap+register`/`==`/`newAppender`、2 份 `host:port` 解析为一条（一般）；`CompressLevel` 的两份手写 match 为一条（轻微）。`ConsoleLoggerAppender`/`FileLoggerAppender`/`Tcp...` 的 `params` 类差异仅在字段集，已在同一份证据里点名差异（socket 类型、参数名、默认端口） |
| §3 空实现 | 1 | `UdpOutputStream.flush`/`UnixDatagramOutputStream.flush`/`ConsoleLoggerAppender.closable` setter 为有意 no-op，缺注释；`BaseLoggerParams.newParams` 抛 `unreachable` 属抽象占位（所有子类覆盖），不算；所有 `catch` 都 `printStackTrace`，无静默吞（但 `doCompress` 吞掉失败后仍删源文件，已按严重项报告） |
| §4 栈溢出 | 0 | 无递归函数；`genTime`/`compressFormat`/`computeBytes` 都是 `match`+循环；`doCompress` 读写循环是迭代；无自引用结构、无深度拷贝 |
| §5 OOM | 0 | 队列容量 1（有界）、压缩缓冲 ≤1MiB（有界）、无全局只增不减容器、无按报文长度预分配（`Array<Byte>(min(fsize,1MiB))` 已夹紧）。线程/atExit 回调增长属资源泄漏量级（每秒级不可能累积到 OOM），已归入 §12 的「无停止机制」 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；写路径「锁+时钟+stat」与 `toArray` 分配已列入「待验证假设」#1/#2/#5 与优化方案 |
| §6.2 大粒度锁 | 2 | ① `RotatableFile`：`fileLock` 内做 `DateTime.now()`+`file.info`+close/rename+压缩入队（阻塞），临界区含 I/O；② `LoggerParams.cj:40-67`：`BaseLoggerParams.register` 的静态 `Mutex` 包住「建目录 / 开文件 / 建 socket」与 `removeIf` 回调，所有 appender 创建串行；仅启动/刷新路径，非请求主路径，故定「一般」 |
| §6.3 并发串行 | 0 | 压缩是单消费线程 + 容量 1，但属后台任务、不在业务主路径，无并发度数据；其阻塞后果已并入 §6.2 第①条。四个 socket appender 各自独立写线程，无 `spawn+get` |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at:0)` 队列、无循环内字符串拼接；`computeBytes`/URL 解析/`genTime` 均 O(len)。`RotatableFile.write` 每次 `file.info` 属系统调用频率问题（待验证假设 #1），不是复杂度问题 |
| §7 降堆内存方案 | 1 | 仅给出压缩缓冲方案（1MiB→64KiB）；`LogWriterImpl` 分配方案归入 CPU/GC 条 |
| §8 降 CPU 方案 | 2 | 轮转判定降频（去锁+去 stat+去时钟）、`writeString` 去分配；均无基线 |
| §9 local mode 可行性 | 1 | 唯一候选是 `doCompress` 的 `Array<Byte>` 缓冲（函数内创建、不外逃，`:271`），但无峰值内存前后数据，且该函数不在请求主路径，按清单只能写「待验证假设」，本轮结论：当前不成立（缺数据）。`LogWriterImpl` 的临时 `Array<Byte>` 会经 `OutputStream` 传出，逃逸，不适用 |
| §11 现有代码的 BUG（存量） | 16 | 覆盖边界（URL 切片、`computeBytes` 空串、`createDirIfNeed` 无目录、SECOND 文件名）、错误处理（压缩删源、rename 失败不重开）、资源（定时器/线程不释放、socket 未 connect、fd 语义）、并发（写入与轮转竞态、`actualOutput` 可见性）、契约（数据报被拆包、可变 Map 键）。其余 5 条按 §1/§2/§3 归类，同为存量（本部分合计 21 条，全部标注「存量」） |
| §12 并发安全与锁粒度 | 3 | 已列出共享路径与缺失同步：`file` 引用（写线程 vs 定时器）、`actualOutput`（消费线程 vs atExit/refresh 线程）、`RotatableFileParams.h`（多次调用并发首算，虽影响极小）；线程封闭结论：`queue` 每个 `RotatableFile` 单消费线程，`fileLock` 保护轮转判定，但**不覆盖**实际写入（严重项） |
| §14 功能完备性与 README 覆盖 | 3 | `url` 配置项（README `:73` 承诺）因键名少一段而不可达；tcp/unix appender 未 `connect()` → 两个 appender 实际不可用；unixDatagram 的 bind 与目标同址 → 该 appender 实际不可用。另：README `:74/:75` 把 `unix`/`unixDatagram` 的专有字段写成 `host`/`port`，而实现读 `path`/`writeTimeout`/`bufSize`（README 属第 1 部分，此条只作交叉线索，不计入本部分统计） |
| 文件覆盖（§13 等） | 15/15 | 本部分 15 个文件全部为 `.cj`，无 `.md`；README/README_en 与 `src/base/**` 属第 1 部分，未在本部分重复审查 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 11 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 21 条（本部分全部为存量），是否纳入修复待用户决定；「待验证假设」5 条不计入统计，不进 `todo.md` / `tasks.md`。

## 总评

`f_log` 的这部分代码（appender 实现 + 轮转文件输出）是「能用但边界很脆」的典型：主路径（正常写入、按时轮转、压缩成功）逻辑是通的，异步队列与压缩放到后台线程的方向也对；但**异常路径与并发边界都没兜住**，而日志模块恰恰是靠异常路径体现价值的。

阻塞项（建议先修）：① `RotatableFile.write` 的锁不覆盖写入，定时轮转可能关掉正在写的句柄；② 压缩失败仍删源文件，已落盘日志会被永久删除；③ `url` 形式构造在缺 `compressFormat=` 时越界崩溃（配置一写就启动失败）；④ unixDatagram 把本地 bind 地址设成发送目标，该 appender 实际投不出去日志；⑤ tcp/unix 两个 appender 从不 `connect()`，socket 始终未连接，日志一条也发不出去。这五条都属于「静态可判定、必现或高概率」，修复面都在 1~2 个函数内。其中 ④⑤ 说明除 console/file 之外的四种 appender 只有 udp 可能真正可用——建议合并报告里把「appender 可用性」单列一节，用最小联调用例（各 kind 各写一条、在接收端断言收到）补回回归。

可排期：UDP 端口恒真判断（未配 port 直接启动失败）、`url` 配置键少一段、压缩入队阻塞持锁、注册锁内做 I/O、rename 失败不重开、SECOND 文件名用错格式字母、`RotatableFile` 没有停止机制（热更新泄漏线程）、数据报被拆成多包、`actualOutput` 无原子发布、`RotatableFileParams` 可变键、4 个 socket appender 的整段复制（修复时必须同步 4 份，已是维护风险）。

性能方面没有 profile/bench 数据，本轮不下结论：写路径「锁 + `DateTime.now()` + `file.info`」与 `LogWriterImpl` 每片段 `toArray` 是可疑热点，已写成待验证假设与优化方案，需按 `cjpm bench -O2` 对照与锁等待采样补齐数据后再定级。

第 1 部分（`base/**`、README）与本部分拼接时，注意 `AsyncLogger` 的片段级写入与本文「数据报拆包」同源，两处应合并为一条，避免重复计数。

# f_rpc 模块审查报告

> **模块第 2/2 部分**：只覆盖 `files/f_rpc.part2.txt` 列出的 6 个文件（`src/server/` 全部 `.cj`）。`README.md` / `README_en.md`、`src/base/**`、`src/client/**`、`src/macros/**`、`src/health/**` 由第 1 部分产出，本报告只在需要给「承诺源 / 落点」时引用它们，不对其下结论。

- **审查日期**：2026-11-28
- **模块路径**：`f_rpc/src/server`（本部分 6 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空 ⇒ 全部记「存量」）
- **审查重点**：重试收敛、服务发现信任边界、配置解析健壮性、日志入参暴露、启动期依赖；附带死代码、重复逻辑、并发安全
- **报告版本**：v1（第 2/2 部分，供主 Agent 与 `f_rpc.part1.md` 合并为 `<module>_v2.md`）

## 发现

### [严重][存量] 非法 `baseAddresses` 项会让整条注册协程静默终止，其后所有种子都不再尝试

- **位置**：`f_rpc/src/server/RPCServer.cj:54`（`Client<RPCMessage>.builder(address: address, …)`）、`f_rpc/src/server/RPCServer.cj:48-76`（`spawn{}` 体）
- **来源**：存量（`git blame` → `b929673847` 2026-09-26）
- **判据**：review-checklist §11「错误处理缺失 / 失败路径静默」、§12.1「异步语义：异常逃出任务」
- **证据**：静态确定 —— `builder(...)` 写在 `spawn{}` 内、但在两个 `while(true){ try{…} }` **之外**；`f_net/src/client/client.cj:366-371` 的 `ClientBuilder(address: String)` 构造函数做的是 `IPSocketAddress.tryParse(address).getOrThrow()`（`IPSocketAddress` 来自 `std.net`，只接受 `<ip>:<port>` 字面量），地址漏端口、写主机名、带首尾空格都会抛异常；`:56-63` / `:64-73` 的 `catch` 只包住 `build()` 与 `transfer()`，接不住它。
- **描述**：异常直接逃出 `spawn` 的 lambda ⇒ 注册协程终止。`Array<Client<RPCMessage>>(addresses.size){…}` 是顺序构造的（`RPCServer.cj:51-75`），所以该地址**之后**的种子一律不会被尝试，`clients.value` 也不会被赋值；节点自身继续对外服务，但服务发现里永远没有它，除了一行 `[FOUNTAIN_RPC.register.newClient]` 之外没有任何「注册链路已死」的信号。进程是否随线程未捕获异常一起退出，取决于运行时策略（`待确认`），但「后续种子不注册」是静态确定的。
- **建议**：`start()` 里先用 `IPSocketAddress.tryParse` 逐条校验 `ServerConfig.baseAddresses`，非法项打 ERROR 并跳过；把 `Client.builder(...)` 挪进 `try` 内；`spawn{}` 最外层再包一层 `catch`，把「注册协程已终止」写到 ERROR 而不是让它静默消失。

### [严重][存量] 注册重试无退避、无上限，且逐种子串行 ⇒ 被拒时 CPU 空转 + ERROR 日志洪水 + 队头阻塞

- **位置**：`f_rpc/src/server/RPCServer.cj:56-63`（建连重试）、`RPCServer.cj:64-73`（注册重试）、`RPCServer.cj:48-76`（逐地址串行）
- **来源**：存量（`git blame` → `b929673847` / `5fde88248c`）
- **判据**：review-checklist §11「无界重试 / 错误处理」、§6.3「并发串行热点」、§12.1「有界性」
- **证据**：静态确定 —— 两个 `while(true)` 的 `catch` 分支只打一条日志就继续下一轮，没有 `sleep`、没有退避、没有最大次数、没有可取消标志；`build()` 最终走到 `TcpSocket(address).connect()`（`f_net/src/client/client.cj:428-433`），对端端口未监听时 Connect 以 RST 立即失败（不是长阻塞），因此循环以「网络往返」级频率空转，每轮写一条 `rpclog.error`。`Array(addresses.size){…}` 顺序构造 ⇒ 前一个地址不成功就不会处理后面的。
- **描述**：滚动发布里「节点先起、种子后起」是最常见的时序，此时该节点会占满一个核心并每秒刷出数千行 ERROR（可写满磁盘），同时**后面本来可达的种子永远轮不到**，节点始终进不了服务发现。`README.md:40` 承诺「注册失败会按固定周期重试」，实现里没有任何周期（文档侧归第 1 部分，见「覆盖自检 §13」）。
- **建议**：改为有界指数退避（如 100ms → 30s 封顶）+ 每个种子独立 `spawn`（或独立状态机），互不阻塞；用 `client.transfer(msg, timeout)` 等 ACK 再判定「注册成功」（现在 `transfer(message)` 只保证写进本地队列就 `break`，日志里的 `host registered` 并不代表种子收到了），并把失败次数暴露成指标。

### [严重][存量] 「先取 size 再取迭代器」+ `getOrThrow()` 的复合读取在并发注册/注销下会抛 `NoneValueException`

- **位置**：`f_rpc/src/server/RPCServer.cj:155-159`（`SubscribeExecutor.exec`）、`f_rpc/src/server/ServiceHub.cj:107-108`（`ServiceHub.metas`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §12.1「检查-然后-写入 / 复合操作非原子」、§11
- **证据**：静态确定 —— `let hosts = serviceHosts.iterator()` 与随后的 `Array<String>(serviceHosts.size){…}` 是**两次独立读取**，`ConcurrentHashMap` 文档只承诺单次操作线程安全，未承诺 `size` 与 `iterator` 一致（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:1395`）；期间发生 `add`/`remove` 时快照条数会少于 `size`，`hosts.next().getOrThrow()` 于是抛 `NoneValueException`（`core_package_enums.md:392-406`）。多一条则被静默丢弃。
- **描述**：注册/注销 churn（滚动发布、节点重启、`DEREGISTER`）期间，`SUBSCRIBE` 会失败；`execute` 的 `catch` 把它转成 ERROR 响应，客户端这一轮服务发现拿不到列表（下一轮可恢复，但 churn 期间会反复失败）。`metas` 走完全相同的写法，`SUBSCRIBE(data:false)` 同样中招。
- **建议**：一次遍历到底——`let out = ArrayList<T>(); while(let Some(x) <- itr.next()){ out.add(x) }`，或直接把 `Iterator` 交给调用方消费（`toData` 侧支持迭代器就不必物化）；不要用 `size` 预分配。

### [一般][存量] 服务注册表只增不减：无 TTL / 无存活回收，且 `REGISTER` 不鉴权、不校验权重与端口

- **位置**：`f_rpc/src/server/RPCServer.cj:22`（`serviceHosts`）、`RPCServer.cj:128-140`（`RegisterExecutor`）、`RPCServer.cj:141-149`（`DeregisterExecutor`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §11「资源不对称」、§12.1（信任边界）、§5（有界性）
- **证据**：静态确定 —— 全文件唯一的删除点是 `DeregisterExecutor.exec` 里的 `serviceHosts.remove(...)`（`:146`），`kill -9`、掉电、网络分区都不会发出 `DEREGISTER`，条目于是永久残留；`RegisterExecutor` 对 `weight`（`Float64.parse`，`:136`）与 `port`（`UInt16.parse`，`:135`）只做语法解析，不做值域/真实性校验，也不校验对端是否真的在该端口监听；`REGISTER` 本身没有鉴权，任何能连上 `rpcServer_port` 的对端都能写表。
- **描述**：种子节点里的死节点条目永不淘汰，客户端每轮订阅都会拿到并去连，靠「失败换节点重试」兜底 ⇒ 选到死节点的那次调用要多付一次超时；错误/恶意的对端可以把权重写成 `1e308` 或负数，把流量吸到自己身上或打乱加权区间（客户端按累计权重建 `TreeMap`，见 `f_net/src/client/MultiClient.cj:97`）。规模上键是 `<ip>:<port>`，单 IP 最多 65536 条，**不构成 OOM**，但确实是「只增不减」。
- **建议**：条目带注册时间戳 + `rpcServer_hostTTL`（`REGISTER` 兼作续约），过期即淘汰；`REGISTER` 时校验 `weight` 为有限正数、`port != 0`；如端口可能暴露在不可信网络，加 token 或至少默认开启限流（当前默认 `UnlimitedRateLimiter`）。

### [一般][存量] 服务端配置项全部静默回落默认值，配错 key 或取值没有任何告警

- **位置**：`f_rpc/src/server/ServerConfig.cj:46-119`（`executors` / `port` / `bufferQueueSize` / `connectionCheckDuration` / `baseAddresses` / `unavailableChecked` / `exactlyVersion` / `weight` 共 8 个 getter，另加 `rateLimiter()`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §11「错误处理缺失」、§14「配置项可用性」
- **证据**：静态确定 —— 每个 getter 都是 `Config.getValue<T>(key) ?? 默认值`；`f_config/src/Config.cj:207-208` 内部走 `T.tryParse`，**取值非法一律返回 None**，`getStringArray`（`Config.cj:210-217`）在 key 缺失时返回 `[]`；整条链路没有一行日志。
- **描述**：`rpcServer_baseAddresses` 拼成 `rpcServer_baseAddress`（或做成 `rpcServer_baseAddresss` 之类的笔误）⇒ 列表为空 ⇒ 节点根本不注册，只有 DEBUG 级 `base addresses: []` 一行；`rpcServer_port=abc` ⇒ 静默监听 1203（可能与别的实例抢端口）；`rpcServer_executors=0` ⇒ 把 0 传给 `Executors`。这些都属于「配错了但没有任何人知道」。注：`rateLimiterName` 的静默退化已在 `README.md:519` 明确声明为设计，不算缺陷。
- **建议**：抽一个 `ServerConfig.require<T>(key, default)`：先用 `getString(key)` 区分「键不存在」与「键存在但解析失败」，后者打 WARN 并写明实际生效值；启动期一次性把生效配置打一条 INFO。

### [一般][存量] CONSUME 成功路径把完整请求参数与返回值写进 INFO 日志

- **位置**：`f_rpc/src/server/RPCServer.cj:171-172`（`infoLog(id, Command.CONSUME(b)){LogMessage.new(message, result, end - start)}`），落点 `f_rpc/src/base/imports.cj:39-41` + `:60-62`（`JsonValue.from(message.toData()).toString()`）
- **来源**：存量（`git blame` → `b929673847`；落点在同模块 base 包，属第 1 部分）
- **判据**：review-checklist §10「安全性：敏感数据进日志」
- **证据**：静态确定 —— `LogMessage.new(message, result, …)` 把整个 `RPCMessage`（含 `params`）与返回 `Data` 一起交给 `toData()` 再 `JsonValue` 化，级别是 `rpclog.info`（`f_rpc/src/base/imports.cj:60-62`）。
- **描述**：登录、改密、支付、下发 token 这类 RPC 的明文参数会随每次调用落盘（格式见 `README.md:542`）。INFO 通常是生产默认级别，`README.md:547` 也确认「正常调用以 INFO 级别记录（含请求消息、结果）」，即文档化行为，但文档化不等于安全。
- **建议**：默认只记 `meta` + 参数个数 + 结果字节数；完整载荷给一个显式开关（`rpcServer_logPayload=false` 默认关），并对参数类型提供脱敏钩子。

### [一般][存量] ERROR 响应把服务端完整异常堆栈（类名 / 文件名 / 行号）回传调用方

- **位置**：`f_rpc/src/server/LogMessage.cj:52-60`（`ErrorMessage.new(param, e)` 拼栈）、`f_rpc/src/server/RPCServer.cj:119`、`:122`、`:180`（`Message.error(id, data: msg.error)`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §10「安全性：信息泄露」
- **证据**：静态确定 —— 报文内容由 `'An exception has occured:\n${e}\n'` 加上每帧 `declaringClass.methodName(fileName: lineNumber)` 拼成，`error()` 原样 `Message.error(id, data: msg.error)` 发回请求方。
- **描述**：任何能连上端口的对端都能构造非法 `REGISTER` / `CONSUME`，拿到服务端类名、源文件名、行号和内部异常文案，等于免费提供测绘信息；对内部服务之间的调用也一样会把这些写进客户端日志。
- **建议**：对外只回稳定的错误码 + 一句话摘要（如 `UNSUPPORTED_COMMAND` / `EXCEEDING` 已有先例）；完整堆栈只进 `errorLog(id, SKELETON, cmd, msg.error)`（`:27` 已经在记），需要回传时给显式 `debug` 开关。顺手修文案 `occured` → `occurred`。

### [一般][存量] `ServiceHub.exactlyVersion` 在包初始化期一次性求值并永久冻结

- **位置**：`f_rpc/src/server/ServiceHub.cj:27`（`private static let exactlyVersion = ServerConfig.exactlyVersion`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §11「契约与实现不符」、§14「接线缺失：配置项读了但不生效」、启动期依赖
- **证据**：静态确定 —— `ServiceHub.register` 是 `@RPCSkeleton` 展开出来的**顶层 `private let _ = {=> … ServiceHub.register(…) }()`**（`f_rpc/src/health/server/HealthRPCImpl.cj.macrocall:41-56`、`f_rpc/src/macros/RPCSkeleton.cj:61-65`），因此对 `ServiceHub` 的首次访问发生在**包 init**，这个 `static let` 就在那一刻定格；对比同文件其它配置项都是 getter 现读。`f_protocol` 对同类问题有明确告诫「不能在包初始化期读配置」（`f_protocol/src/default/Message.cj:31-42`），此处虽不会抛（`getValue` 返回 Option），但会把「当时读到的值」固化。
- **描述**：`rpcServer_exactlyVersion` 走环境变量 / 命令行能生效（`f_config/src/Config.cj:55-85` 的 `static init` 在包 init 时已经把 env 与 argv 灌进 `ARGS`）；但任何「进程启动之后再 `Config.set`」的路径（`Config.set` 会触发 `REFRESHER`，`Config.cj:107-127`）都不会生效，且 `ServerConfig` 没有注册任何 `refresher`，与其它 getter 的行为不一致。是否真有部署路径这么做（`待确认`），但「值被冻结」本身是静态确定的。
- **建议**：要么在 README 里把「这些配置只能在 env/argv 给定」写成硬约束，要么在 `ServiceHub` 上注册 `Config.refresher('rpcServer', …)` 重建 hub；不要在 static 初始化里读配置。

### [一般][存量] 关停回调跨线程读 `clients.value` 无任何同步，注册未完成时读到的是零值数组

- **位置**：`f_rpc/src/server/RPCServer.cj:46-47`（`unsafeZeroValue` + `Box`）、`:51`（`clients.value = Array(...)`，要等全部种子处理完才赋值）、`:77-91`（`ExitCallbacks.atExit` 回调读 `clients.value`）
- **来源**：存量（`git blame` → `b929673847`）
- **判据**：review-checklist §12.1「可见性 / 发布逸出」
- **证据**：静态确定 —— `Box<T>` 只是 `public var value: T` 的普通字段（`stdlib/doc/libs/std/core/core_package_api/core_package_classes.md:89-108`），不提供内存序；写方是 `spawn` 出的注册线程，读方是 `ExitCallbacks.onExit` 所在线程（`f_base/src/signal.cj:60-68`），两者之间没有 join、原子量或锁。`clients.value = Array(...)` 的赋值点在顺序构造**全部**地址之后（`:51-75`）。
- **描述**：注册还在进行时收到 SIGTERM/SIGINT，回调读到的是初始的 `unsafeZeroValue<Array<Client>>()`，本轮已注册成功的种子收不到 `DEREGISTER` ⇒ 注册表残留死节点（与上一条叠加）。零值 `Array<Client>` 的 `size`/迭代行为在 std 文档中查不到（`unsafeZeroValue` 未收录），`for(client in clients.value …)` 是否会读到空指针长度 `待确认`。
- **建议**：改用 `AtomicReference<Array<Client>>`（或 `synchronized` 保护）发布；注册每成功一个就 append 一次并发布新快照，而不是全部完成才赋值；读侧先取本地快照，再判 `size`。

### [轻微][存量] `execute` 里 `let cmd = message.command` 赋值后从未使用

- **位置**：`f_rpc/src/server/RPCServer.cj:104`（后面 `:113` 用的是 `message.command`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §1「读了不用」
- **证据**：静态确定 —— 该局部变量在 `:104-126` 内无第二次引用。
- **描述**：纯冗余，读代码时容易误以为分发用的是这个副本。
- **建议**：删除该行。

### [轻微][存量] `ConsumeExecutor` 的 `buffer` 字段从未被读取

- **位置**：`f_rpc/src/server/RPCServer.cj:168`（`ConsumeExecutor(private let buffer: SocketBuffer, …)`），`exec()` 体 `:169-182` 只用到 `b` / `id` / `message`
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §1「无调用者 / 读了不用」
- **证据**：静态确定 —— `buffer` 在结构体内零引用，构造时仍需调用方传值（`:117`）。
- **描述**：死字段，还让调用方误以为响应要经该 buffer 发出（实际是返回值交给 `Server.start` 统一 `transfer`）。
- **建议**：删掉该参数与字段。

### [轻微][存量] `RPC_SERVER_PORT` 与 `RPC_SERVER_PREFIX_PORT` 同值重复，且前者全仓零引用

- **位置**：`f_rpc/src/server/ServerConfig.cj:22-23`（`RPC_SERVER_PREFIX + "_port"` 与 `RPC_SERVER_PREFIX + '_port'`）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §1（`ServerConfig` 是 `internal class`，其 `public static const` 对外不可达 ⇒ 全项目无使用即死代码）、§2「字面量复制」
- **证据**：静态确定 —— 全仓 `grep RPC_SERVER_PORT` 只命中定义行本身（`RPC_SERVER_PREFIX` 21 处、`RPC_SERVER_PREFIX_PORT` 2 处，其余常量各 2 处）；两者取值都是 `"rpcServer_port"`。
- **描述**：两套同名异写法的常量并存，后续维护者容易只改一处；其中一个已是死代码。
- **建议**：删掉 `RPC_SERVER_PORT`，保留 `RPC_SERVER_PREFIX_PORT`（`port` getter `:52-56` 用它）。

### [轻微][存量] 对端地址按第一个 `:` 截断，IPv6 字面量会得到错误甚至相同的注册键

- **位置**：`f_rpc/src/server/RPCServer.cj:132`（`addr[0 .. addr.indexOf(":").getOrThrow()]`）、`:146`（`DeregisterExecutor` 同一写法）
- **来源**：存量（`git blame` → `8d455daa57`）
- **判据**：review-checklist §11「边界 / 输入假设」
- **证据**：静态确定 —— 任何 IPv6 文本形式都含多个 `:`：`::1:1203` 首个 `:` 在 0 位 ⇒ 地址段为空串，键变成 `:1203`；`[::1]:1203` ⇒ 地址段为 `[`。不同 IPv6 节点会算出同一个键。
- **描述**：一旦对端经 IPv6 连入，注册键要么全部撞在一起（后注册的覆盖先注册的），要么把不可达的 `[` / 空串作为主机名发给客户端。当前 `TcpServerSocket(bindAt:)` 通常只监听 IPv4（`f_net/src/server/server.cj:327-338`），所以是否真的可达需确认（`待确认`），但解析假设本身是错的。
- **建议**：用 `buffer.remoteAddress` 的地址对象（`IPSocketAddress`）分别取 `address` / `port`，不要对 `toString()` 做字符串切分。

> **范围外提示（不计入本部分统计）**：`f_rpc/src/client/RPCClient.cj:249-261` 另有一个同名 `LogMessage`，字段是 `message` / `result: ?DataAny`，与服务端版本（`param` / `result: DataAny`）不同 ⇒ 两类日志行的 JSON 键不一致，统一解析日志的下游需要兼容两套。客户端文件属第 1 部分。

## 优化可行性方案

> 不是缺陷，是「还能更好」；三条都没有改前基线，按铁律只能标 `无基线（待验证）`。

### [CPU] 订阅响应每次全量重建并整体序列化

- **现状**：每次 `SUBSCRIBE` 都 `new Array<String>(N)` + 逐条 `'${host},${weight}'` 拼串（`RPCServer.cj:154-159`），或 `new Array<ServiceMeta>(N)` + 整体 `toData()`（`ServiceHub.cj:105-110`），随后 `Server` 侧还要再编码一帧。客户端默认 1s 刷新一轮（README:46 描述），代价约 `O(N × 客户端数)` 每秒。
- **方案**：把 `metas` 的 `Data` 表示缓存起来，在 `hub.addIfAbsent` 真正插入时置脏重建；节点表同理按「本节点版本号」做增量或在无变更时直接复用上一次的 `Data`。
- **预期**：需实测；只在大 N（数百服务）或多客户端同时刷新时可观测。按 Amdahl 估算前先拿到 SUBSCRIBE 端到端占比。
- **代价**：多一份缓存（`Data` 常驻，量级 N×元数据），需要失效逻辑；语义不变。
- **验证**：`cjprof record` 跑 200 个服务 / 50 个客户端 / 60s，看 `SubscribeExecutor.exec` + 序列化自耗时占比；对照改前改后端到端 P50/P99 与 CPU。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ServiceHub.register` 的类型图遍历无 visited 集合，且内层每次重放全部已注册接口

- **现状**：`q`（`ArrayQueue`）只按「是否标准库接口」过滤入队（`ServiceHub.cj:44-98`），没有 visited 集合 ⇒ 菱形继承下同一接口会被多次入队；`types.add(ti.qualifiedName)` 之后立刻 `for(tin in types)` 把**所有**已命中接口重新注册 4 个变体（`addIfAbsent` × 4 × k），整体 `O(k²)` 次哈希写入，k 为匹配接口数。
- **方案**：加 `HashSet<String> visited` 去重入队；内层只注册本轮新增的 `ti`（回溯注册的目的是「祖先接口也要注册」，可用「命中时把整条父链补登记」实现，而不是重放全量）。
- **预期**：启动期注册耗时随 k 线性化；需先测出注册在启动总耗时中的占比。
- **代价**：改动注册语义的推导逻辑，必须用「多接口 / 菱形继承 / 带 BeanMeta 与不带」四组用例做等价性验证（`hub` 最终条目集合必须完全一致）。
- **验证**：`cjpm bench -O2` 或启动期分段计时，服务数 10 / 100 / 1000 三档对照 `hub.size` 与耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ErrorMessage.new(param, e)` 用循环字符串 `+` 拼栈

- **现状**：`var errmsg = …; for (stack in e.getStackTrace()){ errmsg = errmsg + … }`（`LogMessage.cj:55-58`），栈深 n 时产生 n 个中间串、总拷贝 `O(n²)`；只在错误路径触发。
- **方案**：`ArrayList<String>` 收集后一次 `join`，或用 `StringBuilder`；顺带限制最大帧数（如 32 帧 + `…`）。
- **预期**：单次错误响应少 n-1 个临时串；n 通常 < 50，收益微小，属于「顺手改」。
- **代价**：无（输出文本保持一致，注意行尾 `\n`）。
- **验证**：构造 200 帧异常，比对 `getAllocatedHeapSize()` 增量与文本一致性。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 订阅路径（`metas` + `toData` + 编码）在大服务数下可能成为热点 | `RPCServer.cj:154-164`、`ServiceHub.cj:105-110` | 自耗时占比、端到端占比 | `cjprof record`，200 服务 / 50 客户端 / 1s 刷新 / 60s；与无订阅基线对照 |
| 2 | 注册重试空转的实际 CPU 与日志吞吐量（决定退避参数） | `RPCServer.cj:56-73` | 每秒迭代次数、ERROR 行数、CPU 占用 | 种子端口关闭时启动节点，采样 `top` 与 60s 内日志行数，3 次取中位数 |
| 3 | `ServiceHub.register` 的 `O(k²)` 重放在真实启动耗时中的占比 | `ServiceHub.cj:44-99` | 启动期分段耗时 | 在 `register` 前后打点，服务数 10 / 100 / 1000 三档 |
| 4 | `hub[meta]` 未命中抛异常（异常控制流）在客户端版本不匹配时的高频代价 | `ServiceHub.cj:101-104` | 未命中次数、单次异常开销 | 加计数埋点，跑「客户端版本与服务端不匹配」场景 10 分钟 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rpc/src/server/LogMessage.cj` | .cj | ✅ | `LogMessage` / `ErrorMessage` 载体；见发现 #7、优化 #3 |
| 2 | `f_rpc/src/server/RPCServer.cj` | .cj | ✅ | 注册/发现/执行主链路；发现 #1/#2/#3/#4/#6/#9/#10/#11/#13 集中在此 |
| 3 | `f_rpc/src/server/RPCServerInitializer.cj` | .cj | ✅ | `Initializer` 实现，`initialize()` 空实现已由 `README.md:401` 声明为设计（no-op），不计缺陷 |
| 4 | `f_rpc/src/server/ServerConfig.cj` | .cj | ✅ | 20 个常量 + 8 个 getter + `rateLimiter()`；见发现 #5、#12 |
| 5 | `f_rpc/src/server/ServiceHub.cj` | .cj | ✅ | 注册表、类型图遍历、版本提取；见发现 #3、#8、优化 #2 |
| 6 | `f_rpc/src/server/imports.cj` | .cj | ✅ | `SKELETON` + 三个日志包装；均被本包引用，无死代码 |

合计：`.cj` 6 个 / `.md` 0 个 / 共 6 个，全部读完（本部分清单不含 `.md`，README 仅作承诺源引用）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 5（#1 协程终止、#2 重试无界、#3 竞态、#4 注册表无回收、#13 IPv6 截断）；安全性 2（#6 入参落盘、#7 堆栈外泄）；契约/生命周期 2（#8 配置冻结、#9 关闭时发布竞态）。语言特性方面核对了 `Box`/`Option`/`Array` 零值语义与 `protected` 跨包可见性，无其它偏差 |
| §1 死代码 | 3 | `let cmd`（#10）、`ConsumeExecutor.buffer`（#11）、`RPC_SERVER_PORT`（#12，`internal class` 的 `public` 成员按「全项目无使用」判）；另核对了 `private`：`serviceHosts`/`error`/`execute`/`EMPTY_DATA_ANY`/`hub`/`version`/`exactlyVersion`/`extractVersion` 均有引用；`protected`：`LogMessage.new`、`ErrorMessage.new` 被本模块 `RPCServer.cj:163/172/119/122/180` 使用，非死代码；三个日志包装与 `SKELETON` 均被引用；`case Command.ACK => None<Message>` 曾按「载荷为 DataNone 会在 `:105` 解码失败」怀疑恒假，核对 `DEFAULT_DATA_FLAG = SILENCE`（`f_data/src/base/global_objects.cj:51`，含 `IGNORE_FIELD_NOT_CONVERTABLE`）后确认 `populate` 会回落成默认 `RPCMessage` 而不抛，分支可达，已排除 |
| §2 重复逻辑 | 1 | 同值常量 `RPC_SERVER_PORT`/`RPC_SERVER_PREFIX_PORT`（#12）；本部分 6 个文件的全部函数体（含 getter、4 个 Executor 的 `exec`）已压成「输入-输出-副作用」逐对比较，`SubscribeExecutor` 与 `metas` 的「size+iterator」是同源写法但已按同一根因合并为 #3，不重复计数；跨包同名 `LogMessage` 记为范围外提示 |
| §3 空实现 | 0 | `RPCServerInitializer.initialize()` 为空但 `README.md:401` 明写「空实现」，属有意的 no-op；本部分唯一的占位注释 `//todo nothing`（`RPCServerInitializer.cj:36`）就在这个已声明为空实现的方法内，不单列；全文没有 `catch {}`、没有 `throw UnsupportedException`、没有开关打开后走空分支 |
| §4 栈溢出 | 0 | 本部分无递归：`ServiceHub.register` 的类型图遍历用 `ArrayQueue` 迭代（`ServiceHub.cj:45-47`），`isNotStdInterface` 排除自身（`:82`）且类继承链有 `sti != cti` 保护（`:78`），无自引用环；`ErrorMessage.new` 的循环深度由 `getStackTrace()` 长度决定，不递归 |
| §5 OOM | 0 | 无「按不可信长度预分配」；`serviceHosts` 键是 `<ip>:<port>`，单 IP 上限 65536 条（约百字节/条），`hub` 只在启动期随 bean 数增长、无请求驱动增长 ⇒ 不构成 OOM（「只增不减」按 §11 报为 #4） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，任何热点结论都不成立；4 条线索已进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex`；`ConcurrentHashMap` 为分段并发容器，临界区不落在本部分代码里 |
| §6.3 并发串行 | 1 | #2 的逐种子串行注册（`Array(addresses.size){…}` 内串行 build+transfer） |
| §6.4 低效算法 | 1 | `ServiceHub.register` 的 `O(k²)` 全量重放 + 无 visited 去重（进「优化可行性方案 [CPU]」，无基线不算缺陷） |
| §7 降堆内存方案 | 1 | `ErrorMessage.new` 的 `O(n²)` 字符串拼接（优化 #3，无基线） |
| §8 降 CPU 方案 | 2 | 订阅全量重建/序列化（优化 #1）、注册重放（优化 #2），均无基线 |
| §9 local mode 可行性 | 0 | 本部分热点路径的临时对象都是短小的 `Array`/`String`，且模块已整体开启 `--enable-local-mode`（`f_rpc/cjpm.toml:10`）；没有「函数内大临时对象 + 峰值内存」证据，收益无法用峰值内存证明，故不给改造建议 |
| §11 现有代码的 BUG（存量） | 13 | 本部分 13 条（严重 3 / 一般 6 / 轻微 4）全部为存量（快照模式无基线，见各条 `git blame`）；已核对边界/空值/错误处理/资源/并发/契约六类：`fromData` 的 `params[0]` 越界、`indexOf`/`parse` 失败均有 `catch` 兜底为 ERROR 响应（行为可接受，未单列），`extractVersion` 缺 `version=` 抛 `RPCVersionException` 已在 `README.md:581` 声明为契约（未单列） |
| §12 并发安全与锁粒度 | 3 | #3（size/iterator 复合读取）、#4（注册表并发写 + 信任边界）、#9（`Box` 跨线程发布无同步）；其余共享状态 `hub`、`serviceHosts` 均用 `ConcurrentHashMap`，`addIfAbsent` 为单次原子操作，未发现检查-然后-写入 |
| §13 文档一致性（跨部分） | 1 | `README.md:40`「注册失败会按固定周期重试」与 `RPCServer.cj:56-73`（无任何周期）不符；README 属第 1 部分，此处只作为 #2 的承诺源，不另计缺陷 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 5 个对外符号（`ServiceHub`、`RPCServerInitializer`、`RPCVersionException`、`LogMessage`、`ErrorMessage`）与 9 个服务端配置项在 README 均有对应段落（`README.md:376-392` / `395-405` / `407-417` / `420-436` / `463-475`），字段与默认值逐项一致；`initialize()` 空实现、`cjpm.toml` 版本依赖均已声明 |
| 文件覆盖（§13 等） | 6/6 | 本部分清单 6 个文件全部读完，无 `.md`；未读 0 个 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 6 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分代码量不大（568 行），结构清晰：命令分发、四个 Executor、注册表、配置各司其职，`ConcurrentHashMap` + `addIfAbsent` 的选型也合理，没有锁、没有递归、没有按报文长度预分配，因此**不存在栈溢出与 OOM 面**。

真正的风险集中在「启动期注册链路」与「服务发现的并发读取」两处，且都是存量问题：

- **阻塞项（建议本版本修）**：#1 非法种子地址直接杀死注册协程、#2 无退避重试导致 CPU 空转 / 日志洪水 / 队头阻塞、#3 订阅时的 `size`+`iterator` 竞态。这三条的共同后果是「节点静默地进不了服务发现，或订阅随机失败」，属于用户可见的功能失效，修复成本都不高（提前校验 + 有界退避 + 一次遍历到底）。
- **排期项**：#4 注册表无 TTL/无鉴权（与 #1/#2 的残留叠加）、#5 配置静默回落（运维诊断成本）、#8 `exactlyVersion` 冻结、#9 关停时 `clients.value` 的发布竞态。
- **安全项**：#6 全量入参进 INFO 日志、#7 堆栈原样回传，都属于「已文档化的设计选择」，但对外暴露面确实偏大，建议与脱敏/错误码改造一起排。
- **轻微项**：两处死代码（`let cmd`、`ConsumeExecutor.buffer`）、一个同值重复常量、IPv6 地址截断，改动都在一行到三行之间。

本部分共 13 条（严重 3 / 一般 6 / 轻微 4），全部为存量，是否纳入修复待用户决定：其中严重与一般 9 条建议排期（3 条严重为阻塞项），轻微 4 条与 3 条优化方案不进修复清单——优化方案全部无基线，只能作为下一轮补数据的输入。

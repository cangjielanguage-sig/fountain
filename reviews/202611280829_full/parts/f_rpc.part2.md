# f_rpc 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rpc`（模块共 24 个源文件；本部分 9 个，其余 15 个见第 1 部分）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce643a`，`git blame` 逐条核对）；快照模式无 diff，全部缺陷记「存量」
- **审查重点**：RPC 服务端 / ServiceHub / 配置 / 宏（类型登记）/ 日志与初始化生命周期、并发安全、资源释放、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，后续与第 1 部分合并为 `f_rpc_review_20261128.md`）

本部分覆盖文件（9 个 `.cj`，无 `.md`）：`src/macros/TypeRegistration.cj`、`src/macros/imports.cj`、`src/rpc.cj`、`src/server/{LogMessage,RPCServer,RPCServerInitializer,ServerConfig,ServiceHub,imports}.cj`。
说明：`workdir` 下不存在 `files/f_rpc.txt`，文件清单以任务给定列表为准，已与 `f_rpc/src` 实际文件逐一对齐；`README.md` / `README_en.md` 未列入本模块 24 个源文件的清单（第 1 部分同样未列入），本报告只在需要定位代码证据时引用它们的行号。

## 发现

### [严重][存量] #1 `Client.builder(...)` 建在重试 `try` 之外：一个非法种子地址即静默终止注册线程，且无任何日志

- **位置**：`src/server/RPCServer.cj:54`（`spawn` 内第 3 行；`try` 从 `57` 开始）
- **来源**：存量（`git blame` d459fdb662 2026-08-30 建 `spawn`，c53eeea70a / 170a9e0df8 后续改动；第 54 行随同一批提交进入）
- **判据**：review-checklist §11（错误处理缺失：失败被静默降级为永久失效）/ §12.1（后台线程无终态）
- **证据**：静态确定 —— `let clientBuilder = Client<RPCMessage>.builder(address: address, ...)` 位于 `while(true){ try{ ... } }` 之前；`Client.builder(address: String, ...)` 的构造函数体是 `IPSocketAddress.tryParse(address).getOrThrow()`（`f_net/src/client/client.cj:366-374`），地址串非法（缺端口 `192.168.1.10`、写成 `1.0,host:1203` 等）时**在 builder 构造处**就抛异常，不进入任何 `catch`。
- **描述**：异常逃出 `spawn` 闭包（仓颉中线程体未捕获异常直接终止该线程），后果：① 该节点此后**永不向任何种子注册**，也不会有任何日志（连 `rpclog.error` 都进不到）；② 若异常发生在遍历到第 k 个地址时，前 k-1 个已注册成功、后续地址全部不注册，集群里出现"半注册"节点；③ 退出回调遍历的是从未赋值的 `clients.value`（见 #3），已建连接也不会关闭。`README.md:37-40` 承诺的"逐个发送 REGISTER / 注册失败按周期重试"在这个入口上完全不成立。
- **建议**：把 `builder(...)` 调用移进内层 `try`，或先 `IPSocketAddress.tryParse` 校验并在启动期 `exit(1)` 报出"第几个 base address 非法、原始值是什么"；注册循环整体包一层 `try/catch`，异常时记录地址并 `continue` 到下一个地址，而不是让线程消失。

### [严重][存量] #2 注册/发送两条 `while(true)` 无退避、无次数上限，每次失败重建连接且不关闭，紧循环烧 CPU、刷日志、漏句柄

- **位置**：`src/server/RPCServer.cj:56-63`（建连重试）、`64-73`（发送 REGISTER 重试）
- **来源**：存量（`git blame` d459fdb662 2026-08-30 建双循环、0ad0680320 2026-08-30 换 `build()`、de0745532f 2026-08-15 补 catch）
- **判据**：review-checklist §5（无界增长：日志洪水）/ §6.3（形式串行）/ §11（错误处理缺失）、fountain-baseline §6（日志规范）
- **证据**：静态确定 —— 两个 `catch(e: Exception)` 分支都只 `rpclog.error(...)`，既无 `sleep`/退避，也无尝试计数，`break` 只在成功时发生；`ClientBuilder.build()` 内部 `Array<TcpSocket>(socketCount){_ => newSocket()}` → `TcpSocket(address); connect()`（`f_net/src/client/client.cj:427-435`），连接失败时已创建的 `TcpSocket` 没有 `close`（是否由 GC 兜底为 待确认）。
- **描述**：种子节点进程挂掉（主机在线）时 `connect` 立即 `ECONNREFUSED`，循环以微秒级周期重复"建 socket → 失败 → 打一条带完整异常栈的 ERROR"。后果：① 单核打满；② 日志文件每秒上万行（`rpclog.error` 的异常重载会输出完整栈，`src/base/imports.cj:48-50`）；③ 每次失败都可能留下一个未关闭的 socket，长时间不可用会耗尽 FD；④ 第二个循环失败时**不会退回重建连接**，一个坏连接会一直重发失败；⑤ 注册是串行的，第一个不可达地址会让后面所有地址永远排不上队。`README.md:40` 写的是"按固定周期重试，不阻塞启动"，与实现不符。
- **建议**：改成"有界重试 + 指数退避（如 100ms 起、上限 `min(refreshInterval, 30s)`）+ 失败计数"；连续失败 N 次后放弃本轮并记录一条带地址与累计次数的 ERROR，`continue` 处理下一个地址；失败路径显式 `client.close()`（或只用 `transfer(message, timeout)` 的同步重载并把连接生命周期收进 `try/finally`）。

### [严重][存量] #3 `clients` 用裸 `Box` 跨线程发布：退出回调与注册线程无同步，早期退出会迭代 `unsafeZeroValue<Array<Client>>()`

- **位置**：`src/server/RPCServer.cj:46-47`（`unsafeZeroValue<Array<Client<RPCMessage>>>()` + `Box`）、`51`（spawn 内写）、`79`（退出回调读）
- **来源**：存量（`git blame` b929673847 2026-09-26 引入 `Box` + `unsafeZeroValue`，91978212cc 2026-09-01 建退出回调）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 发布逸出 / 可见性）、§11（未初始化引用）
- **证据**：静态确定 —— `std.core.Box<T>` 的定义就是 `public var value: T`（`std/core/core_package_api/core_package_classes.md` 的 `class Box<T>` 一节，无锁、无原子、无 `synchronized`），写方是 `spawn` 内的注册线程，读方是 `ExitCallbacks.atExit` 回调线程，两者之间没有任何 happens-before 边。
- **描述**：三种后果。① **可见性**：进程退出时回调可能读到旧值（零值数组），于是 deregister 与 `client.close()` 全部跳过；② **零值数组**：`unsafeZeroValue<Array<T>>()` 给的是零位模式的引用，`for(client in clients.value ...)` 会先取 `.size`，对空引用取长度属未定义行为（本仓已有 `unsafeZeroValue<Message>()` 触发段错误的历史，见第 1 部分 #15 与 `RPCClient.cj:183-184` 的注释），启动未完成即退出时可能崩溃在退出路径上；③ **泄漏**：`clients.value = Array(...)` 是"全部连接建完才赋值"，只要有一个地址一直连不上，已建好的 `Client`（socket + 写队列线程 + 探活定时器）就永远不可达，既不会进退出回调、也没人 `close`。
- **建议**：不要用 `Box` 做跨线程发布。改成 `AtomicReference`/`Mutex` 保护的 `Array<Client>`，或更简单——先 `let clients = addresses.map{...}` 在**同一个线程**里建完，再用 `synchronized(lock){ published = clients }` 发布并让退出回调在同一把锁下取快照；零值数组换成 `Array<Client<RPCMessage>>()`（空数组），并去掉 `unsafeZeroValue`。

### [一般][存量] #4 退出注销是 fire-and-forget：`transfer()` 后立刻 `close()`，DEREGISTER 帧大概率还在队列里被丢弃

- **位置**：`src/server/RPCServer.cj:81-86`（`81` 发送、`85` 关闭）
- **来源**：存量（`git blame` 8e7c43bdc6 2026-08-30 发消息、d459fdb662 2026-08-30 加 `finally close`）
- **判据**：review-checklist §11（资源/消息生命周期不对称）、§12.1（异步语义）
- **证据**：静态确定 —— `Client.transfer(message): MessageFuture<Message>` 只把写帧塞进 `SocketBuffer` 的 `ArrayBlockingQueue`（`f_net/src/client/client.cj:322-345` → `f_net/src/SocketBuffer.cj:75-87`），写线程按 50ms 轮询取帧；`close()` 只 `stop.stopped.store(1)` 并等待**正在写的那一帧**（`SocketBuffer.cj:96-130`），写线程的主循环条件是 `while (stop.stopped.load() == 0)`，stop 置 1 后**不再排空队列**。`finally` 里的 `client.close()` 紧接着执行，排队中的 deregister 帧没有任何机会发出。
- **描述**：节点正常退出时注销请求多半丢失，种子节点的 `serviceHosts` 永久保留该 `host:port`；结合 #5（无 TTL）与客户端发现逻辑（第 1 部分 #1），死节点会被持续下发给所有客户端，每次调用都要先连一个已关闭的端口失败再换节点。文件里的 `catch` 也无法感知这件事——`transfer` 根本不会因为"帧没发出"而抛错。
- **建议**：改用同步重载 `client.transfer(deregisterMessage, timeout)`（`client.cj:325-334`，内部 `future.tryGet`）并给 `100ms~1s` 超时，再 `close()`；或在 `SocketBuffer.close()` 里加"最多再排出 N 帧"的有界收尾（当前语义是直接丢弃队列，属于 f_net 侧设计，跨模块修改需与 `f_net` 对齐）。

### [一般][存量] #5 `serviceHosts` 无鉴权、无上限、无 TTL：任意对端可写入，崩溃节点永久残留

- **位置**：`src/server/RPCServer.cj:22`（全局表）、`128-139`（REGISTER 写入）、`141-148`（唯一删除路径）、`150-165`（全量下发）
- **来源**：存量（`git blame` `Server.cj` 5fde88248c 2026-08-09 建表；`RPCServer.cj` d459fdb662 2026-08-30 拆分）
- **判据**：review-checklist §5（无界容器/缓存无淘汰）、§10 安全性（外部输入未校验）、§14（承诺的"服务发现"缺少失效语义）
- **证据**：静态确定 —— 删除只有 `DEREGISTER` 一条路径（`146`），且只能删自己 IP + 报文里 port 的键；表里没有任何时间戳/心跳，没有容量上限；`RegisterExecutor` 对载荷只做 `UInt16.parse` / `Float64.parse`，不做身份校验。
- **描述**：① **污染**：任何能连上该端口的进程都能 `REGISTER` 任意 port（host 取对端 IP），把伪造的大量 `ip:port` 写进表里，随后被 `SUBSCRIBE` 全量下发给所有客户端去连接（发现污染 / 放大攻击面）；② **增长**：单个 IP 最多可写入 65536 个 port 条目，多 IP 情况下无上限，且只有显式注销才减少；③ **残留**：进程崩溃 / 被 kill -9 / 注销丢失（#4）都会留下永久死条目。整体把 #2 的"连接失败"问题扩散到全集群。
- **建议**：给条目加"最近 REGISTER/心跳时间"，`SubscribeExecutor` 只下发 `now - lastSeen < 3 × checkDuration` 的条目并惰性清理；对 `REGISTER` 的 `port`/`weight` 做范围校验（`port != 0`、`weight` 有限且 > 0）；如需防污染，至少要求 REGISTER 携带与 `rpcServer_port` 匹配的共享凭据（或限定 base address 白名单）。

### [一般][存量] #6 `size` 与迭代器组合不原子：并发 REGISTER/DEREGISTER 期间 SUBSCRIBE 会抛 `NoSuchElementException`

- **位置**：`src/server/RPCServer.cj:155-159`（`serviceHosts.size` + `iterator()`）、`src/server/ServiceHub.cj:107-108`（`hub.size` + `iterator()`）
- **来源**：存量（`git blame` 8d455daa57 2026-08-09 同一提交引入两处同型代码）
- **判据**：review-checklist §12.1（检查-然后-写入 / 快照语义未定义）、§11
- **证据**：静态确定 —— `Array<String>(serviceHosts.size){_ => let (host, weight) = hosts.next().getOrThrow(); ... }` 先读一次 `size` 做预分配，再按该长度逐个 `next()`；`ConcurrentHashMap` 保证单个操作原子，但"读 size"与"迭代"是两次独立快照，删除会让迭代器实际产出少于 size 个元素 → `next()` 返回 `None` → `getOrThrow()` 抛错。
- **描述**：`serviceHosts` 在运行期被 REGISTER/DEREGISTER 持续修改，而 SUBSCRIBE 由每个客户端的发现线程每秒发起，窗口真实存在：一旦命中，整条 SUBSCRIBE 失败（`RPCServer.execute` 转成 ERROR 响应），该客户端本轮拿不到节点列表。`ServiceHub.metas` 是同一写法，但 `hub` 实际只在启动期写，风险低，属同型代码应一并修。
- **建议**：改成"先物化再取长度"——`let list = serviceHosts.iterator().map{...}.collectArray()`，或 `let out = ArrayList<String>(); for ((h, w) in serviceHosts) { out.add(...) }`，彻底去掉 `size` 预分配；`metas` 同样处理，或直接缓存快照（见 O1）。

### [一般][存量] #7 `hub.addIfAbsent` 静默"先注册先赢"，违反基线"同名注册必须启动失败"

- **位置**：`src/server/ServiceHub.cj:61`、`65`、`70`、`74`
- **来源**：存量（`git blame` 2b7d8ce2f1 2026-08-26、a4db0ebab1 2026-08-22、015897de81 2026-08-15 分批引入）
- **判据**：fountain-baseline §4（同名注册：启动直接失败，不做隐式优先级；"先注册先赢"即违规）、review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 四处都是 `hub.addIfAbsent(meta, fn)`，返回值（`Bool`）被丢弃；前面 `rpclog.debug{...${hub.contains(m1)}}` 说明作者知道会冲突，但只在 DEBUG 打一行，不失败、不 WARN。
- **描述**：两个 `@Bean` 实现类若取同一个 `@BeanMeta[name]` 且实现同一接口方法（条件化装配、灰度双实现、旧实现忘记删），后注册者的 `fn` 被静默丢弃；调用方按 Bean 名发起的 RPC 会打到**另一个实现**上，没有任何启动期或运行期信号。这类错误一旦上线极难定位（接口响应"看着对但业务数据不对"）。
- **建议**：把 `addIfAbsent` 的返回值当契约——冲突时 `throw RPCException("duplicate service registration: ${meta}")`（启动期失败），或以 `WARN` + 明确的注册来源（类名）覆盖日志；若确实需要优先级，改为显式优先级字段并在文档中写明，而不是依赖注册顺序。

### [一般][存量] #8 服务端每次 CONSUME 都以 INFO 全量记录请求与响应（含请求参数原文）

- **位置**：`src/server/RPCServer.cj:171-173`（`innerInfo` → `infoLog`，调用点在 `176`/`178`）；同型调用另有 `SubscribeExecutor` 的 `163`；载体 `src/server/LogMessage.cj:25-29`
- **来源**：存量（`git blame` `Server.cj` 5fde88248c 2026-08-09 / 8d455daa57 2026-08-09）
- **判据**：review-checklist §10 安全性（敏感数据进日志）、fountain-baseline §6（日志不得出现凭据/令牌/完整报文）、perf §9.1（日志放大）
- **证据**：静态确定 —— `infoLog<LogMessage>(id, cmd){LogMessage.new(message, result, end - start)}`；`LogMessage.new` 把 `RPCMessage`（含 `params`）与 `DataAny` 结果都包成 `DataAny`，`logmsg` 再 `JsonValue.from(...).toString()`（`src/base/imports.cj:39-41`）。这些序列化发生在 `rpclog.info{...}` 的惰性块内，但 INFO 默认开启，等于**每个 RPC 调用都做一次请求+响应全量序列化并落盘**。
- **描述**：与第 1 部分 O4 是同一根因的**服务端侧**：除写放大与 GC 压力外，所有入参（口令、令牌、身份证、完整业务报文）都会以明文进入 INFO 日志，而 RPC 入参通常正是最敏感的数据。服务端日志常被采集到集中式平台，权限比数据库更宽。
- **建议**：INFO 只保留"接口.方法 + trace + 耗时 + 结果字节数"，请求/响应体降到 DEBUG 惰性块并加体积上限与字段脱敏；这是可配置项（如 `rpcServer_logPayload`），默认关闭。

### [一般][存量] #9 错误响应原样回传完整异常堆栈，且 CONSUME 无任何鉴权/授权

- **位置**：`src/server/LogMessage.cj:52-60`（把 `getStackTrace()` 逐帧拼进 `error` 文本）、`src/server/RPCServer.cj:180`、`122`、`119`（`Message.error(id, data: msg.error)`）
- **来源**：存量（`git blame` 早期提交；`LogMessage.cj` 注释记录了 2026-10 的同类事故修复）
- **判据**：review-checklist §10 安全性（敏感信息外泄 / 越权）、fountain-baseline §2/§6
- **证据**：静态确定（泄露路径） —— `ErrorMessage.new(message, e)` 生成的 `errmsg` 含异常消息 + 每个栈帧的 `declaringClass / methodName / fileName / lineNumber`，经 `error()`（`RPCServer.cj:24-29`）直接作为 `Message.error` 的 data 返回给调用方；客户端第 1 部分 #7 又把它 `toString()` 进 `RPCException`，最终落到调用方日志。
- **描述**：任何能连上 `rpcServer_port` 的进程都可以：① 通过构造请求触发异常，拿到服务端内部类名、源码文件名、行号、依赖版本等指纹（为进一步攻击做信息收集）；② 直接 `CONSUME` 任意已注册方法（`ServiceHub.call` 只按 `meta` 查表，不看调用方身份），即整台服务的全部 RPC 接口对内网完全开放。是否为"仅内网可信"部署 待确认。前者是框架默认行为，即使内网也建议收敛。
- **建议**：错误响应只回"错误码 + 简短消息 + traceId"，完整堆栈只写服务端日志（按 traceId 关联）；如确需回栈，做成显式开关（默认关）并在文档中标注风险。鉴权建议在 `execute` 入口加可插拔的 `Authenticator`（默认 allow-all 但留出接点），至少让使用方能接线。

### [一般][存量] #10 每个方法发布 2~4 个 `ServiceMeta` 变体，客户端为每个变体单独建连接池

- **位置**：`src/server/ServiceHub.cj:58-75`（4 个变体全量 `addIfAbsent`）、`105-110`（`metas` 原样下发）；消费侧 `src/client/RPCClient.cj:110-140`、`167-172`、`src/client/ClientConfig.cj:183`
- **来源**：存量（`git blame` 2b7d8ce2f1 / 9d2cdba67e / a4db0ebab1 / 015897de81，2026-08-15~30）
- **判据**：review-checklist §5（资源按倍数放大）、§7（可降低堆内存）、§11（设计契约副作用）
- **证据**：静态确定（倍数关系）—— 注册侧对每个命中的接口写 `(version,name)`、`(*,name)`，Bean 名非空时再加 `(version,'')`、`(*,'')`；`metas` 直接返回 `hub` 的全部键。消费侧 `metas` 是 `HashMap<ServiceMeta, TreeSet<String>>`，`ServiceMeta` 的 `equal/hash` 只排除 `weight`（第 1 部分 #10 已核对），因此 4 个变体是 4 个不同的 key；`for((meta, hostSet) in metas)` 对每个 key 都 `ClientConfig.createClient(hosts)` 建一个 `MultiClient`（每个 host 至少一条 `Client`，含 socket + 写队列线程 + 探活定时器）。
- **描述**：一个只有 1 个接口方法、1 个 Bean 名的服务，在客户端会产生 4 个连接池；实际命中的只有与 stub 版本/Bean 名匹配的那 1 个，其余 2~3 个池**永不使用**却持续占着 TCP 连接、定时器与堆内存。规模估算：`4 × 方法数 × 节点数 × socketCount` 条连接（100 个方法、10 个节点即 4000 条），足以在小机器上撞到 FD 上限。此处只给倍数关系与代码路径，实际 FD/线程占用 需实测（见待验证假设 3）。
- **建议**：两侧各收敛一处即可——① 注册侧只登记"客户端可能用到的变体"（例如只在 `exactlyVersion=true` 时登记精确版本，或把 `name` 归一化为一个键 + 匹配时再回退）；② 更彻底：客户端把响应按 `(typeName, methodName, argTypeNames)` 归并成一个逻辑服务，版本/Bean 名作为可选维度在**调用时**匹配，而不是每变体一个连接池。

### [一般][存量] #11 接口过滤规则与 README 相反：文档说跳过 `fountain::` 前缀，实现只跳过 `std.` 与比较接口

- **位置**：`src/server/ServiceHub.cj:81-95`（`isNotStdInterface`，`89-94` 为白名单）；文档 `f_rpc/README.md:69`
- **来源**：存量（`git blame` 代码侧历史提交；README 表述未随 2026-10 的 `fountain::` 前缀修复更新）
- **判据**：review-checklist §13（文档与实现相反）、§14（接入/行为说明缺失）
- **证据**：静态确定 —— README:69 写"会自动跳过 `std.`、`fountain::` 前缀接口及常用系统接口"，而 `isNotStdInterface` 只判 `startsWith('std.')` 与 10 个比较接口名；代码注释（`ServiceHub.cj:86-88`）明确说明**故意不再排除 `fountain::`**，因为曾导致 `fountain::rpcdef.EchoRPC` 这类应用接口注册不进去。
- **描述**：使用者按 README 理解，会以为"放在 `fountain::` 命名空间下的接口不会被发布"，从而把 RPC 接口放进 `fountain::` 前缀并期待被忽略（或在排查"为什么多了几个服务"时被误导）；反之，正是这条过期表述掩盖了历史上的真实故障。
- **建议**：同步 README（中英两版，`README_en.md` 同段）为"只跳过 `std.` 前缀与标准比较类接口，其他接口（含 `fountain::` 前缀）只要声明了同名函数就注册"，并补一句"前缀过滤只看 `std.`，是否注册由反射判定"。

### [一般][存量] #12 服务版本从**工作目录**的 `cjpm.toml` 读取，类初始化即读文件，缺失/不可读直接抛异常

- **位置**：`src/server/ServiceHub.cj:26`（`private static let version = extractVersion()`）、`111-120`
- **来源**：存量（`git blame` 1c1fa9c63f 2026-08-09）
- **判据**：review-checklist §11（错误处理：可选元数据变成硬依赖）、§14（部署约束未显式落到配置）
- **证据**：静态确定 —— `'cjpm.toml' |> env.getWorkingDirectory().join |> File.readFrom |> String.fromUtf8`，逐行找 `version=`，找不到 `throw RPCVersionException(...)`；该 `let` 是第一次访问 `ServiceHub`（即任何 `ServiceHub.register`，发生在骨架类的包/类初始化）时求值。
- **描述**：部署形态改变即失效——systemd / 容器把工作目录设为 `/` 或应用二进制目录、只分发编译产物而不带 `cjpm.toml`、工作目录里另有一份无 `version=` 的 `cjpm.toml`，都会让**第一个 RPC 骨架类初始化**抛 `RPCVersionException`；异常发生在类初始化阶段，堆栈指向宏展开位置，很难联想到"工作目录"这一原因。即使成功，版本也只能是"运行目录那份 toml 的版本"，与实际部署的服务版本可能不一致（灰度时尤其危险）。README:391 有写这条约束，但没有任何回退或启动期校验。
- **建议**：把版本改为编译期常量（`@RPCSkeleton` 展开时从 `cjpm.toml` 读入并生成字面量，或由构建脚本注入 `const`），运行期不再读文件；至少要在启动期显式校验并在缺失时 `exit(1)` 报"当前工作目录 X 缺少 version，或配置 `rpcServer_version`"，并支持配置项覆盖。

### [轻微][存量] #13 死代码 4 处

- **位置与证据**：
  1. `src/server/ServerConfig.cj:23` `public static const RPC_SERVER_PORT = RPC_SERVER_PREFIX + '_port'`：与 `22` 行的 `RPC_SERVER_PREFIX_PORT` 同值（`'rpcServer_port'`），全仓搜索 `RPC_SERVER_PORT` 只有定义处（`port` 属性用的是 `RPC_SERVER_PREFIX_PORT`）；`ServerConfig` 是 `internal class`，其 `public` 常量对外不可达 → 按硬原则二判死代码。
  2. `src/server/imports.cj:23-25` `func errorLog(id: MessageID, command: Command, message: ErrorMessage)`：全模块唯一的 `errorLog` 调用点 `RPCServer.cj:27` 命中 4 参 `String` 重载，本 3 参包装无调用者（顶层无修饰符 = 本包可见）。
  3. `src/server/RPCServer.cj:168` `ConsumeExecutor(private let buffer: SocketBuffer, ...)`：`exec()`（`169-182`）只用 `id`/`b`/`message`，`buffer` 字段从未读取（CONSUME 的响应由 `Server` 回写，不需要 buffer）。
  4. `src/server/RPCServer.cj:104` `let cmd = message.command`：此后 `match(message.command)`（`113`）重新取了一次，`cmd` 赋值后从未使用。
- **判据**：review-checklist §1（无调用者 / 读了不用），判前已核对所属顶层声明可见性（`internal class ServerConfig`、顶层 `func`、`private struct ConsumeExecutor`）
- **来源**：存量（`git blame` 8d455daa57 2026-08-09 / `Server.cj` 5fde88248c 2026-08-09）
- **建议**：删除 1、2、4；3 同时删掉构造参数与调用点（`117`）的实参，避免让读者以为 CONSUME 需要回写 buffer。

### [轻微][存量] #14 重复逻辑：远端地址解析 ×2、`fromData` 三段 match ×3、端口键常量 ×2、内层幂等重注册

- **位置**：
  - `src/server/RPCServer.cj:131-132` 与 `145-146`：`let addr = buffer.remoteAddress.toString(); addr[0 .. addr.indexOf(":").getOrThrow()]` 逐字对齐，只有后续动作不同。
  - `src/server/RPCServer.cj:106-112` 与 `src/client/RPCClient.cj:45-50`、`79-84`：同一"`tryFromData` → `case x: T` / `case x: ?T` / 兜底"三段式，只差元素类型与默认值（第 1 部分 #14 已报客户端两处，此处是第三份）。
  - `src/server/ServerConfig.cj:22-23`：两个常量生成同一个键 `rpcServer_port`（与 #13-1 同源）。
  - `src/server/ServiceHub.cj:56-57`：`for(tin in types)` 在每次发现新接口时把**全部已发现接口**再注册一遍，靠 `addIfAbsent` 幂等去重，属 O(k²) 次重复构造 4 个 `ServiceMeta` 的无效工作（k 为接口数，启动期一次，代价可忽略）。
- **判据**：review-checklist §2（只改类型名 / 字面量复制）
- **证据**：静态确定 —— 两处地址解析的表达式完全相同；三段 match 的分支顺序与兜底一致；两个常量的表达式只差引号风格。
- **描述**：地址解析是**行为**重复而非纯代码重复：将来给 IPv6 或代理场景加特判时很容易只改一处（`DEREGISTER` 键与 `REGISTER` 键就会不一致，直接导致注销失效）；三段 match 是宏/协议两侧的公共适配层，新增一种"可空返回"形态时要改三处。
- **建议**：抽 `private func hostOf(buffer: SocketBuffer): String`（放 `RPCServer.cj` 内，顺带集中处理 #15）；`fromData` 抽成 `f_rpc.base` 的 `func dataAs<T>(data: Data, default: T): T`（下层能力放 base，符合分层）；删掉 `RPC_SERVER_PORT`；`ServiceHub.register` 的内层循环改为"只注册本次新发现的接口"（`types.add` 返回 `Bool` 时再注册，或在循环外统一注册一遍）。

### [轻微][存量] #15 注册/注销按首个 `:` 切分远端地址：IPv6 与"无端口"两种输入都会得到错误键

- **位置**：`src/server/RPCServer.cj:131-132`（REGISTER）、`145-146`（DEREGISTER）
- **来源**：存量（`git blame` `Server.cj` 5fde88248c 2026-08-09）
- **判据**：review-checklist §11（边界/空值未处理）、§10 正确性（地址语义）
- **证据**：静态确定（对 IPv6 形态）/ 待确认（f_net 的 `SocketAddress.toString()` 输出格式）—— `remoteAddress` 是 `std.net.SocketAddress`（`f_net/src/SocketBuffer.cj:151-155`），代码假设 `toString()` 形如 `1.2.3.4:1203`；若对端是 IPv6（如 `[::1]:1203` 或 `::1:1203`），`indexOf(":")` 取到的是 IPv6 地址内部的冒号，得到的 host 是 `[` 或 `:` 之类；若地址串里没有 `:`，`getOrThrow()` 直接抛异常（被 `execute` 兜成 ERROR 响应，注册失败但调用方只看到通用错误）。
- **描述**：在纯 IPv4 部署下不触发；一旦宿主机启用 IPv6 或客户端从 IPv6 地址连入，`serviceHosts` 的键会变成非法字符串，`SUBSCRIBE` 下发的 `host,weight` 也让客户端无法连接（第 1 部分已记录客户端把解析失败当异常抛出）。属"部署形态一换就静默失效"。
- **建议**：用 `SocketAddress` 的结构化访问取 host/port（`IPSocketAddress.addr`/`port` 之类，按 std.net 文档现场核对），不要对 `toString()` 做字符串切分；取不到时记录 WARN 并拒绝注册（让节点在日志里可见），而不是产生半合法键。

### [轻微][存量] #16 限流器配置键偏离本文件既定的 `rpcServer_rateLimiter*` 命名，易与其它模块同名键冲突

- **位置**：`src/server/ServerConfig.cj:29-38`（7 个键）、使用点 `83-114`
- **来源**：存量（`git blame` 早期提交）
- **判据**：review-checklist §2（命名不一致导致的行为漂移）、§10 设计合理性（全局配置命名空间）
- **证据**：静态确定 —— 同一组常量里，`RPC_SERVER_RATE_LIMITER_NAME = 'rpcServer_rateLimiterName'` 带 `rateLimiter` 中缀，而 `MAX_TOKENS/TIMEOUT/MAX_WAITINGS/LEAKING_PER_DURATION/LEAKING_DURATION/WINDOW/LIMIT/TOKENS/POPULATION_PERIOD` 生成的是 `rpcServer_maxTokens`、`rpcServer_timeout`、`rpcServer_window`、`rpcServer_limit` 这类**无归属**的键。
- **描述**：`Config` 是全局键空间，`rpcServer_timeout` 与"RPC 服务端整体超时"在字面上无法区分；将来若要给服务端加 `rpcServer_timeout`（例如调用超时，第 1 部分 #6 已提出该需求），会与限流器的 `timeout` **直接撞键**，而撞键不会报错，只会静默读到另一个语义的值。README:512-517 已把当前键写成事实，改名属破坏性变更，需与文档同步。
- **建议**：统一为 `rpcServer_rateLimiter_<param>`（保留旧键作为别名读取一个版本，并在文档中标注 deprecated）；同时把"服务端整体超时"这类新键与限流参数在命名上分开。

### [轻微][存量] #17 `RPCServerInitializer.initialize()` 是空实现 + `//todo nothing` 占位注释

- **位置**：`src/server/RPCServerInitializer.cj:35-37`
- **来源**：存量（`git blame` 早期提交）
- **判据**：review-checklist §3（空实现 / `TODO` 占位）
- **证据**：静态确定 —— 函数体只有一行 `//todo nothing`；调用方 `InitializerCollection.doInit()`（`f_app/src/Initializer.cj:79-96`）在 `89` 行对每个 initializer 调 `initialize()`，本模块真正的工作全在 `start()`（`App.cj:57-62` 为每个 initializer 单独 `spawn` 调 `start()`），`README.md:401` 也写明"空实现"。
- **描述**：契约没被破坏（`Initializer.start()` 有默认空实现，`initialize()` 无必须的副作用），所以不按"承诺但未实现"定严重；但 `//todo nothing` 这类占位注释会让人以为还有未完成项，且一旦未来需要在 `initialize()` 做校验（例如 #12 的 `cjpm.toml` 存在性、`rpcServer_port` 合法性），这里是最合适的落点。
- **建议**：删掉 `//todo nothing`，改成一句说明性注释（"服务在 start() 中阻塞启动，initialize 无前置动作"）；如采纳 #12 的建议，把"版本/端口预校验"放进 `initialize()`，让配置错误在启动序列里尽早失败。

### [轻微][存量] #18 `ServiceHub.register` 为 DEBUG 日志无条件构造字符串与 4 份 `ServiceMeta`

- **位置**：`src/server/ServiceHub.cj:42`（`argTypeNameStr`）、`58-74`（`meta`/`m1..m4` + `hub.contains`）
- **来源**：存量（`git blame` 2b7d8ce2f1 2026-08-26 / 9d2cdba67e 2026-08-30）
- **判据**：review-checklist §8（无谓分配，非热点）/ §10 可读性（日志与业务混在一起）
- **证据**：静态确定 —— `argTypeNameStr = argTypeNames.toString().replace('[', '').replace(']', '')` 在 `rpclog.debug{...}` 之前求值，DEBUG 关闭时仍执行两次全串扫描与两次新串分配；`let m1 = meta` 等四个别名只为拼进 DEBUG 日志，每次注册额外做 4 次 `hub.contains`（哈希 5 个字符串）。
- **描述**：只在启动期执行一次（规模 = 方法数 × 接口数），收益很小；但这段代码把"注册"与"打日志"耦合在一起，`meta` 被反复重新赋值（`meta = ServiceMeta('*', ...)`），可读性成本高于性能成本——这正是注册冲突（#7）容易被忽略的原因（冲突信息只在 DEBUG 里）。
- **建议**：注册主体抽成 `registerVariant(version: String, name: String, tin: String)` 循环遍历 `[(version,name),('*',name),...]`，日志与冲突检测放到该函数内（冲突按 #7 抛错/告警）；`argTypeNameStr` 移入 `rpclog.debug{...}` 块内延迟求值。

## 优化可行性方案

> 不是缺陷，是"还能更好"。下列两条都**没有改前/改后对照数据**，`证据状态` 为 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [CPU] O1 `ServiceHub.metas` 每次 SUBSCRIBE 全量重建 `Array<ServiceMeta>`

- **现状**：`metas` 每次调用都 `hub.iterator()` + `Array<ServiceMeta>(hub.size)`（`ServiceHub.cj:105-110`）；`hub.size` 在典型工程里是"方法数 × 接口数 × 2~4"，SUBSCRIBE 频率是"每个客户端 × 每个节点 × 1/`refreshIntervalSeconds`"，随后整份数组还要 `toData()` 序列化（`RPCServer.cj:161`）。
- **方案**：`hub` 只在包初始化期写，属"写一次、读多次"：用一个 `volatile`（或 `Mutex` 保护的）`Array<ServiceMeta>` 快照缓存，`addIfAbsent` 成功后置脏，`metas` 首次读时重建并缓存；`Array<ServiceMeta>` 本身不可变，可跨线程共享。
- **预期**：每次 SUBSCRIBE 省掉一次 O(hub.size) 的迭代 + 一次对象数组分配；SUBSCRIBE 序列化的字节数不变（若不做 #10 的变体合并）。收益与 SUBSCRIBE 频率成正比，需实测。
- **代价**：多一个缓存失效点（注册发生在启动期，实际风险极低）；`Array` 需要复制一份以避免外部修改（当前调用方只 `toData()`，可共享）。
- **验证**：`cjprof record` 跑"50 节点 × 每节点 200 方法"的 10 分钟稳态，对比 `metas`/`toData` 的自耗时占比与 `getAllocatedHeapSize()` 增速；`cjpm bench -O2` 度量单次 SUBSCRIBE P50/P95。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] O2 服务端 `hub` 与 SUBSCRIBE 载荷按变体去重（与 #10 同源）

- **现状**：`hub` 为每个（接口, 方法）常驻 2~4 个 `ServiceMeta`，每个都带一份 `Array<String> argTypeNames`；这份数据同时通过 `metas` 序列化给每个客户端，并被客户端放大成 2~4 倍连接池。
- **方案**：`hub` 只存一份"逻辑注册项"（`typeName + methodName + argTypeNames` → `fn`），`version`、`name` 作为注册项内部的**匹配维度集合**；`metas` 下发时按客户端需要的维度投影（或在请求里带上期望版本，服务端一次性匹配），从而让客户端每个逻辑服务只建一个连接池。
- **预期**：服务端常驻对象数与 SUBSCRIBE 载荷降到 1/2~1/4；客户端连接池、定时器、socket 同比例下降（这是 #10 的根治方向）。
- **代价**：`ServiceMeta` 的匹配逻辑从"整键相等"改为"维度匹配"，需要改 `ServiceHub.call` 与客户端 `services` 的键设计；属于协议层语义变更，需要与 `f_jsonrpc` 等复用方确认无外部依赖。
- **验证**：同样服务规模下对比 `hub.size`、单次 SUBSCRIBE 字节数、客户端 `services` 条目数、进程 FD 数（`/proc/<pid>/fd`）与 RSS；同时用并发压测验证变体匹配未退化（版本/Bean 名/通配三种调用各 1 万次，断言命中同一实现）。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | SUBSCRIBE 的全量 `metas` 序列化（含 2~4 份变体）在客户端发现线程上占可观自耗时 | `src/server/ServiceHub.cj:105-110`、`src/server/RPCServer.cj:161` | `metas` + `toData` 的自耗时占比与单次字节数 | `cjprof record` 跑 50 节点 × 200 方法、10 分钟稳态；对 `RPCServer.execute` 的 SUBSCRIBE 分支做分段计时 |
| 2 | 每次 CONSUME 的 `hub[meta]` 查找（5 个字符串哈希）+ INFO 日志的 `JsonValue` 序列化是服务端主路径热点 | `src/server/ServiceHub.cj:101-103`、`src/server/RPCServer.cj:172` | 两者自耗时占比、单次分配字节 | `cjprof record` 跑 10k 次单参调用（INFO 开/关两组），对比 P95 与分配量 |
| 3 | 变体放大后客户端实际连接数 = 2~4 × 方法数 × 节点数，可能触到 FD 上限 | `src/client/RPCClient.cj:110-140`、`src/server/ServiceHub.cj:58-75` | 实际 `services` 条目数、每池 socket 数、进程 FD 峰值 | 100 方法 × 10 节点环境，启动后统计 `services.size` 与 `/proc/<pid>/fd`，再逐步加到 500 方法观察 FD 增长曲线 |
| 4 | 退出时 `Box` 的可见性/零值数组在真实退出时序下会造成注销丢失或崩溃 | `src/server/RPCServer.cj:46-51`、`79` | 触发概率与失败形态 | 构造"种子不可达 + 立即 SIGTERM"与"正常退出"两组各 100 次，统计 deregister 到达率与退出码；必要时用 TSan 类工具看数据竞争 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/macros/TypeRegistration.cj` | .cj | ✅ | 类型收集/去重与 `registerRPCType<X>()` 生成均与 `RPCSkeleton` 调用契约一致；核对 `f_data/base/DataTypeRegistry.cj` 后确认"集合元素类型不被登记"不构成缺陷（`@DataAssist` 类在包初始化时自登记），未报 |
| 2 | `src/macros/imports.cj` | .cj | ✅ | `identifierRegex` 被 `RPCSkeleton.cj:39` 使用；`public import f_bean.macros.*` 为宏包对外契约，无问题 |
| 3 | `src/rpc.cj` | .cj | ✅ | 只有 `package fountain::f_rpc`（16 行），无任何声明；`README.md:25` 已记为「根包（空）」，属有意保留，无问题 |
| 4 | `src/server/LogMessage.cj` | .cj | ✅ | 见 #8、#9；`EMPTY_DATA_ANY` 有注释解释为何不用 `unsafeZeroValue`，核对该注释与 `RPCTypeRegistration` 的记录一致，非空实现 |
| 5 | `src/server/RPCServer.cj` | .cj | ✅ | 见 #1~#6、#8~#10、#13~#15 |
| 6 | `src/server/RPCServerInitializer.cj` | .cj | ✅ | 空 `initialize()` + `//todo nothing`，见 #17；`start()` 由 `App.run` 在独立 `spawn` 中调用（`f_app/src/App.cj:57-62`），阻塞语义成立 |
| 7 | `src/server/ServerConfig.cj` | .cj | ✅ | 见 #13（`RPC_SERVER_PORT` 死常量）、#16（限流键命名）；9 个配置属性逐一核对均有使用点，默认值与 README 一致 |
| 8 | `src/server/ServiceHub.cj` | .cj | ✅ | 见 #5~#7、#10~#12、O1、O2 |
| 9 | `src/server/imports.cj` | .cj | ✅ | `errorLog(id, command, message: ErrorMessage)` 无调用者（#13）；`debugLog`/`infoLog` 包装分别被 `133/144/163` 与 `172` 使用 |

合计：`.cj` 9 个 / `.md` 0 个 / 共 9 个，全部读完（`README.md` / `README_en.md` 不在本部分文件清单内，仅作交叉核对）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #1/#2/#4/#6；设计 #7/#10/#12；语言特性 #3（`Box` 不是同步原语）、#2（`try` 作用域漏掉 builder）；安全性 #5/#8/#9；可读性 #11（文档与实现相反） |
| §1 死代码 | 4 | 逐个符号机械搜索：`private`（`serviceHosts`、`error`、`addRPCType`、`version`/`exactlyVersion`/`hub`、`extractVersion`、四个 Executor 结构）均有引用；`internal`（`ServerConfig` 全部 prop、`ServiceHub.call`/`metas`、`SKELETON`、`identifierRegex`、`collectRPCTypes`/`rpcTypeRegistrations`）均有调用者；`protected`（`LogMessage.new`、`ErrorMessage.new`×2）属 `public class` 成员 → 按硬原则豁免；`public`（`ServiceHub`/`RPCVersionException`/`RPCServerInitializer`/`LogMessage`/`ErrorMessage`/`registerRPCType`）对外可达不判。命中：#13 的 `RPC_SERVER_PORT`（`internal class` 的 public 成员，全仓仅定义处）、`server/imports.cj:23-25` 的 `errorLog` 重载、`ConsumeExecutor.buffer` 字段、`execute` 的 `let cmd`（`104` 赋值后 `match(message.command)` 未用它）；另 `Command.ACK` 分支（`118`）在 ping 匹配失败的 ACK 上可达，不判死分支 |
| §2 重复逻辑 | 1 | 同文件内把 9 个文件的 ~40 个函数体压成"输入→输出→副作用"两两比对；跨文件按相同字面量/错误消息搜索。命中 #14：① 远端地址解析在 `131-132` 与 `145-146` 各写一遍；② `fromData` 的三段 match 与第 1 部分已报的客户端两处同型（三份）；③ `RPC_SERVER_PORT` 与 `RPC_SERVER_PREFIX_PORT` 同值；④ `ServiceHub.register` 内层 `for(tin in types)` 对已注册项重复 `addIfAbsent`（幂等，O(k²) 构造）。`rateLimiter()` 四段"读配置 + `?? 默认` + `Duration.millisecond *`"差异在构造器与默认值，属参数化差异，不判重复 |
| §3 空实现 | 1 | `RPCServerInitializer.initialize()` 空实现 + `//todo nothing`（#17）。判断为轻微而非严重：`Initializer` 的初始化职责在本模块落在 `start()`（`App.cj:57-62` 对每个 initializer 单独 `spawn` 调 `start()`），`initialize()` 无契约要求；`README.md:401` 亦写明"空实现"。`ServiceHub`/`RPCServer` 无 `catch {}` 静默吞异常（`error` 路径有日志） |
| §4 栈溢出 | 0 | 本部分无递归：`ServiceHub.register` 的类型图遍历用显式 `ArrayQueue` BFS（有 `sti != t` 自环过滤，类继承链无环），宏函数只做线性扫描；`ErrorMessage.new` 的字符串拼接是循环非递归 |
| §5 OOM | 1 | #5（`serviceHosts` 无鉴权、无上限、无 TTL）。其余预分配长度均来自本地集合快照：`Array<String>(serviceHosts.size)`、`Array<ServiceMeta>(hub.size)`、`Array<Client>(addresses.size)`，非报文头可控；`ErrorMessage` 堆栈文本受异常深度约束，不构成 OOM |
| §6.1 热点瓶颈 | 0 | scope 明确"未提供 profile / bench 数据"，疑似热点（`metas` 重建、`hub[meta]` 查找、全量 INFO 日志）只进「待验证假设」1-2 与 O1，未当发现 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/读写锁；共享状态全部是 `ConcurrentHashMap` 单操作，唯一的同步缺失是 `Box`（按正确性报 #3） |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`；注册虽然串行遍历地址，但属"启动期一次性"而非请求路径，且其真实问题是无退避紧循环（#2）与线程死亡（#1） |
| §6.4 低效算法 | 0 | 逐函数核对复杂度：`metas`/`SUBSCRIBE` 为 O(hub.size)（规模=方法×接口，见 O1）；`register` 内层 O(k²) 但 k 为接口数（≤10 量级）且只在启动期执行一次；`addr.indexOf(":")` 为 O(地址长度)；无嵌套循环匹配、无 `remove(at: 0)`、无循环内字符串 `+`（`ErrorMessage` 的拼接在异常路径且帧数有限） |
| §7 降堆内存方案 | 1 | O2（变体合一，服务端常驻 + 客户端连接池同步下降），标 `无基线（待验证）`；另核对：`clear()` 不归还物理内存的语义已体现在"降对象数"而非"降 RSS"的预期表述中 |
| §8 降 CPU 方案 | 1 | O1（`metas` 快照缓存），标 `无基线（待验证）`；#8 的日志降级已在「发现」中按安全/写放大报，此处不重复计数 |
| §9 local mode 可行性 | 0 | `f_rpc/cjpm.toml` 已开 `--enable-local-mode`；本部分没有"函数内创建、函数内释放"的大对象——`metas`/`SUBSCRIBE` 的数组直接 `toData()` 进入 `Message`（逃逸），`LogMessage`/`ErrorMessage` 逃逸进日志与响应，`Array<String>`/`ServiceMeta` 都随响应离开函数；峰值内存收益无法用数据证明，不立项 |
| §11 现有代码的 BUG（存量） | 18 | 18 条发现全部为存量（快照模式无基线，逐条 `git blame` 到 2026-08~09 的提交，HEAD `8c0ce643a` 为当日合并提交）；覆盖边界（#1、#6、#15）、空值/零值（#3）、错误处理（#1、#2、#12）、资源（#2、#3、#4、#5）、并发（#3、#6）、契约（#7、#10、#11）、安全（#5、#8、#9） |
| §12 并发安全与锁粒度 | 2 | 计数为 #3（`clients` 裸 `Box` 跨线程发布）与 #6（`size`+迭代非原子）；其余共享路径逐条给出：`serviceHosts`（CHM 单操作安全，但无鉴权 → #5）、`hub`（写入在启动期，冲突静默 → #7）。本部分无锁，故不涉及锁粒度；线程封闭/不可变部分：`ServerConfig` 全为 `const` + 只读 prop，`LogMessage`/`ErrorMessage`/`registerMessage` 每次新建，`RPCMessage.clearCurrentTrace()` 在 `finally` 清理线程局部 |
| §14 功能完备性与 README 覆盖 | 2 | #11（README:69 的接口过滤规则与实现相反，双证：文档行号 + `isNotStdInterface` 代码）；#10（变体放大属"能力接线方式"问题）。另核：`README.md:322-327` 的 `EXCEEDING`/`UNSUPPORTED_COMMAND` 在服务端确有用点（`RPCServer.cj:42`、`119`），限流器实现见 `ServerConfig.cj:83-114`——第 1 部分 #18 的"零引用/未接线"结论应撤回（见下节） |
| 文件覆盖（§13 等） | 9/9 | 本部分 9 个 `.cj` 全部读完；`.md` 未列入本模块 24 个源文件清单（第 1 部分亦未列入），§13 仅用于交叉核对本部分涉及的 README 契约（#11、#12） |

## 与第 1 部分的交叉

- **需撤回的结论**：第 1 部分 #18 称 `EXCEEDING` / `UNSUPPORTED_COMMAND` "全仓零引用、限流未接线"。本部分取证相反：`RPCServer.cj:42` 用 `ErrorMessage(EXCEEDING)` 作 `defaultResp`（限流拒绝的默认响应），`RPCServer.cj:119` 用 `UNSUPPORTED_COMMAND` 作未知命令的 ERROR data，限流器构造在 `ServerConfig.cj:83-114` 并由 `RPCServer.cj:42` 传给 `Server`。合并时请把 #18 改成"两个常量已接线，但 README 未说明限流拒绝时的响应形态/客户端如何区分"这类文档问题，或直接删除。
- **同一根因的服务端侧**：第 1 部分 O4（每次调用 INFO 全量日志）在服务端对应 `RPCServer.cj:171-173`，本部分已单列为 #8（并按"敏感数据进日志"定为一般缺陷），合并时请保留两侧位置、不要按两条缺陷计数。
- **同型代码**：`fromData` 的三段 match（本部分 #14）与第 1 部分 #14 的 `tryFromData` 两处是同一抽取点，合并后建议只留一条。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 9 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

第 2 部分覆盖 RPC 的"服务端一半"：注册/注销、服务表下发、`ServiceHub` 的注册与分发、服务端配置、类型登记宏、初始化生命周期。

- **阻塞项（严重）**：三条都指向**注册线程没有任何失败边界**。#1 是一个非法地址就让注册线程无声消失（连日志都没有）；#2 是一个不可达地址就让注册线程进入无退避紧循环，烧 CPU、刷日志、漏 socket；#3 是用 `Box` 把连接数组裸发布给退出回调，启动未完成就退出时可能迭代零值数组。三者叠加的实际效果是：**"节点注册"这件小事在异常场景下既不可观测也不可恢复**，而客户端整个发现链路都押在注册表上（第 1 部分 #1/#2 已证明发现线程同样脆弱）。建议把"注册/注销"作为一个整体重写：有界退避、逐地址隔离失败、连接与退出回调走同一把锁或原子引用、注销用同步发送。
- **排期项（一般）**：#10（变体放大成 2~4 倍连接池）是唯一会随服务规模线性放大资源的项，规模大时先修它；#4/#5（注销丢失 + 无 TTL/无鉴权）决定"服务表能否自愈"；#6 是并发下的偶发订阅失败；#7 是启动期应失败的静默冲突；#8/#9 是安全面（请求/堆栈进日志与响应、CONSUME 无鉴权），至少要给出开关与文档说明；#11/#12 是文档与部署契约的精度问题。
- **代码质量**：`ServerConfig` 的配置读取、`ServiceHub` 的反射遍历、宏里的类型收集都有交代"为什么这么写"的注释（例如为什么用运行时探测而不生成 `registerType<T>()`、为什么不再过滤 `fountain::` 前缀），这些是本模块最有价值的部分；死代码只有 4 处（其中 2 处是 25 行内的本地残留），重复逻辑 1 组，整体属于健康的存量水平。主要风险不在"写错"，而在**后台线程的错误边界**与**资源生命周期的发布方式**。
- **本轮结论**：存量缺陷 18 条（严重 3 / 一般 9 / 轻微 6），是否纳入修复待用户决定；建议优先级 #1/#2/#3（注册线程）→ #10（连接放大）→ #4/#5（服务表自愈）→ #8/#9（安全面）→ #6/#7。

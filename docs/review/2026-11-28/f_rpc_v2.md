# f_rpc 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_rpc`（26 个文件：24 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_rpc.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] `start()` 的两阶段状态机没有异常出口，初始化线程一旦抛错，其他所有调用线程永久空转

- **位置**：`f_rpc/src/client/RPCClient.cj:29-33`（CAS 0→1）、`RPCClient.cj:34`（`initCodecPools()`，无 try）、`RPCClient.cj:148-152`（`ExitCallbacks.atExit`）、`RPCClient.cj:153`（`started.store(2)`）、`RPCClient.cj:154-156`（`while(started.load() != 2){}`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（同步缺失 / 可见性）、§6.3（并发串行）、§11
- **证据**：静态确定 —— `started` 的 1→2 转移只发生在分支末尾第 153 行，`initCodecPools()`（按配置重建两个 codec 池，`PoolConfig.cj:86-99` 会读 8 个配置项并调用 `DefaultCodec.setBufferPool/setBytesPool`）和 `ExitCallbacks.atExit` 都在这条路径上且没有 `finally`；一旦其中任一步抛异常，`started` 永久停在 1。此后每次 `start()` 都会落到 `else` 分支的 `while(started.load() != 2){}` —— 没有 yield / sleep / 超时 / 日志
- **描述**：`call()` 的第一步就是 `start()`（`RPCClient.cj:179`）。初始化线程抛错（配置值非法导致 `setBufferPool` 拒绝、`rpclog` 初始化失败、`atExit` 注册失败等）后，**进程内后续每一个 RPC 调用线程都会在一个热循环里 100% 占核且永不返回**：既不报错也不超时，表现为「服务活着但所有 RPC 线程卡死」，比直接抛异常难排查得多。同一时刻的并发调用者也会一起卡住
- **建议**：状态机改成三态（0=未启动 / 1=启动中 / 2=就绪）+ 失败态；初始化包 `try { … } catch (e) { started.store(失败); throw/记录 }`，等待侧改为「带超时的等待 + 失败态立即抛出原始异常」；`while` 里至少 `sleep(1ms)`，理想是条件变量 / `Channel`

### [一般][存量] 发现线程首轮 `createClient()` 在 try 之外，配置非法时后台线程静默死掉且不再重建

- **位置**：`f_rpc/src/client/RPCClient.cj:39`（`let clients = ClientConfig.createClient()`）、`RPCClient.cj:72`（`try{` 从这里才开始）、`RPCClient.cj:141-145`（catch / finally 只覆盖本轮订阅逻辑）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失）、§14.1（接线缺失 / 半成品）、§5（拒绝路径）
- **证据**：静态确定 —— `spawn{ while(true){ let clients = ClientConfig.createClient() … try{ … } catch{ warn } finally{ sleep } } }`，`createClient()` 在 `while` 内、`try` 外；`ClientConfig.serverAddresses`（`ClientConfig.cj:52-61`）对 `split(',')` 结果直接取 `arr[0]` / `arr[1]`，`Float64.parse` 也不捕获，所以一个笔误（例如漏写权重、多写一个 `|`）就会抛 `OutOfBoundsException` / `NumberFormatException`。该异常直接冲出 `spawn` 的 lambda，`while` 循环结束、线程死亡；而主线程随后照常 `started.store(2)`
- **描述**：配置缺失走的是「记 ERROR + `exit(1)`」（`ClientConfig.cj:255-266`），而配置**格式错误**走的是「发现线程静默死亡 + 进程继续运行」。后者后果更糟：`services` 永远为空，每次 RPC 调用都白等 `discoveryTimeout`（默认 5s）后抛 `no available client …`，从错误信息完全看不出是配置解析失败；且没有任何自愈路径，只能重启
- **建议**：把 `createClient()` 挪进 `try`（或整轮包 try），解析失败时用 `rpclog.error` 打印配置项名 + 原文并把 `started` 置为失败态；`serverAddresses` / `socketOption*` 加字段数校验（见下一条）

### [一般][存量] 重试不区分错误类型：业务异常（`Command.ERROR`）与响应类型不符也会被当成可重试失败，重复执行到重试耗尽

- **位置**：`f_rpc/src/client/RPCClient.cj:206-220`（`Command.ERROR` / 类型不符都在 `try` 内 `throw RPCException`）、`RPCClient.cj:221-231`（统一 `catch(e: Exception){ tried++ … }`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§12.1（异步语义）
- **证据**：静态确定 —— 服务端把业务异常编码成 `ERROR` 响应（README.md:535「服务调用异常（携带异常堆栈文本）」），客户端在 `case Command.ERROR => throw RPCException(data.toString())`（第 218 行）后立刻被同一个 `catch` 捕获，`tried++` 并继续用下一个节点重发；类型不符（第 212-216 行）同样计入重试。重发使用 `Message.consume(once: true, qos: AtMostOnce, …)` 新建消息与**新 MessageID**（第 200 行）
- **描述**：业务层已经执行并失败（或已成功但返回类型对不上）的调用，会在其它节点上再执行 `retryCount` 次。对非幂等接口（下单、扣款、发消息）这是重复副作用；对纯失败的业务异常则是把一次可定位的错误摊成 N 次执行 + 一个 `RPCException` 聚合体（原始堆栈只能从 `suppressed` 里翻）。注释与 README 都只强调「聚合上报」，未声明「任意异常都重试、包括业务异常」
- **建议**：按错误类别分流——网络/连接/超时类（`ClientException`、`InputClosedException`）才换节点重试；`Command.ERROR` 与反序列化失败立即抛出（可包一层 `RPCException` 但不再重试）；如需更强语义，把「已发出」与「未发出」区分开，只重试确定未送达的调用

### [一般][存量] 单次 RPC 没有超时参数，只能靠心跳/断链解除，`retryCount` 与 `discoveryTimeout` 都不覆盖

- **位置**：`f_rpc/src/client/RPCClient.cj:203`（`client.transfer(sending).get()`）、`f_rpc/src/client/ClientConfig.cj:119-123`（`rpcClient_readTimeout` 可选，默认无）
- **来源**：存量
- **判据**：review-checklist §11（资源与阻塞）、§12.1（异步语义：超时但任务继续跑）
- **证据**：静态确定 —— 用的是无超时重载：`Client.transfer(message): MessageFuture<Message>`（`f_net/src/client/client.cj:322-324`），`MessageFuture.get()` 在 `ref`/`failure` 都为空时无限 `condition.wait()`（`f_net/src/MessageFuture.cj:50-57`）。解除阻塞只有两条路：连接读线程失败时 `pending.close(...)`（`f_net/src/client/client.cj:112/129/136`）或 PING 心跳判定失败后拆链
- **描述**：对端「连得上、收得下、但不回包」（业务线程池被占满、处理极慢）时，调用方线程会一直挂在 `get()` 上；`retryCount` 只在拿到异常后才生效，`discoveryTimeout` 只管「等发现」。服务端慢请求会沿着客户端线程一路把调用方拖死，且线程数不可控
- **建议**：改用 `transfer(message, timeout)` / `tryGet(timeout)`，超时值由配置（如 `rpcClient_callTimeout`）给出并作为单次尝试的 deadline；超时后主动 `connection.pending.forget` 并计入重试

### [一般][存量] 重建连接池时直接 `close()` 掉调用线程正在迭代的 `MultiClient`，且 `call()` 失败后不会重新取 `services`

- **位置**：`f_rpc/src/client/RPCClient.cj:127-139`（`services[meta] = ClientConfig.createClient(hosts); clients.close()`）、`RPCClient.cj:188`（`for(client in availableClients(message.meta))` 只解析一次）
- **来源**：存量
- **判据**：review-checklist §12.1（跨线程资源 / 迭代与修改并发）、§11
- **证据**：静态确定 —— `availableClients()` 返回的是 `services` 里那一刻的 `MultiClient` 引用；`MultiClient.close()` 会 `closed = true` 并逐个 `client.close()`（`f_net/src/client/MultiClient.cj:246-262`）；发现线程在节点集合变化时直接对旧对象 `close()`。调用方的 `for` 循环已绑定旧集合，`catch` 只会 `tried++` 继续在同一批已关闭的 client 上重试
- **描述**：刷新周期默认 1s，只要节点集合变化（扩容/缩容/滚动重启）就有一个窗口：窗口内正在执行的调用，第一次失败后剩余重试全部打在已关闭的连接上，立刻抛聚合 `RPCException`；节点集合其实已经更新，重试却「收不敛」。这类偶发失败会被误判为下游故障
- **建议**：`catch` 里重新 `services.get(meta)` 取最新 `MultiClient`（引用不同才换），或让发现线程「先发布新对象、延迟关闭旧对象」（旧对象在引用计数归零/上次使用时间超过一个刷新周期后再关）

### [一般][存量] `services` 只增不删：元数据消失后条目与其连接池永不回收

- **位置**：`f_rpc/src/client/RPCClient.cj:27`（`private static let services = ConcurrentHashMap<…>()`）、`RPCClient.cj:110-140`（只在 `metas` 里出现时更新/重建，无删除分支）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 缓存键无界）、§12.1（有界性）
- **证据**：静态确定 —— 全仓搜 `services.remove` / `services.clear`（`grep -rn "services\.\(remove\|clear\)" f_rpc/src` 无命中）；`metas` 是每轮重新构建的 `HashMap`，某个 `ServiceMeta` 不再被任何节点上报后，`services` 里对应条目与其 `MultiClient`（含每个节点的 TCP 连接、读线程）就永久留着，只在进程退出时由 `atExit(252)` 关闭
- **描述**：以下场景会持续堆积：`rpcServer_exactlyVersion=true` 的补丁版本滚动发布（每次 `a.b.c` 都是新 `ServiceMeta`）、服务下线、Bean 改名。每堆积一条就多一组 socket + 读线程，且 `atExit` 回调里还要遍历关闭它们。条目数由「历史上出现过的元数据集合」决定，不受任何上限约束
- **建议**：每轮结束后把不在本轮 `metas` 里的键收集起来 `services.remove(meta)` 并 `close()`（注意与上一条的关闭时机配合）；或给条目加「最近一次出现轮次」，超过 N 轮未出现即淘汰

### [一般][存量] 配置解析不校验字段数与数值，且 `retryCount` 允许负数

- **位置**：`f_rpc/src/client/ClientConfig.cj:54-59`（`arr[0]` / `arr[1]` / `Float64.parse`）、`ClientConfig.cj:141-146`（`socketOptionBool` 取 `arr[0..2]`）、`ClientConfig.cj:151-156`（`socketOptionInt` 取 `arr[0..2]`）、`ClientConfig.cj:164-167`（`retryCount` 无下限）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 配置校验）、§14.1（配置项被读取但无校验）
- **证据**：静态确定 —— `Config.getStringArray(_, delim: '|')` 得到元素后直接 `addr.split(',')` 取 `arr[1]`；`rpcClient_serverAddress='1.0'`（漏写地址）→ `OutOfBoundsException`；`rpcClient_socketOptionBool='6,1'` → 同样越界；`rpcClient_retryCount=-1` → 第 191 行 `tried(0) > -1` 成立，**任何调用都不会被发出**，直接抛 `retry count exceeded`
- **描述**：这些问题本身是「配置写错」，但后果是「栈指向 `ClientConfig` 内部 + 现象是 RPC 全部失败」，运维无法从日志/堆栈定位到具体配置项（与上一条的静默死线程叠加）。负数重试次数这类「看起来合法」的取值没有拒绝路径
- **建议**：统一走一个「按配置项名 + 期望格式」的解析辅助：字段数不足就抛带 `key`、原文、期望格式的 `RPCException`；数值型加范围校验（`retryCount ≥ 0`、`queueSize ≥ 1`、`socketCount ≥ 1`）

### [一般][存量] 调用日志把完整入参与返回值写盘（含每条重试失败的 ERROR 全量序列化）

- **位置**：`f_rpc/src/client/RPCClient.cj:223`（`errorLog(sending.id, 'Stub', sending.command, message, e)`）、`f_rpc/src/base/imports.cj:51-53`（`JsonValue.from(message.toData())`）、`RPCClient.cj:240-244`（`infoLog<LogMessage>` 记请求 + 结果）、`f_rpc/src/base/ControllerTraceAspect.cj:36-43`（INFO 记控制器全部入参）
- **来源**：存量
- **判据**：review-checklist §10（敏感数据进日志）、fountain-baseline §6（日志不得出现凭据/令牌/完整报文）
- **证据**：静态确定 —— `errorLog<T>(… message: T, e: Exception) where T <: ToData` 会把整个 `RPCMessage`（`meta` + `params`）序列化成 JSON 写进 ERROR；`call()` 的 `catch` 在**每次**节点失败时都调用它；`infoLog` 以 INFO 记「请求消息、结果、耗时」（README.md:547 亦如此声明）；`ControllerTraceAspect` 对每个控制器方法把 `funcInfo.args` 逐个 `toData()` 后 `toString()` 拼进 `log.info`
- **描述**：`RPCMessage.params` 是业务实参（登录口令、令牌、身份证号、完整请求体都在其中）。默认 INFO 级别下一次成功调用就落一条含全量请求与结果的日志；失败重试时每个节点再落一条 ERROR。日志既是磁盘放大源也是数据外泄面；`ControllerTraceAspect` 还额外把 HTTP 入参写进同一份日志
- **建议**：日志只保留 `message.id`、`meta.typeName/methodName`、`params.size`、`consumed` 与异常类型；确需报文时走 DEBUG + 显式开关 + 长度截断；敏感字段用白名单/掩码（`f_log` 已有结构化字段能力）

### [一般][存量] `@RPCStub` 属性解析对未知键与缺失配置静默放过，等于让 `version` 退回通配

- **位置**：`f_rpc/src/macros/RPCStub.cj:41-64`（`case _ => ()`、`i += 2` 无越界保护）、`RPCStub.cj:55-56`（`exactlyVersion` 配置缺失 `?? false`）、`RPCStub.cj:68-74`（`version` 缺失即 `diagReport` + 抛错，与前者不一致）
- **来源**：存量
- **判据**：review-checklist §11（静默失效）、§14.1（半成品 / 取值校验）
- **证据**：静态确定 —— 属性循环里未识别的 token 直接 `case _ => ()` 丢弃，没有 `diagReport`；`version`/`name`/`exactlyVersion` 三个分支都是 `i += 2` 后直接 `attr[i].value`，属性写成 `@RPCStub[version]` 时下标越界（宏内异常，报错信息不可读）
- **描述**：`@RPCStub[verison='1.0.0']`（键名拼错）不会报错，`version` 保持初始值 `'*'` —— 客户端从此匹配**任意版本**的服务端，把「版本不匹配应该立即失败」变成「悄悄连到错误版本」。同一个宏里 `version` 缺失是编译错误（`diagReport(ERROR)`），`exactlyVersion` 配置项缺失却静默取 `false`，两套标准并存
- **建议**：`case _` 改为 `diagReport(ERROR, … 未知属性 <name>，支持 version/name/exactlyVersion)`；所有 `i += 2` 前校验 `i + 1 < attr.size`；`exactlyVersion` 取不到配置值时也报错（或至少在 `version` 缺配置时同构处理）

### [一般][存量] `@RPCSkeleton` 的 `weight` 取不到配置项时静默退化为 1.0

- **位置**：`f_rpc/src/macros/RPCSkeleton.cj:36-43`（`Config.getValue<Float64>(w) ?? 1.0`、`Float64.parse(w)` 无捕获）
- **来源**：存量
- **判据**：review-checklist §11（静默失效 / 配置校验）、§2（与 `@RPCStub` 的同构解析不一致）
- **证据**：静态确定 —— `weight=某个配置项名` 时若该配置项不存在，`?? 1.0` 直接吃掉落空；同样的「标识符当配置项」逻辑在 `RPCStub.cj:68-74` 里是 `getOrThrow{ diagReport(ERROR …) }`
- **描述**：权重决定流量分配，`@RPCSkeleton[weight=nodeWeight]` 少配一个环境变量就会让该节点被当成权重 1.0 参与负载均衡（而不是编译失败），线上表现为「权重配置无效、流量倾斜」
- **建议**：与 `@RPCStub.version` 对齐——查不到配置项就 `diagReport(ERROR)` + 抛出；`Float64.parse` 包 try 并给出属性名

### [一般][存量] `README` 的 `ServiceMeta` 构造签名与实现不符（按文档写会编译不过）

- **位置**：文档 `f_rpc/README.md:307-313`、`f_rpc/README_en.md:320-326`；代码 `f_rpc/src/base/RPCMessage.cj:86-104`
- **来源**：存量
- **判据**：review-checklist §13（API / 默认值与源码不符）
- **证据**：静态确定 —— 文档写 `weight!: Float64 = 1.0`（命名参数 + 默认值）；代码里 `weight: Float64` 是**位置参数且无默认值**（第 86 行），另有一个「不带 weight」的 6 参重载，它转调时传的是 `0.0`（第 102-104 行）。文档的 4 参/6 参示例 `ServiceMeta(version, name, typeName, methodName, argTypeNames, exactlyVersion: false)`（`ServiceMeta` 展开示例，README.md:248）恰好命中第 102 行重载，得到 `weight = 0.0` —— 而文档同页第 306 行说默认 `1.0`
- **描述**：两种用法都会踩坑。其一，照文档写 `ServiceMeta(v, n, t, m, args, weight: 2.0)` → 编译错误（`weight` 不是命名参数）。其二，照示例省略 weight → 实际 `weight = 0.0`，而客户端第 114 行用 `meta.weight != 1.0` 判「是否被骨架覆盖」，0.0 会被当成「有显式权重」，把该服务所有主机权重压成 0（累计权重区间退化）。文档的默认值与实现的默认值方向相反
- **建议**：**先**把代码统一（`weight` 要么全部命名参数带默认 1.0，要么删掉 6 参重载、让 `weight` 必填并更新宏展开），**再**按最终签名改两份 README；`ServiceMeta` 用 `?Float64`（`None` = 未覆盖）比用 `1.0` 当哨兵更能表达「未设置」

### [一般][存量] README 承诺「服务端继承客户端 trace」，实现里没有任何读写 `message.trace` 的地方

- **位置**：文档 `f_rpc/README.md:285-288`、`f_rpc/README_en.md:298-300`；代码 `f_rpc/src/base/RPCMessage.cj:30-56`、`f_rpc/src/client/RPCClient.cj:200`
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现相反）、§14.1（承诺了但没实现，需双证）
- **证据**：静态确定 —— 承诺源：README「当服务端再次调用其它服务时会自动继承当前服务从客户端接收到的 trace」。缺失证据：全仓 `grep -rn "trace" f_rpc/src`（排除 `.macrocall`）只有 `RPCMessage` 自身与 `ControllerTraceAspect` 命中，**没有任何代码读 `message.trace` 或写它**；`trace_` 只在 `trace` 属性 getter 里被 `currentTrace()` 填值，而发送路径（`RPCClient.cj:200` 的 `Message.consume(… data: message)`、服务端解码）从不触碰这个属性 ⇒ 出网报文的 `trace_` 恒为 `''`，服务端只能另生成一个本地 id（`RPCMessage.cj:45-53`）。`f_protocol` 里也没有承载 trace 的字段（`grep -rn "trace" f_protocol/src` 无命中）
- **描述**：跨进程 trace 传递实际上不存在：客户端日志里的 trace 与服务端日志里的 trace 是两个独立生成的 `MessageID`，无法串起一次调用的两端。README 把这条当作已实现能力写在「核心 API」里
- **建议**：要么在 `RPCClient.call` 里 `message.trace = RPCMessage.currentTrace()`（并把 `trace_` 纳入序列化）、服务端解码后 `currentTrace_.set(...)`；要么把 README 改成「trace 仅在进程内生效，跨进程靠 MessageID 关联」

### [一般][存量] `rpc_codec*` 八个配置项无任何文档，而其他模块的 README 明确指向这里

- **位置**：代码 `f_rpc/src/base/PoolConfig.cj:35-49`；文档 `f_rpc/README.md:457-521`（配置项参考，无 `rpc_codec*` 条目）、`f_rpc/README_en.md:476-520`；外部引用 `f_codec/README.md:112`、`f_pool/README.md:343`
- **来源**：存量
- **判据**：review-checklist §14.2（公开配置项未文档化）、§13
- **证据**：静态确定 —— `PoolConfig.cj` 定义 8 个 key（`rpc_codecBufferPoolInitSize/MinSize/MaxSize`、`rpc_codecBytesPoolInitSize/MinSize/MaxSize/ArraySize`、`rpc_codecPoolMaxWaiting`），默认值分别为 1024/1024/1024、0/1/1024/4096、30s；`grep -rn "rpc_codec" f_rpc/README*.md` 只命中包结构表（README.md:26）里「`rpc_codec*` 池配置（`PoolConfig`）」一句，配置项表里一条都没有；`f_codec/README.md:112` 却写「见 f_rpc README」
- **描述**：池参数直接影响编解码吞吐与内存峰值（`rpc_codecPoolMaxWaiting` 配 0 表示无限等待，配置错误会让 `encode()` 无限阻塞），使用者按 f_codec 的指引来 f_rpc 找，找不到任何 key 名与默认值
- **建议**：在 `f_rpc/README.md` 的配置项参考里补一张「codec 池（前缀 rpc_codec）」表：key、类型、默认值、含义（尤其 `rpc_codecPoolMaxWaiting` 的 `≤0 = 真无限等待` 语义）

### [一般][存量] `LogMessage()` 公开默认构造产出零值 `RPCMessage`，格式化即崩

- **位置**：`f_rpc/src/client/RPCClient.cj:248-259`（`public init(){ this(unsafeZeroValue<RPCMessage>()) }`）；对照 `RPCClient.cj:183-185` 的注释
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§3（公开契约承诺有行为）
- **证据**：静态确定 —— 同一文件的注释写明「不能用 `unsafeZeroValue<Message>()`：它的 id 是零值，一旦调用在发出消息前就失败，finally 里的日志会格式化零值 `MessageID`（DateTime 未初始化）而段错误」，而 `LogMessage()` 恰好把 `unsafeZeroValue<RPCMessage>()` 作为公开默认构造的入口；`LogMessage` 是 `@DataAssist` 类型，被日志/序列化格式化时会走到 `message.id`
- **描述**：README 把 `public init()` 列为 `LogMessage` 的合法 API（README.md:368）。用它构造再交给 `infoLog`/`toData()` 会复现注释里描述的段错误——已知会崩的入口被公开且无注释警告
- **建议**：删掉默认构造（`@DataAssist` 的 fields 路径不依赖无参构造即可），或改为 `init(){ this(RPCMessage()) }`；若必须保留，注释里显式标注「仅用于反序列化，禁止格式化」

### [一般][存量] `tryFromData` 解码失败被当成「没有服务 / 没有主机」，与「确实为空」不可区分

- **位置**：`f_rpc/src/client/RPCClient.cj:45-50`（`Array<ServiceMeta>`）、`RPCClient.cj:79-84`（`Array<String>`）
- **来源**：存量
- **判据**：review-checklist §3（`case _ => ()` 兜底吃掉错误）、§11（静默）
- **证据**：静态确定 —— 三分支 `match(any){ case x: Array<T> => x; case x: ?Array<T> => x ?? []; case _ => [] }`，`case _` 把「载荷类型不符 / 解码失败」直接压成空数组；上游 `subscribe()` 随后 `if(array.isEmpty()){ return true }`（第 51-53 行）当作「该节点没有服务」并返回成功
- **描述**：客户端与服务端 `ServiceMeta` 结构不一致（版本漂移、字段增删）时，服务端的服务列表会被解码成空数组 → 客户端认为对端没有服务、不报错、不记日志，最终只在调用侧表现为「等 5s 后 no available client」。真正的原因（解码失败）被吞掉
- **建议**：`case _` 改为 `throw RPCException("subscribe payload is not Array<…>: …")` 或至少 `rpclog.warn` 带上 `TypeInfo` 与载荷大小；「确实为空」走 `?Array` 的 `None` 语义区分

### [一般][存量] `ServiceMeta` 版本截断按 `.` 拆分后直接取 `v[1]`

- **位置**：`f_rpc/src/base/RPCMessage.cj:86-92`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 越界）
- **证据**：静态确定 —— `let v = version.split('.'); '${v[0]}.${v[1]}'`，仅在 `exactlyVersion || version == '*'` 之外执行；`version = '1'` / `'1.0-beta'` 之外的任何无点串都会 `v[1]` 越界
- **描述**：`version` 来自 `@RPCStub` 属性（字面值或配置项）、`cjpm.toml` 或调用方显式传入；写成 `'1'` 时抛 `OutOfBoundsException`，异常点落在 `ServiceMeta` 构造里，宏展开的注册代码会把它变成「整个模块注册失败」，错误信息不指向配置项
- **建议**：`v.size >= 2` 才截断，否则原样保留；更好的是引入/复用版本类型做解析与比较

### [轻微][存量] 死代码：`errorLog(_, _, _, e: Exception)` 重载全仓零调用

- **位置**：`f_rpc/src/base/imports.cj:48-50`
- **来源**：存量
- **判据**：review-checklist §1（`protected` 顶层函数在本 module 内无引用即死代码）
- **证据**：静态确定 —— 全仓 `grep -rn --include=*.cj --exclude-dir=.worktrees "errorLog("` 只有 4 处调用：`RPCClient.cj:223`（5 参带 message）、`server/imports.cj:24`（`ErrorMessage`，走 `T <: ToData` 重载）、`RPCServer.cj:27`（`String`，走 `String` 重载），**没有任何调用点匹配「只有异常、无 message」这个重载**。同文件另外 3 个 `errorLog` 重载均有调用者
- **描述**：该重载是「记异常但不带报文」的入口，看起来正是修上一条（日志暴露入参）时应该用的东西，但当前无人调用；保留它会让人误以为「已经有不带报文的日志路径」
- **建议**：要么在改日志时把它用起来（`RPCClient.cj:223` 换成它），要么删除

### [轻微][存量] 重复逻辑：`checker()` 两份同体实现，`Duration` 读取两种等价写法

- **位置**：`f_rpc/src/base/imports.cj:64-66` 与 `f_rpc/src/client/ClientConfig.cj:184-186`；`f_rpc/src/base/PoolConfig.cj:73-80` 与 `f_rpc/src/client/ClientConfig.cj:77-81`
- **来源**：存量
- **判据**：review-checklist §2（只改上下文 / 同语义两种写法）
- **证据**：静态确定 —— 两处 `checker(): ?Message { Message.ping() }` 逐字相同（前者已作为 module 级 `protected` 被 `server/RPCServer.cj:41/54` 使用，后者在 `createClient` 里又定义了一遍）；`Config.getData<Duration>(k)` 与 `Config.getDuration(k)` 在 `f_config/src/Config.cj:244-246` 是同一个实现（后者就是前者的一行包装），f_rpc 里两种写法并存
- **描述**：无行为差异，纯粹是「新代码没复用既有 helper」。`checker` 的重复会在需要改 PING 载荷时漏改一处
- **建议**：`ClientConfig.createClient` 直接用 `checker`（module 级 `protected` 已可见）；Duration 统一用 `Config.getDuration`

### [轻微][存量] 重复逻辑：两段 `tryFromData` 三分支样板只改了类型名

- **位置**：`f_rpc/src/client/RPCClient.cj:45-50` 与 `RPCClient.cj:79-84`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 除 `Array<ServiceMeta>` / `Array<String>` 外，两个 `match` 的分支顺序、`case _ => []` 兜底、变量名 `any`/`array` 完全对齐，各 6 行
- **描述**：同一段「宽松解包 + 失败当空」的语义写了两遍；上一处（解码失败静默）要修时必须同步改两处，否则两条路径行为漂移
- **建议**：抽成模块内 `private func unpackArray<T>(data: DataAny, label: String): Array<T>`，把「失败时抛/告警」的策略收在一处（泛型是否可用需按 `f_data` 的 `tryFromData` 签名确认，`待确认`）

### [轻微][存量] `ControllerTraceAspect`：start 用 INFO、end 用 DEBUG；`finally` 里无条件清空而非恢复原 trace

- **位置**：`f_rpc/src/base/ControllerTraceAspect.cj:43`（`log.info`）、`ControllerTraceAspect.cj:48`（`log.debug`）、`ControllerTraceAspect.cj:46-47`（`RPCMessage.clearCurrentTrace()`）
- **来源**：存量
- **判据**：review-checklist §10（可维护性 / 语义与命名）、§11（语义与注释不符）
- **证据**：静态确定 —— 进入时 `RPCMessage.currentTrace()`（第 33 行）在 ThreadLocal 为空时会**新建并写入**一个 id，退出时 `clearCurrentTrace()` 把它置 `None`；若外层已有 trace（嵌套调用、或被 RPC 服务端处理链路包裹的控制器），这里清掉的是外层的值而不是恢复进入前的值
- **描述**：日志成对性上，start 是 INFO、end 是 DEBUG，生产级别下只能看到 start；trace 语义上，「清空」不等于「恢复」，外层链路在控制器返回后丢失 trace，后续同线程日志再也串不起来
- **建议**：进入时把 `currentTrace_.get()` 的原值取出，`finally` 里写回原值（`Some` 就恢复，`None` 才清空）；end 日志与 start 用同一级别（或用同一个 `debug{…}` 闭包）

### [轻微][存量] `@RPCStub` 对「带默认实现的属性」静默跳过

- **位置**：`f_rpc/src/macros/RPCStub.cj:98-105`（`else if (let p: PropDecl <- d && p.lBrace.kind == LCURL) { continue }`）、`f_rpc/src/macros/RPCStub.cj:30-31`（注释「不能实现属性」）
- **来源**：存量
- **判据**：review-checklist §14.1（只做了一半的分支 / 静默跳过）、§13
- **证据**：静态确定 —— 接口里 `prop x { get() { … } }`（带默认实现）走 `continue` 被丢弃，生成的 `_Stub__` 直接继承默认实现；不带实现体的 `prop x: Int64` 才走 `diagReport(ERROR)`
- **描述**：同一个「不支持属性」的约束，两种写法一个静默跳过、一个编译报错。静默跳过的那种，客户端调用该属性会拿到本地默认实现的结果，而不是远程值——属于「看起来能用、实际没走 RPC」
- **建议**：`PropDecl` 一律 `diagReport(ERROR)`，或至少在属性带默认实现时给 WARN 说明「不会走 RPC」

### [轻微][存量] 首个 RPC 调用在服务发现完成前按 20ms 轮询阻塞调用线程

- **位置**：`f_rpc/src/client/RPCClient.cj:164-177`
- **来源**：存量
- **判据**：review-checklist §6.4（忙轮询）、§11
- **证据**：静态确定 —— `while(true){ if(let Some(c) <- services.get(meta)) return c; if(now>=deadline) break; sleep(20ms) }`，默认 5s 上限 ⇒ 最多 250 次唤醒/调用
- **描述**：并发 N 个「尚未发现」的调用会形成 N 倍定时唤醒，且调用方线程被整段阻塞（不是异步等待）。当前服务数与并发下量级不大，故定为轻微
- **建议**：用条件变量/事件在发现线程发布时通知；或退避（20ms→100ms→500ms）

<!-- 第 2 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 不是缺陷，是「还能更好」。以下两条均无改前/改后基线，标注为「无基线」，不进 `tasks`。

### [CPU] 把调用日志与控制器 trace 日志改为惰性求值、只记标识与耗时

- **现状**：每次 RPC 调用在 `finally` 里构造 `LogMessage`（`RPCClient.cj:240-244`），INFO 级别下把请求（`RPCMessage`，含 `meta` + `params`）与结果整体 `toData()` 成 JSON；`ControllerTraceAspect.cj:36-42` 对每个控制器方法**先**把全部入参 `toData()` → `JsonValue` → `toString()` 拼进字符串，**再**交给 `log.info`（字符串参数已求值，与日志级别无关）
- **方案**：调用日志改为只传 `(id, meta.typeName, meta.methodName, params.size, consumed, 异常类型)`；需要报文时走独立 DEBUG 开关 + 截断。`ControllerTraceAspect` 改成 `log.info{…}` 闭包，且闭包内只做「trace + 方法名 + 参数类型名」，参数值不出现在任何级别
- **预期**：省掉每次调用/每个 HTTP 请求的「全参序列化 + 字符串拼接 + 落盘」；具体降幅取决于参数规模，未测
- **代价**：排障时看不到报文，需要时得开 DEBUG 开关；日志格式变化影响既有 grep/告警规则
- **验证**：`cjpm bench -O2` 跑 `@DataAssist` 中等体积参数（如 20 字段）的调用 10 万次，对比「现状 / 只记标识」两版的 P50 与吞吐中位数；同时对照日志字节数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 发现循环的重试与轮询加退避 / 事件化

- **现状**：`RPCClient.cj:95-108` 的 `while(true){ try{ build/transfer }catch{ error } }` 无 sleep、无次数上限，对端拒绝连接时按「失败-打印-立即重试」空转；`availableClients` 20ms 轮询（第 167-175 行）
- **方案**：指数退避 100ms→5s + ±20% 抖动 + 上限后放弃本轮（记 ERROR 等下一轮）；`availableClients` 改条件变量或「发现线程发布后通知」
- **预期**：对端不可用时该线程 CPU 从忙等降到近 0，日志条数按退避间隔线性下降；未测
- **代价**：故障恢复延迟从「立即」变成「最多一个退避窗口」；需要新增可见的失败计数指标
- **验证**：`cjprof record` 跑「种子节点拒绝连接」60s，对比改前改后进程 CPU 时间、日志行数、发现恢复时间
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

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

<!-- 第 1 部分 -->

> 无性能数据支撑，不进 `todo.md` / `tasks.md`，仅用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | INFO 级全量入参/结果序列化占单次 RPC 端到端耗时的可观比例 | `f_rpc/src/client/RPCClient.cj:240-244`、`base/ControllerTraceAspect.cj:36-42` | `toData`/`JsonValue` 的自耗时占比 | `cjprof record` 跑 10k 次调用（参数 10~20 字段），看 `JsonValue.from`、`toData` 自耗时；再用「只记 id/耗时」的对照版本跑同负载 |
| 2 | 一轮发现耗时可能超过 `refreshIntervalSeconds`（默认 1s），使发现线程常驻忙 | `f_rpc/src/client/RPCClient.cj:35-146` | 单轮耗时随节点数/服务数的分布 | 在 `sleep(refreshIntervalSeconds)` 前后打点，跑 50 节点 × 200 服务，记录轮次间隔中位数与最大值 |
| 3 | `services` 无淘汰在 `rpcServer_exactlyVersion=true` 滚动发布下持续增长 | `f_rpc/src/client/RPCClient.cj:110-140` | 条目数、socket 数、RSS 的增长速率 | 连续发布 20 个补丁版本，每轮记录 `services.size`、`/proc/<pid>/fd` 数量、RSS |
| 4 | 20ms 轮询在 N 并发未发现服务时放大唤醒 | `f_rpc/src/client/RPCClient.cj:167-175` | 唤醒次数与线程阻塞占比 | 100 并发调用一个未注册的服务，统计 5s 内 `sleep` 唤醒总数与 CPU 时间 |

<!-- 第 2 部分 -->

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 订阅路径（`metas` + `toData` + 编码）在大服务数下可能成为热点 | `RPCServer.cj:154-164`、`ServiceHub.cj:105-110` | 自耗时占比、端到端占比 | `cjprof record`，200 服务 / 50 客户端 / 1s 刷新 / 60s；与无订阅基线对照 |
| 2 | 注册重试空转的实际 CPU 与日志吞吐量（决定退避参数） | `RPCServer.cj:56-73` | 每秒迭代次数、ERROR 行数、CPU 占用 | 种子端口关闭时启动节点，采样 `top` 与 60s 内日志行数，3 次取中位数 |
| 3 | `ServiceHub.register` 的 `O(k²)` 重放在真实启动耗时中的占比 | `ServiceHub.cj:44-99` | 启动期分段耗时 | 在 `register` 前后打点，服务数 10 / 100 / 1000 三档 |
| 4 | `hub[meta]` 未命中抛异常（异常控制流）在客户端版本不匹配时的高频代价 | `ServiceHub.cj:101-104` | 未命中次数、单次异常开销 | 加计数埋点，跑「客户端版本与服务端不匹配」场景 10 分钟 |

## 文件覆盖

> 与 `files/f_rpc.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rpc/README.md` | .md | ✅ | — |
| 2 | `f_rpc/README_en.md` | .md | ✅ | — |
| 3 | `f_rpc/src/RpcTestSetup_test.cj` | .cj | ✅ | — |
| 4 | `f_rpc/src/base/ControllerTraceAspect.cj` | .cj | ✅ | — |
| 5 | `f_rpc/src/base/PoolConfig.cj` | .cj | ✅ | — |
| 6 | `f_rpc/src/base/RPCException.cj` | .cj | ✅ | — |
| 7 | `f_rpc/src/base/RPCMessage.cj` | .cj | ✅ | — |
| 8 | `f_rpc/src/base/RPCTypeRegistration.cj` | .cj | ✅ | — |
| 9 | `f_rpc/src/base/imports.cj` | .cj | ✅ | — |
| 10 | `f_rpc/src/client/ClientConfig.cj` | .cj | ✅ | — |
| 11 | `f_rpc/src/client/RPCClient.cj` | .cj | ✅ | — |
| 12 | `f_rpc/src/client/imports.cj` | .cj | ✅ | — |
| 13 | `f_rpc/src/encodedmessage_release_test.cj` | .cj | ✅ | — |
| 14 | `f_rpc/src/health/HealthRPC.cj` | .cj | ✅ | — |
| 15 | `f_rpc/src/health/server/HealthRPCImpl.cj` | .cj | ✅ | — |
| 16 | `f_rpc/src/macros/RPCSkeleton.cj` | .cj | ✅ | — |
| 17 | `f_rpc/src/macros/RPCStub.cj` | .cj | ✅ | — |
| 18 | `f_rpc/src/macros/TypeRegistration.cj` | .cj | ✅ | — |
| 19 | `f_rpc/src/macros/imports.cj` | .cj | ✅ | — |
| 20 | `f_rpc/src/rpc.cj` | .cj | ✅ | — |
| 21 | `f_rpc/src/server/LogMessage.cj` | .cj | ✅ | — |
| 22 | `f_rpc/src/server/RPCServer.cj` | .cj | ✅ | — |
| 23 | `f_rpc/src/server/RPCServerInitializer.cj` | .cj | ✅ | — |
| 24 | `f_rpc/src/server/ServerConfig.cj` | .cj | ✅ | — |
| 25 | `f_rpc/src/server/ServiceHub.cj` | .cj | ✅ | — |
| 26 | `f_rpc/src/server/imports.cj` | .cj | ✅ | — |

合计：`.cj` 24 个 / `.md` 2 个 / 共 26 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 正确性：重试语义、重建竞态、版本越界、配置解析；安全性：日志暴露入参（1 条）；设计：`services` 无淘汰、状态机无失败态 |
| §1 死代码 | 1 | 逐个 `private` / `internal` / `protected` 符号全仓搜过：`logmsg`×3、`rpclog`、`errorLog`×4、`debugLog`/`infoLog`、`checker`、`EMPTY_META`、`build`、`register/deregister/subscribe`、8 个 `rpc_codec*` 常量与其 getter、`codecPoolsInitialized`、`initCodecPools`、`ClientConfig` 的 23 个常量与 16 个 private prop、`identifierRegex`、`collectRPCTypes`/`addRPCType`/`rpcTypeRegistrations` 均有调用者；**只有 `errorLog(id,label,command,e: Exception)` 零调用 = 死代码**。`public` 且对外可达（`RPCException`/`RPCMessage`/`ServiceMeta`/`RPCClient`/`ClientConfig`/`LogMessage`/`registerRPCType`/两个常量/两个宏/`ControllerTraceAspect.proceed`）不判 |
| §2 重复逻辑 | 3 | 同文件逐函数体比对 + 跨文件按字面量/错误消息搜索：①`checker()` 两份同体；②`tryFromData` 三分支样板两份（只改类型名）；③`Config.getData<Duration>` 与 `Config.getDuration`（等价两写法）。`ServiceMeta` 两个 init 是 TypeInfo→String 适配，不算重复；4 个 `errorLog` 重载语义不同（是否带 message、类型 T 是否 `ToData`），保留 |
| §3 空实现 | 2 | ①`RPCTypeRegistration.cj:49-51` `catch (_: Exception) {}` 静默吞掉登记失败（无日志、无返回值，第二次跨网络传输才暴露）；②`RPCClient` 的 `case _ => []` 把解码失败当空集合。测试 sink 的 `flush(){}` 是有意构造 |
| §4 栈溢出 | 0 | 无递归：宏是 `while`/`for` 遍历 token 与 decl，`TypeRegistration` 线性去重，`RPCClient` 全是循环；无自引用结构遍历 |
| §5 OOM | 1 | `services`（`ConcurrentHashMap`）只增不删，键是服务元数据、值含 socket 与读线程，无容量/TTL；已单列为发现。其余容器（`metas`/`hostMap`/`TreeSet`）均为一轮内局部变量 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，两条性能嫌疑（INFO 全量序列化、发现循环忙等）只写进「优化可行性方案（无基线）」与「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无显式锁：并发原语只有 `AtomicBool`（池初始化）、`AtomicInt8`（start 状态）、`ConcurrentHashMap`（services）；`ThreadLocal` 线程封闭 |
| §6.3 并发串行 | 2 | ①`start()` 的等待侧是纯自旋（已按严重单列）；②发现线程单线程串行 SUBSCRIBE 所有节点、每轮 `sleep` 在轮末，一轮超时就挤占下一轮（数据不足，列待验证假设 2） |
| §6.4 低效算法 | 1 | `availableClients` 20ms 轮询（轻微）；发现循环无退避（并入发现/优化方案）。无 `remove(at:0)`、无嵌套 `contains`、无循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 本部分无稳定的大对象驻留：`RPCMessage`/`ServiceMeta` 都是单次调用生命周期；`metas`/`hostMap` 每轮重建。`services` 的堆积问题已按缺陷（§5）报，不以「优化方案」重复计 |
| §8 降 CPU 方案 | 2 | ①日志惰性求值 + 只记标识；②发现循环退避 / 轮询事件化。均为 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 无「函数内创建、函数内销毁的大中间对象」证据：`ControllerTraceAspect` 的临时 `Array<JsonValue>` 规模由形参个数决定（个位数），收益无法用峰值内存证明，且 `toData`/`JsonValue` 返回值会逃逸 |
| §11 现有代码的 BUG（存量） | 22 | 本轮 20 个文件的全部现有逻辑按「边界/空值/错误处理/资源/并发/契约不符」过了一遍：22 条全部标 `[存量]`（快照模式无 diff，全部为存量） |
| §12 并发安全与锁粒度 | 3 | 已列的 3 条共享路径：`started` 状态机（自旋无退出）、`services` 与发现线程的重建/关闭（跨线程替换容器 + 关闭在用对象）、`services` 无淘汰；`AtomicBool`/`AtomicInt8`/`ConcurrentHashMap`/`ThreadLocal` 的用法本身正确，`services` 的复合操作（get→put→close）非原子问题已并入重建竞态那条 |
| §14 功能完备性与 README 覆盖 | 3 | ①README 承诺的跨进程 trace 未实现（双证见该条）；②`rpc_codec*` 8 个配置项未进配置表（f_codec README 反向引用）；③`LogMessage()` 默认构造被文档列为合法用法却会复现已知段错误。`registerRPCType` 已进「其他公开 API」；`server` 侧公开 API 的 README 覆盖留待第 2 部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件。§13 命中 4 条：ServiceMeta 签名、trace 承诺、`rpc_codec*` 缺表、README_en 漏约束句（最后一条为轻微，未单列） |

### 第 2 部分

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
| 严重 | 4 |
| 一般 | 21 |
| 轻微 | 10 |
| 其中存量 | 35 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：这套代码的「已知坑」意识很强——`weight` 排除出相等/哈希、累计权重区间、`retryCount` 的 `tried > retryCount`、`unsafeZeroValue` 的段错误、负载均衡桶边界，都在注释里留了现场记录与归档链接，`PoolConfig` 还明确写了「不要在包初始化期读配置」。这是本部分最值得肯定的地方。本部分的问题集中在四处：

1. **故障期不可控**（严重 1 + 一般 3，另有一条退避方案）：`start()` 的状态机没有失败态，初始化抛错会让所有 RPC 线程永久自旋；发现线程首轮在 `try` 之外，配置写错就静默失联；单次调用没有 deadline；发现循环无退避。这四条共同的效果是「一处小故障 → 整机 RPC 挂住且没有明确错误」，优先级最高。
2. **重试语义偏离承诺**（一般 1）：`Command.ERROR` 与类型不符都被当成可重试失败，非幂等接口会被重复执行到重试耗尽，原始错误沉进 `suppressed`。这既是正确性问题也是运维可观测性问题，建议与 README 的「异常聚合上报」一并重新定义。
3. **生命周期不对称**（一般 2）：`services` 只增不删、重建时直接关闭调用线程在用的 `MultiClient`。两者叠加会在滚动发布窗口内同时造成「偶发失败」与「句柄/线程缓慢增长」。
4. **文档与实现漂移**（一般 3 + 轻微 2）：`ServiceMeta` 构造签名与默认值写反、跨进程 trace 是不存在的承诺、8 个 `rpc_codec*` 配置项无表；另有两处小漂移（README_en 漏掉「data 必须能转换为返回类型」、`@RPCStub` 对带默认实现的属性静默跳过与文档措辞不符）。文档在这三处会把使用者直接带进坑里，且都是「两边都能指出来」的硬证据，修复成本低于其误导成本。

建议排期：先修第 1 组（严重 1 条 + 配置解析/发现线程那两条），再统一重试语义与日志脱敏，最后收文档与死代码/重复逻辑。代码整体结构清晰、注释质量高，没有发现设计层面的方向性错误；本部分的风险主要落在异常路径与边界上，而不是主干逻辑。

**第 2 部分**：本部分代码量不大（568 行），结构清晰：命令分发、四个 Executor、注册表、配置各司其职，`ConcurrentHashMap` + `addIfAbsent` 的选型也合理，没有锁、没有递归、没有按报文长度预分配，因此**不存在栈溢出与 OOM 面**。

真正的风险集中在「启动期注册链路」与「服务发现的并发读取」两处，且都是存量问题：

- **阻塞项（建议本版本修）**：#1 非法种子地址直接杀死注册协程、#2 无退避重试导致 CPU 空转 / 日志洪水 / 队头阻塞、#3 订阅时的 `size`+`iterator` 竞态。这三条的共同后果是「节点静默地进不了服务发现，或订阅随机失败」，属于用户可见的功能失效，修复成本都不高（提前校验 + 有界退避 + 一次遍历到底）。
- **排期项**：#4 注册表无 TTL/无鉴权（与 #1/#2 的残留叠加）、#5 配置静默回落（运维诊断成本）、#8 `exactlyVersion` 冻结、#9 关停时 `clients.value` 的发布竞态。
- **安全项**：#6 全量入参进 INFO 日志、#7 堆栈原样回传，都属于「已文档化的设计选择」，但对外暴露面确实偏大，建议与脱敏/错误码改造一起排。
- **轻微项**：两处死代码（`let cmd`、`ConsumeExecutor.buffer`）、一个同值重复常量、IPv6 地址截断，改动都在一行到三行之间。

本部分共 13 条（严重 3 / 一般 6 / 轻微 4），全部为存量，是否纳入修复待用户决定：其中严重与一般 9 条建议排期（3 条严重为阻塞项），轻微 4 条与 3 条优化方案不进修复清单——优化方案全部无基线，只能作为下一轮补数据的输入。

# f_rpc 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rpc`（本部分 18 个 `.cj` + 2 个 `.md`，共 20 个文件）
- **部分范围**：`README.md` / `README_en.md` / `src/rpc.cj` / `src/base/**` / `src/client/**` / `src/health/**` / `src/macros/**` / 两个测试文件（`src/server/**` 属第 2 部分，本报告不对其展开）
- **基线**：工作区快照（master 与 sts/1.3.x 同提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：重试收敛、服务发现信任边界、配置解析健壮性、日志入参暴露、启动期依赖
- **报告版本**：v1（分部分报告；同日 `docs/review/2026-11-28/f_rpc.md` 是主 Agent 的抽样版，合并由主 Agent 负责）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 无性能数据支撑，不进 `todo.md` / `tasks.md`，仅用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | INFO 级全量入参/结果序列化占单次 RPC 端到端耗时的可观比例 | `f_rpc/src/client/RPCClient.cj:240-244`、`base/ControllerTraceAspect.cj:36-42` | `toData`/`JsonValue` 的自耗时占比 | `cjprof record` 跑 10k 次调用（参数 10~20 字段），看 `JsonValue.from`、`toData` 自耗时；再用「只记 id/耗时」的对照版本跑同负载 |
| 2 | 一轮发现耗时可能超过 `refreshIntervalSeconds`（默认 1s），使发现线程常驻忙 | `f_rpc/src/client/RPCClient.cj:35-146` | 单轮耗时随节点数/服务数的分布 | 在 `sleep(refreshIntervalSeconds)` 前后打点，跑 50 节点 × 200 服务，记录轮次间隔中位数与最大值 |
| 3 | `services` 无淘汰在 `rpcServer_exactlyVersion=true` 滚动发布下持续增长 | `f_rpc/src/client/RPCClient.cj:110-140` | 条目数、socket 数、RSS 的增长速率 | 连续发布 20 个补丁版本，每轮记录 `services.size`、`/proc/<pid>/fd` 数量、RSS |
| 4 | 20ms 轮询在 N 并发未发现服务时放大唤醒 | `f_rpc/src/client/RPCClient.cj:167-175` | 唤醒次数与线程阻塞占比 | 100 并发调用一个未注册的服务，统计 5s 内 `sleep` 唤醒总数与 CPU 时间 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rpc/README.md` | .md | ✅ | 与实现逐节核对；见 §13/§14 问题（ServiceMeta 签名、trace 承诺、`rpc_codec*` 缺失） |
| 2 | `f_rpc/README_en.md` | .md | ✅ | 与中文版结构一致；「快速失败」一节漏掉「data 必须能转换为返回类型」的约束（轻微，见覆盖自检 §13） |
| 3 | `f_rpc/src/RpcTestSetup_test.cj` | .cj | ✅ | 测试用 `protocol_hostId` 初始化；顶层 `testProtocolHostIdSetup` 靠初始化副作用生效，可接受 |
| 4 | `f_rpc/src/base/ControllerTraceAspect.cj` | .cj | ✅ | 日志暴露入参、trace 清空而非恢复（发现 + 轻微） |
| 5 | `f_rpc/src/base/PoolConfig.cj` | .cj | ✅ | CAS 一次性初始化；配置项无文档（§14）；`Config.getData<Duration>` 与 `getDuration` 重复 |
| 6 | `f_rpc/src/base/RPCException.cj` | .cj | ✅ | 模板异常类，4 个构造均符合 `BaseException` |
| 7 | `f_rpc/src/base/RPCMessage.cj` | .cj | ✅ | 版本截断越界（发现）；`trace` 字段无读写方（§13） |
| 8 | `f_rpc/src/base/RPCTypeRegistration.cj` | .cj | ✅ | `catch (_: Exception) {}` 静默吞异常（已并入 §3 统计，见覆盖自检） |
| 9 | `f_rpc/src/base/imports.cj` | .cj | ✅ | 4 个 `errorLog` 重载中 1 个无调用者（死代码） |
| 10 | `f_rpc/src/client/ClientConfig.cj` | .cj | ✅ | 配置解析不校验（发现）、`checker` 重复（轻微） |
| 11 | `f_rpc/src/client/RPCClient.cj` | .cj | ✅ | 主要风险集中地：状态机、重试语义、重建竞态、services 无淘汰、日志暴露 |
| 12 | `f_rpc/src/client/imports.cj` | .cj | ✅ | 纯 import（`public import` + `internal import` 双写的注释已说明原因） |
| 13 | `f_rpc/src/encodedmessage_release_test.cj` | .cj | ✅ | 两个回归用例（池释放、`ServiceMeta` 身份）；`write` 恒抛的 sink 为有意设计 |
| 14 | `f_rpc/src/health/HealthRPC.cj` | .cj | ✅ | `@RPCStub` 最小示例，与 README 一致 |
| 15 | `f_rpc/src/health/server/HealthRPCImpl.cj` | .cj | ✅ | `@RPCSkeleton` 最小示例，与 README 一致 |
| 16 | `f_rpc/src/macros/RPCSkeleton.cj` | .cj | ✅ | 属性解析静默退化（发现）；`args[$i]` 无越界保护（由服务端 catch 兜住，见第 2 部分） |
| 17 | `f_rpc/src/macros/RPCStub.cj` | .cj | ✅ | 未知属性静默忽略（发现）；属性带默认实现被跳过（轻微） |
| 18 | `f_rpc/src/macros/TypeRegistration.cj` | .cj | ✅ | 去重按 `toTokens().toString()` 文本比较，无界数量级（每接口几十个类型），可接受 |
| 19 | `f_rpc/src/macros/imports.cj` | .cj | ✅ | `identifierRegex` 被两个宏共用，非死代码 |
| 20 | `f_rpc/src/rpc.cj` | .cj | ✅ | 仅 `package` 声明（包锚点），无声明可审 |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 15 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

（本部分发现共 22 条，全部为存量（快照模式无 diff），是否纳入修复待用户决定；不计入本表的待验证假设 4 条。）

## 总评

这套代码的「已知坑」意识很强——`weight` 排除出相等/哈希、累计权重区间、`retryCount` 的 `tried > retryCount`、`unsafeZeroValue` 的段错误、负载均衡桶边界，都在注释里留了现场记录与归档链接，`PoolConfig` 还明确写了「不要在包初始化期读配置」。这是本部分最值得肯定的地方。本部分的问题集中在四处：

1. **故障期不可控**（严重 1 + 一般 3，另有一条退避方案）：`start()` 的状态机没有失败态，初始化抛错会让所有 RPC 线程永久自旋；发现线程首轮在 `try` 之外，配置写错就静默失联；单次调用没有 deadline；发现循环无退避。这四条共同的效果是「一处小故障 → 整机 RPC 挂住且没有明确错误」，优先级最高。
2. **重试语义偏离承诺**（一般 1）：`Command.ERROR` 与类型不符都被当成可重试失败，非幂等接口会被重复执行到重试耗尽，原始错误沉进 `suppressed`。这既是正确性问题也是运维可观测性问题，建议与 README 的「异常聚合上报」一并重新定义。
3. **生命周期不对称**（一般 2）：`services` 只增不删、重建时直接关闭调用线程在用的 `MultiClient`。两者叠加会在滚动发布窗口内同时造成「偶发失败」与「句柄/线程缓慢增长」。
4. **文档与实现漂移**（一般 3 + 轻微 2）：`ServiceMeta` 构造签名与默认值写反、跨进程 trace 是不存在的承诺、8 个 `rpc_codec*` 配置项无表；另有两处小漂移（README_en 漏掉「data 必须能转换为返回类型」、`@RPCStub` 对带默认实现的属性静默跳过与文档措辞不符）。文档在这三处会把使用者直接带进坑里，且都是「两边都能指出来」的硬证据，修复成本低于其误导成本。

建议排期：先修第 1 组（严重 1 条 + 配置解析/发现线程那两条），再统一重试语义与日志脱敏，最后收文档与死代码/重复逻辑。代码整体结构清晰、注释质量高，没有发现设计层面的方向性错误；本部分的风险主要落在异常路径与边界上，而不是主干逻辑。

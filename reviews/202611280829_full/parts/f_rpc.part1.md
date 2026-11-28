# f_rpc 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rpc`（模块共 24 个源文件；本部分 15 个，其余 9 个见第 2 部分）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce643a`，`git blame` 逐条核对）；快照模式无 diff，全部缺陷记「存量」
- **审查重点**：RPC 客户端 / 消息与类型身份 / 类型注册 / 宏生成 / 健康检查的正确性、序列化边界、并发安全、资源释放、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，后续与第 2 部分合并为 `f_rpc_review_20261128.md`）

本部分覆盖文件（15 个 `.cj`，含 2 个 `_test.cj`，无 `.md`）：`src/RpcTestSetup_test.cj`、`src/encodedmessage_release_test.cj`、`src/base/{ControllerTraceAspect,PoolConfig,RPCException,RPCMessage,RPCTypeRegistration,imports}.cj`、`src/client/{ClientConfig,RPCClient,imports}.cj`、`src/health/HealthRPC.cj`、`src/health/server/HealthRPCImpl.cj`、`src/macros/{RPCSkeleton,RPCStub}.cj`。
说明：`workdir` 下不存在 `files/f_rpc.txt`，文件清单以任务给定列表为准，已与 `f_rpc/src` 实际文件逐一对齐；`src/macros/TypeRegistration.cj`（`collectRPCTypes` 的实现）归第 2 部分，本报告只按调用契约使用它。

## 发现

### [严重][存量] 服务发现的内层重连循环无退避、无次数上限，单节点不可用即紧循环刷错误日志并永久卡死发现流程

- **位置**：`src/client/RPCClient.cj:94-108`（重试循环 `95-104`，错误日志 `102`）
- **来源**：存量（`git blame` d459fdb662 2026-08-30 建循环、0675205da2 2026-09-08 补日志、b929673847 2026-09-26 改 `unsafeZeroValue` 占位）
- **判据**：review-checklist §5（无界增长：日志洪水）、§6.2 / §12.1（同步缺失导致的线程独占）、§11（错误处理缺失）
- **证据**：静态确定 —— `for((host, weight) in hostMap)` 内是 `while(true){ while(true){ try{ client = ...build(); break } catch(e){ rpclog.error(...) } } ... }`：`catch` 分支既没有 `sleep`，也没有尝试计数，`break` 只在 `build()` 成功时才发生。
- **描述**：`Client.builder(...).build()` 会 `TcpSocket.connect()`（`f_net/src/client/client.cj:427-435`）。节点进程挂了但主机在线时 `connect` 立即 `ECONNREFUSED`，循环以微秒级周期重复「建 socket → 失败 → 写一条带完整异常栈（含 `toString()` 的 875B 级堆栈，见 `.autocode/bugs/bug-archived-on-20261004.md` 关于 ErrorMessage 的同类记录）的 ERROR 日志」，后果有三：① CPU 单核占满、② 日志文件每秒上万行（磁盘可被打满）、③ 该轮发现永远走不到 `metas` 汇总与后续 `for((meta, hostSet))`，即**一个坏节点会让所有服务的发现停摆**（`services` 永远拿不到新条目，调用方只能等到 `discoveryTimeout` 后抛 `no available client`）。地址串非法（如 `1.0,host` 缺端口）时 `IPSocketAddress.tryParse(...).getOrThrow()` 也是同步抛错，行为相同。
- **建议**：给重连加指数退避（`100ms` 起、上限 `refreshIntervalSeconds`）+ 最大尝试次数；超过次数后放弃本轮、`continue` 处理下一个 host，并只打一条 WARN 汇总（不要每轮每 host 打全栈 ERROR）；`var client: Client<...> = unsafeZeroValue<...>()` 这个占位值没有任何用途，改成 `Option<Client>` 或把 `build()` 收进 `if (let Ok)` 结构，避免将来误用零值对象。

### [严重][存量] 发现线程首句 `ClientConfig.createClient()` 在 `try` 之外，一次异常即永久终止发现且不会重启

- **位置**：`src/client/RPCClient.cj:39`（`try` 从 `72` 开始、`catch` 在 `141`）、`src/client/ClientConfig.cj:52-60`
- **来源**：存量（`git blame` 9a50cd1200 2026-10-03 / cdf0be348f 2026-10-04）
- **判据**：review-checklist §11（错误处理缺失，失败被静默降级为永久失效）、§12.1（可见性 / 状态机无终态）
- **证据**：静态确定 —— 第 39 行位于 `spawn{ while(true){ ...` 中但**在** `try{`（第 72 行）之前；`started` 已是 `2`（第 153 行），`start()` 第 30-31 行此后直接 `return`，没有任何重启路径。
- **描述**：`ClientConfig.createClient()` 的调用链是 `createClient()`（`ClientConfig.cj:247`）→ `requireServerAddresses()`（`255`）→ `serverAddresses`（`52`），其中 `let arr = addr.split(',')` 后直接取 `arr[1]`：只要 `rpcClient_serverAddress` 少写逗号（把 `1.0,host:1203` 误写成 `1.0host:1203`），立刻抛 `IndexOutOfBoundsException`。该异常逃出 `spawn` 闭包（仓颉里线程体未捕获异常会终止该线程），发现循环就此结束且**不会重建**；`services` 保持空表，所有 RPC 调用都退化成「等 `discoveryTimeout`（默认 5s）后抛异常」。也就是说，一个配置拼写错误从「启动失败并给出明确原因」退化为「服务长时间静默不可用」，正好抵消了 `requireServerAddresses`（`ClientConfig.cj:250-266`）特意做的「缺配置就 ERROR + exit」的设计意图。
- **建议**：把第 39 行移进 `try`，让 `catch` 至少 `warn` 一轮并进入下一轮；`serverAddresses` 解析加校验（`split` 后 `size < 2` → 抛带配置项名与原始值的明确异常），或在 `requireServerAddresses` 里统一校验并在启动期 `exit(1)`。

### [一般][存量] 发现轮次失败时不关闭本轮发现连接，每轮泄漏一组 `Client`

- **位置**：`src/client/RPCClient.cj:39-45`（建连接）、`93`（唯一 `close`）、`141-145`（catch 只打日志）
- **来源**：存量（`git blame` 0675205da2 2026-09-08）
- **判据**：review-checklist §11（资源释放不对称：异常跳过释放）、§12.1
- **证据**：静态确定 —— `clients.close()` 只出现在 `try` 块正常路径末尾（第 93 行），`catch`（141）与 `finally`（143-145）里都没有关闭动作。
- **描述**：`for(client in clients){ ... }` 里任一步抛异常都会跳过第 93 行：`hostMap.add` 重复键、`h.indexOf(',').getOrThrow()`（86）、`Float64.parse`（88）、`ClientConfig.createClient(hosts)`（134/138，`loadbalance` 配错时抛 `LoadBalanceException`）都会触发。异常被外层 `catch` 吞成一条 WARN，而本轮建出的 `Client`（含 socket 与后台检查线程）既不关闭也不进入 `services`，只能等 GC。发现每 `refreshIntervalSeconds`（默认 1s）跑一次，持续失败即持续累积句柄。
- **建议**：用 `finally` 或 resource 语法包住本轮 `clients`：`finally { clients.close() }`（第 93 行的显式 `close` 随之下移），并在 `catch` 里保留首轮/变比的 WARN 而不是每轮全量刷。

### [一般][存量] 重建连接池时先发布新值再关闭旧 `MultiClient`，正在进行的调用会命中 "Client is closed"

- **位置**：`src/client/RPCClient.cj:127-136`（`134` 写表、`135` close）
- **来源**：存量（`git blame` 0675205da2 2026-09-08）
- **判据**：review-checklist §12.1（并发：共享可变状态的替换与使用无隔离）、§11（资源与使用者生命周期不一致）
- **证据**：静态确定 —— `services[meta] = ClientConfig.createClient(hosts)` 后紧接 `clients.close()`；`clients` 是第 127 行从表中取出的**旧**实例，而 `call()`（第 188 行）正在并发使用同一个对象。
- **描述**：`services` 是 `ConcurrentHashMap`，单次 `get/put` 原子，但「取旧值 → 建新值 → 替换 → 关旧值」不是原子操作。发现线程执行到 135 行时，另一个业务线程若已从 188 行拿到旧 `MultiClient`，其 `client.transfer(...)` 会因 `Client.close()` 立刻失败；`retryCount` 默认 0 时这次调用直接失败（进 `ex` 聚合）。节点集合每次上下线都会触发一次，属于「扩容/摘节点瞬间的偶发调用失败」。
- **建议**：延迟关闭（替换后把旧实例丢给一个延迟队列，等 `checkDuration` 之后再 `close`），或引用计数；最低成本是重试次数默认值不为 0 时把「`Client is closed`」这一类错误单列为可重试错误并立即换下一个 client（当前的重试语义已经换 client，只是默认不重试）。

### [一般][存量] 一次性初始化标记无失败回滚，且等待方是无超时自旋，初始化抛异常会挂死后续调用线程

- **位置**：`src/client/RPCClient.cj:30-35`、`153-156`；`src/base/PoolConfig.cj:81-89`
- **来源**：存量（`git blame` 9a50cd1200 2026-10-03 / 0675205da2 2026-09-08）
- **判据**：review-checklist §12.1（检查-然后-写入 / 状态机终态缺失）、§11（错误处理缺失）
- **证据**：静态确定 —— `started.compareAndSwap(0, 1)` 成功后依次执行 `initCodecPools()`、`spawn{...}`、`ExitCallbacks.atExit(252, ...)`、`started.store(2)`，中间没有任何 `try/finally` 把 `started` 复位；等待分支是 `while(started.load() != 2){}`（无 `sleep`、无超时、无失败标志）。`initCodecPools()` 同样是 `compareAndSwap(false, true)` 后直接调 `DefaultCodec.setBufferPool/setBytesPool`（`DefaultCodec.cj:73-84` 内部构造 `ArrayPool` 会校验参数），中途抛异常则两个池只初始化一半且**永不再重试**。
- **描述**：两个后果。① 配置错误（如 `rpc_codecBufferPoolMinSize` 大于 `maxSize`、`rpc_codecBytesPoolArraySize` 非法）时 `initCodecPools()` 抛异常 → `started` 永远停在 1 → 所有已经进入 `start()` 的其他线程在 155 行**空转永久阻塞**（不抛错、不超时，进程表现为 CPU 100% 且业务全挂）；② 即使不挂，自旋期间也在纯烧 CPU（仓颉 `AtomicInt8.load` 是原子读，循环体没有 `yield`）。
- **建议**：状态位改成四态（0 未开始 / 1 进行中 / 2 成功 / 3 失败），初始化主体放 `try{...}catch{ store(3); throw }`；等待方改为「`sleep(1ms)` 轮询 + 超时 + 失败态直接抛 RPCException」，或直接用 `Mutex` + `Condition` 做一次性初始化。

### [一般][存量] RPC 调用与服务发现都用 `transfer(...).get()`，没有任何调用级超时

- **位置**：`src/client/RPCClient.cj:203`（业务调用）、`44` 与 `77`（发现请求）
- **来源**：存量（`git blame` 0675205da2 2026-09-08）
- **判据**：review-checklist §11（契约：呼叫无超时）、§12.1（Future 无界等待）、§5（线程堆积间接放大内存）
- **证据**：静态确定 —— `f_net` 同时提供 `transfer(message): MessageFuture<Message>`（`f_net/src/client/client.cj:322`）与带超时的 `transfer(message, timeout): ?Message`（`325-334`，内部 `future.tryGet(timeout)`），本模块三处都用了前者再 `get()`。
- **描述**：`rpcClient_readTimeout` 未配置（README 标注默认「无」）时，服务端进程卡住（不是断开，例如 Full GC 抖动、死循环、对端网卡 hang）会让调用线程在 `get()` 上无限期阻塞。RPC 线程池被逐个占满后，`ControllerTraceAspect` 之外的业务线程也会排队，最终表现为整个应用假死——而 `retryCount` 与 `discoveryTimeout` 都帮不上（它们只覆盖「拿到异常之后」）。
- **建议**：为 RPC 调用引入独立超时（新配置项如 `rpcClient_callTimeout`，或复用 `readTimeout`），改用 `future.tryGet(timeout)`；超时按可重试错误处理并给异常带上「服务名 + 主机 + 已用时长」。

### [一般][存量] 服务端 `ERROR` 被当作传输失败重试，最终抛出空消息的 `RPCException`，且 AtMostOnce 下可能重复执行

- **位置**：`src/client/RPCClient.cj:206-220`（`218` 抛业务错误）、`221-231`（同一 `catch` 当传输错误处理）
- **来源**：存量（`git blame` 0675205da2 2026-09-08）
- **判据**：review-checklist §11（错误处理：失败路径当重试路径）、§10 正确性（业务异常语义丢失）
- **证据**：静态确定 —— `case Command.ERROR => throw RPCException(data.toString())` 位于第 202 行 `try{` 的作用域内，紧接的 `catch(e: Exception)`（221）会 `tried++` 并继续下一轮 `for(client ...)`。
- **描述**：① 服务端业务异常（含限流、反序列化失败）会被当成网络问题重试 `retryCount` 次，`qos: AtMostOnce` + `once: true` 只是**不希望**重复，实际是客户端重发，非幂等服务（下单、扣款）会被执行多次；② 重试用尽后 `throw ex`，而 `ex` 是 `RPCException()` 空参构造（227）再 `addSuppressed(e)`，**主消息为空字符串**，调用方日志里只能看到一条无 message 的 `RPCException` + suppressed 链，排查体验极差（`retry count exceeded` 也只在 `ex` 为空时才当主异常）。
- **建议**：把 `Command.ERROR` 分支移出重试 `try`（先 `match(resp.command)` 判 `ERROR` 直接抛业务异常，只对 `transfer` 本身失败重试）；主异常用 `RPCException("rpc call <type>.<method> failed after ${tried} attempt(s)", e)` 之类带上下文的构造。

### [一般][存量] `ControllerTraceAspect` 每个 HTTP 请求都把全部入参符号化并写 INFO 日志

- **位置**：`src/base/ControllerTraceAspect.cj:33-43`（序列化 `36-41`，INFO `43`）
- **来源**：存量（`git blame` 45cdcfe6a1 2026-09-06）
- **判据**：review-checklist §10 安全性（敏感数据进日志）、fountain-baseline §6（日志中不得出现凭据、令牌、完整报文）、perf §9.1（日志放大）
- **证据**：静态确定 —— 第 36-41 行对 `args` 全量 `toData()` → `JsonValue.from(...)` → `toString()`，第 42 行拼进 `invocation`，第 43 行 `log.info(...)`；这些计算在 `log.info` **之前**完成，因此即使 INFO 被关掉也照样做全量序列化。
- **描述**：该切面按 `@AspectRoute` 命中所有 `fountain::f_mvc.{Get,Post,Put,Delete,Patch}Mapping`，即每个 HTTP 请求都会把全部入参（登录口令、令牌、完整表单、文件 base64 之类）**明文**写进 INFO 日志；这既违反本仓日志规范，也构成一条稳定的敏感数据外泄面（日志文件通常权限更宽、会被采集到集中式日志平台）。附带成本：每请求一次全量 `toData` + `JsonValue` + 字符串拼接（见 O2）。
- **建议**：默认只记录「方法限定名 + 参数个数 + 类型名 + trace」，参数体放到独立的 DEBUG 开关后面（`log.debug{...}` 惰性块 + 显式配置项），并对 `password`/`token`/`Authorization` 等字段名做脱敏；无论如何不应在 INFO 落全量报文。

### [一般][存量] `finally` 里构造完整日志，异常会覆盖正在进行中的异常

- **位置**：`src/client/RPCClient.cj:237-245`（`infoLog<LogMessage>`）、`src/base/ControllerTraceAspect.cj:44-49`
- **来源**：存量（`git blame` 0675205da2 2026-09-08 / 45cdcfe6a1 2026-09-06）
- **判据**：review-checklist §11（错误处理：`finally` 抛异常吞掉原异常）、§12.1
- **证据**：静态确定 —— 两处 `finally` 内都没有 `try/catch`：`infoLog<LogMessage>(...)` 会走 `logmsg` → `JsonValue.from(message.toData())`（`src/base/imports.cj:39-41`），序列化 `RPCMessage` 时会读 `trace` 属性（`RPCMessage.cj:32-43`），进而 `MessageID()`；`ControllerTraceAspect` 的 `finally` 里拼接 `invocation` 已是现成字符串，但 `log.*` 本身也可能因 logger 关闭/磁盘满抛错。
- **描述**：`RPCMessage.trace` 的 getter 在 `trace_` 为空时调用 `currentTrace()`（`RPCMessage.cj:45-53`）→ `MessageID()`，而 `MessageID` 在 `hostId == 0` 时抛 `IllegalArgumentException`（`f_protocol/src/default/MessageID.cj:29-32`）。也就是说，**失败路径上写日志这一步本身会抛异常**，把真正的传输/业务错误覆盖成一条与根因无关的异常（仓库里已有同类教训：`RPCClient.cj:183-184` 的注释就是为这个段错误留下的）。`ControllerTraceAspect` 的 `finally` 同时承担 `clearCurrentTrace()`，一旦日志抛错，清理也会被打断。
- **建议**：`finally` 内统一 `try{ ... }catch(e){ /* 记录到 stderr 或计数 */ }`；或把日志构造改为惰性且不可能抛错的形态（trace 取不到就写 `-`）。

### [一般][存量] 负载均衡权重语义错配：`meta.weight != 1.0` 时用「首个节点」的权重覆盖全部主机

- **位置**：`src/client/RPCClient.cj:110-121`（判定 `114-119`）、`40`（`metas` 键）
- **来源**：存量（`git blame` 0675205da2 2026-09-08）
- **判据**：review-checklist §11（语义与注释不符）、§10 正确性（分发比例错误）
- **证据**：静态确定 —— `metas` 是 `HashMap<ServiceMeta, TreeSet<String>>`，而 `ServiceMeta` 的 `equal/hash` 明确排除 `weight`（`RPCMessage.cj:79-83` 的注释与 `@DataExclude[equal hash]`），因此同名的多节点 meta 只保留**第一个插入的实例**；第 114 行 `if(meta.weight != 1.0){ meta.weight } else { hostMap.get(host) ?? 1.0 }` 用这个实例的 weight 给 `hostSet` 里**所有**主机赋权。
- **描述**：节点 A 以 `weight=2.0` 注册、节点 B 以默认 `1.0` 注册同一服务时，`metas[S]` 先插入哪个取决于发现遍历顺序，之后 A、B 都拿到同一个权重（2.0 或 1.0），B 自己上报的 `host:port,weight`（`RPCServer.cj:137` 的 `serviceHosts.add`、`152-160` 的发布）被丢弃。若 `@RPCSkeleton[weight=...]` 本意是「服务级权重，覆盖节点权重」，那 `hostMap` 的解析与缺省 `?? 1.0` 就是死路径；若是「节点级权重」，这里就是明确的分发比例错误。两种意图只能有一个成立，当前实现各占一半。
- **建议**：统一语义——节点级权重时删掉 `meta.weight` 分支（`weight` 字段也可移出 `ServiceMeta`，顺带去掉 `@DataExclude[equal hash]` 这类易错标注）；服务级权重时删掉 `hostMap` 的权重解析，并给 `metas` 键加上 weight 或在文档写明「服务权重优先、节点权重被忽略」。

### [一般][存量] `ServiceMeta` 版本号截断不校验段数，`version='1'` 会让首次调用抛下标越界

- **位置**：`src/base/RPCMessage.cj:86-98`（`90-91` 为 `v[0]`/`v[1]`）；入口 `src/macros/RPCStub.cj:65-74`
- **来源**：存量（`git blame` c1e5e63be8 2026-08-13 / 51aa3da3fd 2026-08-19）
- **判据**：review-checklist §11（边界越界）、§3（契约声称的输入格式未校验）
- **证据**：静态确定 —— `'1'.split('.')` 长度为 1，第 91 行 `v[1]` 抛 `IndexOutOfBoundsException`；`RPCStub` 的属性校验只拦「空版本」与「当作配置项解析」（`RPCStub.cj:65-74`），注释里写的「version 包含两位或三位版本数字」（`RPCStub.cj:26`）没有任何代码校验。
- **描述**：`@RPCStub[version='1']` 能通过宏展开，错误要到**第一次 RPC 调用**构造 `ServiceMeta` 时才以 `IndexOutOfBoundsException` 出现（堆栈指向宏展开处，与配置项无关联提示）；`version='1.'` 之类同样一路放行。考虑到版本号决定了客户端与服务端能否匹配，这类错误越早失败越好。
- **建议**：在 `ServiceMeta` 构造（或 `RPCStub` 展开期）校验 `split('.')` 段数为 2 或 3 且每段可解析为整数，否则 `diagReport(ERROR, ...)` 指明期望格式；`ServiceMeta` 内再兜一层 `getOrThrow` 带上下文。

### [一般][存量] `ControllerTraceAspect` 隐式依赖 `protocol_hostId`，未配置时首个 HTTP 请求即抛异常

- **位置**：`src/base/ControllerTraceAspect.cj:33` → `src/base/RPCMessage.cj:45-53`（`MessageID()` 在 `49`）→ `f_protocol/src/default/MessageID.cj:29-32`
- **来源**：存量（`git blame` 45cdcfe6a1 2026-09-06）
- **判据**：review-checklist §11（契约与实现不符：埋点切面把可选依赖变成硬依赖）、§10 正确性
- **证据**：静态确定（链路）—— `proceed` 第一行就 `RPCMessage.currentTrace()`；`currentTrace()` 在 ThreadLocal 为空时 `MessageID()`；`MessageID` 在 `hostId == 0` 时抛 `IllegalArgumentException`，而 `ProtocolConfig` 的默认值就是 `0`（`f_protocol/src/default/ProtocolConfig.cj:22-25`）。触发条件是「f_rpc 已加载 + 未配 `protocol_hostId` + 存在 MVC 控制器」——三者的组合面（例如只跑 HTTP 但依赖链里带了 f_rpc 的进程）**待确认**，仓库测试里靠 `RpcTestSetup_test.cj:22` 显式 `Config.set(protocol_hostId, 1)` 才能跑通，说明测试环境同样踩过这个前置条件。
- **描述**：日志埋点本应「拿不到链路 id 就降级」，实际却让每个被切面拦截的控制器方法在进入业务前抛 `IllegalArgumentException`（500）。由于异常发生在 `point(...)` 之前，业务体一次都不会执行。
- **建议**：`currentTrace()` 里对 `MessageID()` 做兜底（catch 后返回进程内自增 id 或 `-`），或在切面里先判 `Config` 是否配了 `protocol_hostId`，未配时跳过 trace 只记方法名。

### [轻微][存量] 死代码 4 处

- **位置与证据**：
  1. `src/client/ClientConfig.cj:244-246` `internal static func createClient(hosts: Array<String>)`：全仓搜索 `createClient` 只有 `183`（带权重重载）、`247`（无参）被调用，本重载零引用（`internal` → 本包及子包范围已搜完）。
  2. `src/base/imports.cj:48-50` `errorLog(id, label, command, e: Exception)`：模块内两个 `errorLog` 调用点（`RPCClient.cj:223`、`RPCServer.cj:27`）分别命中 5 参（`T, e`）与 4 参 `String` 重载，本重载无调用者；顶层 `protected` 无引用即死代码。
  3. `src/client/RPCClient.cj:91` `let ok = subscribe(client, false)`：`ok` 赋值后从未读取（同时丢掉了「该节点的元数据收集失败」这一信号，见下文建议）。
  4. `src/client/RPCClient.cj:18` `HashSet`：全文件只在 `import` 行出现（其余集合类型 `TreeSet/TreeMap/HashMap` 均有使用）。
- **判据**：review-checklist §1（无调用者 / 读了不用 / 未使用的 `import`）
- **来源**：存量（`git blame` b929673847 2026-09-26 / f8c91ac435 2026-08-15 / 0675205da2 2026-09-08）
- **建议**：删除 1、2、4；第 3 处改为 `if (!subscribe(client, false)) { rpclog.warn(...) }`，把「本轮某节点汇总失败」显式化，而不是静默丢一个 bool。

### [轻微][存量] 重复逻辑 2 组：`tryFromData` 三段式强转、`checker()`

- **位置**：
  - `src/client/RPCClient.cj:45-50` 与 `79-84`：`Array<X>.tryFromData(...)` 后 `match(any){ case x: X => x; case x: ?X => x ?? []; case _ => [] }` 逐行对齐，只有元素类型（`ServiceMeta` / `String`）不同。
  - `src/base/imports.cj:64-66` 与 `src/client/ClientConfig.cj:184-186`：两个 `checker(): ?Message` 函数体都是 `Message.ping()`；`ClientConfig` 里的局部版遮蔽了模块级 `checker`，`RPCClient.cj:99` 用的又是模块级那个。
- **判据**：review-checklist §2（只改类型名 / 字面量复制）
- **证据**：静态确定 —— 两处 match 分支与兜底完全一致；两个 `checker` 体一致，`Message.ping()`（`f_protocol/src/default/Message.cj:247-249`）无参数，无行为差异。
- **描述**：第 1 组属于「只改类型名」的泛型可抽取点（`func tryArray<T>(data: Data): Array<T>`），后续新增一种数组解析时容易只改一处、漏另一处；第 2 组是纯冗余，`ClientConfig` 的局部 `checker` 会让人误以为客户端与发现连接用的是两套探活。
- **建议**：第 1 组抽成 `private func tryArray<T>(data: Data): Array<T>`（放 `RPCClient` 内即可，不改分层）；第 2 组删除 `ClientConfig` 的局部定义，直接引用 `f_rpc.base` 的 `checker`。

### [轻微][存量] `unsafeZeroValue` 当默认值，产出字段引用为空的「僵尸对象」

- **位置**：`src/base/RPCMessage.cj:22-23`（`EMPTY_META = unsafeZeroValue<ServiceMeta>()` 作为 `meta` 初值）、`src/client/RPCClient.cj:253-255`（`LogMessage.init()` 用 `unsafeZeroValue<RPCMessage>()`）
- **来源**：存量（`git blame` c312328fb8 2026-08-20 / e5de733f3c 2026-08-21）
- **判据**：review-checklist §11（空值未处理 / 未初始化引用）
- **证据**：静态确定（风险路径）—— `ServiceMeta` 的 5 个字段是 `String`/`Array<String>`，`unsafeZeroValue` 给出的是零位模式而非 `ServiceMeta()` 的字段初值；`RPCMessage()` 无参构造直接把 `meta` 置为该零值。`RPCMessage` 的 `dataFields()` 创建器正是 `RPCMessage()`（`.macrocall` 中 `ObjectFields.getObjectFields<RPCMessage>{([...], {=> RPCMessage()})}`），反序列化数据若缺 `meta` 字段就会留下这个零值 `meta`，之后任何 `meta.typeName/version` 读取都是对空引用的解引用。`LogMessage()` 同理：它是 `public` 的默认构造，序列化它就会访问零值 `RPCMessage`。仓库内已有同类事故记录（`RPCClient.cj:183-184`：「不能 `unsafeZeroValue<Message>()` … 会段错误」）。
- **建议**：`EMPTY_META` 换成 `ServiceMeta()`（一次小分配，可忽略），或把 `meta` 声明为 `?ServiceMeta` 并在读处显式判空；`LogMessage.init()` 的默认构造改为 `LogMessage(RPCMessage())` 至少让字段合法。

### [轻微][存量] `RPCStub` 属性解析静默忽略未知属性；`genStub` 用 `catch(_){}` 吞异常

- **位置**：`src/macros/RPCStub.cj:41-64`（`case _ => ()` 在 `61`）、`77-82`（`catch(_){}`）
- **来源**：存量（`git blame` 早期提交）
- **判据**：review-checklist §3（静默吞掉 / 空 `catch`）、§1（无效分支）
- **证据**：静态确定 —— 属性扫描对任何非 `name/version/exactlyVersion` 的 token 直接 `i++` 跳过，不 `diagReport`；`genStub(exactlyVersion, version, name, decl)` 开头的 `try{ decl.genericParam; diagReport(ERROR,...); throw RPCException() }catch(_){}` 里，`catch` 同时吞掉了自己刚 `diagReport` 之后抛的 `RPCException` 与 `decl.genericParam` 的「无泛型参数」探测异常——用异常做控制流。
- **描述**：`@RPCStub[versoin='1.0']`（拼错）不会报错，`version` 静默保持 `'*'`，客户端从此按通配版本匹配服务端；这类拼写错误在启动期完全无感知，直到运行期匹配不到服务才暴露。`catch(_){}` 也会吞掉 `diagReport` 内部的异常（诊断未送达时编译仍继续）。
- **建议**：`case _ =>` 分支改为 `diagReport(ERROR, attr[i], 'unknown attr ...')`；泛型参数检测改成显式判断（`decl.genericParam.size > 0` 或 `isGenericDecl`），去掉 `try/catch` 控制流。

### [轻微][存量] `RPCSkeleton` 生成的参数解包不校验 `args` 个数

- **位置**：`src/macros/RPCSkeleton.cj:99-124`（生成 `args[$i]` 于 `111`）
- **来源**：存量（`git blame` 早期提交）
- **判据**：review-checklist §11（边界：数组下标未校验）、§3（错误信息缺失）
- **证据**：静态确定 —— `extractParams` 对第 `i` 个形参无条件生成 `FountainDataConvert<T>(args[$i].data).getOrThrow()`，没有任何 `args.size` 比较。
- **描述**：客户端与服务端版本不一致时（这正是 `version` 配置想支持的场景），参数个数更少的一方会触发 `IndexOutOfBoundsException`；服务端虽然会 `catch` 成 `ERROR` 响应（`RPCServer.cj:175-178`），但客户端看到的是与参数契约无关的越界堆栈，排查成本高。参数更多时多余参数被静默丢弃，也不告警。
- **建议**：生成 `if (args.size != N) { throw RPCException("...expects N args, got ${args.size}") }` 前置校验，或在 `ServiceHub.call` 里按 `argTypeNames` 校验。

### [轻微][存量] `EXCEEDING` / `UNSUPPORTED_COMMAND` 全仓零引用，README 承诺的限流与「不支持命令」ERROR data 未接线

- **位置**：`src/base/imports.cj:31-32`
- **来源**：存量（`git blame` 早期提交）
- **判据**：review-checklist §14（承诺了但没实现 / 接线缺失）、§13（文档与实现不一致）
- **证据**：静态确定 —— 全仓（除 `worktrees/`）搜 `EXCEEDING`、`UNSUPPORTED_COMMAND`、`ServerExceeding`、`UnsupportedCommand` 只命中定义本身与 `README.md:326/520/535`；`f_rpc/src` 内搜 `RateLimiter|rateLimiter` 无任何结果。
- **描述**：README 的「限流器配置」整节（4 种算法 + `rpcServer_rateLimiterName`）与「`ERROR` data 为 `ServerExceeding` / `UnsupportedCommand`」在 `f_rpc` 源码里找不到实现与引用；两个 `public const` 因此只剩「对外可达的常量」这一身份（按硬原则一不判死代码）。究竟是限流由别的模块实现、还是这部分能力整体未接线，需要第 2 部分（`RPCServer`/`ServiceHub`）与本条合并确认。
- **建议**：先确认归属：若限流确由 `f_rpc` 负责，补实现并在限流分支使用 `EXCEEDING`；若由外部模块负责，把两个常量删除或移到真正使用它的模块，并修正 README 的表述。

### [轻微][存量] 发现连接硬编码 `checkDuration: Duration.second`，忽略 `rpcClient_checkDuration`

- **位置**：`src/client/RPCClient.cj:99`；对照 `src/client/ClientConfig.cj:188-194`（业务连接用配置值）
- **来源**：存量（`git blame` b929673847 2026-09-26）
- **判据**：review-checklist §2（配置读取不一致导致的行为漂移）、§14（配置项被读取却未覆盖全部路径）
- **证据**：静态确定 —— 同一模块两条建连路径对 `checkDuration` 的取值不同：业务连接走 `checkDuration` 属性（`ClientConfig.cj:77-81`，默认 1s），发现连接写死 `Duration.second`。
- **描述**：用户把 `rpcClient_checkDuration` 调大/调小以期控制探活开销时，发现连接不受影响；调小到 `100ms` 想加快故障发现时同样无效（发现连接仍 1s）。默认值恰好相同，因此只在显式配置时暴露，属于难以定位的「配了不生效」。
- **建议**：改为 `checkDuration: ClientConfig.checkDuration`（需要把该属性从 `private` 提到 `internal`，与 `retryCount`/`discoveryTimeout` 同级）。

### [轻微][存量] `services` 只增不删，已消失的服务条目与其连接常驻

- **位置**：`src/client/RPCClient.cj:127-140`（只 `get`/赋值，无 `remove`）、`148-152`（退出时才统一关闭）
- **来源**：存量（`git blame` 0675205da2 2026-09-08）
- **判据**：review-checklist §5（全局集合只增不减）、§11（资源生命周期）
- **证据**：静态确定 —— 全文件对 `services` 只有 `get`（127、168）、下标赋值（134、138）与退出遍历（149），没有删除路径；重建判据是「同一 meta 的主机集合变化」，服务**整体消失**时循环根本不会看到该 meta。
- **描述**：服务下线后对应 `MultiClient` 与其 socket、检查线程一直保留到进程退出；`availableClients` 仍会立即返回这个「全死」的客户端，于是调用方每次都要经历「换节点重试 → 失败」而不是快速失败。条目数受服务数约束（不构成无界增长），故定为轻微。
- **建议**：在发现轮次结束后对比本轮 `metas` 的键集合，对不在本轮结果里的条目 `remove` 并 `close()`（注意与 #4 的「正在使用」问题共用延迟关闭机制）。

### [轻微][存量] 8 个 `rpc_codec*` 配置项未进入 README 配置表

- **位置**：`src/base/PoolConfig.cj:36-49`
- **来源**：存量（`git blame` `PoolConfig.cj` 2026-09~10）
- **判据**：review-checklist §14.2（关键配置无文档）、§13（文档与实现一致性）
- **证据**：静态确定 —— `README.md`/`README_en.md` 只在模块表里提了一句「`rpc_codec*` 池配置」（`README.md:26`），「客户端配置（前缀 rpcClient）」表（`README.md:477-500`）与服务端配置表里都没有这 8 个键（`codecBufferPoolInitSize/MinSize/MaxSize`、`codecBytesPoolInitSize/MinSize/MaxSize/ArraySize`、`codecPoolMaxWaiting`），也没有默认值说明。
- **描述**：池耗尽直接表现为 RPC 编码阻塞/超时（正是 `PoolConfig.cj` 注释里 `.autocode` 7.6 记录的历史故障），而调参入口没有任何文档；使用者只能读源码。`codecPoolMaxWaiting` 的「`≤0` = 真无限等待」这种反直觉语义尤其需要写明。
- **建议**：在 README 增加「codec 池配置」表（8 个键 + 类型 + 默认值 + 何时需要调整），并注明 `rpc_codecPoolMaxWaiting` 的 `≤0` 语义；中英两版同步。

## 优化可行性方案

> 下列均为「还能更好」，无改前/改后对照数据，`证据状态` 一律为 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [CPU] O1 stub 每次调用重建 `ServiceMeta` 与 `TypeInfo` 并重算 hash

- **现状**：`RPCStub` 生成的每个方法体都在**调用期**执行 `TypeInfo.of<接口>().qualifiedName`、每个实参 `TypeInfo.of<参数类型>().qualifiedName`、`Array<String>` 拼装、`ServiceMeta(...)` 构造，再以该对象做 `services` 查询（`RPCClient.cj:168`）。`ServiceMeta.hashCode()` 首次调用要哈希 5 个字符串 + `argTypeNames.toString()`（`RPCMessage.cj` 生成的 `hashCode`）。对象数/字节量随 QPS 线性增长，生命周期仅一次调用。
- **方案**：把 meta 的不可变部分（`version/name/typeName/methodName/argTypeNames`）沉到 stub 类的 `static let` 里，调用期只构造 `RPCMessage(meta, args)`；`services` 键改用 `String` 组合键或直接复用该静态 meta。
- **预期**：每次调用省 1 个 `ServiceMeta` + 1 个 `Array<String>` + N 次 `TypeInfo.of` + 一次字符串哈希；具体比例需实测。
- **代价**：stub 生成代码变复杂；`version/name` 来自宏属性与配置，静态化后不再随配置热变更（本仓本来就是启动期读一次配置，无影响）。
- **验证**：`cjpm bench -O2` 对照 10k 次空参/单参调用，取中位数与 P95；`cjprof record` 看 `ServiceMeta.hashCode`/`TypeInfo.of` 的 self time 占比。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] O2 `ControllerTraceAspect` 无条件符号化全部入参

- **现状**：每个 HTTP 请求都要 `args[i].toData()` + `JsonValue.from` + `Array.toString()` + 字符串插值（`ControllerTraceAspect.cj:36-42`），与大对象入参（分页查询结果、上传描述）成正比；日志级别关闭时这些计算照做。
- **方案**：先判日志级别（`log.isInfoEnabled()` 之类），再决定是否序列化；把参数体降级到 DEBUG 惰性块；对体积设上限（超长截断）。
- **预期**：省掉一次与请求体等量的序列化 + 两次中间字符串；端到端收益取决于控制器方法本身耗时，需实测。
- **代价**：trace 日志信息量下降（可接受，见 #8 的安全理由）。
- **验证**：同一组请求（1KB / 100KB 入参）在 INFO 开/关两种配置下对比 QPS 与 `cjprof` 中 `JsonValue` 相关自耗时。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] O4 每次 RPC 调用把完整请求/响应写 INFO

- **现状**：`RPCClient.call` 的 `finally` 用 `infoLog<LogMessage>` 记录 `RPCMessage`（含 `params`）+ `DataAny` 响应 + `consumed`（`RPCClient.cj:237-245`），服务端对应 `RPCServer.cj:172` 同样记录（服务端侧归第 2 部分）。INFO 开启时，单次调用要额外序列化一份请求与一份响应并落盘。
- **方案**：默认只在 DEBUG 落全量，INFO 只留「接口.方法 + trace + 耗时 + 结果大小」；对 `params`/结果做体积上限与字段脱敏。
- **预期**：每次调用少 2 次 `toData`+`JsonValue` 序列化与 2 行磁盘写；高 QPS 下写放大与 GC 压力同步下降。
- **代价**：排障时需要临时打开 DEBUG；日志格式变更会影响既有日志解析规则。
- **验证**：固定 QPS 压测，对比「INFO 全量 / INFO 摘要 / DEBUG 全量」三档的吞吐、P99、磁盘写字节数（`perf §9.3` 要求不只看「关日志后变快」）。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] O3 发现轮次每 `refreshIntervalSeconds` 全量物化服务元数据

- **现状**：每轮（默认 1s）为每个种子节点建 `MultiClient`、把 `Array<ServiceMeta>` 与 `Array<String>` 全量反序列化，再建 `metas: HashMap<ServiceMeta, TreeSet<String>>`、`hostMap: TreeMap<String, Float64>`、每个 meta 一份 `hosts: Array<(Float64,String)>` 与 `StringBuilder`（`RPCClient.cj:39-140`）。服务数 N、节点数 M 时每轮约 `O(N·M)` 个短命对象。
- **方案**：把 `metas`/`hostMap`/`StringBuilder` 提为发现线程的成员复用（`clear()` 后重用）；对 `hostDesc` 这类纯日志字符串只在 DEBUG 开启时构造。
- **预期**：每轮少 3 个容器 + N 个 `StringBuilder` 的分配；稳态 RSS 与 GC 次数下降，幅度需实测。
- **代价**：`clear()` 不归还物理内存（`mem §3.2`），要配合「容量上限」使用；复用容器需注意本轮残留（键必须每轮清空）。
- **验证**：20 个服务 × 5 节点、跑 10 分钟，对比 `getAllocatedHeapSize()` 增速、GC 次数、RSS 稳态。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ServiceMeta` 构造 + `hashCode` + `TypeInfo.of` 在 RPC 调用路径上占比可观（O1） | `src/client/RPCClient.cj:188`、`src/macros/RPCStub.cj:142-153` | 自耗时占比、每次调用分配字节 | `cjprof record` 跑 10k 次 stub 调用；`getAllocatedHeapSize()` 前后差 |
| 2 | 每请求 `JsonValue` 序列化是 HTTP 控制器热点之一（O2） | `src/base/ControllerTraceAspect.cj:36-41` | 该段自耗时占请求总耗时比例 | 对 1KB / 100KB 入参分段计时（进切面前后打点），各 1000 次取中位数 |
| 3 | 发现线程每秒 `O(N·M)` 分配造成 GC 抖动（O3） | `src/client/RPCClient.cj:39-140` | 每分钟分配量、GC 次数与停顿 | 20 服务 × 5 节点稳态跑 10 分钟，采 `cjprof heap` |
| 4 | INFO 级全量请求/响应日志的写放大影响吞吐（O4） | `src/client/RPCClient.cj:240-244` | 日志字节/秒、落盘阻塞时长 | 三档日志配置压测，记录磁盘写字节与 P99 |
| 5 | 发现线程单线程串行处理所有服务，服务数上百时一轮可能超过 `refreshIntervalSeconds` | `src/client/RPCClient.cj:110-140` | 单轮耗时 vs 刷新周期 | 打点「本轮开始/结束」，服务数 10/50/200 各跑 10 分钟 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/RpcTestSetup_test.cj` | .cj | ✅ | 测试前置：`protocol_hostId=1`，反证 #12 的 hostId 硬依赖 |
| 2 | `src/base/ControllerTraceAspect.cj` | .cj | ✅ | 见 #8、#12、O2；另核对 `Aspect.proceed` 语义（`f_aspect/src/Aspect.cj:56`、`Aspects.cj:59-110`），try-finally 作表达式返回值成立，不报返回值丢失 |
| 3 | `src/base/PoolConfig.cj` | .cj | ✅ | 见 #5（标记无回滚）；`maxWaiting` 与 `f_pool` 语义核对一致（`f_pool/src/ArrayPool.cj:31` 注释：`Duration.Max` = 真无限等待）；见 #21 |
| 4 | `src/base/RPCException.cj` | .cj | ✅ | 纯异常定义，4 个构造均对外可达，无问题 |
| 5 | `src/base/RPCMessage.cj` | .cj | ✅ | 见 #11、#15；结合 `.macrocall` 核对 `trace` 已进序列化字段、`weight` 已排除 equal/hash |
| 6 | `src/base/RPCTypeRegistration.cj` | .cj | ✅ | 反射探测 + `catch` 兜底有注释说明（`RPCTypeRegistration.cj:49-51`），属有意的「不登记也不影响调用方」，不算空实现 |
| 7 | `src/base/imports.cj` | .cj | ✅ | 见 #13（`errorLog(e:)` 死代码）、#18（两个常量零引用） |
| 8 | `src/client/ClientConfig.cj` | .cj | ✅ | 见 #2（地址解析）、#13、#14、#19；配置项与 README 表逐项核对，无遗漏项 |
| 9 | `src/client/RPCClient.cj` | .cj | ✅ | 见 #1~#7、#10、#13、#14、#15、#19、#20 |
| 10 | `src/client/imports.cj` | .cj | ✅ | `public import`/`internal import` 双导入的写法与注释一致，无问题 |
| 11 | `src/encodedmessage_release_test.cj` | .cj | ✅ | 两个回归用例（编码缓冲释放、meta 身份）与 #10/#15 的 `weight` 排除设计一致，未发现用例本身缺陷 |
| 12 | `src/health/HealthRPC.cj` | .cj | ✅ | 单方法接口，`@RPCStub` 无属性 → `version='*'`，与 #11 的版本校验相关 |
| 13 | `src/health/server/HealthRPCImpl.cj` | .cj | ✅ | `HealthData()` 不是空实现：其字段全是运行时计算的 `prop`（`f_health/src/HealthData.cj:24-63`），默认构造即完整语义 |
| 14 | `src/macros/RPCSkeleton.cj` | .cj | ✅ | 见 #17、#16（同类 `catch(_){}` 模式）；`weight` 属性解析与模板生成核对无误 |
| 15 | `src/macros/RPCStub.cj` | .cj | ✅ | 见 #11、#16；生成的 stub 体与 `.macrocall` 产物一致 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分文件清单不含 `.md`，§13 文档一致性仅用于交叉核对 README 契约）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | #7（业务错误被当传输错误重试）、#8（敏感数据进日志）、#11（版本截断越界）、#12（埋点切面引入硬依赖）、#16（异常做控制流）、#17（下标未校验）。设计面：`ControllerTraceAspect` 放在 `f_rpc` 而非 `f_mvc`，但以字符串注解名解耦（`ControllerTraceAspect.cj:22`），不构成反向依赖，不单列 |
| §1 死代码 | 1 | 已逐个符号机械搜索：`private`（`EMPTY_META`、`build`、`codec*` 六个配置函数、`requireServerAddresses`、`services`/`started`/`retryCount`）均有引用；`internal`（`retryCount`、`refreshIntervalSeconds`、`discoveryTimeout`、`createClient` 三个重载）中仅 `createClient(hosts:)` 无引用；`protected`（`registerMessage`/`deregisterMessage`/`subscribe`、`initCodecPools`、`checker`、`rpclog`、`errorLog`/`debugLog`/`infoLog` 各重载、`RPC_CODEC_*` 常量）除 `errorLog(e:)` 外均有调用者；`public` 顶层声明（`registerRPCType`、`UNSUPPORTED_COMMAND`、`EXCEEDING`、`RPCMessage`/`ServiceMeta`/`RPCClient`/`ClientConfig`/`LogMessage` 的成员）对外可达，按硬原则一不判。结果见 #13（4 处）、#18（常量仅作信息记录，不作死代码） |
| §2 重复逻辑 | 1 | 已把本部分 5 个文件内 40 余个函数体压成「输入→输出→副作用」两两比对：命中 #14 两组（`tryFromData` 三段 match ×2、`checker()` ×2）。跨文件按相同字面量/正则搜索：`'[FOUNTAIN_RPC.` 前缀统一走 `imports.cj` 的 `logmsg`，无复制；`Message.ping()` 仅上述两处 |
| §3 空实现 | 0 | 逐个核对空体/TODO/`catch {}`：`RPCTypeRegistration.cj:49-51` 的 `catch` 有明确注释（非对象类型不登记不影响调用方），`HealthRPCImpl.health()` 返回的 `HealthData()` 字段是运行时计算的 `prop`（非占位），`ControllerTraceAspect.proceed` 有实际副作用；本部分无 `TODO`/`UnsupportedException` |
| §4 栈溢出 | 0 | 本部分无递归调用（`RPCMessage`/`ServiceMeta`/`ClientConfig`/宏均为线性流程）；宏生成代码无自递归；`f_rpc` 的 `EncodedMessage` 递归在 `f_protocol`，不在本部分 |
| §5 OOM | 0 | 逐处核对「按不可信长度预分配」：`Array<(Float64,String)>(hostSet.size)`、`Array<JsonValue>(args.size)`、`Array<String>(serviceHosts.size)` 的长度均来自本地集合大小而非报文头；`metas`/`hostMap`/`services` 规模受「服务数 × 节点数」约束（见 #20，非无界）；发现轮次的分配问题走 O3（GC 压力，非 OOM） |
| §6.1 热点瓶颈 | 0 | scope 明确「未提供 profile/bench 数据」，本部分所有疑似热点（stub meta 构造、`ControllerTraceAspect` 序列化、发现轮次物化、INFO 日志放大）均只能进「待验证假设」1-5，未当发现 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`；`ConcurrentHashMap`/`AtomicInt8` 无锁内 I/O、解析、回调；性能面的问题表现为自旋（#5），按正确性报，不按锁粒度报 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`；发现线程单线程串行是「一个后台线程按周期刷新全局表」的设计，不构成「形式并发实际串行」，其单轮耗时上限列入待验证假设 5 |
| §6.4 低效算法 | 0 | 逐函数核对复杂度：`hashCode` 一次 O(字段数)、`hostMap`/`TreeSet` 为 O(log n)、`hostDesc` 拼接为 O(节点数)、无嵌套循环匹配；`Array.toString()` 在日志路径上是 O(n) 但 n 为入参个数（见 O2 而非复杂度缺陷） |
| §7 降堆内存方案 | 1 | O3（发现轮次容器复用），标 `无基线（待验证）`；另核对 `clear()` 不归还物理内存、`unsafeZeroValue` 不构成额外堆占用 |
| §8 降 CPU 方案 | 3 | O1（stub meta 构造）、O2（切面序列化）、O4（INFO 全量日志），全部 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | `f_rpc/cjpm.toml` 已开 `--enable-local-mode`；本部分没有「函数内创建、函数内销毁的大对象」（`ControllerTraceAspect` 的字符串逃逸进日志调用，stub 的 meta 逃逸进 `RPCMessage`），改造候选的峰值内存收益无法用数据证明，不立项 |
| §11 现有代码的 BUG（存量） | 21 | 本轮 21 条发现全部为存量（快照模式无基线，逐条 `git blame` 到 2026-08~10 的历史提交，HEAD `8c0ce643a` 仅为合并提交）；覆盖边界（#2、#11、#17）、空值（#15）、错误处理（#7、#9、#5）、资源（#3、#4、#20）、并发（#2、#4、#5）、契约（#6、#10、#12） |
| §12 并发安全与锁粒度 | 3 | 共享路径逐条给出：`services`（`ConcurrentHashMap`，读-替换-关闭非原子 → #4）、`started`（CAS 后无失败回滚 + 无超时自旋 → #5）、`clients` 生命周期（关闭与使用竞争 → #4）。线程封闭的部分：`metas`/`hostMap`/`hosts` 只在发现线程内使用，`RPCMessage`/`ServiceMeta` 为每次调用新建（`ServiceMeta.hashCode` 的 `__hAsh__` 缓存是非原子的幂等写，64 位对齐写在目标平台为原子，不单列）；trace `ThreadLocal` 服务端每消息清理（`RPCServer.cj:124`），客户端线程长期复用同一 id，属设计选择，记入覆盖说明不作缺陷 |
| §14 功能完备性与 README 覆盖 | 2 | #18（限流/不支持命令的 `ERROR` data 承诺无实现，双证：`README.md:520/535` + 全仓搜不到使用点）、#21（8 个 `rpc_codec*` 配置项未入配置表）；`HealthRPC`/`HealthRPCImpl` 与 README 健康检查描述一致，`ClientConfig` 的 22 个配置项与 README 表逐项对齐无缺 |
| 文件覆盖（§13 等） | 15/15 | 本部分 15 个 `.cj` 全部读完；无 `.md`（README/README_en/doc 归第 2 部分），§13 仅用于交叉核对本部分涉及的 README 契约（#18、#21） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

## 总评

第 1 部分覆盖 RPC 客户端的「骨架」：消息/元数据身份、配置、服务发现后台线程、调用重试、宏生成、健康检查。

- **阻塞项（严重）**：#1 与 #2 都指向同一个结构性弱点——**服务发现后台线程没有任何失败边界**。一个节点进程挂掉就能让它进入无退避的死循环刷全栈日志并把发现流程永久停在该 host；一个配置拼写错误就能让它抛出未捕获异常后彻底消失，而 `started` 已置 2、永不重启，调用方只能拿到「等 5s 后 no available client」。这两条合起来使「服务发现」成为整个 RPC 链路最脆弱的一环，建议作为本模块首要修复项。
- **排期项（一般）**：#6（调用无超时）决定了一个卡住的服务端能把调用方线程池整体拖死；#7（`ERROR` 当传输错误重试）在 AtMostOnce 下存在非幂等操作重复执行的语义风险，二者都属于「不修则半可用」；#3/#4/#5 是资源与初始化路径的对称性/原子性缺失；#8/#12 是埋点切面的两个方向——一个把敏感数据写进 INFO，一个把可选依赖变成硬依赖；#9（finally 日志覆盖原异常）会显著抬高线上排障成本；#10/#11 是 meta 语义与配置校验的精度问题。
- **可维护性**：消息与配置的类型定义整体清晰，`RPCMessage`/`ServiceMeta` 的 `weight` 排除说明、`ClientConfig` 的重建/负载均衡注释、`PoolConfig` 的「为什么在这里」注释都是高质量的历史沉淀；问题集中在「后台线程的错误边界」「跨模块契约（`protocol_hostId`、`f_net` 的超时 API）」「日志进主路径」这三块，且都能用很小的改动收敛。
- **代码质量**：宏生成的 stub/skeleton 结构正确（与 `.macrocall` 产物一致），`ServiceMeta` 身份测试与编码缓冲释放回归测试覆盖了历史两个 P0；死代码与重复逻辑各 1 条，属正常存量水平。

存量缺陷共 21 条（严重 2 / 一般 10 / 轻微 9），是否纳入修复待用户决定；建议优先级：#1/#2（发现线程）→ #6（调用超时）→ #7（错误重试语义）→ #8（敏感日志）→ #3/#4/#5。

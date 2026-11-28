# f_jsonrpc 模块审查报告（模块第 2/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jsonrpc`（本部分 10 个 `.cj` + 10 个 `.md`，共 20 个文件；模块整体 32 个 `.cj` + 30 个 `.md`，其余文件属第 1/3/4 部分）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 基线）。本部分所有问题来源均为「存量（快照模式无基线）」，逐条附 `git blame` 依据
- **审查重点**：RPC 协议正确性、批量与错误码、超时与资源、死代码、重复逻辑、存量 BUG
- **报告版本**：v1

## 发现

### [一般][存量] `batch([])` 发出协议非法的空批量：真实服务端回 `-32600`，客户端抛异常；单测用假传输把行为固化成「返回空数组」

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:110-118`（无空输入短路，`JsonArray(list: requests)` 直接序列化成 `[]`）、`:119-142`（按对象/数组分支解析）；单测 `f_jsonrpc/src/client/JsonRpcClient_test.cj:208-213`（`testBatchEmptyInputReturnsEmpty`）；服务端对照 `f_jsonrpc/src/server/JsonRpcServer.cj:135-137`（`'Invalid Request: empty batch'` + `-32600`）
- **来源**：存量（`git blame -L 110,120` → `5fa2b837d8` 2026-10-25「fix(f_jsonrpc): 客户端流式上限、重试边界与响应解析收敛」）
- **判据**：review-checklist §11「契约与实现不符 / 与规格冲突」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 客户端只在 119 行之后处理响应，空数组没有本地短路；服务端 `handleBatch` 第 135 行显式把 `items.size == 0` 判为 `-32600`，客户端 132-139 收到错误对象后 `throw JsonRpcException(-32600, ...)`
- **描述**：`batch(calls)` 的注释承诺「返回与输入同序的响应」，但对空输入既不短路也不返回空数组，而是把 `[]` 发出去——这是 JSON-RPC 2.0 明确禁止的报文（规范：空批量 = Invalid Request），服务端必然拒绝，调用方得到 `JsonRpcException(-32600)` 而不是空数组。单测之所以通过，是因为 `FakeTransport` 直接回 `'[]'`，把「客户端会发非法报文」和「服务端会拒绝」两个事实都绕过去了，测试与真实链路结论相反
- **建议**：`batch` 开头加 `if (calls.isEmpty()) { return Array<JsonRpcResponse>() }`；把 `testBatchEmptyInputReturnsEmpty` 改成断言「`transport.send` 未被调用」（`FakeTransport` 加 `calls` 计数），或换成走 `JsonRpcServer` 的真链路用例

### [一般][存量] 单条 `call` 不校验响应的 `id` 回显与 `jsonrpc` 版本，批量路径却按 id 匹配——错配响应会被当成功

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:86-95`（解析后只取 `error` / `result`）、`:213-219`（`toResponse` 原样带回 `id`，从不比对）、对照 `:121-142`（批量为每条响应按 id 建索引）
- **来源**：存量（blame `e153677c93` 2026-10-24 首次入库；批量 id 匹配为 `5fa2b837d8` 2026-10-25）
- **判据**：review-checklist §10 正确性、§11「契约与实现不符」、§13/§14 协议字段未落地
- **证据**：静态确定 —— `call` 里 `requestBody(method, params, Some(id))` 生成的 id 之后只用于组包，`toResponse` 结果除 `error`/`result` 外没有任何字段被读；全文件搜不到 `'jsonrpc'` 的读取（只有写入，`:183`）
- **描述**：客户端自己发号并期望一一对应，但从不校验响应 `id` 是否等于本次请求 id，也不校验 `jsonrpc == '2.0'`。HTTP 一问一答让错配概率很低，但这是客户端唯一的协议自检点：反向代理/连接复用错位、服务端 bug 回错 id、中间层把通知响应当结果返回时，调用方会拿到别人的结果并认为成功（数据错误，而不是异常）。批量路径已经用 id 建索引证明「按 id 校验」在本模块是被认可的做法，两条路径的严格程度不一致
- **建议**：`call` 里把请求 id 传进比对：`match (response.id) { case Some(rid) if (rid.toString() == id.toString()) => ...; case _ => throw JsonRpcException(INTERNAL_ERROR, 'response id mismatch: expected ${id}, got ...') }`；`jsonrpc` 字段按「缺省容忍、出现则必须为 `2.0`」处理，避免破坏宽松服务端兼容

### [一般][存量] 传输层 HTTP 状态码被丢弃：413 / 5xx 的错误体被当 JSON-RPC 响应解析，错误统一塌缩成 `-32603`

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:292-318`（`send` 只读 headers 与 body，全文无 `response.status`）、`:197-211`（解析失败统一包装 `-32603 malformed json-rpc response`）
- **来源**：存量（blame `5fa2b837d8` 2026-10-25）
- **判据**：review-checklist §11「错误处理缺失」、§13「错误码与规格不一致」
- **证据**：静态确定 —— `HttpJsonRpcTransport.send` 内对 `response` 的使用只有 `headers.getFirst('Content-Length')`、`response.body.read`、`response.close()`；`f_jsonrpc/doc/f_jsonrpc模块设计.md:699` 明确 413 与框架级 5xx 是仅有的非 200 响应
- **描述**：设计规定「请求体超限 → 413、框架级异常 → 5xx」，这两类响应的 body 不是 JSON-RPC 对象（纯文本/HTML）。客户端拿到后走 `parseValue` → 抛 `-32603 'malformed json-rpc response: ...'`，调用方既不知道是 413（该缩请求体）还是 500（该重试/告警），也无法按状态码做降级；`retryOnConnectFailure` 同样无从判断。这是「错误码」在传输层的缺口：状态码信息在进入协议层之前就被丢掉了
- **建议**：`send` 的读阶段先取 `response.status`，`>= 400` 时有界读取（复用 `cap`）后抛携带状态码的异常（新增 `JsonRpcHttpStatusException` 或给 `JsonRpcConnectException` 加 `status` 字段，属 public 契约变更需确认）；最低限度把 status 拼进现有错误消息

### [一般][存量] 重试边界把「等响应头超时」也算作可重试的建连失败——开启重试后非幂等方法可能被执行多次

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:292-296`（`catch (e: Exception) { throw JsonRpcConnectException(...) }`）、`:162-175`（`sendWithRetry` 只认 `JsonRpcConnectException`）、选项定义 `:29-33`
- **来源**：存量（blame `5fa2b837d8` 2026-10-25「重试边界」专项提交）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「异步语义：超时但任务继续跑」、§10 错误处理
- **证据**：静态确定（包装范围）+ 需实测（`readTimeout` 在 `client.send` 内触发的具体时机）——`ClientBuilder().readTimeout(opts.timeout)`（`:265`）的语义是「读取整个响应的超时时间」（`cangjie_stdx/doc/libs_stdx/net/http/http_package_api/http_package_classes.md:546-556`），而 `client.send` 只在拿到响应头后才返回；此间任何异常（读超时、写中断、TLS/DNS 失败）都落进同一个 catch
- **描述**：类注释与 `retryOnConnectFailure` 的注释都承诺「只对建连/发送阶段失败重试；读响应失败不重试——服务端可能已经执行过」。但「请求已完整写出、等服务端响应超时」在实现里被归入可重试的一侧，于是开启 `retryOnConnectFailure: 3` 后，一个耗时超过 `timeout`（默认 30s）的写操作会被重复执行 4 次，副作用叠加。默认值 0 使这个问题只在显式开启时出现，而开启正是文档鼓励用于「网络抖动」的场景
- **建议**：把可重试判定收窄到连接建立阶段（无法细分时至少排除超时类异常与已写出请求后的失败）；若 stdx 无法区分，就把选项改名为 `retryOnTransportFailure` 并在注释写明「可能重复执行，非幂等方法保持 0」，同时把 `JsonRpcConnectException` 的语义从「建连失败」放宽为「传输失败」以免注释与实现继续背离

### [一般][存量] `callAsync` 每次 `spawn` 一个新线程：无并发上限、无请求级超时，注入 transport 时 `timeout` 完全失效

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:97-101`（`spawn { call(...) }`）；`ClientOptions.timeout` 的唯一消费点 `:265`
- **来源**：存量（blame `e153677c93` 2026-10-24）
- **判据**：review-checklist §6.3「`spawn` 形式并发」、§12.1「有界性 / 异步语义」、§5「一次提交全量任务」
- **证据**：静态确定 —— `spawn` 的语义是「创建一个新的仓颉线程」（`cangjie_runtime/stdlib/doc/libs_std/sync/sync_package_overview.md:15`），`callAsync` 没有任何池、信号量或队列；`ClientOptions.timeout` 只传给 `ClientBuilder.readTimeout/writeTimeout`，`init(transport:)` 分支（`:77-80`）只取 `retryOnConnectFailure`，`timeout` 被静默忽略且无注释说明；`Future` 没有 deadline
- **描述**：`callAsync` 是「线程换皮」：N 个并发调用 = N 个线程，N 由调用方循环决定，没有背压；批量并发（`for (...) { futs.add(client.callAsync(...)) }`）在 1k 级就会把线程数推到 1k，线程栈与调度开销随 N 线性增长。同时注入自定义 transport 的调用方以为 `ClientOptions.timeout` 生效，实际没有任何超时手段，`Future.get()` 可以永久阻塞
- **建议**：用 `f_concurrent` 的固定大小执行器（或自建有界队列 + worker）承载 `callAsync`，暴露 `maxInFlight!`；文档标注线程成本；`timeout` 在注入 transport 时改为由 `JsonRpcClient` 侧用带 deadline 的等待实现（或在 `ClientOptions` 注释里明确「仅 HTTP 传输生效」）

### [一般][存量] SSE 客户端只处理「流结束（None）」：读异常直接穿透，既不关连接也不重连，也不包装成 `JsonRpcConnectException`

- **位置**：`f_jsonrpc/src/client/JsonRpcSseClient.cj:65-98`（`match (current.next())` 外层无 `try`）、`:110-135`（`reconnect` 只被 `None` 分支调用）；异常来源 `f_httpclient/src/sse/SseReader.cj:179`（`SseLineTooLongException`）、`:229`（`SseTimeoutException`，默认 `idleTimeout = 120s`，见 `:49`）；错误原因丢失点 `f_jsonrpc/src/client/SocketSseConnection.cj:59-62`
- **来源**：存量（blame `d41a1ec14f` / `ddfd26b45e` 2026-11-10）
- **判据**：review-checklist §11「错误处理缺失 / 资源不对称」、§3「静默吞异常」、§13 契约
- **证据**：静态确定（无 catch；异常类型与默认值见上述行）——`SseReader.next()` 的异常路径是 `throw`，`JsonRpcSseClient.next()` 内只有 `match`，因此异常原样抛给调用方，`connection` 仍指向坏连接；`SocketSseConnection.open` 的 catch 只 `client.close(); None`，把 `e.message` 丢掉
- **描述**：类注释承诺「断线时带 `Last-Event-ID` 重连，最多 `retry` 次；超过则抛 `JsonRpcConnectException`，不静默结束」。实现只把「读端返回 None」当作断线，而真实的网络中断、单行超过 1 MiB、空闲超过 120s 都以异常形式出现：此时既不关闭当前连接（句柄留到 GC/进程退出），也不重连，调用方拿到的是 `SseTimeoutException` 之类的内部异常，重连语义完全失效。`f_jsonrpc` 自己的 SSE 服务端每 15s 发 `: ping`（`f_jsonrpc/src/server/SseStream.cj:41,152`），所以同构部署不易触发；对接无心跳的第三方 SSE 时 120s 必现，且错误信息里看不到服务端返回过什么
- **建议**：把 `current.next()` 包进 `try`：捕获后 `current.close()`、`connection = None`、转入 `reconnect()`，用尽次数时抛 `JsonRpcConnectException('...', cause)`（若异常类型不支持 cause，至少把 `e.message` 拼进消息）；`SocketSseConnection.open` 失败时保留原因供上层日志使用

### [一般][存量] `retry <= 0` 时「流正常结束」被当成连接失败：`next()` 抛 `JsonRpcConnectException` 而不是返回 `None`

- **位置**：`f_jsonrpc/src/client/JsonRpcSseClient.cj:131-133`（`if (retry <= 0) throw ... 'sse reconnect disabled'`）、对照 `:64` 的「连接正常结束返回 `None`」与 `:48` 的 `retry!` 参数
- **来源**：存量（blame `ddfd26b45e` 2026-11-10）
- **判据**：review-checklist §11「语义与命名 / 注释不符」
- **证据**：静态确定 —— `next()` 在 `connection` 为 `None` 或读到流结束时都调用 `reconnect()`；`retry = 0` 使 `while (attempt < retry)` 一次都不执行，直接落到 131 行的 `throw`
- **描述**：`retry` 的语义是「最多重连几次」，取 0 的合理含义是「不重连、流结束即结束」；实现把这种情况下所有结束都变成异常，于是 `retry = 0` 的客户端永远拿不到 `None`：正常收尾与真正失败无法区分，调用方只能 `catch` 后靠字符串判断。这与第 64 行注释直接冲突
- **建议**：`reconnect()` 在 `retry <= 0` 时返回 `false`（由 `next()` 返回 `None`），只在「尝试过且全部失败」时抛；若要保留「禁用重连即视为错误」的语义，则改注释并换成明确的异常类型/错误码（不要复用 `JsonRpcConnectException`）

### [一般][存量] SSE 连接 URL 的 `topic` / `taskId` / `cursor` 未做百分号编码，且不校验 HTTP 状态码

- **位置**：`f_jsonrpc/src/client/SocketSseConnection.cj:44-54`（字符串直接拼接查询串）、`:55-62`（`client.get()` 后不读 `response.status`）
- **来源**：存量（blame `0f065277fd` 2026-11-10）
- **判据**：review-checklist §10 安全性（外部输入未校验）、§11「边界 / 错误处理」
- **证据**：静态确定 —— `full += '${separator}topic=${topic}&taskId=${taskId}'`、`full += '&cursor=${value}'` 没有任何编码步骤；`HttpClient.get()` 直接返回 `HttpResponse`（`f_httpclient/src/httpclient.cj:138-140`），4xx/5xx 不抛异常
- **描述**：`topic` / `taskId` 是调用方传入的标识，包含 `&`、`=`、`#`、空格或非 ASCII 时会改变查询串语义（例如 `taskId='a&topic=x'` 等效于注入一个 topic）或让 URL 非法；`Last-Event-ID` 更危险——SSE 规范允许任意字符串 id，一旦 id 含 `&`/空格，续传直接失效。另外 401/500 的错误体被当作一条 SSE 流读到结束，退化成「重连 N 次后抛 generic 错」，状态码与错误信息全部丢失
- **建议**：用 `f_httpclient` 已有的 `Form` / `FormBuilder`（`f_httpclient/src/httpclient.cj:193-215`，值经 `Form.toEncodeString()` 编码）构造查询串，或补一个最小 RFC 3986 编码工具（当前 SDK 文档里没查到通用 URL 编码 API，`cangjie_runtime/stdlib/doc/libs_std/net/**` 无 URL 类，属待确认）；`open` 里检查 `response.status`，非 2xx 时 `close()` 并带状态码返回/抛出

### [一般][存量] `JsonRpcSseClient` 的可变状态无任何同步，`close()` 与 `next()` 并发时会漏关连接

- **位置**：`f_jsonrpc/src/client/JsonRpcSseClient.cj:43-45`（`connection` / `lastEventId` / `closed` 普通字段）、`:65-98`（读、改 `connection`）、`:100-107`（`close`）、`:124-127`（`reconnect` 写回 `connection`）
- **来源**：存量（blame `ddfd26b45e` 2026-11-10）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性 / 发布逸出」
- **证据**：静态确定 —— 三个字段都是普通 `var`/`let`，类内无 `Mutex`/`Atomic`/`synchronized`，也没有「非线程安全」的类注释；同类 `SseReader` 反而明确声明「非线程安全」（`f_httpclient/src/sse/SseReader.cj:24`），说明本仓库有写这条契约的习惯，此处属于漏写
- **描述**：最自然的用法是「一个线程循环 `next()`，另一个线程 `close()` 取消」。并发时序：T1 读到 `case None`，`connection = None`，进入 `reconnect()` 并通过 `if (closed)` 检查；T2 此时 `close()` 置 `closed = true`、关掉旧连接并返回；T1 随后 `connect(extra)` 成功并 `connection = Some(新连接)`——`close()` 已经返回，新连接再没人关，直到进程退出或下一条事件（此时 `next()` 会继续读一条本该被取消的流）。此外 `closed` 无可见性保证，T1 可能读到旧值。两个并发调用者只要有 `close` 与 `next` 这一对就成立，不需要多读者
- **建议**：二选一并写进类注释：①声明「单线程使用，`close` 必须与 `next` 同线程或由调用方加锁」（最省事，符合已有 `SseReader` 的写法）；②若要支持跨线程取消，`closed` 用 `AtomicBool`，`connection` 的发布/清理放进同一把 `Mutex`，并在 `reconnect()` 赋值后复查 `closed`，命中则关闭新连接返回 `false`

### [轻微][存量] `batch` 不预检条数：明知服务端会以 `-32003` 拒整批，仍先构造完整报文

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:110-118`；常量侧 `f_jsonrpc/src/base/JsonRpcProtocol.cj:41`（`DEFAULT_MAX_BATCH_SIZE`，全仓唯一消费点是服务端 `f_jsonrpc/src/server/JsonRpcServer.cj:363`）
- **来源**：存量（blame `5fa2b837d8` 2026-10-25）
- **判据**：review-checklist §5「缺少拒绝路径」、§14.1「接线缺失」（客户端侧上限未接线）
- **证据**：静态确定 —— 客户端对 `calls` 的规模没有任何检查，`JsonArray(list: requests).toString()` 先整包序列化再发；服务端 `handleBatch:138-145` 在超限时直接返回 `-32003` 并附 `{limit, size}`
- **描述**：批量上限只存在于服务端且可配置（`maxBatchSize_`），客户端完全不知道这个上限，超过时付出一次整包序列化 + 一次往返才拿到 `-32003`；请求体越大浪费越明显。这不是安全问题（调用方给自己传大数组），但属于「拒绝路径」缺失导致的无效工作
- **建议**：加可选 `maxBatchSize!`（默认不校验，避免与可配置的服务端上限漂移），超限时本地抛 `-32003`，`data` 结构与服务端保持一致（`{limit, size}`），并补一条单测断言「不发请求」

### [轻微][存量] 同一响应的 `Content-Length` 被解析两次（`send` 与 `readCapped` 各一次）

- **位置**：`f_jsonrpc/src/client/JsonRpcClient.cj:300-307`（超限预判）与 `:346-352`（初始容量）；解析实现 `:324-334`
- **来源**：存量（blame `5fa2b837d8` 2026-10-25）
- **判据**：review-checklist §2「同义实现重复执行」（同一输入、同一输出、同一副作用，调用两次）
- **证据**：静态确定 —— `declaredLength(response)` 在同一次 `send` 调用里被调用两次，每次都要 `headers.getFirst` + `trimAscii` + `Int64.parse` 并分配临时字符串
- **描述**：`readCapped` 拿到的 `cap` 与 `send` 里已经校验过的声明长度是同一个值，第二次解析没有新增信息；两次解析若遇到上游 header 变化（理论上不会，但语义上重复）还会产生不一致的判定
- **建议**：`send` 里解析一次存入局部变量，作为参数传给 `readCapped(response, cap, declared)`，`readCapped` 内部不再调 `declaredLength`

### [轻微][存量] 测试辅助函数重复实现，且两处 `Content-Length` 口径不同（字节 vs 字符）

- **位置**：`f_jsonrpc/src/client/HttpJsonRpcTransport_test.cj:123-142`（`writeBytes` 与 `writeText` 函数体逐行相同，仅入参类型不同）、`:144-146`（`responseOf` 用 `body.unsafeBytes().size`）；`f_jsonrpc/src/client/ReadBufferReuse_test.cj:35-37`（`rpcResponse` 用 `body.size`，注释自认「本文件的 body 全部为 ASCII」）
- **来源**：存量（blame `5fa2b837d8` 2026-10-25 与 `7851b4094d` 2026-11-22）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」，且属「近似重复其中一块少了边界判断」
- **证据**：静态确定 —— `writeText` 就是 `writeBytes(sock, text.unsafeBytes(), counter)` 展开；`responseOf`/`rpcResponse` 构造同一个 HTTP 响应模板，差异仅在长度口径：字节数（正确）与字符数（仅 ASCII 成立）
- **描述**：同一模块的测试里有两套「拼 HTTP 响应」的实现，其中一套的长度口径在多字节 UTF-8 body 上会算错。当前基准用例的 body 全是 ASCII，所以没炸；一旦有人复用 `rpcResponse` 写含中文的用例，`Content-Length` 偏小，客户端会读到被截断的 body，失败现象与真正的原因（长度口径）无关，排查成本高
- **建议**：删 `writeText`，统一走 `writeBytes`；把 `responseOf` 提到一个共用的测试辅助（同包 `private` 不行就 `internal`），`rpcResponse` 改为调用它，长度统一用 `unsafeBytes().size`

### [轻微][存量] 两条测试自身的健壮性问题：门控用例永远无断言、超限用例用墙钟门限

- **位置**：`f_jsonrpc/src/client/ReadBufferReuse_test.cj:238-245`（`testBenchGateDefaultsOff` 两个分支都只 `println` + `return`，零断言）；`f_jsonrpc/src/client/HttpJsonRpcTransport_test.cj:179`（`@Assert(true, elapsed < 700)`）
- **来源**：存量（blame `7851b4094d` 2026-11-22 / `5fa2b837d8` 2026-10-25）
- **判据**：review-checklist §3「空实现（用例无断言）」、§11「测试对机器速度敏感」
- **证据**：静态确定 —— 前者无论门控开关都只有打印，用例恒通过；后者把 700ms 墙钟写死进断言，而同一文件其它用例都用内容/字节数断言
- **描述**：`testBenchGateDefaultsOff` 不验证任何行为，只占一个用例名额，容易让人误以为门控逻辑被测过（真正的门控行为在 `testBenchReadBufferAllocation` 里）。`elapsed < 700` 在 CI 负载高、GC 抖动或慢磁盘上会偶发失败，且失败信息（700ms 超时）与真实断言目标（「没有读完 body 就快速失败」）不对应
- **建议**：删掉 `testBenchGateDefaultsOff`，或改成断言「未设门控时 `jsonrpcBenchEnabled() == false`」；把 `elapsed < 700` 换成与字节数相关的硬断言（`written < cap + 8192` 已有，可只保留它），墙钟只在失败时打印

### [轻微][存量] 归档规格与实现漂移：`getMeta` 无注解时的默认超时，规格写 `500ms`，实现是「不设超时」

- **位置**：文档侧 `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/specs/json-rpc/spec.md:41`（`MUST 返回 JsonRpcMeta('', '500ms')`）与 `:48-51`（Scenario「无注解」→ `timeout = "500ms"`）、`f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/design.md:15`；实现侧 `f_jsonrpc/src/server/JsonRpcRegistry.cj:37,43,47`（`JsonRpcMeta('', '')`，注释写明「不设超时，handler 在请求线程内联执行」）
- **来源**：存量（实现侧变更 `13c921ebc` 2026-10-25「fix(f_jsonrpc,f_mvc): 默认不设超时，显式超时恢复请求上下文」，规格未同步）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定（两侧原文对照）；定性待确认——`13c921ebc` 的提交说明表明「不设超时」是有意变更，因此这是文档滞后而非实现缺陷
- **描述**：规格要求默认超时 500ms，实现改成了空串（= 不设超时、内联执行）。按规格理解的使用者会以为未标注 `@JsonRpcMeta` 的方法有 500ms 上限，实际没有；反过来，运维按规格评估「最坏耗时」时会把默认值算进去，与实际不符。因为规格已经归档、变更属有意，按文档滞后处理，不改实现
- **建议**：在 `spec.md:41,48-51` 与 `design.md:15` 补一句「后续变更 `13c921ebc` 取消默认 500ms，未标注注解时不设超时」；或把这几段标注为已被取代

### [轻微][存量] 两处 wildcard import 在文件内找不到对应符号（疑似未使用）

- **位置**：`f_jsonrpc/src/client/SocketSseConnection.cj:21`（`import fountain::f_jsonrpc.base.*`）、`f_jsonrpc/src/client/HttpJsonRpcTransport_test.cj:24`（`import fountain::f_data.*`）
- **来源**：存量（blame `0f065277fd` 2026-11-10 / `5fa2b837d8` 2026-10-25）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：待确认 —— 逐符号核对：`SocketSseConnection` 只用到 `HttpClient` / `SseReader` / `SseEvent` / `SseConnection` / `HashMap`，没有 `base` 包类型；`HttpJsonRpcTransport_test` 用到的 `JsonRpcException` 来自 `base`，`f_data` 侧没有可见引用。但仓颉扩展方法依赖 import 生效，静态无法排除某个扩展由 `f_data` 提供，故不判死代码
- **描述**：多余 wildcard import 会扩大编译依赖面并误导读者以为本文件与 `f_data` / `base` 有耦合；若确为扩展方法所需，则应在文件内加一句注释说明原因
- **建议**：删掉后在 `f_jsonrpc` 内跑一次 `cjpm build` 确认无扩展方法缺失；保留的话加注释写明「为 X 扩展方法」

## 优化可行性方案

### [堆内存] 空响应 / 无 `Content-Length` 的响应仍预分配 8192 B 的 `ArrayList`

- **现状**：`readCapped` 的 `initial` 默认 8192，只有 `declared > 0 && declared <= cap` 时才用声明值（`JsonRpcClient.cj:345-352`）。因此 `notify()` 的 `Content-Length: 0` 响应、以及 chunked 小响应都会先分配 8192 B 的 `ArrayList<Byte>` 底层数组，随后 `unsafeData()` 只返回 0～数十字节；本模块刚通过线程缓冲消掉了「每次 8192 B 读缓冲」，这一条是同一路径上剩下的固定分配
- **方案**：`initial` 改为 `min(max(declared, 0), cap)` 并对无 `Content-Length` 的情形取一个更小的初始值（如 512），依赖 `ArrayList` 扩容处理大响应；或在 `declared == 0` 时直接 `return Array<Byte>()`
- **预期**：空响应每次少分配约 8 KiB；`notify` / 无体响应密集场景按调用次数线性下降。大响应会多 1～2 次扩容复制（代价侧）
- **代价**：大响应（>512 B 且无 `Content-Length`）多几次数组复制；`unsafeData()` 的最终拷贝不变；语义无变化
- **验证**：`F_JSONRPC_BENCH=1 cjpm test --filter '*ReadBufferReuse*'`，对比 `send_small` 现有基线 `allocPerCall=11,478 B`（`design.md` §10.2），并新增 `case=send_empty`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `batch` 的 id 两次 `toString()` + 字符串哈希

- **现状**：`batch` 先在 126-130 行把每条响应的 id `toString()` 作 `HashMap<String, ...>` 的 key，再在 144-152 行把每个请求 id 再 `toString()` 一次去查表（`:145`），并在缺失分支再 `toString()` 一次（`:150`）。客户端自己生成的 id 一定是 `JsonInt`（`newId()` `:177-179`），却按字符串建索引
- **方案**：改用 `HashMap<Int64, JsonRpcResponse>`，key 取 `id` 的整数值（`JsonInt.toInt64()`；非整数 id 走「无法匹配」分支），只在实际报错消息里保留一次 `toString()`
- **预期**：每条调用少 2 次短字符串分配与 2 次字符串哈希；100 条批量约少 200 个临时字符串。相对整包 JSON 序列化占比很小
- **代价**：客户端需假定自己生成的 id 类型（已是事实）；服务端若把 `id` 回成字符串 `"1"` 则匹配不上（当前 `toString()` 方案能匹配），需在文档声明 id 必须原样回显
- **验证**：`cjpm bench -O2` 或 `F_JSONRPC_BENCH` 加 `case=batch100`，对比 `allocPerCall` 与中位耗时（需 5 样本中位数 + 离散度）
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ThreadLocal.get()` + `match` 的每次响应开销在真实 RPC 延迟中占比可忽略（设计文档只给了 `-O0` 分配量 32 B/op，没有耗时占比） | `f_jsonrpc/src/client/JsonRpcClient.cj:269-277,354` | 单次 `readBuffer()` 的 ns 与端到端 RPC 耗时的比值 | `cjprof record` 跑 10k 次小响应调用（`-O2`），看 `readBuffer` self time 占比 |
| 2 | `callAsync` 的线程创建是并发场景的主要成本，且线程数在 1k 级会触发调度/内存压力 | `f_jsonrpc/src/client/JsonRpcClient.cj:97-101` | 并发 100/1k/5k 时的 P99 延迟、线程数与 RSS | 压测脚本 + `ps -L` / 线程数埋点，对比有界池版本 |
| 3 | `readCapped` 每块 `buffer[0..size]` 切片复制占大响应处理成本的可测比例（现有 `send_multichunk` 只给 `allocPerCall=66,242 B`，未拆出拷贝项） | `f_jsonrpc/src/client/JsonRpcClient.cj:365` | 24 KiB / 1 MiB 响应的分段耗时与分配归因 | `F_JSONRPC_BENCH` 加分段计时，或 `cjprof` 看 `Array` 拷贝相关栈 |
| 4 | `batch` 在 100 条规模时 `JsonArray(list:)` + `toString()` 的峰值内存与耗时占比（客户端无上限校验，规模由调用方决定） | `f_jsonrpc/src/client/JsonRpcClient.cj:118` | 100/1k/10k 条的峰值分配与中位耗时 | `case=batch{N}` 基准，记录 `allocPerCall` 与峰值 `getUsedHeapSize()` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jsonrpc/doc/spec/record-f-jsonrpc-batch-blocker/tasks.md` | .md | ✅ | 纯文档变更记录；引用的 `JsonRpcClient.cj:107-152` 行号已漂移（当前 110-155），结论本身仍成立 |
| 2 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/design.md` | .md | ✅ | 与实现一致（除 `case=reuse` 的 `sink ^= buf[0]` 笔误，实现是 `fetchAdd`）；§10 的基线数据是本部分唯一可用性能资料 |
| 3 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/proposal.md` | .md | ✅ | 与实现一致；`ThreadLocal` 存储类型已按 §10.3 改为 `ReadBufferHolder`，Impact 段有说明 |
| 4 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/specs/json-rpc/spec.md` | .md | ✅ | 三条 Requirement 与 `ReadBufferReuse_test.cj` 的用例逐条对应，无缺口 |
| 5 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/tasks.md` | .md | ✅ | T1-T6 全部勾选，与代码现状一致 |
| 6 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/design.md` | .md | ✅ | D2 的「默认 500ms」与实现不符，见 §13 发现（文档滞后） |
| 7 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/proposal.md` | .md | ✅ | 背景与变更内容与当前代码一致 |
| 8 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/specs/json-rpc/spec.md` | .md | ✅ | `getMeta` 默认值漂移，见 §13 发现 |
| 9 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/tasks.md` | .md | ✅ | demo 相关任务属范围外（demo 模块不在本次范围），未展开核对 |
| 10 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/verify-report.md` | .md | ✅ | 历史 verify 记录（58 passed），当前用例数已增长，属归档结论 |
| 11 | `f_jsonrpc/src/JsonRpc.cj` | .cj | ✅ | 仅三条 `public import` 重导出，无逻辑 |
| 12 | `f_jsonrpc/src/base/JsonRpcException.cj` | .cj | ✅ | 码段注释与设计 4.6 一致；`from` / `toJson` 为对外 API |
| 13 | `f_jsonrpc/src/base/JsonRpcMeta.cj` | .cj | ✅ | `timeoutDuration` 每次 get 现解析；宏在注册期只取一次（`src/macros/JsonRpc.cj:165-180`），不在请求路径 |
| 14 | `f_jsonrpc/src/base/JsonRpcProtocol.cj` | .cj | ✅ | 常量与 `messageOf` 一致；`SERVER_ERROR` 标注「实现不产生」，与 server 侧 grep 结果一致 |
| 15 | `f_jsonrpc/src/client/HttpJsonRpcTransport_test.cj` | .cj | ✅ | 发现：`writeText`/`writeBytes` 重复、`elapsed < 700` 墙钟断言、疑似冗余 import |
| 16 | `f_jsonrpc/src/client/JsonRpcClient.cj` | .cj | ✅ | 本部分主要缺陷集中处（空批量、id 校验、状态码、重试边界、`callAsync`） |
| 17 | `f_jsonrpc/src/client/JsonRpcClient_test.cj` | .cj | ✅ | 空批量用例与真实服务端行为相反（见发现 1） |
| 18 | `f_jsonrpc/src/client/JsonRpcSseClient.cj` | .cj | ✅ | 异常穿透、`retry<=0` 语义、无同步三处发现 |
| 19 | `f_jsonrpc/src/client/ReadBufferReuse_test.cj` | .cj | ✅ | 门控用例无断言；`rpcResponse` 长度口径按字符（ASCII 限定） |
| 20 | `f_jsonrpc/src/client/SocketSseConnection.cj` | .cj | ✅ | 查询串未编码、不校验状态码、吞异常、疑似冗余 import |

合计：`.cj` 10 个 / `.md` 10 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 6（空批量、id 校验、状态码、重试边界、SSE 异常路径、SSE 无同步）、安全性 1（URL 未编码）、设计 2（`callAsync` 线程模型、SSE 类未声明线程安全）、可读性 2（`retry<=0` 语义、测试辅助重复）、语言特性 1（`spawn` 当异步用） |
| §1 死代码 | 1 | 逐符号核对：`READ_BUFFER_BYTES`/`ReadBufferHolder`/`readBuffer` 均有引用；测试内 `fillText`/`rpcResponse`/`fillBuffer`/`isFilledWith`/`tagOf`/`jsonrpcBench*`/`RawHttpServer`/`readHeader`/`write*`/`responseOf`/`FakeTransport`/`FailingTransport` 全被使用；`JsonRpcSseClient.init(connect:)` 仅测试用（可见性建议，非死代码）；`while (true)` 之后的 `throw IOException('unreachable')`（`JsonRpcClient.cj:174`）与 `return None`（`JsonRpcSseClient.cj:97`）是编译器确定返回分析所需，不判死代码；`public` 均在对外可达类型上，不判。唯一命中：2 处疑似未使用 wildcard import（定为待确认） |
| §2 重复逻辑 | 2 | 同文件两两比对：`parseValue`/`parseObject`/`toResponse`/`toError`/`requestBody`/`newId` 无同语义重叠；`sendWithRetry` 与 `reconnect` 的重试循环语义不同（一个是同请求重发，一个是连接重建），不判重复。命中：`declaredLength` 双解析；测试内 `writeText`/`writeBytes` 与 `responseOf`/`rpcResponse` 两组重复 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`；`parseOf` 对坏帧返回 `None` 属有注释的有意设计；`SocketSseConnection.open` 的 `catch` 吞异常已并入发现 6。命中：`testBenchGateDefaultsOff` 零断言 |
| §4 栈溢出 | 0 | 本部分无递归：`batch`/`readCapped`/`send`/`next` 全是循环；`parseValue` 调用的 `JsonValue.fromJson` 递归属范围外（见下方提示） |
| §5 OOM | 1 | 响应体有 `maxResponseBytes` 上限（默认 8 MiB，流式超限即停），不构成无界增长；`batch` 无客户端上限校验记入轻微发现。无长期持有容器 |
| §6.1 热点瓶颈 | 0 | 无 profile 数据；`design.md` §10 只有 `-O0` 分配量与耗时，不含 self time 占比，热点未成立，已列入待验证假设 1-4 |
| §6.2 大粒度锁 | 0 | 本部分无线程锁；`ThreadLocal` 是线程私有而非临界区 |
| §6.3 并发串行 | 1 | `callAsync` 用 `spawn` 换并发（已报）；`testConcurrentCallsGetIntactResponses` 里 `spawn` 后 `get()` 是测试同步用法，不判 |
| §6.4 低效算法 | 1 | `batch` 的 id 双重 `toString()` 记入优化方案；`readCapped` 按块切片复制列入待验证假设（未测占比） |
| §7 降堆内存方案 | 1 | 空响应仍预分配 8 KiB `ArrayList`（无基线，待验证） |
| §8 降 CPU 方案 | 1 | `batch` id 字符串化（无基线，待验证） |
| §9 local mode 可行性 | 0 | `readCapped` 的 ArrayList/切片均需逃逸为返回值，`batch` 的 `requests`/`responses` 逃逸进 `JsonArray` 与返回值；`doc/spec/record-f-jsonrpc-batch-blocker/tasks.md:7-10` 已有实测结论（local `ArrayList` 不能作堆返回值），本部分无新增可行点 |
| §11 现有代码的 BUG（存量） | 9 | 本部分读到的 9 处存量缺陷：空批量、id/版本校验、状态码丢弃、重试边界、`callAsync` 资源、SSE 异常路径、`retry<=0`、SSE URL 编码、SSE 无同步；另有边界/空值逐项核对无问题：`readCapped` 对 `declared<=0`、`total>cap`、空 body、恰好等于 cap 均正确；`toError` 对非对象/非数字 code 已收敛 |
| §12 并发安全与锁粒度 | 3 | `JsonRpcClient` 的 `AtomicInt64` 发号、`HttpJsonRpcTransport` 的静态 `ThreadLocal` 缓冲均安全（注释与 `ReadBufferReuse_test` 覆盖）；命中：SSE 三字段无同步、`callAsync` 无界 `spawn`、`SocketSseConnection` 关闭与读并发（并入发现 9） |
| §14 功能完备性与 README 覆盖 | 1 | README 与 README_en 不在本部分文件清单（属其他部分），未展开；本部分文档的承诺项逐条对照：`reuse` 规格的 8 条用例、分配门限、`SKIP` 门控均已落地；`rework` 规格的 `getMeta` 默认值未落地（见 §13 发现） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分（客户端与协议常量 + 3 份规格文档）代码结构清晰、注释密度高，`readCapped` 的线程本地缓冲改造与 `HttpJsonRpcTransport_test` / `ReadBufferReuse_test` 的覆盖质量明显高于模块平均水平：超限检测、流式截断、连接复用、跨线程隔离都有针对性用例，未发现崩溃、数据损坏或无界增长类静态缺陷。

主要风险集中在**协议层与网络层的边界**，且都属存量：

1. 客户端只做「JSON 能否解析」的最低校验，`id` 回显、`jsonrpc` 版本、HTTP 状态码三个协议自检点全部缺失，导致错配响应与 413/5xx 都塌缩成 `-32603`（发现 2、3）；批量路径反而按 id 校验，两条路径严格度不一致。
2. 超时语义分裂：`timeout` 只管 HTTP 传输、注入 transport 即失效，`callAsync` 无线程上限也无 deadline，「可重试」的判定把读超时也算进去（发现 4、5）——非幂等方法在开启重试后可能重复执行，这是本部分最需要在文档与实现上对齐的一条。
3. SSE 客户端的结束/异常/并发三条路径都没写完：只处理 `None`，异常穿透、`retry=0` 把正常收尾当失败、`close()` 跨线程会漏关连接（发现 6-9）。同构部署有 15s 心跳兜底，对接第三方 SSE 时风险会立刻显形。

建议排期：先修发现 1（空批量，改动 3 行）+ 发现 7（`retry<=0` 语义），再统一「超时与重试」契约（发现 3、4、5），最后补 SSE 的异常与并发语义（发现 6、8、9）。轻微项可与上述改动合并处理。

存量缺陷共 15 条（一般 9 + 轻微 6），是否纳入修复待用户决定；优化方案 2 条均无改前基线，只作为下一轮补数据的候选，不进修复清单。

**范围外提示**：`f_data/src/json/JsonValue.cj:176-200` 的 `fromJson` 对嵌套数组/对象递归解析（递归点 `:185`、`:196`）且无深度上限，`JsonRpcClient.parseValue`（`JsonRpcClient.cj:199`）直接调用；恶意深嵌套响应可触发栈溢出，建议在 `f_data` 轮次单独评估。

# f_jsonrpc 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_jsonrpc`（62 个文件：32 个 .cj + 30 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_jsonrpc.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] README 声明「不提供 SSE」，模块已实现 SSE 且被 `f_a2a` 依赖

- **位置**：`f_jsonrpc/README.md:31`、`f_jsonrpc/README.md:500`；`f_jsonrpc/README_en.md:32`、`f_jsonrpc/README_en.md:511`
- **来源**：存量（快照模式无基线；`git log -- f_jsonrpc/README.md` 显示 SSE 类由 `f624bf2fa` 追加进 README 末尾，正文未同步）
- **判据**：review-checklist §13（文档承诺与实现相反）/ §14.1（承诺与实现冲突）
- **证据**：静态确定 —— README 第 31 行写「传输只做 HTTP POST，不提供 GET / SSE / WebSocket」，第 500 行把「SSE / WebSocket 传输」列为「不做的部分」；但同一文件第 533–539 行又列出 `SseController` / `SseHub` / `SseStream` / `SseSubscription` / `JsonRpcSseClient`，实现见 `SseController.cj:35`（`GET /rpc/stream`）、`SseHub.cj:47`、`JsonRpcSseClient.cj:39`；根 `README.md:118` 也写明 `f_a2a`「流式走 SSE」
- **描述**：模块已经把 SSE 作为一等能力（服务端推送 + 客户端流式消费 + 断线补发），README 两处却把 SSE 写成未实现。使用者按 README 会判定「没有推送能力」，或在评估 `f_a2a` 依赖时误以为 SSE 来自别处；同时 README 自身前后矛盾，无法作为契约依据。
- **建议**：删除第 31 行「不提供 GET / SSE」与「不做的部分」里的 SSE 条目，改为「POST + `application/json` 为 JSON-RPC 传输；`GET /rpc/stream` 为 SSE 推送扩展」；中英两版同步（英文版同一处）。

### [一般][存量] `README_en.md` 仍写「无注解默认 500ms 超时」，与实现和中文版相反

- **位置**：`f_jsonrpc/README_en.md:94`（对照 `f_jsonrpc/README.md:94`、`f_jsonrpc/README_en.md:520`、`f_jsonrpc/README.md:509`）
- **来源**：存量
- **判据**：review-checklist §13（API / 默认值与源码不符；`README_en` 与 `README.md` 结论相反）
- **证据**：静态确定 —— 实现 `JsonRpcRegistry.cj:39-48` 在无注解 / 无匹配重载时返回 `JsonRpcMeta('', '')`，`macros/JsonRpc.cj:175-179` 对空串返回 `None<Duration>`，即**不设超时**；中文版第 94 行写「无注解时描述为空串、不设超时」，英文版第 94 行写「empty description and a `500ms` timeout when there is no annotation」，而英文版自己的迁移表第 520 行又写「Default timeout 500 ms → none」
- **描述**：默认超时从 500ms 改为「无」是 `fix-jsonrpc-mcp-review-findings` 的既定变更，英文 README 漏改。英文读者会以为方法 500ms 必然超时（进而写 `catch` / 重试逻辑），实际 handler 会一直内联执行；英文版还缺「`timeout` 空串 = 不设超时」这条规则。
- **建议**：把 `README_en.md:94` 改为「empty description and no timeout when there is no annotation」，并补「empty string means no timeout」一条，与 `README.md:94-95` 对齐。

### [一般][存量] `@JsonRpcMapping` 的参数面写错：文档说「只暴露 `path`」，实现暴露 5 个

- **位置**：`f_jsonrpc/README.md:409-410`、`f_jsonrpc/README_en.md:417-418`
- **来源**：存量
- **判据**：review-checklist §13（API 与源码不符）+ §14.2（公开 API 文档化错误）
- **证据**：静态确定 —— `JsonRpcMapping.cj:26-32` 的构造参数是 `path!` / `params!` / `headers!` / `ignoreAuth!` / `ignorePrivilege!`；设计文档 2.4（`doc/f_jsonrpc模块设计.md:341-347`）与 `doc/spec/fix-jsonrpc-mcp-review-findings/specs/json-rpc/spec.md:207` 都明确要求暴露这 5 个
- **描述**：README 把 `@JsonRpcMapping` 描述成只能传 `path`，读者会认为无法给 JSON-RPC 端点关掉 MVC 会话校验（`ignoreAuth` / `ignorePrivilege`）或按 header 分版本（`headers` / `params`）。这与设计里「JSON-RPC 端点常常要关掉 MVC 的会话校验」的意图直接冲突。
- **建议**：README 改为「固定 `POST` + `application/json`，暴露 `path` / `params` / `headers` / `ignoreAuth` / `ignorePrivilege`」，并给一个 `ignoreAuth: true` 的示例。

### [一般][存量] `ClientOptions.timeout` 被描述成「单次 HTTP 请求超时」，实现只覆盖读 / 写

- **位置**：`f_jsonrpc/README.md:431`（表格）与 `f_jsonrpc/README.md:222`（示例注释）；`f_jsonrpc/README_en.md:440`、`f_jsonrpc/README_en.md:224`
- **来源**：存量
- **判据**：review-checklist §13（默认值 / 语义与源码不符）；规格 `doc/spec/fix-jsonrpc-mcp-review-findings/specs/json-rpc/spec.md:316` 明确要求 README 写「仅作用于读 / 写超时，不含建连与整体 deadline」
- **证据**：静态确定 —— `JsonRpcClient.cj:265` 只把它传给 `ClientBuilder().readTimeout(opts.timeout).writeTimeout(opts.timeout)`，没有整体 deadline，也没有 connect timeout 参数
- **描述**：调用方按「单次请求 30s 超时」设计重试 / 熔断，实际建连阶段不受该值约束，连接黑洞场景下调用会远超声明的上界；与规格要求的措辞也不一致。
- **建议**：README 两版都改为「读 / 写超时（不含建连与整体 deadline）」，并在「超时」小节注明建连阶段由底层 HTTP 客户端默认值决定。

### [一般][存量] 重试边界无法按文档区分「发送前失败」与「已发送后等响应失败」

- **位置**：`f_jsonrpc/README.md:211-212`、`f_jsonrpc/README_en.md:212-213`；实现 `f_jsonrpc/src/client/JsonRpcClient.cj:291-296`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §12.1（异步语义 / 超时但任务继续跑）
- **证据**：待确认 —— 代码把 `client.send(builder.body(body).build())` 的**所有**异常统一包成 `JsonRpcConnectException`（唯一的可重试异常），而 `sendWithRetry`（`JsonRpcClient.cj:162-175`）对它无条件重试；`client.send` 若在「请求已写出、等待响应头」阶段抛错（读超时 / 连接被重置），该错误同样被标成可重试。需确认 `stdx.net.http.Client.send` 是否阻塞到响应头返回；`cangjie-doc-lookup` 的本地文档目录在本机不存在（`~/.autocode/cj/doc` 为空），无法现场核对签名语义
- **描述**：README 承诺「只有建连 / 发送阶段失败才重试；读响应阶段失败永不重试（服务端可能已执行）」。实现只有一个 `try/catch`，异常类型不携带阶段信息，因此「请求已到达服务端、但读响应头失败」这一类会被当成建连失败重试，非幂等方法可能被执行多次。若确认 `send` 覆盖响应头阶段，本条应升级为**严重**（重复写入）。
- **建议**：把传输拆成显式的 `connect` / `write` / `readHead` 三段，只对前两段抛 `JsonRpcConnectException`；`send` 内部的读超时、连接重置一律抛普通 `IOException`。README 随之写明「`send` SPI 实现方必须自己保证阶段标注，否则重试语义不成立」。

### [一般][存量] SSE 丢弃事件的「warn 一次」承诺没有接线

- **位置**：`f_jsonrpc/src/server/SseHub.cj:110-114`、`f_jsonrpc/src/server/SseStream.cj:53-78`；承诺源 `f_jsonrpc/doc/spec/add-jsonrpc-sse/design.md:56-61`、`f_jsonrpc/doc/spec/add-jsonrpc-sse/specs/jsonrpc-sse/spec.md:39-47`
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现 / 接线缺失）+ §3（静默吞掉异常类）
- **证据**：静态确定 —— `SseStream.push` 在丢弃时 `dropReported = true` 并返回 `false`，但唯一调用点 `SseHub.cj:112` 写的是 `let _ = item.stream.push(text)`，返回值被丢弃；`SseStream.cj:71` 的注释「只用来打一次 warn」与 `dropped` 这个 prop 在全仓**只被** `src/server/Sse_test.cj:72` 读过，`SseHub.cj` / `SseStream.cj` 内没有任何 `Logger` / `log.append` / `println`
- **描述**：规格要求「溢出时丢最旧并记录一次 warn，MUST NOT 无限增长或阻塞发布方」。缓冲与丢弃都实现了，告警没实现：慢消费者丢事件时线上没有任何日志，`dropped` 变成一个只给测试看的公开属性；排障时无法区分「业务没发」与「发出被丢」。
- **建议**：`SseHub.publish` 检查 `push` 返回值，首次为 `false` 时按 `topic` / `subscriberId` 打一条 `WARN`（含 `dropped=true`），后续不再重复；或把 `dropped` 改成一次性 `takeDropped()` 由 hub 消费。

### [一般][存量] SSE 公共 API 在 README 只有符号清单，端点 / 参数 / 帧格式 / 限制全部缺失

- **位置**：`f_jsonrpc/README.md:533-539`、`f_jsonrpc/README_en.md:544-550`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化 / 缺关键段落）
- **证据**：静态确定 —— 两版 README 全文检索 `/rpc/stream`、`text/event-stream`、`Last-Event-ID`、`cursor`、`topic`/`taskId` 查询参数均为 0 命中（`grep -n "/rpc/stream\|Last-Event-ID\|cursor\|text/event-stream" README.md README_en.md` 无输出），「SSE」在两版各只出现 2 次（均为「不做」与末尾清单）；`SseController.cj:35,44-66` 定义的 `?topic=&taskId=&cursor=`、`Last-Event-ID` 优先规则、默认 topic `default` 均无文档
- **描述**：`SseHub`（`publish` / `subscribe` / `subscriberCount` / `reset`）、`SseStream`（容量 256、15s 心跳、`read` 返回 0 才表示结束）、`SseSubscription`（`id` / `close`）、`JsonRpcSseClient`（`retry` 默认 3、超限抛异常、`close`）都只有名字，没有语义；「进程内广播、多实例需外部总线」这条部署限制也没有任何落点（`doc/spec/add-jsonrpc-sse/tasks.md:27` 声称已写入 `known-limitations.md`，但全仓只有 `f_llm/doc/known-limitations.md`，`f_jsonrpc/doc/` 下不存在该文件）
- **建议**：补「SSE 推送」一节：端点与查询参数、帧格式（`id` / `event: message` / `data` 为 JSON-RPC 通知）、断线补发与 `Last-Event-ID`、订阅者缓冲 256 + 丢最旧、客户端重连 3 次、以及多实例限制；同时落地 `f_jsonrpc/doc/known-limitations.md`。

### [轻微][存量] 依赖清单与 `cjpm.toml` 不一致（中文版缺 `f_config`，英文版还缺 `f_httpclient`）

- **位置**：`f_jsonrpc/README.md:36-44`、`f_jsonrpc/README_en.md:37-44`；实际 `f_jsonrpc/cjpm.toml:1-8`
- **来源**：存量
- **判据**：review-checklist §13（配置与源码不符；中英不同步）
- **证据**：静态确定 —— `cjpm.toml` 声明 7 个依赖：`f_bean` / `f_config` / `f_data` / `f_httpclient` / `f_log` / `f_macros` / `f_mvc`；中文 README 列 6 个（少 `f_config`），英文 README 列 5 个（少 `f_config`、`f_httpclient`）
- **描述**：`f_httpclient` 是 SSE 客户端（`JsonRpcSseClient.cj:21` 引用 `fountain::f_httpclient.sse.*`）的必需依赖，`f_config` 也是模块声明依赖。照英文版清单搭环境会在 SSE 路径上缺依赖；两版清单互不一致也让「以哪个为准」无解。
- **建议**：两版都改为模块真实依赖集合，或直接写「依赖见 `f_jsonrpc/cjpm.toml`」避免二次维护。

### [轻微][存量] README 对「位置参数」的说法自相矛盾（总述说支持，细则限定单参数）

- **位置**：`f_jsonrpc/README.md:29` 与 `f_jsonrpc/README.md:96`（英文版 `README_en.md:30` / `:95`）
- **来源**：存量
- **判据**：review-checklist §13（同一文档内部结论相反）
- **证据**：静态确定 —— 第 29 行把「位置参数与命名参数」列为已实现；第 96 行限定「单参数按规范传 `[值]` 或 `{"参数名": 值}`；多参数必须传对象」。实现与之相符：`macros/JsonRpc.cj:120,140-144` 对多参数固定 `named: true`，`JsonRpcArgs.cj:29-38` 在 `named` 分支只接受 `JsonObject`，数组直接抛 `-32602`
- **描述**：读第 29 行的人会给多参数方法传 `[1,2]`，得到 `-32602 "params must be an object for a multi-parameter method"`。协议层支持位置参数，但宏生成的方法不支持，文档没有把这个边界讲清。
- **建议**：第 29 行改成「位置参数（单参数数组）/ 命名参数（对象）」；或在 1.1 节补一句「多参数方法只接受命名参数，位置数组会返回 `-32602`」。

### [轻微][存量] 同一套协议规则在 4 份文档里各写一遍，已出现相反结论

- **位置**：`f_jsonrpc/doc/f_jsonrpc模块设计.md:1008`（批量「顺序不保证」）vs `f_jsonrpc/doc/spec/add-f-jsonrpc/specs/json-rpc/spec.md:35`、`f_jsonrpc/README.md:451`、`f_jsonrpc/README_en.md:460`（同序）；错误码表重复于 `README.md:174-181`、`README_en.md:173-180`、`doc/f_jsonrpc模块设计.md:685-697`、`doc/spec/fix-jsonrpc-mcp-review-findings/specs/json-rpc/spec.md:75-81`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制：同一张状态码表 / 同一组规则散落多处，导致行为漂移）
- **证据**：静态确定 —— 实现 `JsonRpcServer.cj:148-163` 按 `items` 顺序 append 响应，`JsonRpcClient.cj:143-154` 按 `ids` 顺序回填，结论是「同序」；设计文档第 1008 行仍写「顺序不保证」，与 spec/README 相反
- **描述**：批量顺序、错误码、上限这些规则被复制到 README（中/英）、设计文档、两份 spec，任一处改动都会漏改其余处（本部分已发现英文版 500ms、依赖清单两处漂移即为同源症状）。设计文档这句「顺序不保证」还会被下游实现者当成许可，写出依赖乱序的客户端。
- **建议**：README 作为唯一对外口径，设计文档与 spec 只保留「见 README 错误码表」的引用；批量顺序统一写「与请求中带 `id` 的条目顺序一致」。

### [轻微][存量] 设计类文档中的代码样例与行号引用已过期

- **位置**：`f_jsonrpc/doc/f_jsonrpc模块设计.md:376`、`:516-539`、`:582`、`:619-624`；`f_jsonrpc/doc/spec/record-f-jsonrpc-batch-blocker/design.md:43`
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用 / 过期文档）
- **证据**：静态确定 —— 设计文档 4.2 仍声明 `JsonRpcContext.meta: HashMap<String, String>` 与 `JsonRpcMethodMeta.inputSchema/outputSchema`，4.3 的 `handle` 仍返回 `?Array<Byte>`，4.4 样例仍传 `meta: forwardableHeaders(ctx)`；实现中这些字段/签名均已不存在（`JsonRpcContext.cj:29-43` 只有 `http/id/endpoint/topic/deadline`，`JsonRpcMethodMeta.cj:29-52` 无 `inputSchema`，`JsonRpcServer.cj:94` 返回 `?JsonValue`，且全仓无 `forwardableHeaders` 定义）。`record-f-jsonrpc-batch-blocker/design.md:43` 指向 `JsonRpcClient.cj:107-152`，实际 `batch` 在 110-155 行
- **描述**：文末「文档与实现对照」表已声明 `meta` 删除与返回类型变化，但正文样例未改，读者复制 4.4 的 controller 会直接编译失败；batch 阻断记录的行号也已偏移（文档自己在风险表里预警过「结论随实现漂移」，但没有更新机制）。
- **建议**：4.2 / 4.3 / 4.4 的代码块改为「示意（非当前签名）」或按现签名重写；文档中的行号引用改成函数名（`JsonRpcClient.batch`）而不是绝对行区间。

### [轻微][存量] 两份归档 spec 内部自相矛盾（任务勾选与验证报告、`read` 结束值）

- **位置**：`f_jsonrpc/doc/spec/add-jsonrpc-macro/tasks.md:33-34` vs `doc/spec/add-jsonrpc-macro/verify-report.md:8`；`f_jsonrpc/doc/spec/add-jsonrpc-sse/tasks.md:7` vs `doc/spec/add-jsonrpc-sse/design.md:46`
- **来源**：存量
- **判据**：review-checklist §13（归档 spec 的「当时结论」不自洽）
- **证据**：静态确定 —— `add-jsonrpc-macro/tasks.md` 的 4.3（全量回归）/ 4.4（提交合并）仍是 `- [ ]`，`verify-report.md` 第 8 行却写「tasks 全部完成（1.1–4.4）」；`add-jsonrpc-sse/tasks.md:7` 写「`close` 后 `read` 返回 -1」，同变更 `design.md:46` 明确写「返回 0（std.io 的 EOF 约定是 0，不是 -1）」，实现 `SseStream.cj:88-96` 返回 0
- **描述**：归档文档是后续变更判断「当时到底验了什么」的唯一依据；勾选状态与验证报告冲突、结束值写反，会让后来者误以为 `read` 用 -1 表示 EOF（若照此写调用方判断，流会读不到结束）。
- **建议**：把 `tasks.md` 的 4.3 / 4.4 按实际状态回填（或在 verify 报告注明「4.3/4.4 由后续提交补齐」），`tasks.md:7` 的 -1 改为 0。

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

### [严重][存量] SSE 订阅表只增不删：`subscribers` 随连接数无界增长，`publish` 退化为 O(总订阅数)

- **位置**：`f_jsonrpc/src/server/SseHub.cj:58-84`（`subscribe` 只 `list.add`）、`f_jsonrpc/src/server/SseHub.cj:36-38`（`SseSubscription.close()` 只关流、不摘除）、`f_jsonrpc/src/server/SseController.cj:70`（丢弃 `SseSubscription` 对象，只取 `.stream`）
- **来源**：存量（快照模式无基线；`git blame` 该文件整文件为 2026 年新增，无 diff 可比）
- **判据**：review-checklist §5「无界容器 / 缓存键无界」、§11「资源不对称」、§14「接线缺失」
- **证据**：静态确定 —— (1) 全仓搜 `unsubscribe` / `subscribers.remove` / `subscribers[`：只有 `SseHub.cj:69` 的**写入**命中，没有任何移除路径；(2) 唯一的批量清空是 `reset()`（`SseHub.cj:130-137`），全仓只被 `Sse_test.cj:82,94,100,109,115,123,129,138` 这 8 处测试调用；(3) `SseController.cj:70` 是 `SseHub.subscribe(...).stream`，`SseSubscription` 对象连引用都不保留，外部即便想 `close()` 也拿不到；(4) 订阅键 `topic` 直接来自 `GET /rpc/stream?topic=`（`SseController.cj:44-51`），是外部可控字符串
- **描述**：每建立一条 SSE 连接就往 `subscribers[topic]` 追加一个 `SseSubscription`（含 `SseStream`、其 `frames` 队列最多 256 个 String 引用与当前帧），**没有任何生命周期终点**。客户端断开后条目仍留在表里：`publish` 每次事件都要遍历该 topic 的全部历史订阅（`SseHub.cj:110-114`），对已关闭的流调用 `push` 只会在 `SseStream.cj:56-58` 直接返回 `true`。后果：
  1. 内存随「累计连接数」线性增长（不是当前连接数），订阅数与 topic 数都无上限，单个客户端循环重连即可把表撑大 → 长跑进程 OOM；
  2. 每条发布事件的成本从 O(活跃订阅) 退化成 O(历史订阅总数)，延迟随运行时长单调劣化；
  3. `subscriberCount()`（`SseHub.cj:120-127`）返回值失真，`JsonRpcZzSse_test.cj:87` 这类「等订阅出现」的判据在脏表上永远为真。
- **建议**：
  1. `SseSubscription.close()` 增加摘除语义（在同一把 `mutex` 内 `subscribers[topic]` 移除自身，空列表时删 key）；
  2. `SseController.stream()` 返回一层包装 `InputStream`，其 `close()` 先 `stream.close()` 再 `subscription.close()`（`f_mvc` 的 `respond(InputStream)` 直接 `body(stream)`，是否在断连时回调 `close()` 属**待确认**，需实测 `SseStream.close()` 是否被调用）；
  3. `publish` 内顺手剔除 `isClosed` 的条目作为兜底；
  4. 给 `subscribers` 加总量上限 / 单 topic 上限，超限拒绝新订阅（返回 `-32003` 语义的 503 亦可），避免外部输入撑爆表。

### [一般][存量] `SseHub` 用一把全局 `Mutex` 保护「序列化 + 全部 topic 的推送」，跨 topic 完全串行

- **位置**：`f_jsonrpc/src/server/SseHub.cj:94-116`（`publish` 的临界区含 `frameOf`）、`f_jsonrpc/src/server/SseHub.cj:97`（`frameOf(id, method, params)` 在锁内做 JSON 构造 + `toString()`）、`:110-114`（锁内遍历全部订阅者 `push`）、`f_jsonrpc/src/server/SseHub.cj:61-82`（`subscribe` 的补发循环也在同一把锁里）
- **来源**：存量
- **判据**：review-checklist §12.2「缩小临界区：I/O、解析、序列化、日志一律移到锁外」「分片」；§6.2「锁内做序列化 / 一把全局锁保护多个无关资源」
- **证据**：静态确定（临界区内容与共享点可直接从代码读出）——临界区里做了三件事：`nextId++`、`frameOf`（`JsonObject` 组装 + `body.toString()`，O(payload)）、`recent` 裁剪 + `for (item in subscribersOf(topic)) push`（O(该 topic 订阅数)）。竞争方 = 所有调用 `publish` 的业务线程（如 `f_a2a/src/server/A2aEvents.cj:43`）+ 所有 `subscribe` 的请求线程；不同 topic 之间没有任何共享不变量，却被同一把锁串行。单次持有时长量级 **待确认**（无 profile，未测量）。
- **描述**：所有 topic 的推送被串成一个全局串行段，发布线程数一多就退化为排队；任何一个大 payload 的序列化都会挡住其它 topic 的订阅补发与新订阅。按 §6.2 的判据这属于「能按 key 切开却用单锁」，但**没有测量数据，不主张吞吐损失比例**。
- **建议**：`nextId` 改 `AtomicInt64`（只保证唯一、不必全局有序）；`subscribers` / `recent` 按 topic 分片，每 topic 一把 `Mutex` —— **同一 topic 内必须保持串行**（帧序即协议语义），跨 topic 不再互斥。分片后 `SseHub.reset()` 需要遍历全部分片，注意与测试的互斥。

### [一般][存量] `SseController` 手写查询串解析：不做百分号解码，与 `f_mvc` 的 `url.queryForm` 语义漂移

- **位置**：`f_jsonrpc/src/server/SseController.cj:74-94`（`queryOf` 手写 `split('&')` + `split('=')`，直接 `trimAscii` 后使用）、`:44-52`（`topic` / `taskId` 取自该结果）、`:61-66`（`cursor` 走 `intOf`）
- **来源**：存量
- **判据**：review-checklist §2「跨层复制：同一套解析一处用框架、一处手写」、§13「与规格漂移」、§11「语义与命名不符」
- **证据**：静态确定 —— `f_mvc` 自己的取参路径是 `url.queryForm` + `getAll`（`f_mvc/src/ControllerFuncParam.cj:45-67`，`rawQuery` 判断在 `:53`，取值在 `:54-57`），由框架统一做表单解码；`SseController.queryOf` 全程只有 `trimAscii()`（`:88`），没有任何百分号解码调用（全仓 `percentDecode` / `urlDecode` / `decodeQuery` 0 命中）。另：`topic` 会被 `trimAscii`（`:45-49`），`taskId` 走 `textOf` 不 trim（`:52`），两者口径不一致。
- **描述**：客户端按 URL 规范编码后发 `?topic=a%20b`（或中文 topic、带 `+` 的 taskId），服务端得到的键就是字面量 `a%20b`，与业务 `publish('a b', ...)` 的 topic 不同 → 订阅成功但永远收不到事件，且 `subscriberCount` 还会显示「有订阅」，排查成本高。当前 `f_a2a` 用的是固定 ASCII topic，所以线上未暴露；只要 topic 里有非保留字符以外的东西（空格、中文、`&`、`=`）就会中招。
- **建议**：删掉 `queryOf`，改成 `@RequestParam topic!: String = 'default'` / `taskId!: String = ''` / `cursor!: Int64 = 0` 让 `f_mvc` 统一解码（同时消掉 `textOf` / `intOf` / `DEFAULT_TOPIC` 三处手写逻辑）；若必须手写，则对齐框架口径：`URL.queryForm` 或显式 percent-decode，并统一 trim 规则。

### [一般][存量] 超时后从不 `future.cancel()`，且超时 handler 的最终结果 / 异常无人观察

- **位置**：`f_jsonrpc/src/server/JsonRpcServer.cj:281-298`（`invokeHandler`：`spawn` 后在 `:292` `future.get(t)`，超时只 `throw JsonRpcException(TIMEOUT)`）
- **来源**：存量
- **判据**：review-checklist §12.1「异步语义：超时但任务继续跑」、§11「错误处理缺失或静默」
- **证据**：静态确定 —— 代码里没有任何 `cancel()` 调用（全仓 `\.cancel\(` 在 `f_jsonrpc` 0 命中）；`Future` 局部变量在 `TimeoutException` 之后随栈帧消失，后续 `get()` 不会再被调用。按 std 文档 `core/core_package_api/core_package_classes.md` §`func get(Duration)`：「如果线程抛出异常退出执行，在 get 调用处将继续抛出该异常」——`get` 是唯一的异常观察通道；§`func cancel()`：「给对应线程发送取消请求……不会立即停止线程执行，仅发送请求」。
- **描述**：设计文档（`doc/f_jsonrpc模块设计.md:1046-1048`）已确认「超时只提前返回错误，不终止 handler」，这一点**不是缺陷**；缺口在两处配套手段缺失：(1) 从不发协作式取消请求，handler 即便遵守 `Thread.currentThread.hasPendingCancellation` 也收不到信号（而 README 只教用户轮询 `ctx.isExpired()`，没有提 `hasPendingCancellation`）；(2) 超时后 handler 若抛异常，没有任何日志——`processOne` 的 `catch` 只覆盖 `get()` 正常返回/抛出的路径（`:216-221`），异常被静默吞掉，排障时只会看到客户端侧 `-32002`。
- **建议**：`catch (_: TimeoutException)` 里先 `future.cancel()` 再转 `-32002`；需要可观测性时用 `spawn { ... }` 外包一层 `try/catch` 把异常写 `log.append(WARN)` 后再 rethrow（这样即便父线程已走，日志也在子线程留下）。

### [一般][存量] `timeout = '0s'` 语义自相矛盾：deadline 立即过期，但 `get(0)` 等价于无限等待

- **位置**：`f_jsonrpc/src/server/JsonRpcServer.cj:274-279`（`deadlineOf`：`MonoTime.now() + t`）、`:282-295`（`Some(t)` 时 `spawn` + `future.get(t)`）；产生 `Some(Duration.Zero)` 的入口 `f_jsonrpc/src/macros/JsonRpc.cj:175-179`（只判 `isEmpty()`，`'0s'` 非空即 `Some`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」、§10 边界；§5 风险面
- **证据**：静态确定（代码路径）+ 文档依据 —— std 文档 `core/core_package_api/core_package_classes.md` §`func get(Duration)`：「如果 `timeout <= Duration.Zero`，等同于 `get()`，即不限制等待时长」。因此 `'0s'` 得到的是：`ctx.deadline == now` → `isExpired()`（`JsonRpcContext.cj:54-58`）**立刻为 true**，而框架侧永远不等超时。
- **描述**：用户按直觉写 `@JsonRpcMeta['desc', '0s']` 想表达「不超时」，实际拿到的是「handler 被挪到子线程、`isExpired()` 一进函数就为 true、框架永不超时」三者叠加：遵守文档自查 deadline 的 handler 会立刻抛 `-32002`，不查的 handler 会跑到底且不触发超时。README 只写了「空串等价于不设超时」（`README.md:95`），没定义 `'0s'`。
- **建议**：`deadlineOf` 里把 `t <= Duration.Zero` 归一成 `None`（= 不设超时、内联执行），`invokeHandler` 的 `match` 同样按 `t > Duration.Zero` 分流；或在注册期（`JsonRpcMethodMeta.init`）把非正 `Duration` 直接当配置错误抛 `IllegalArgumentException`。二选一都要在 README 补一句 `'0s'` 的处理。

### [轻微][存量] `processOne` 的「方法未解析」分支重复实现了 `notifyOrError`

- **位置**：`f_jsonrpc/src/server/JsonRpcServer.cj:226-233` vs `:324-331`（`notifyOrError`）
- **来源**：存量
- **判据**：review-checklist §2「换控制流：语义相同、只差日志文案」
- **证据**：静态确定 —— 两处都是「有 `id` → `respondError(...)`；无 `id` → 打一条 WARN 并返回 `None`」，唯一差异是日志文案（`"json-rpc notification '${method}' failed with ${failCode}"` vs `"json-rpc notification rejected: ${message}"`）与 `data` 恒为 `None`
- **描述**：`resolve` 失败分支没有复用 `notifyOrError(hasId, idValue, failCode, JsonRpcProtocol.messageOf(failCode), None)`，导致同一语义两份实现；今后改错误回包结构（例如给 `-32601` 补 `data`）容易只改一处，形成行为漂移。
- **建议**：直接 `return notifyOrError(hasId, idValue, failCode, JsonRpcProtocol.messageOf(failCode), None)`；若想保留更具体的日志，把 log 文案做成 `notifyOrError` 的可选参数，而不是复制分支。

### [轻微][存量] `REPLAY_CAPACITY` 与 `SseStream` 的默认 `capacity` 是两个独立的 256

- **位置**：`f_jsonrpc/src/server/SseHub.cj:162`（`REPLAY_CAPACITY: Int64 = 256`）、`f_jsonrpc/src/server/SseStream.cj:41`（`capacity!: Int64 = 256`）、`f_jsonrpc/src/server/SseHub.cj:60`（`SseStream()` 用默认容量）+ `:74-78`（补发循环 `push`）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制（同一上限写两处，靠约定同步）」
- **证据**：静态确定 —— 补发把最多 `REPLAY_CAPACITY` 条帧一次性塞进新建的默认容量队列；两者相等（都是 256）时正好不丢，一旦 `REPLAY_CAPACITY` 被调大而 `SseStream()` 默认值没跟着改，补发的前几条会被 `SseStream.push` 以「满了丢最旧」静默丢弃（`SseStream.cj:59-64`），且丢帧告警本身也没接线（第 1 部分已计）。
- **建议**：`subscribe` 里显式 `SseStream(capacity: REPLAY_CAPACITY)`，或把常量提到一处（`SseHub.REPLAY_CAPACITY` 由 `SseStream` 引用），去掉隐式耦合。

### [轻微][存量] `SseHub.reset()` / `subscriberCount()` 是测试专用 `public` API，`reset` 会重置全局事件 id

- **位置**：`f_jsonrpc/src/server/SseHub.cj:129-137`（`reset`，注释写明「测试用」）、`:120-127`（`subscriberCount`）、`:48-52`（静态可变状态）
- **来源**：存量
- **判据**：review-checklist §1 硬原则一的补充「只给测试用的公开 API 单列可见性建议」；§11「契约与实现不符」
- **证据**：静态确定 —— 全仓 `SseHub.reset(` / `SseHub.subscriberCount(` 只在 `f_jsonrpc/src/server/Sse_test.cj` 与 `JsonRpcZzSse_test.cj` 命中，无生产调用方；`reset` 把 `nextId` 归零（`:134`），而 `Last-Event-ID` 补发依赖「id 单调」（`:44`、`:75`）
- **描述**：`SseHub` 是 `public class`、这两个方法对外可达，按硬原则一**不算死代码**；但生产代码误调 `reset()` 会让事件 id 回绕，已连接的客户端带着旧 `Last-Event-ID` 重连时再也匹配不到新事件（`event.id > lastEventId` 恒不成立），属于「看着像清理接口、实则破坏协议不变量」。
- **建议**：`reset` 收窄为 `internal`（同包测试仍可用），或改名 `resetForTest` 并在 KDoc 里写明「禁止生产调用」；`subscriberCount` 可保留（运维/测试都需要）。

### [轻微][存量] 构造器对非正数 `maxBatchSize` / `maxBodyBytes` 静默忽略

- **位置**：`f_jsonrpc/src/server/JsonRpcServer.cj:372-377`、`:379-384`
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失或静默」、§10 边界
- **证据**：静态确定 —— `if (n > 0) { ... }` 之后直接 `this`，非法值既不抛错也不打日志，配置者只会看到「设了没生效」
- **描述**：`maxBatchSize(0)` / `maxBodyBytes(-1)` 会退回默认值（100 / 读 `MVCConfig`），与「显式配置优先」的承诺（`:36-37`、`:265-272`）相反，且无任何提示。同文件 `maxBatchSize(0)` 语义在别处也没有文档定义。
- **建议**：非法值抛 `IllegalArgumentException`（配置错应当启动失败，符合 `fountain-baseline.md` §4「同名注册启动直接失败」的取向），至少 `log.append(WARN)` 说明已回退。

### [轻微][存量] 测试文件里的死符号与恒等包装

- **位置**：`f_jsonrpc/src/server/JsonRpcMacro_test.cj:61-63`（`private func hidden()`，全仓无调用，只用于断言「没被注册」）、`f_jsonrpc/src/server/JsonRpcServer_test.cj:481-482`（`let schema = JsonObject()` 与 `schema.add(...)` 后再未使用，`JsonRpcMethodMeta` 构造没传 `paramsSchema`）、`f_jsonrpc/src/server/JsonRpcServer_test.cj:48-51`（`parse(value) = value`）
- **来源**：存量
- **判据**：review-checklist §1 机械动作 1（`private` 无调用者）、§1「读了不用」
- **证据**：静态确定 —— `hidden` 全仓只有定义处与 `names.contains('knowledge.hidden')` 字符串字面量命中，没有调用；`schema` 变量在 `JsonRpcServer_test.cj:480-491` 内赋值两次后无读取；`parse` 全部调用点传入的已经是 `JsonValue`（如 `:105`、`:147`）
- **描述**：均属测试内的残留（`hidden` 是刻意的反例夹具，建议加一行注释说明；`schema` 明显是漏删；`parse` 是接口收窄后留下的垫片）。
- **建议**：`hidden` 加注释「仅用于断言未被注册」；删掉 `schema` 三行；`parse` 换成直接调用或删掉。

### [轻微][存量] `imports.cj` 的两个 `internal import` 在该文件内无任何使用

- **位置**：`f_jsonrpc/src/macros/imports.cj:18-19`（`internal import std.ast.*`、`internal import fountain::f_macros.*`）
- **来源**：存量
- **判据**：review-checklist §1 机械动作 7（未使用的 `import`）
- **证据**：静态确定 —— 该文件除注释与 `package` 外只有三行 `import`，没有任何声明或表达式；`std.ast` 的使用者在同包 `JsonRpc.cj:18`（自带一份 `internal import std.ast.*`），`f_macros` 的唯一符号 `extractFirstDecl` / `topMacroAnonymousClosure` / `diagReport` 也在 `JsonRpc.cj` 内使用（`:59,182,46`）
- **描述**：宏包的 import 是**按文件**生效的，该文件里的两条 `internal` 导入没有载体可作用；只有 `:20` 的 `public import fountain::f_bean.macros.*` 有明确用途（把 `@Bean` 带给展开后的用户代码，与 `exports.cj:20-22` 同思路）。
- **建议**：删掉 `:18-19`；若担心同包其它文件遗漏导入，应在那些文件补，而不是集中写在一个空文件里（`internal import` 不会跨文件生效）。

### [轻微][存量] `@JsonRpc` 的 `namespace` 参数校验偏松

- **位置**：`f_jsonrpc/src/macros/JsonRpc.cj:39-56`（`namespaceOf`）
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」、§14「半成品：只处理部分输入」
- **证据**：静态确定 —— `:43-45` 只判 `attr[i + 1].kind == COLON` 就直接取 `attr[i + 2].value`，不校验 `attr[i + 2].kind`（`@JsonRpc[namespace: 1]` 会静默生成方法名 `1.fn`）；`:51-54` 对「有属性但没有 `namespace` 关键字」会报错（注释明确是为了不静默丢命名空间），但对「`namespace` 之外的多余属性」（如 `@JsonRpc[namespace: a, foo: b]`）在 `:44` 提前 `return`，静默忽略
- **描述**：同一个函数里，一种写法（旧的 `topic:`）报错、另一种（多余属性）静默忽略，校验口径不一致；非法 `namespace` token 会生成不可预期的方法名，错误要到运行期 `-32601` 才暴露。
- **建议**：`:44` 改成校验 `attr[i + 2].kind == IDENTIFIER` 否则 `diagReport`；解析完 `namespace` 后检查是否还有剩余 token，有则报「不支持额外属性」。

<!-- 第 4 部分 -->

### [一般][存量] 空帧入队会让 `read` 在未 `close` 时返回 0，调用方按 EOF 提前终止 SSE 响应

- **位置**：`f_jsonrpc/src/server/SseStream.cj:92-105`（`92` 行判断 `offset >= current.size`、`94` 行 `current = frame`、`97` 行 `offset = 0`、`100-104` 行拷贝循环）；入队侧 `SseStream.cj:54-69` 不校验空串
- **来源**：存量（快照模式无基线；blame `00d2a8f6d`）
- **判据**：review-checklist §11「契约与实现不符」、§10 正确性（边界/空值）；契约源为 `SseStream.cj:26`「`read` 返回 **0** 表示结束，且只有 `close()` 之后才会返回 0」
- **证据**：静态确定 —— `push('')` 把空串加入 `frames`（`push` 无长度校验）；`read` 取到该帧后 `current = ''`、`offset = 0`，`while (written < buffer.size && offset < current.size)` 一次都不执行，直接返回 `written == 0`。仓颉 `InputStream.read` 文档只约定「返回读取的字节数」（`cangjie_runtime/stdlib/doc/libs/std/io/io_package_api/io_package_interfaces.md:13-27`），0 当 EOF 是本类的自述契约；`f_mvc/src/ResponseDownload.cj:73` 的 `while (let bytes <- input.read(buf) && bytes > 0)` 与 `f_mvc/src/RequestMeta.cj:396-404` 的 chunked 流式响应都按「0 = 结束」消费，`Sse_test.cj:32-34` 的 `drain` 同样把 `<= 0` 当结束
- **描述**：任何空帧都会让 `read` 返回 0，HTTP 层随即认为响应体结束并收尾，长连接被静默关闭，而 `closed` 仍是 `false`（后续写入全部丢失）。同一契约在 `SseStream.cj:89-91`（`buffer.size == 0` 直接返回 0）也有一处例外——这是 std 的普遍约定，本身无害，但说明 `:26` 那句「只有 close 之后」并不成立，读代码的调用方容易把 0 一律当 EOF。当前仓内唯一生产者 `SseHub.frameOf`（`SseHub.cj:151-160`）总是拼出非空帧，所以尚未触发，属公开 API 上的潜伏缺陷
- **建议**：`read` 里对空帧继续取下一帧（`while` 取帧直到 `current` 非空或 `nextFrame()` 返回 `None`），或在 `push` 处拒绝空串并返回 `false`；同时把 `:26` 的契约改成「仅当 `close()` 且队列排空后返回 0；空 buffer 返回 0」

### [一般][存量] `heartbeat` 构造参数未校验，非正值会让 `wait` 在 `read` 路径抛 `IllegalArgumentException`

- **位置**：`f_jsonrpc/src/server/SseStream.cj:41-51`（构造只夹取 `capacity`，`heartbeat` 原样保存）、`SseStream.cj:115`（`available.wait(timeout: heartbeat)`）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §11「缺少边界校验 / 契约与实现不符」；`Condition.wait(timeout!: Duration)` 文档明确「如果 `timeout` 小于等于 `Duration.Zero`，抛出 `IllegalArgumentException`」（`cangjie_runtime/stdlib/doc/libs/std/sync/sync_package_api/sync_package_interfaces.md:61-84`，第 83 行）
- **证据**：静态确定 —— `init(capacity!: Int64 = 256, heartbeat!: Duration = Duration.second * 15)` 对 `capacity <= 0` 有回落（`:42-46`），对 `heartbeat` 没有任何归一化；`heartbeat = Duration.Zero` 或负值时，第一次空队列 `read` 进到 `nextFrame` 的 `wait` 就抛异常
- **描述**：异常从 `read` 直接穿透到调用方（`InputStream.read` 无返回值表示失败），SSE 请求线程在进入流式响应后崩溃，且该连接既不 `close` 也不返回数据。`heartbeat` 是 public 构造命名参数（`SseStream` 为 public 类），外部可任意传值；类注释与 `init` 都没有写参数约束。`capacity` 的静默夹取同样没有文档说明（传 0 得到容量 1，行为是「每帧都丢前帧」而不是「不限」）
- **建议**：构造时与 `capacity` 一样归一化 `heartbeat`（`<= Duration.Zero` 时回落到 15s），或对非正值抛带说明的 `IllegalArgumentException`；在 `init` 上补参数文档，写清 `capacity` 的下界与丢弃策略

### [一般][存量] `close()` 与「帧消费完」都不释放缓冲，已关闭/已读完的流仍持有最多 `capacity` 帧

- **位置**：`f_jsonrpc/src/server/SseStream.cj:145-150`（`close` 只置 `closed` + `notifyAll`）、`SseStream.cj:100-106`（`current` 消费完后不复位）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §7「缩短生命周期」、§11「资源释放不对称」、§12.1「跨线程资源」
- **证据**：静态确定 —— `close()` 之后 `frames`、`head`、`current` 原样保留；每条流最多保留 `capacity`（默认 256）个帧字符串，外加 `current` 里最后一帧的完整副本。持有路径：`SseHub.subscribers`（`SseHub.cj:51`）→ `ArrayList<SseSubscription>` → `SseSubscription.stream`（`SseHub.cj:27`）→ `SseStream.frames`；而 `SseSubscription.close()`（`SseHub.cj:36-38`）只转调 `stream.close()`，`SseHub` 没有任何退订/移除路径（`subscribers` 只在 `subscribe` 里 `add`、`reset` 里 `clear`），所以「关闭的流」仍被全局表长期强引用
- **描述**：单条流的滞留量 = 最多 256 帧 + 1 帧，乘以全局订阅表里积累的连接数。`close()` 是唯一显式的资源释放 API，却不释放任何数据；`read` 消费完一帧后 `current` 也一直指向它，直到下一帧到达。这条本身是「关闭后不回收」，真正的放大器是 `SseHub` 无退订（见「范围外提示」），因此未按严重计
- **建议**：`close()` 内在锁里 `frames.clear()`、`head = 0`、`current = ''`；`read` 在 `offset` 追平 `current.size` 时把 `current` 置空；跨文件补齐 `SseHub.unsubscribe(id)` 并在响应结束时调用

### [轻微][存量] 「丢帧只 warn 一次」只实现了一半：只置标志，没有任何告警调用

- **位置**：`f_jsonrpc/src/server/SseStream.cj:53-78`（`push` 置 `dropReported`、`dropped` getter）；消费侧 `SseHub.cj:112`（`let _ = item.stream.push(text)` 丢弃返回值）；`Sse_test.cj:72` 只断言标志
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §14「承诺了但没实现」（承诺源：`f_jsonrpc/doc/spec/add-jsonrpc-sse/design.md:58`「溢出时 `removeFirst()` 再 `addLast()`，并置 `dropped = true`（**只 warn 一次**，避免刷屏）」）
- **证据**：静态确定 —— 全仓 `.dropped` 只有 `Sse_test.cj:72` 一处读取（`grep -rn "\.dropped"`），生产代码零引用；`SseHub.publish` 用 `let _` 吞掉 `push` 的返回值，模块内也没有任何 `f_log` 调用与之关联
- **描述**：慢消费者丢事件时，服务端既不记日志也不计数，`dropped` 一旦置位永不复位。design.md 承诺的「warn 一次」完全缺失，线上只能看到事件消失，无法判断是网络抖动还是本地丢弃
- **建议**：在 `SseHub.publish` 检查 `push` 返回值并 `f_log` 各订阅一次 warn（带 `subscription.id` / `topic` / 丢弃计数），或给 `SseStream` 增加 `dropCount: Int64` 由 hub 汇总；`dropped` 的注释同步改成「是否曾经丢过帧」

### [轻微][存量] `push` 在已关闭时返回 `true`，调用方无法区分「已投递 / 已丢弃 / 已关闭」

- **位置**：`f_jsonrpc/src/server/SseStream.cj:55-58`（`if (closed) { return true }`）、`SseStream.cj:66-67`（`return pendingCount < capacity`）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §11「语义与命名不符」、§10 可维护性
- **证据**：静态确定 —— 关闭后帧被直接丢弃，却返回「本次未发生丢弃」的 `true`；真正的丢弃返回 `false`
- **描述**：返回值的语义是「没有丢帧」，而关闭分支既没入队也没丢帧计数，`false` 与 `true` 都无法表达「流已结束」。`SseHub` 现在忽略返回值所以无害，但任何按布尔值做投递统计/重试的调用方都会得到错误结论
- **建议**：文档明确「`closed` 后返回 `true` 表示不再投递」并改名（如 `tryPush`），或改成三态（枚举/`Result`）；至少在注释里写清

### [轻微][存量] SSE 过滤/补发用例只做正向断言，过滤与广播同时失效也能通过

- **位置**：`f_jsonrpc/src/server/Sse_test.cj:99-110`（topic 隔离）、`Sse_test.cj:114-124`（taskId 过滤）、`Sse_test.cj:128-139`（Last-Event-ID 补发）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §14「示例/用例覆盖不足」、§11「测试未覆盖承诺行为」
- **证据**：静态确定 —— `testTopicIsolation` 只在 `b` 上 publish，随后断言 `subscriberCount('a') == 1`，**从未读取 `a` 的流**，注释「a 收不到 b 的事件：读会走到心跳」与实际代码不符；`testTaskIdFilter` 只断言第一帧含 `one`，不检查第二帧是否混入 `two`；`testReplayAfterLastEventId` 只断言含 `three`，不检查 `one`/`two` 是否被重复补发。把 `SseHub.matches` 改成恒 `true`、或把 `publish` 改成向所有 topic 广播，这三条用例仍会全绿
- **描述**：`Sse_test.cj` 的 8 条用例覆盖了「写入能读回 / 心跳 / 丢弃 / 补发能到」，但过滤的反向行为没有任何断言；而 topic/taskId 过滤正是该接口对外的核心承诺（`SseHub.cj:57/86-93`、README 的 A2A 用例）。另外 `drain`（`Sse_test.cj:29-36`）用 `String.fromUtf8(buffer[0..count])` 解码被截断的字节，帧大于缓冲（如含中文的 100+ 字节帧）时会抛 UTF-8 解码异常，只是当前用例的帧都小于缓冲才没暴露
- **建议**：隔离用例读一次 `a` 并断言只得到 `: ping`；过滤用例再读一帧并断言不含 `two`；补发用例断言不含 `one`/`two`；`drain` 改为累积字节后一次性解码（或只用 ASCII 断言）

### [轻微][存量] `Sse_test.cj` 的 `import std.collection.*` 未使用

- **位置**：`f_jsonrpc/src/server/Sse_test.cj:18`
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 文件内只使用 `Array`/`String`/`Duration`/`JsonString`/`SseHub`，`grep -nE "ArrayList|HashMap|HashSet|ArrayDeque|LinkedList|TreeMap"` 零命中
- **描述**：多余导入增加编译依赖面（`std.collection` 整体导入），也让读者误以为用例用了集合类型
- **建议**：删除该行；`std.time`（`Duration`）、`std.unittest*`、`f_data` 保留

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分为文档子集，未提供任何性能基线（无 `cjprof` / `cjpm bench` 输出，`scope.md` 的「已有性能资料」仅 `docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md`，与本部分 20 个文件无关），因此**不产出优化方案**，相关线索全部落在「待验证假设」。

- 堆内存方案：0
- CPU 方案：0

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

> 本部分没有 profile / bench 数据，以下方案全部为「无基线（待验证）」，不进 `tasks.md`。

### [CPU] `JsonRpcServer.methods()` 每次调用重建列表并做插入排序

- **现状**：`f_jsonrpc/src/server/JsonRpcServer.cj:64-80` 每次遍历 `ConcurrentHashMap` 收集全部方法，再用插入排序按名排序；比较次数 O(n²)（n=5000 时约 1.2×10⁷ 次字符串比较，与 `JsonRpcZzHttp_test.cj:155-168` 里 5000 方法的规模同量级）。仓内当前无调用方（`grep '\.methods()'` 只命中测试），README 声明的用途是给 `tools/list` 生成稳定输出。
- **方案**：注册期维护「按名排序的不可变快照」——`addMethod` 置脏标记（`AtomicBool`），`methods()` 首次访问时重建并缓存引用；或至少把插入排序换成一次 `sort`（O(n log n)）。
- **预期**：无法量化（无基线）。理论上 n=5000 时排序从 O(n²) 降到 O(n log n)；缓存后重复调用只剩一次拷贝。
- **代价**：多一份列表引用（元素对象共享，不复制方法元数据）；`addMethod` 从纯写变成写 + 置脏；需要保证快照重建期间读到的是一致版本。
- **验证**：`cjpm bench -O2`，1k / 5k 方法各调 `methods()` 1000 次，取中位数与离散程度；同时跑 `cjprof record` 确认排序占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

> 以下均无改前基线，按规则只能作为「待验证」方案，不进修复清单。

### [CPU] `read` 逐字节索引复制，大帧回放时每次读都要做 N 次边界检查

- **现状**：`SseStream.cj:100-104` 对每字节执行 `buffer[written] = current[offset]`（`String` 下标 + `Array` 写入各带一次边界检查）。`f_mvc` 的流式写出按 `MVCConfig.downloadBufferSize` 分块读（`f_mvc/src/ResponseDownload.cj:71-75`），单次 `read` 最多拷 `buffer.size` 字节；A2A 状态事件的帧通常 100B–1KB，若推送大 payload（如工具结果）可到数十 KB
- **方案**：帧改存 `Array<Byte>`（`SseHub.frameOf` 生成 `toString().unsafeBytes()` 或编码一次），`read` 用 `Array.copyTo(dst, srcStart, dstStart, copyLen)`（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:472-475`）一次拷完剩余片段，`currentOffset` 之外不再逐字节循环
- **预期**：把每次 read 的 N 次索引/边界检查降为 1 次批量拷贝；收益随帧大小线性增长（待测）
- **代价**：`frames` 元素类型从 `String` 变 `Array<Byte>`，`SseHub`/测试的 `push` 调用点与断言需同步；`ping` 常量也要转字节
- **验证**：`cjpm bench -O2`，1KB / 100KB 两档帧各 10k 次 read，取中位数与 P95，与当前实现同机对照；`cjprof record` 看 `read` 的 self time 占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ArrayList + head + compact` 换成 `ArrayDeque`，去掉 2× 峰值与临时副本

- **现状**：`SseStream.cj:33-35` 用 `ArrayList` + `head` 模拟出队，`compact()`（`:131-143`）在 `head >= 64 && head*2 >= size` 时新建 `kept` 把存活帧全部复制一遍再回填。队列满后每次 `push` 只 `head++`，`frames.size` 继续增长到约 `2 × capacity` 才压缩，因此稳态下 256 容量的流最多持有约 512 个槽位，压缩瞬间还多一份 `kept` 副本（再 +256 引用）
- **方案**：改用 `std.collection.ArrayDeque<String>`（`ArrayDeque.addLast` / `removeFirst` 均存在，见 `cangjie_runtime/stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:288-291`、`:427-430`），丢弃 `head`/`compact` 与临时 `kept`；这与设计文档 `doc/spec/add-jsonrpc-sse/design.md:44` 原本写的 `ArrayDeque<Array<Byte>>` 一致
- **预期**：每流稳态槽位从 ~512 降到 ~257，压缩时的临时副本与 O(k) 复制消失；对象数减少与峰值内存下降需实测
- **代价**：`ArrayList` 的按下标访问（`frames[head]`）改成 `removeFirst()`，`push` 的「丢最旧」从 `head++` 改成 `removeFirst()`（返回 `?T` 需处理 `None`）；行为语义不变
- **验证**：1000 条并发流、每流 256 帧稳态负载，`-O2`，对比 `getAllocatedHeapSize()` 峰值 / RSS / 每秒 push 吞吐
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 设计文档「10 条批量比 10 次单发快 5~8 倍」无实测依据，可能随网络 RTT / 服务端耗时结构变化 | `doc/f_jsonrpc模块设计.md:1217` | 同环境、同输入的批量与单发对照 | `cjpm bench -O2`：1 条 ×1000 次 vs 10 条 ×100 次，取中位数与 P95，记录本机 loopback RTT |
| 2 | 设计文档「`toString()` 比 `toJsonString()` 少 30~50% 字节」未给样本 | `doc/f_jsonrpc模块设计.md:1215` | 真实响应体字节统计 | 对 20 个典型响应（含 `@DataAssist` 对象、批量 10 条）分别取两种序列化长度 |
| 3 | SSE 长连接「每请求一线程」的并发上限与内存占用未量化，可能成为线程耗尽面 | `SseController.cj:36`（`stream()` 返回不结束的 `InputStream`）、`doc/spec/add-jsonrpc-sse/design.md:87` | 并发连接数 → 线程数 / RSS 曲线 | 用 200 / 500 / 1000 条并发 `/rpc/stream` 压测，记录 `f_mvc` 线程池配置、线程数与 RSS |
| 4 | 客户端 `batch` 用 `id.toString()` 做索引键，服务端若回显不同的等价表示（如 `1` vs `1.0`）会导致整批落成 `-32603` | `JsonRpcClient.cj:127`、`:145` | 非本模块服务端的 id 回显格式样本 | 用第三方 JSON-RPC 服务端（或改写回显）跑一条 `batch`，核对 `id` 文本形式是否与请求一致 |
| 5 | SSE 服务端 `recent`（每 topic 256 帧）与 `subscribers`（按 topic 累积）没有 topic 数量上限，`topic` 又来自 `/rpc/stream?topic=` 外部输入，可能被构造成无界增长 | `SseHub.cj:51-52`、`SseController.cj:44-51` | 稳定态下不同 topic 数与 RSS / 堆占用的关系 | 连续用 1k / 10k 个不同 topic 订阅 + 发布，观察 `getAllocatedHeapSize()` 与 RSS 是否回落 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ThreadLocal.get()` + `match` 的每次响应开销在真实 RPC 延迟中占比可忽略（设计文档只给了 `-O0` 分配量 32 B/op，没有耗时占比） | `f_jsonrpc/src/client/JsonRpcClient.cj:269-277,354` | 单次 `readBuffer()` 的 ns 与端到端 RPC 耗时的比值 | `cjprof record` 跑 10k 次小响应调用（`-O2`），看 `readBuffer` self time 占比 |
| 2 | `callAsync` 的线程创建是并发场景的主要成本，且线程数在 1k 级会触发调度/内存压力 | `f_jsonrpc/src/client/JsonRpcClient.cj:97-101` | 并发 100/1k/5k 时的 P99 延迟、线程数与 RSS | 压测脚本 + `ps -L` / 线程数埋点，对比有界池版本 |
| 3 | `readCapped` 每块 `buffer[0..size]` 切片复制占大响应处理成本的可测比例（现有 `send_multichunk` 只给 `allocPerCall=66,242 B`，未拆出拷贝项） | `f_jsonrpc/src/client/JsonRpcClient.cj:365` | 24 KiB / 1 MiB 响应的分段耗时与分配归因 | `F_JSONRPC_BENCH` 加分段计时，或 `cjprof` 看 `Array` 拷贝相关栈 |
| 4 | `batch` 在 100 条规模时 `JsonArray(list:)` + `toString()` 的峰值内存与耗时占比（客户端无上限校验，规模由调用方决定） | `f_jsonrpc/src/client/JsonRpcClient.cj:118` | 100/1k/10k 条的峰值分配与中位耗时 | `case=batch{N}` 基准，记录 `allocPerCall` 与峰值 `getUsedHeapSize()` |

<!-- 第 3 部分 -->

> 无性能测试数据，仅作为下一轮补数据的清单，不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 所有 topic 的 SSE 发布被一把全局锁串行，发布线程 > 2 时 P99 延迟随并发上升 | `f_jsonrpc/src/server/SseHub.cj:94-116` | 锁等待时长、BLOCKED 线程数、P99 | 4/8 个发布线程 × 200 订阅者压 `/rpc/stream`，采线程状态 + 分段计时；`cjprof` 看不到锁竞争，必须另采线程状态 |
| 2 | 死订阅条目导致 `publish` 单次耗时随「累计连接数」增长 | `f_jsonrpc/src/server/SseHub.cj:110-114` | 订阅表规模 vs 单次 publish self time | 反复建连/断连 N=1k/10k 次后，测 `publish` 1000 次的中位耗时，并采样 `getAllocatedHeapSize()` |
| 3 | `methods()` 的 O(n²) 排序在 n=5000 时到达毫秒级 | `f_jsonrpc/src/server/JsonRpcServer.cj:69-78` | 单次调用耗时 | `cjpm bench -O2`，n = 100 / 1000 / 5000 三档各 1000 次 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `read` 的逐字节复制是大帧 SSE 回放的主要自耗时 | `SseStream.cj:100-104` | `read` 的 self time 占比、帧大小分布 | `cjprof record` 跑 10k 帧回放（1KB 与 100KB 两档），对照 `copyTo` 版本 |
| 2 | 每流 `mutex` 与 `SseHub` 全局锁串联（publish 持 hub 锁调 `push` 取流锁）限制多订阅者下的 publish 吞吐 | `SseStream.cj:55`、`SseStream.cj:111`；`SseHub.cj:94-116` | 锁等待时长、BLOCKED 线程数、publish P95 | 100/1000 个订阅者并发 publish，分段计时 + 线程状态采样（CPU profile 看不到锁等待） |
| 3 | `compact()` 的 O(k) 重建在「慢消费者 + 持续 publish」下形成周期性 CPU 尖峰 | `SseStream.cj:131-143` | 每次 compact 耗时与触发频率 | 容量 256、publish 速率高于读速率 10 倍，分段计时统计 compact 调用次数与总耗时 |

## 文件覆盖

> 与 `files/f_jsonrpc.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jsonrpc/README.md` | .md | ✅ | — |
| 2 | `f_jsonrpc/README_en.md` | .md | ✅ | — |
| 3 | `f_jsonrpc/doc/f_jsonrpc模块设计.md` | .md | ✅ | — |
| 4 | `f_jsonrpc/doc/spec/add-f-jsonrpc/design.md` | .md | ✅ | — |
| 5 | `f_jsonrpc/doc/spec/add-f-jsonrpc/proposal.md` | .md | ✅ | — |
| 6 | `f_jsonrpc/doc/spec/add-f-jsonrpc/specs/json-rpc/spec.md` | .md | ✅ | — |
| 7 | `f_jsonrpc/doc/spec/add-f-jsonrpc/tasks.md` | .md | ✅ | — |
| 8 | `f_jsonrpc/doc/spec/add-f-jsonrpc/verify-report.md` | .md | ✅ | — |
| 9 | `f_jsonrpc/doc/spec/add-jsonrpc-macro/design.md` | .md | ✅ | — |
| 10 | `f_jsonrpc/doc/spec/add-jsonrpc-macro/proposal.md` | .md | ✅ | — |
| 11 | `f_jsonrpc/doc/spec/add-jsonrpc-macro/specs/json-rpc/spec.md` | .md | ✅ | — |
| 12 | `f_jsonrpc/doc/spec/add-jsonrpc-macro/tasks.md` | .md | ✅ | — |
| 13 | `f_jsonrpc/doc/spec/add-jsonrpc-macro/verify-report.md` | .md | ✅ | — |
| 14 | `f_jsonrpc/doc/spec/add-jsonrpc-sse/design.md` | .md | ✅ | — |
| 15 | `f_jsonrpc/doc/spec/add-jsonrpc-sse/proposal.md` | .md | ✅ | — |
| 16 | `f_jsonrpc/doc/spec/add-jsonrpc-sse/specs/jsonrpc-sse/spec.md` | .md | ✅ | — |
| 17 | `f_jsonrpc/doc/spec/add-jsonrpc-sse/tasks.md` | .md | ✅ | — |
| 18 | `f_jsonrpc/doc/spec/fix-jsonrpc-mcp-review-findings/specs/json-rpc/spec.md` | .md | ✅ | — |
| 19 | `f_jsonrpc/doc/spec/record-f-jsonrpc-batch-blocker/design.md` | .md | ✅ | — |
| 20 | `f_jsonrpc/doc/spec/record-f-jsonrpc-batch-blocker/proposal.md` | .md | ✅ | — |
| 21 | `f_jsonrpc/doc/spec/record-f-jsonrpc-batch-blocker/tasks.md` | .md | ✅ | — |
| 22 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/design.md` | .md | ✅ | — |
| 23 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/proposal.md` | .md | ✅ | — |
| 24 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/specs/json-rpc/spec.md` | .md | ✅ | — |
| 25 | `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/tasks.md` | .md | ✅ | — |
| 26 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/design.md` | .md | ✅ | — |
| 27 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/proposal.md` | .md | ✅ | — |
| 28 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/specs/json-rpc/spec.md` | .md | ✅ | — |
| 29 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/tasks.md` | .md | ✅ | — |
| 30 | `f_jsonrpc/doc/spec/rework-jsonrpc-macro-and-demos/verify-report.md` | .md | ✅ | — |
| 31 | `f_jsonrpc/src/JsonRpc.cj` | .cj | ✅ | — |
| 32 | `f_jsonrpc/src/base/JsonRpcException.cj` | .cj | ✅ | — |
| 33 | `f_jsonrpc/src/base/JsonRpcMeta.cj` | .cj | ✅ | — |
| 34 | `f_jsonrpc/src/base/JsonRpcProtocol.cj` | .cj | ✅ | — |
| 35 | `f_jsonrpc/src/client/HttpJsonRpcTransport_test.cj` | .cj | ✅ | — |
| 36 | `f_jsonrpc/src/client/JsonRpcClient.cj` | .cj | ✅ | — |
| 37 | `f_jsonrpc/src/client/JsonRpcClient_test.cj` | .cj | ✅ | — |
| 38 | `f_jsonrpc/src/client/JsonRpcSseClient.cj` | .cj | ✅ | — |
| 39 | `f_jsonrpc/src/client/ReadBufferReuse_test.cj` | .cj | ✅ | — |
| 40 | `f_jsonrpc/src/client/SocketSseConnection.cj` | .cj | ✅ | — |
| 41 | `f_jsonrpc/src/client/SseClient_test.cj` | .cj | ✅ | — |
| 42 | `f_jsonrpc/src/exports.cj` | .cj | ✅ | — |
| 43 | `f_jsonrpc/src/macros/JsonRpc.cj` | .cj | ✅ | — |
| 44 | `f_jsonrpc/src/macros/imports.cj` | .cj | ✅ | — |
| 45 | `f_jsonrpc/src/server/JsonRpcArgs.cj` | .cj | ✅ | — |
| 46 | `f_jsonrpc/src/server/JsonRpcContext.cj` | .cj | ✅ | — |
| 47 | `f_jsonrpc/src/server/JsonRpcController.cj` | .cj | ✅ | — |
| 48 | `f_jsonrpc/src/server/JsonRpcMacro_test.cj` | .cj | ✅ | — |
| 49 | `f_jsonrpc/src/server/JsonRpcMapping.cj` | .cj | ✅ | — |
| 50 | `f_jsonrpc/src/server/JsonRpcMapping_test.cj` | .cj | ✅ | — |
| 51 | `f_jsonrpc/src/server/JsonRpcMethodMeta.cj` | .cj | ✅ | — |
| 52 | `f_jsonrpc/src/server/JsonRpcRegistry.cj` | .cj | ✅ | — |
| 53 | `f_jsonrpc/src/server/JsonRpcServer.cj` | .cj | ✅ | — |
| 54 | `f_jsonrpc/src/server/JsonRpcServer_test.cj` | .cj | ✅ | — |
| 55 | `f_jsonrpc/src/server/JsonRpcTimeout_test.cj` | .cj | ✅ | — |
| 56 | `f_jsonrpc/src/server/JsonRpcZzHttp_test.cj` | .cj | ✅ | — |
| 57 | `f_jsonrpc/src/server/JsonRpcZzSse_test.cj` | .cj | ✅ | — |
| 58 | `f_jsonrpc/src/server/SseController.cj` | .cj | ✅ | — |
| 59 | `f_jsonrpc/src/server/SseHub.cj` | .cj | ✅ | — |
| 60 | `f_jsonrpc/src/server/SseMapping.cj` | .cj | ✅ | — |
| 61 | `f_jsonrpc/src/server/SseStream.cj` | .cj | ✅ | — |
| 62 | `f_jsonrpc/src/server/Sse_test.cj` | .cj | ✅ | — |

合计：`.cj` 32 个 / `.md` 30 个 / 共 62 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 本部分无 `.cj`，语义正确性由第 2–4 部分覆盖；文档层的契约正确性命中 1 条（重试边界 #5）。安全性方面核对了「`-32603` 固定文案、不泄漏内部方法清单」的文档承诺与 `JsonRpcServer.cj:219-220` 一致，无缺口 |
| §1 死代码 | 0 | 无 `.cj` 可判可达性；改为对文档引用的符号做存在性检索：`JsonRpcRegister` / `parseTimeout` / `forwardableHeaders` / `inputSchema` / `outputSchema` / `Context.meta` 在当前 `src/` 中均不存在，属「文档引用已删除 API」而非死代码，已记入 #11 |
| §2 重复逻辑 | 1 | 已比对 4 份文档中的错误码表、批量规则、上限表：批量顺序出现相反结论，错误码表 4 处重复（#10） |
| §3 空实现 | 1 | 逐个核对文档承诺的副作用：SSE 丢弃告警（`push` 返回值被丢弃、`dropped` 无生产读取者）命中（#6）；其余承诺（超时 `spawn`、schema 预编译、`setResponseHeader` no-op）均与实现一致 |
| §4 栈溢出 | 0 | 本部分无递归代码；文档未描述递归遍历结构，无「承诺递归能力」缺口 |
| §5 OOM | 0 | 文档承诺的上限（`maxBatchSize` 100、`maxBodyBytes` 2 MiB、SSE 订阅者缓冲 256、响应 8 MiB）逐条与实现核对均成立；内存类疑点（topic 维度无上限）缺数据，已列入待验证假设 5 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据；设计文档 §8 的倍数与百分比无基线，已列入待验证假设 1、2 |
| §6.2 大粒度锁 | 0 | 本部分无 `.cj`；`SseHub` 在全局 `Mutex` 内 `push` 与序列化的疑点属第 3 部分范围，见文末「范围外提示」 |
| §6.3 并发串行 | 0 | 文档未承诺并发模型；`JsonRpcServer` / `JsonRpcClient` 的并发描述与实现（`ConcurrentHashMap`、`AtomicInt64`）一致 |
| §6.4 低效算法 | 0 | 文档只声明方法表 O(1) 查找，实现用 `ConcurrentHashMap` 成立；无其它算法承诺 |
| §7 降堆内存方案 | 0 | 无基线。`record-f-jsonrpc-batch-blocker` 的四个临时集合与 `JsonRpcClient.batch:110-155` 现状一致，阻断结论成立，不构成方案 |
| §8 降 CPU 方案 | 0 | 无基线，无可执行方案（见「优化可行性方案」） |
| §9 local mode 可行性 | 0 | 文档只记录 `batch` 的两个逃逸阻断（`JsonArray(list:)` 与 `toArray()`），与实现结构一致；无峰值内存数据，不作可行性结论 |
| §11 现有代码的 BUG（存量） | 1 | 命中重试阶段不可区分（#5，证据待确认）；另核对了 `id` 保真、空批量、批量超限、`-32001` 不产生等文档明示的边界，与 `JsonRpcServer.cj` 一致 |
| §12 并发安全与锁粒度 | 0 | 本部分无并发代码；错误码与上限等共享状态描述不涉及线程模型。SSE 全局锁与订阅注册表属第 3 部分 |
| §14 功能完备性与 README 覆盖 | 3 | 命中 #1（声明未实现）、#6（告警未接线）、#7（SSE 公共 API 无使用文档）；其余公开 API（base/server/client 全部符号）已逐项在 README 中定位到段落 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个 `.md` 全部读完，无缺失 |

### 第 2 部分

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

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 3（查询串解码、`timeout='0s'`、超时异常无观察）；设计 3（SSE 订阅生命周期、锁粒度、测试专用 public API）；可读性/接口健壮性 1（构造器静默忽略非法值）；安全性并入订阅泄漏一条（`topic` 来自外部输入 + 表无上限 = 内存 DoS 面）；语言特性侧核对了 `synchronized` 是关键字作用域（`return` 会解锁并返回外层，`MvcProbe.ensure` 写法合法）、`Future.get(Duration<=0)` 等价 `get()`，均查 std / 语言文档后判定 |
| §1 死代码 | 2 | 逐个核对了本部分 20 个文件里的 `private` / `internal` 符号：`isValidId`、`asValue`、`resolveBodyLimit`、`deadlineOf`、`invokeHandler`、`checkParams(Ex)`、`notifyOrError`、`respondOk/Error`、`markStatusCode`、`subscribersOf`、`matches`、`frameOf`、`queryOf`、`textOf`、`intOf`、`namespaceOf`、`expand`、`asFunc`、`generateMethod`、`ident`、`compiledSchema`、`derive`、`namespaceOf`（meta）均有调用者；`SseEvent`（internal class）的 `public` 成员被 `SseHub` 使用，不是死代码。命中 2 条：测试内死符号（`hidden()` / 未用 `schema` / `parse` 恒等包装）与 `imports.cj` 未使用导入。`JsonRpcContext.endpoint`、`SseSubscription.id`、`SseHub.reset/subscriberCount` 属对外可达 `public`，只作信息记录，未判死代码（`reset` 另列可见性建议） |
| §2 重复逻辑 | 2 | 同文件两两比对：`processOne` 未解析分支 vs `notifyOrError`（语义同、日志文案异）；`REPLAY_CAPACITY` vs `SseStream` 默认 `capacity` 的 256 字面量耦合。另核对了 `respondError`/`respondOk`、`checkParams`/`checkParamsEx`、`handleRoot`/`handleTopic`、`JsonRpcMapping`/`SseMapping` 的构造体、`queryOf`/`textOf`/`intOf`：前四组是「薄包装 / 两条路由 / 刻意不复用（注释已说明）」，不算重复；`SseController` 手写查询解析与 `f_mvc` 的 `url.queryForm` 属跨层重复，但根因是解码缺失，已计入「一般」#3 不重复计数。跨文件搜了相同错误文案与字面量：`'Invalid Request'` 系列均在 `JsonRpcServer` 内单点产生 |
| §3 空实现 | 0 | 逐个看了空函数体与 `catch {}`：`SseSubscription.close` 有关闭语义；`JsonRpcTestController` 两个 `()` 函数体是 `MVCStarter.generateAndRegister` 的路由夹具；`FakeSseConnection.close()` 是测试替身的有意 no-op；`SingleDistributor.register` 是实现接口所需；`JsonRpcMacroTestRPC.touch()` 空体是 `Unit` 返回值用例。`handle` 里 `catch (_: Exception) { parsed = None }` 把解析失败显式转成 `-32700` 返回给调用方，不属于静默吞异常 |
| §4 栈溢出 | 0 | 本部分无递归：宏 `expand` → `extract` 是单层调用，`namespaceOf`/`asFunc`/`generateMethod` 无自调用；SSE 补发与批量处理都是单层 `for`，不遍历用户可控的树；无 `clone`/`deepCopy` 式递归 |
| §5 OOM | 1 | 「严重」#1（`subscribers` 无界 + `topic` 外部可控，量化见该条）。其余面已核对：请求体受 `maxBodyBytes`（默认 2 MiB）与 `f_mvc` 双重限制、批量 ≤ 100（`DEFAULT_MAX_BATCH_SIZE`）、`recent` 每 topic ≤ 256 帧、`SseStream` 队列有界丢最旧（`SseStream.cj:59-67`），均有拒绝路径 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile / bench 数据，`SseHub` 锁与 `methods()` 排序都只作「待验证假设」#1-#3，不作热点结论 |
| §6.2 大粒度锁 | 1 | 「一般」#2（全局 `Mutex` 内含 `frameOf` 序列化 + 全订阅遍历 + 补发循环）。按 §6.2 要求给了临界区内容与竞争方，持有时长量级标「待确认」 |
| §6.3 并发串行 | 0 | 并发串行点与 §6.2 同根因（所有发布抢同一把锁），不重复计数；`invokeHandler` 是「一次 spawn 一次 get」，不是批量装并发，属设计如此（超时语义需要） |
| §6.4 低效算法 | 0 | 已核对：`methods()` 插入排序 O(n²) 但**仓内无调用方**，无法成立热点 → 转「优化可行性方案（CPU，无基线）」；`recent` 的 `remove(at: 0)` 只在固定 256 上限内、每次最多一次，不判；`subscribersOf` 每次 `publish` 新建一个空 `ArrayList`（`:139-144`）属微量分配，无数据不判 |
| §7 降堆内存方案 | 0 | 本部分最大的常驻内存（SSE 订阅表与每订阅 ≤256 帧缓冲）是无界增长缺陷，已在「严重」#1 处理；其余分配均有上限且生命周期限于单次请求，找不到可用峰值数据支撑的独立方案 |
| §8 降 CPU 方案 | 1 | `methods()` 快照缓存 + 排序降复杂度（无基线，不进 tasks） |
| §9 local mode 可行性 | 0 | `SseHub.frameOf` 的 `JsonObject` 树是函数内临时对象，但结果 `String` 会逃逸进 `recent` 与各队列，`@ local!` 不成立；且没有前后峰值内存数据，收益不可证。`JsonRpcServer` 的响应对象同样逃逸给 `f_mvc` |
| §11 现有代码的 BUG（存量） | 5 | 「严重」#1 + 「一般」#2-#5（锁粒度、查询串未解码、超时未取消/异常无观察、`'0s'` 语义矛盾）。另核对了以下边界均无缺陷：`id` 类型校验（string/number/null，`JsonRpcServer.cj:320-322`）、`id: null` 视为非通知、空批量 → 单个 `-32600`、批量超限 → 单个 `-32003` 且不部分执行、非对象批量项 → 该项 `-32600`、通知失败不返回体但落 WARN、`-32603` 固定文案不泄漏内部信息、`SseController` 的 `Last-Event-ID` 优先于 `cursor`、`intOf` 非法值回落 0 |
| §12 并发安全与锁粒度 | 1 | §12.1 未命中：`SseHub` 的静态可变状态全程在同一把 `Mutex` 内读写（`subscribe`/`publish`/`subscriberCount`/`reset` 都在 `synchronized(mutex)` 里，`subscribersOf` 只在锁内调用），`JsonRpcServer.methods_`/`topics` 用 `ConcurrentHashMap` 且写入是 `addIfAbsent`（无检查-然后-写入），未发现数据竞争。§12.2 命中 1（「一般」#2）。另记录一个**已知无害窗口**：`addMethod` 先写 `methods_`（`:57`）后写 `topics`（`:60`），启动期若有并发请求，可能短暂得到 `-32004`；只发生在 static init 注册阶段，未单列 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不重复计数：SSE 丢帧 warn 未接线、README 的 SSE 章节缺失已由第 1 部分计入。本部分核对了 `SseHub` 4 个 public 方法 / `SseSubscription` 2 个 public 成员 / `SseController` 端点参数，均与 README 的符号清单一致（缺段落问题归第 1 部分）；`JsonRpcServer.methods()` 的「供 `tools/list` 使用」找不到真实消费者（`f_mcp` 用自建 `toolsSorted`，见 `f_mcp/src/server/McpServer.cj:582-600`），已作为「优化方案」的现状说明，未按「承诺未实现」计缺陷（它只是注释与 README 的用途描述，不影响协议） |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完，无 `.md`（`.md` 归第 1 部分）。§13 文档一致性在本部分只做「代码侧对文档承诺」的核对（spec `add-jsonrpc-sse/specs/jsonrpc-sse/spec.md:39-47` 的有界与告警、`:34-37` 的超出缓冲补发），文档行本身的问题归第 1 部分 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 正确性 2（空帧导致伪 EOF、heartbeat 未校验）；设计 0（`SseStream` 单责、`SseHub` 分桶合理）；语言特性 0（`Mutex`+`Condition` 用法与官方 `sync.md:622-652` 的 `synchronized` 语义一致，`condition()` 在持锁下创建符合 `sync_package_classes.md:8965-8997`）；可读性 0（命名与注释整体清晰）；安全性 0（无外部输入解析、无凭据、无注入面） |
| §1 死代码 | 1 | 已逐个核对 `private` 符号：`mutex`/`available`/`capacity`/`heartbeat`/`frames`/`head`/`current`/`offset`/`closed`/`dropReported`/`nextFrame`/`compact`/`PING` 全部有引用，`Sse_test.drain` 被 8 处调用；`protected` 声明 0 个；`public`（`SseStream` 为 public 类，成员对外可达）不判死代码，仅记录仓内 `isClosed`/`dropped` 无生产调用；命中：1 个未使用 import |
| §2 重复逻辑 | 0 | 已把本部分 2 个文件内 8 个函数体（`push`/`dropped`/`isClosed`/`read`/`nextFrame`/`compact`/`close` + `drain`）压成「输入-输出-副作用」两两比对，无同语义实现；跨文件搜相同字面量/模板：`String.fromUtf8` 在其它测试里出现但语义不同（整块解码 vs 截断解码），`Int64(frames.size) - head` 只在 `push`/`nextFrame` 各出现一次，属同一不变量的两处读取，不构成可合并重复 |
| §3 空实现 | 0 | 两个文件无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；「丢帧不告警」属「有代码但没接线」，已在 §14 计 1 条 |
| §4 栈溢出 | 0 | `read`/`nextFrame`/`compact`/`push` 均为单层循环或直接转调，无自递归、无间接递归、无递归遍历外部结构 |
| §5 OOM | 0 | 每流队列由 `capacity`（默认 256）+ `current` 封顶，属有界容器；单帧大小由调用方决定但不来自不可信报文，未按报文长度预分配。全局订阅表无界增长在 `SseHub`（范围外提示） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；逐字节拷贝、compact 周期、锁串联三项只进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 0 | 临界区只有 `ArrayList` 索引/追加、最多约 512 项的 `compact` 复制与 `notifyAll`，无 I/O、日志、序列化、外部回调；`wait` 会释放锁（`sync_package_interfaces.md:51-59`）。锁是否已成热点缺数据，见假设 #2 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池/批量任务，不存在「形式并发实际串行」 |
| §6.4 低效算法 | 0 | 确认存在两处低效写法：`read` 逐字节拷贝、`compact` 全量重建（均为 O(n) 且无提前退出优化空间），但无耗时占比数据，按规则归入优化方案与假设，不计缺陷 |
| §7 降堆内存方案 | 1 | `close()`/消费完成后不释放 `frames`、`current`（一般，见发现 3）；另 1 条 `ArrayList+head` → `ArrayDeque` 方案（无基线） |
| §8 降 CPU 方案 | 1 | `read` 逐字节复制改批量 `copyTo`（无基线） |
| §9 local mode 可行性 | 0 | `read`/`nextFrame` 不分配对象；`compact` 内的 `kept` 是短生命周期 `ArrayList`，但函数返回后无逃逸、规模 ≤256，收益只能靠峰值内存证明，无数据，不列方案 |
| §11 现有代码的 BUG（存量） | 4 | 发现 1/2/3/5（空帧伪 EOF、heartbeat 未校验、关闭不释放、closed 返回值）全部为存量；边界（空串/空 buffer/非正 Duration）、空值、资源、契约四类已逐函数核对；测试用例缺陷（6）归 §14 |
| §12 并发安全与锁粒度 | 0 | 共享可变状态 `frames`/`head`/`closed`/`dropReported` 全部在 `mutex` 内读写；`current`/`offset` 只由 `read` 读写，符合 `InputStream` 单读线程约定（`f_mvc` 在请求线程内 `copy`），`close()` 可跨线程但只写受锁保护的 `closed`；单锁、无嵌套、`wait` 释放锁，未发现死锁或丢唤醒路径 |
| §13 文档一致性 | 0 | 本部分无 `.md` 文件；与本部分代码相关的文档冲突（README 仍称不做 SSE、tasks.md 写 -1）在「范围外提示」中列出，不计入本部分 |
| §14 功能完备性与 README 覆盖 | 2 | 「丢帧只 warn 一次」未接线（`design.md:58` 承诺，`SseStream.cj:53-78` + `SseHub.cj:112` 无告警）；SSE 过滤/补发用例缺反向断言（`Sse_test.cj:99-139`）。`SseStream` 的 public 成员均在 README「其他公开 API」中列名（`README.md:538`），`close()`/构造参数未展开属 README 部分 |
| 文件覆盖（§13 等） | 2/2 | 与 `files/f_jsonrpc.part4.txt` 一一对应，无缺项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 23 |
| 轻微 | 22 |
| 其中存量 | 46 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：文档整体结构是合格的：README 有包结构、端点表、错误码表、上限表、迁移表和完整 API 参考，设计文档保留了决策依据，归档 spec 也都带验证报告，明显高于「只有一段用法」的水平。本部分的问题几乎都属同一类——**文档滞后于实现**：SSE 整套能力已经落地并被 `f_a2a` 依赖，README 正文却仍写「不做 SSE」（#1），同一份 README 末尾又列出这些类；英文版停在 500ms 默认超时的旧世界（#2）；`@JsonRpcMapping` 的参数面、`ClientOptions.timeout` 的语义与实现不符（#3 #4）。这类偏差不会让代码跑不起来，但会让使用者按错误的契约设计重试、超时与鉴权。

唯一需要优先确认的是 #5：客户端把 `client.send` 的所有异常都归为「可重试的建连失败」，与「读响应阶段永不重试」的公开承诺在边界上不重合；一旦确认 `stdx.net.client.send` 覆盖响应头阶段，非幂等方法就有重复执行风险，届时应升级为严重项。其余一般项（SSE 告警未接线 #6、SSE 文档缺失 #7）可以排期修，轻微项属文档卫生。

阻塞项：无。建议合并前由主 Agent 把 #1 #2 #3 #4 并入模块报告的 §13 汇总，避免与第 2–4 部分的源码结论重复计数。

---

### 范围外提示（不计入本部分统计）

- `f_jsonrpc/src/server/SseHub.cj:61-82` 在全局 `Mutex` 内做补发与 `push`，`publish` 又在锁内序列化 JSON 并遍历全部订阅者；且 `subscribers` 从未在订阅关闭时移除条目（`SseSubscription.close` 只关流），`recent` 按 topic 无上限累积（`topic` 来自外部查询参数）。锁粒度属 §6.2/§12.2，注册表无界属 §5，建议第 3 部分（`SseHub.cj` / `SseController.cj`）重点核实。
- `f_jsonrpc/src/server/SseController.cj:68-70` 只设置 `Cache-Control` / `X-Accel-Buffering`，未显式写 `Transfer-Encoding: chunked`；`doc/spec/rework-jsonrpc-macro-and-demos/design.md:31-33`（D5）记录 stdx 对无长度 `InputStream` body 要求显式 chunked，否则 500。若 `f_mvc` 的 `respond(InputStream)` 已代设则无事，建议第 3/4 部分用 `/rpc/stream` 冒烟确认。

**第 2 部分**：本部分（客户端与协议常量 + 3 份规格文档）代码结构清晰、注释密度高，`readCapped` 的线程本地缓冲改造与 `HttpJsonRpcTransport_test` / `ReadBufferReuse_test` 的覆盖质量明显高于模块平均水平：超限检测、流式截断、连接复用、跨线程隔离都有针对性用例，未发现崩溃、数据损坏或无界增长类静态缺陷。

主要风险集中在**协议层与网络层的边界**，且都属存量：

1. 客户端只做「JSON 能否解析」的最低校验，`id` 回显、`jsonrpc` 版本、HTTP 状态码三个协议自检点全部缺失，导致错配响应与 413/5xx 都塌缩成 `-32603`（发现 2、3）；批量路径反而按 id 校验，两条路径严格度不一致。
2. 超时语义分裂：`timeout` 只管 HTTP 传输、注入 transport 即失效，`callAsync` 无线程上限也无 deadline，「可重试」的判定把读超时也算进去（发现 4、5）——非幂等方法在开启重试后可能重复执行，这是本部分最需要在文档与实现上对齐的一条。
3. SSE 客户端的结束/异常/并发三条路径都没写完：只处理 `None`，异常穿透、`retry=0` 把正常收尾当失败、`close()` 跨线程会漏关连接（发现 6-9）。同构部署有 15s 心跳兜底，对接第三方 SSE 时风险会立刻显形。

建议排期：先修发现 1（空批量，改动 3 行）+ 发现 7（`retry<=0` 语义），再统一「超时与重试」契约（发现 3、4、5），最后补 SSE 的异常与并发语义（发现 6、8、9）。轻微项可与上述改动合并处理。

存量缺陷共 15 条（一般 9 + 轻微 6），是否纳入修复待用户决定；优化方案 2 条均无改前基线，只作为下一轮补数据的候选，不进修复清单。

**范围外提示**：`f_data/src/json/JsonValue.cj:176-200` 的 `fromJson` 对嵌套数组/对象递归解析（递归点 `:185`、`:196`）且无深度上限，`JsonRpcClient.parseValue`（`JsonRpcClient.cj:199`）直接调用；恶意深嵌套响应可触发栈溢出，建议在 `f_data` 轮次单独评估。

**第 3 部分**：协议主路径的工程质量明显高于一般水平：批量 / 通知 / 空批量 / 批内部分失败 / `id` 保真 / `-32003` 不部分执行 / `-32603` 固定文案，全部与设计文档 4.7-4.8 与 `-32xxx` 码表逐条对得上，配套测试（`JsonRpcServer_test` + `JsonRpcTimeout_test` + `JsonRpcZzHttp_test`）也确实在真实 HTTP 面上验证了 Content-Type、chunked 与线程上下文恢复，不是只测纯函数。

**阻塞项只有一条**：SSE 订阅表没有生命周期终点（「严重」#1）。它同时解释了 `subscriberCount` 失真、`publish` 随运行时长变慢、以及内存随累计连接数增长——`f_a2a` 这类长跑服务接上 SSE 后必然踩到，建议优先修（`SseSubscription.close()` 摘除 + 包装 `InputStream` 的 `close()` + 每 topic 上限）。

可以排期的有：`SseHub` 一把全局锁跨 topic 串行（#2）、SSE 端点手写查询解析缺百分号解码（#3）、超时后不发 `future.cancel()` 且迟到异常无人观察（#4）、`timeout='0s'` 的双重语义（#5）。第 4、5 条都是边角配置语义，改动小、风险低，适合顺手收口。

轻微项集中在测试残留、字面量耦合、测试专用 public API 与宏参数校验，不影响线上行为。性能方面本部分没有任何 profile / bench 数据，锁竞争与 `methods()` 排序成本一律只记为「待验证假设」，未写入结论。

**第 4 部分**：`SseStream` 是一个约 150 行的阻塞队列式 `InputStream`，核心设计是对的：单锁 + 条件变量实现阻塞读、`wait` 超时产出 `: ping` 注释帧、队列满丢最旧不阻塞发布方、读写分离的 `head` 游标加定期压缩控制内存，与 `design.md` 的 D3/D4 基本一致。真正的问题集中在契约边界而不是主流程：`read` 用 0 表达 EOF，却在空帧和空 buffer 两个分支提前返回 0（一般）；`heartbeat` 作为 public 参数不校验，非正值会把 `read` 变成抛异常（一般）；`close()` 不释放队列，配合 `SseHub` 无退订把「关闭」变成「仍然占内存」（一般，放大器在范围外）。这四条都不影响当前默认路径（`SseHub.frameOf` 不产空帧、heartbeat 用默认值、`SseHub` 目前也不调 `close`），属于「一旦被外部按 public API 使用就会踩」的潜伏缺陷。

测试侧 8 条用例覆盖了写入读回、心跳、丢弃、补发、过滤的正向路径，但三条过滤类用例都只断言「目标事件到了」，没有断言「非目标事件没到」，把 `matches` 改成恒真也不会失败——这是本部分最值得先补的地方，成本极低。其余两条轻微（丢帧告警未接线、`push` 关闭后返回 `true`）属于可观测性与 API 语义问题，排在契约修复之后。

没有阻塞项：严重 0 条，建议按「一般 3 条 + 测试反向断言」排期；性能与内存方向没有基线数据，只给出 2 条待验证方案与 3 条假设，未做任何「能降 X%」的结论。

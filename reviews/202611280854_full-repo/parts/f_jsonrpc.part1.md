# f_jsonrpc 模块审查报告（模块第 1/4 部分：文档子集）

- **审查日期**：2026-11-28
- **模块路径**：`f_jsonrpc`（模块共 32 个 `.cj` / 30 个 `.md`；本部分 = 20 个 `.md`，全部为文档）
- **基线**：工作区快照（`sts/1.3.x` 工作区，未对照远端目标分支）——本部分所有问题来源均为「存量」
- **审查重点**：RPC 协议正确性、批量与错误码、超时与资源、死代码、重复逻辑、存量 BUG；本部分落在**文档承诺与实现是否一致**（§13 / §14），并用 `src/` 现场取证
- **报告版本**：v1（分报告，待主 Agent 与 part2–part4 合并为 `docs/review/2026-11-28/f_jsonrpc.md`）

> 说明：本部分不含 `.cj`，因此 §1 死代码、§4 栈溢出、§5 OOM 等代码级维度只做「文档所引用符号 / 结构是否仍存在」的机械核对，语义审查由第 2–4 部分覆盖。为核对文档，本部分另行读了 `src/base/*`、`JsonRpcServer.cj`、`JsonRpcRegistry.cj`、`JsonRpcMethodMeta.cj`、`JsonRpcContext.cj`、`JsonRpcMapping.cj`、`JsonRpcController.cj`、`JsonRpcArgs.cj`、`JsonRpcClient.cj`、`SseHub.cj`、`SseStream.cj`、`SseController.cj`、`SseMapping.cj`、`JsonRpcSseClient.cj`、`macros/JsonRpc.cj`、`exports.cj`、`cjpm.toml` 作为取证材料，这些文件的缺陷归第 2–4 部分。

## 发现

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

## 优化可行性方案

本部分为文档子集，未提供任何性能基线（无 `cjprof` / `cjpm bench` 输出，`scope.md` 的「已有性能资料」仅 `docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md`，与本部分 20 个文件无关），因此**不产出优化方案**，相关线索全部落在「待验证假设」。

- 堆内存方案：0
- CPU 方案：0

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 设计文档「10 条批量比 10 次单发快 5~8 倍」无实测依据，可能随网络 RTT / 服务端耗时结构变化 | `doc/f_jsonrpc模块设计.md:1217` | 同环境、同输入的批量与单发对照 | `cjpm bench -O2`：1 条 ×1000 次 vs 10 条 ×100 次，取中位数与 P95，记录本机 loopback RTT |
| 2 | 设计文档「`toString()` 比 `toJsonString()` 少 30~50% 字节」未给样本 | `doc/f_jsonrpc模块设计.md:1215` | 真实响应体字节统计 | 对 20 个典型响应（含 `@DataAssist` 对象、批量 10 条）分别取两种序列化长度 |
| 3 | SSE 长连接「每请求一线程」的并发上限与内存占用未量化，可能成为线程耗尽面 | `SseController.cj:36`（`stream()` 返回不结束的 `InputStream`）、`doc/spec/add-jsonrpc-sse/design.md:87` | 并发连接数 → 线程数 / RSS 曲线 | 用 200 / 500 / 1000 条并发 `/rpc/stream` 压测，记录 `f_mvc` 线程池配置、线程数与 RSS |
| 4 | 客户端 `batch` 用 `id.toString()` 做索引键，服务端若回显不同的等价表示（如 `1` vs `1.0`）会导致整批落成 `-32603` | `JsonRpcClient.cj:127`、`:145` | 非本模块服务端的 id 回显格式样本 | 用第三方 JSON-RPC 服务端（或改写回显）跑一条 `batch`，核对 `id` 文本形式是否与请求一致 |
| 5 | SSE 服务端 `recent`（每 topic 256 帧）与 `subscribers`（按 topic 累积）没有 topic 数量上限，`topic` 又来自 `/rpc/stream?topic=` 外部输入，可能被构造成无界增长 | `SseHub.cj:51-52`、`SseController.cj:44-51` | 稳定态下不同 topic 数与 RSS / 堆占用的关系 | 连续用 1k / 10k 个不同 topic 订阅 + 发布，观察 `getAllocatedHeapSize()` 与 RSS 是否回落 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_jsonrpc.part1.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jsonrpc/README.md` | .md | ✅ | 与实现逐项对照；见发现 #1 #3 #4 #5 #8 #9 #10，SSE/依赖/超时均有偏差 |
| 2 | `f_jsonrpc/README_en.md` | .md | ✅ | 与中文版及实现对照；见发现 #1 #2 #3 #4 #5 #8 #9 #10 |
| 3 | `f_jsonrpc/doc/f_jsonrpc模块设计.md` | .md | ✅ | 设计意图文档，文末有「文档与实现对照」；4.2/4.3/4.4 样例过期（#11），4.8 批量顺序与 spec 冲突（#10），§8 性能数字无基线（待验证假设 1/2） |
| 4 | `doc/spec/add-f-jsonrpc/design.md` | .md | ✅ | 归档设计；D3 包布局与现目录（base/client/server/macros）已不同，属归档口径，不另报 |
| 5 | `doc/spec/add-f-jsonrpc/proposal.md` | .md | ✅ | 归档提案，与归档设计自洽 |
| 6 | `doc/spec/add-f-jsonrpc/specs/json-rpc/spec.md` | .md | ✅ | 归档规格；「inputSchema/outputSchema」已由 `fix-jsonrpc-mcp-review-findings` 的 MODIFIED 需求取代，按归档口径不报 |
| 7 | `doc/spec/add-f-jsonrpc/tasks.md` | .md | ✅ | 归档任务清单，12.1 声称 README 中英成对（实际已漂移，见 #2） |
| 8 | `doc/spec/add-f-jsonrpc/verify-report.md` | .md | ✅ | 归档验证报告；测试数与 11.4 遗留项说明自洽 |
| 9 | `doc/spec/add-jsonrpc-macro/design.md` | .md | ✅ | 归档设计；`@jsonrpc[topic:]` / `JsonRpcRegister` 已被后续 rework 取代，D3 的编译期注解提取与现宏（运行期 `getMeta`）不同，均属归档口径，不另报 |
| 10 | `doc/spec/add-jsonrpc-macro/proposal.md` | .md | ✅ | 归档提案，同上 |
| 11 | `doc/spec/add-jsonrpc-macro/specs/json-rpc/spec.md` | .md | ✅ | 归档规格；「缺省无超时」与实现一致 |
| 12 | `doc/spec/add-jsonrpc-macro/tasks.md` | .md | ✅ | 归档任务；4.3 / 4.4 未勾选，与 verify-report「全部完成」矛盾（#12） |
| 13 | `doc/spec/add-jsonrpc-macro/verify-report.md` | .md | ✅ | 归档验证报告；第 8 行称 tasks 1.1–4.4 全部完成，与 tasks.md 不符 |
| 14 | `doc/spec/add-jsonrpc-sse/design.md` | .md | ✅ | 归档设计；D3「close 后 read 返回 0」与 tasks 1.1「返回 -1」矛盾（#12），D4「warn 一次」未实现（#6） |
| 15 | `doc/spec/add-jsonrpc-sse/proposal.md` | .md | ✅ | 归档提案；承诺的 `known-limitations.md` 不存在（#7） |
| 16 | `doc/spec/add-jsonrpc-sse/specs/jsonrpc-sse/spec.md` | .md | ✅ | 归档规格；有界缓冲 / 补发 / 重连要求与实现基本一致，告警要求未实现（#6） |
| 17 | `doc/spec/add-jsonrpc-sse/tasks.md` | .md | ✅ | 归档任务；1.1 的 `-1` 与设计冲突（#12）、4.3 声称的限制文档缺失（#7） |
| 18 | `doc/spec/fix-jsonrpc-mcp-review-findings/specs/json-rpc/spec.md` | .md | ✅ | 当前生效的 MODIFIED 规格；README 的 timeout 措辞（#4）与 `-32003` / `-32001` 语义均按此核对 |
| 19 | `doc/spec/record-f-jsonrpc-batch-blocker/design.md` | .md | ✅ | 纯文档变更记录；四个临时集合与 `JsonRpcClient.batch` 现状一致，行号已偏移（#11） |
| 20 | `doc/spec/record-f-jsonrpc-batch-blocker/proposal.md` | .md | ✅ | 与 design 一致；local 阻断结论与实现集合对得上 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完（本部分清单内无 `.cj`；为核对文档另读了 17 个 `src/` 文件与 `cjpm.toml`，不计入本部分统计）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 存量缺陷 12 条（0 严重 / 7 一般 / 5 轻微），是否纳入修复待用户决定；本部分未对源码做任何修改。

## 总评

文档整体结构是合格的：README 有包结构、端点表、错误码表、上限表、迁移表和完整 API 参考，设计文档保留了决策依据，归档 spec 也都带验证报告，明显高于「只有一段用法」的水平。本部分的问题几乎都属同一类——**文档滞后于实现**：SSE 整套能力已经落地并被 `f_a2a` 依赖，README 正文却仍写「不做 SSE」（#1），同一份 README 末尾又列出这些类；英文版停在 500ms 默认超时的旧世界（#2）；`@JsonRpcMapping` 的参数面、`ClientOptions.timeout` 的语义与实现不符（#3 #4）。这类偏差不会让代码跑不起来，但会让使用者按错误的契约设计重试、超时与鉴权。

唯一需要优先确认的是 #5：客户端把 `client.send` 的所有异常都归为「可重试的建连失败」，与「读响应阶段永不重试」的公开承诺在边界上不重合；一旦确认 `stdx.net.client.send` 覆盖响应头阶段，非幂等方法就有重复执行风险，届时应升级为严重项。其余一般项（SSE 告警未接线 #6、SSE 文档缺失 #7）可以排期修，轻微项属文档卫生。

阻塞项：无。建议合并前由主 Agent 把 #1 #2 #3 #4 并入模块报告的 §13 汇总，避免与第 2–4 部分的源码结论重复计数。

---

### 范围外提示（不计入本部分统计）

- `f_jsonrpc/src/server/SseHub.cj:61-82` 在全局 `Mutex` 内做补发与 `push`，`publish` 又在锁内序列化 JSON 并遍历全部订阅者；且 `subscribers` 从未在订阅关闭时移除条目（`SseSubscription.close` 只关流），`recent` 按 topic 无上限累积（`topic` 来自外部查询参数）。锁粒度属 §6.2/§12.2，注册表无界属 §5，建议第 3 部分（`SseHub.cj` / `SseController.cj`）重点核实。
- `f_jsonrpc/src/server/SseController.cj:68-70` 只设置 `Cache-Control` / `X-Accel-Buffering`，未显式写 `Transfer-Encoding: chunked`；`doc/spec/rework-jsonrpc-macro-and-demos/design.md:31-33`（D5）记录 stdx 对无长度 `InputStream` body 要求显式 chunked，否则 500。若 `f_mvc` 的 `respond(InputStream)` 已代设则无事，建议第 3/4 部分用 `/rpc/stream` 冒烟确认。

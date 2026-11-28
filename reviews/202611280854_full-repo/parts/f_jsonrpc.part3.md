# f_jsonrpc 模块审查报告（模块第 3/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jsonrpc`（模块共 32 个源文件 / 30 个 .md；**本部分 20 个文件，全部为 `.cj`**）
- **本部分范围**：`src/client/SseClient_test.cj`、`src/exports.cj`、`src/macros/{JsonRpc.cj, imports.cj}`、`src/server/{JsonRpcArgs, JsonRpcContext, JsonRpcController, JsonRpcMapping, JsonRpcMethodMeta, JsonRpcRegistry, JsonRpcServer, SseController, SseHub, SseMapping}.cj` 及 server 侧 6 个测试文件
- **基线**：工作区快照（sts/1.3.x，无 diff）——**本部分全部问题来源均为「存量」**
- **审查重点**：RPC 协议正确性、批量与错误码、超时与资源、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分报告，由主 Agent 合并进 `docs/review/2026-11-28/f_jsonrpc.md`）

> 与第 1 / 2 部分的分工：第 1 部分（`.md`）已把「README 声明不提供 SSE」「SSE 丢帧 warn 未接线」「SSE 公共 API 文档缺失」列为它的发现，并在文末把 **`SseHub` 锁粒度、订阅表无界** 明确移交本部分核实。本报告对已计过的条目只做交叉引用、**不重复计数**。

## 发现

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

## 优化可行性方案

> 本部分没有 profile / bench 数据，以下方案全部为「无基线（待验证）」，不进 `tasks.md`。

### [CPU] `JsonRpcServer.methods()` 每次调用重建列表并做插入排序

- **现状**：`f_jsonrpc/src/server/JsonRpcServer.cj:64-80` 每次遍历 `ConcurrentHashMap` 收集全部方法，再用插入排序按名排序；比较次数 O(n²)（n=5000 时约 1.2×10⁷ 次字符串比较，与 `JsonRpcZzHttp_test.cj:155-168` 里 5000 方法的规模同量级）。仓内当前无调用方（`grep '\.methods()'` 只命中测试），README 声明的用途是给 `tools/list` 生成稳定输出。
- **方案**：注册期维护「按名排序的不可变快照」——`addMethod` 置脏标记（`AtomicBool`），`methods()` 首次访问时重建并缓存引用；或至少把插入排序换成一次 `sort`（O(n log n)）。
- **预期**：无法量化（无基线）。理论上 n=5000 时排序从 O(n²) 降到 O(n log n)；缓存后重复调用只剩一次拷贝。
- **代价**：多一份列表引用（元素对象共享，不复制方法元数据）；`addMethod` 从纯写变成写 + 置脏；需要保证快照重建期间读到的是一致版本。
- **验证**：`cjpm bench -O2`，1k / 5k 方法各调 `methods()` 1000 次，取中位数与离散程度；同时跑 `cjprof record` 确认排序占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据，仅作为下一轮补数据的清单，不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 所有 topic 的 SSE 发布被一把全局锁串行，发布线程 > 2 时 P99 延迟随并发上升 | `f_jsonrpc/src/server/SseHub.cj:94-116` | 锁等待时长、BLOCKED 线程数、P99 | 4/8 个发布线程 × 200 订阅者压 `/rpc/stream`，采线程状态 + 分段计时；`cjprof` 看不到锁竞争，必须另采线程状态 |
| 2 | 死订阅条目导致 `publish` 单次耗时随「累计连接数」增长 | `f_jsonrpc/src/server/SseHub.cj:110-114` | 订阅表规模 vs 单次 publish self time | 反复建连/断连 N=1k/10k 次后，测 `publish` 1000 次的中位耗时，并采样 `getAllocatedHeapSize()` |
| 3 | `methods()` 的 O(n²) 排序在 n=5000 时到达毫秒级 | `f_jsonrpc/src/server/JsonRpcServer.cj:69-78` | 单次调用耗时 | `cjpm bench -O2`，n = 100 / 1000 / 5000 三档各 1000 次 |

## 文件覆盖

> 与 `files/f_jsonrpc.part3.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/client/SseClient_test.cj` | .cj | ✅ | 客户端 SSE 测试（假连接 / 重连脚本），本部分仅作契约对照；客户端实现缺陷归第 2 部分 |
| 2 | `src/exports.cj` | .cj | ✅ | 3 条 `public import` 均为宏展开产物服务，用途正确 |
| 3 | `src/macros/JsonRpc.cj` | .cj | ✅ | 见「轻微」`namespaceOf` 校验偏松 |
| 4 | `src/macros/imports.cj` | .cj | ✅ | 见「轻微」未使用 `internal import` |
| 5 | `src/server/JsonRpcArgs.cj` | .cj | ✅ | 单/多参数取值优先级与 `add-jsonrpc-macro/design.md:75` 一致，未发现缺陷 |
| 6 | `src/server/JsonRpcContext.cj` | .cj | ✅ | `isExpired` 边界与 README 一致；`endpoint` 仓内只写不读（public 字段，仅记录） |
| 7 | `src/server/JsonRpcController.cj` | .cj | ✅ | 通知走 `Unit` 分支与设计 4.8 一致；`endpoint` 字符串未被消费 |
| 8 | `src/server/JsonRpcMacro_test.cj` | .cj | ✅ | 见「轻微」`hidden()` 夹具 |
| 9 | `src/server/JsonRpcMapping.cj` | .cj | ✅ | 三项固定字段与设计 2.4 一致 |
| 10 | `src/server/JsonRpcMapping_test.cj` | .cj | ✅ | 路由注册断言；`JsonRpcTestController` 的空函数体是反射夹具，不算空实现 |
| 11 | `src/server/JsonRpcMethodMeta.cj` | .cj | ✅ | 注册期编译 schema、命名空间预处理均正确 |
| 12 | `src/server/JsonRpcRegistry.cj` | .cj | ✅ | `getMeta` 两条回退分支重复返回 `JsonRpcMeta('','')`，属噪声级重复，未单列 |
| 13 | `src/server/JsonRpcServer.cj` | .cj | ✅ | 见「严重」1 条以外的「一般」2 条与「轻微」3 条 |
| 14 | `src/server/JsonRpcServer_test.cj` | .cj | ✅ | 协议主路径覆盖充分（批量/通知/id 保真/413/未知 topic）；见「轻微」测试残留 |
| 15 | `src/server/JsonRpcTimeout_test.cj` | .cj | ✅ | 真实 HTTP 面 + 线程/上下文恢复断言；无缺陷 |
| 16 | `src/server/JsonRpcZzHttp_test.cj` | .cj | ✅ | 计时类断言（`:167`、`:190`）用固定余量，跨机器有脆性，未单列 |
| 17 | `src/server/JsonRpcZzSse_test.cj` | .cj | ✅ | 验证流式写出与 chunked；`subscriberCount` 判据受订阅泄漏影响（见「严重」） |
| 18 | `src/server/SseController.cj` | .cj | ✅ | 见「一般」查询串解析、`topic` 无界；chunked 已由 `f_mvc/src/RequestMeta.cj:396-405` 代设，无问题 |
| 19 | `src/server/SseHub.cj` | .cj | ✅ | 见「严重」订阅泄漏、「一般」锁粒度、3 条「轻微」 |
| 20 | `src/server/SseMapping.cj` | .cj | ✅ | 与 `@JsonRpcMapping` 并列的取舍写在注释里，合理 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

> 仅统计本部分；跨行引用的同一发现不重复计数。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

**存量 12 条**（1 严重 / 4 一般 / 7 轻微），是否纳入修复待用户决定。

### 范围外提示（不计入本部分统计）

- `f_jsonrpc/README.md:31`「传输只做 HTTP POST，不提供 GET / SSE / WebSocket」与 `SseController.cj:35` 实现的 `GET /rpc/stream` 相反（第 1 部分已计）。
- `doc/f_jsonrpc模块设计.md:1016-1024` 仍写「正常返回 `Array<Byte>`」，实现已改为 `JsonValue`（`JsonRpcServer.cj:88-94`、`JsonRpcController.cj:45-57`）；`:1008`「批量顺序不保证」与 `:1077`「与输入同序」自相矛盾（实现是同序）。文档归属第 1 部分。
- `f_jsonrpc/doc/spec/add-jsonrpc-sse/design.md` 未讨论订阅的退出/清理，只写了「进程内广播」；本次「严重」#1 属规格层面缺口，建议补一条 requirement。

## 总评

协议主路径的工程质量明显高于一般水平：批量 / 通知 / 空批量 / 批内部分失败 / `id` 保真 / `-32003` 不部分执行 / `-32603` 固定文案，全部与设计文档 4.7-4.8 与 `-32xxx` 码表逐条对得上，配套测试（`JsonRpcServer_test` + `JsonRpcTimeout_test` + `JsonRpcZzHttp_test`）也确实在真实 HTTP 面上验证了 Content-Type、chunked 与线程上下文恢复，不是只测纯函数。

**阻塞项只有一条**：SSE 订阅表没有生命周期终点（「严重」#1）。它同时解释了 `subscriberCount` 失真、`publish` 随运行时长变慢、以及内存随累计连接数增长——`f_a2a` 这类长跑服务接上 SSE 后必然踩到，建议优先修（`SseSubscription.close()` 摘除 + 包装 `InputStream` 的 `close()` + 每 topic 上限）。

可以排期的有：`SseHub` 一把全局锁跨 topic 串行（#2）、SSE 端点手写查询解析缺百分号解码（#3）、超时后不发 `future.cancel()` 且迟到异常无人观察（#4）、`timeout='0s'` 的双重语义（#5）。第 4、5 条都是边角配置语义，改动小、风险低，适合顺手收口。

轻微项集中在测试残留、字面量耦合、测试专用 public API 与宏参数校验，不影响线上行为。性能方面本部分没有任何 profile / bench 数据，锁竞争与 `methods()` 排序成本一律只记为「待验证假设」，未写入结论。

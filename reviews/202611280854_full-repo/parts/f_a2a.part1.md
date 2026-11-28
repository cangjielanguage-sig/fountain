# f_a2a 模块审查报告（模块第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_a2a`（本部分 13 个 `.cj` + 7 个 `.md`，共 20 个文件；第 2 部分为 `A2aTaskStore.cj` / `A2aStream_test.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线；源码提交 2026-11-10 `7c593d47`，全部记为「存量」）
- **审查重点**：协议实现正确性、空实现、死代码、重复逻辑、并发安全、存量 BUG、README/文档一致性
- **报告版本**：v1

## 发现

### [严重] `working` 任务在执行结束前不落库，`tasks/get` / `tasks/cancel` 对执行中任务一律返回 `-32020`；取消结果还会被终态整体覆盖

- **位置**：`f_a2a/src/server/A2aServer.cj:199-218`（`send`，`store.save` 只在 217）、`f_a2a/src/server/A2aServer.cj:100-128`（`stream`，`store.save` 只在 118）、`f_a2a/src/server/A2aServer.cj:232-250`（`cancelTask` 只从 store 取任务）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「并发正确性 / 契约与实现不符」、§12.1「检查-然后-写入」；README.md:35「只能取消 `submitted` / `working`」、doc/a2a-protocol.md:95-96、spec.md:57-60
- **证据**：静态确定 —— `task` 在 201 行只是局部对象，`executor.execute` 期间库中不存在该 id；`cancelTask` 第一句就是 `store.get(id)`，必然 `None` 并抛 `-32020`。测试 `A2aServer_test.cj:144-154` 通过手工 `store.save` 预置 `working` 任务绕过了真实路径，所以没有暴露
- **描述**：`send` / `stream` 的执行窗口内任务对外不可见：`a2a.tasks.get` 拿不到、`a2a.tasks.cancel` 报「任务不存在」，与 README/设计文档承诺的「取消 working 任务」「流中取消收到 canceled 事件」直接冲突。进一步地，即使把 `store.save` 提到执行前，`cancelTask` 保存的 `canceled` 仍会被 `apply()` + 末尾 `store.save(task)` 用发送方手里的旧快照整对象覆盖（没有版本号 / 期望状态校验），取消会静默丢失。这是「读-改-写」跨两次 `save` 的丢失更新
- **建议**：建任务后立即 `save`（`submitted`/`working`）再执行；终态落库改为条件更新（`A2aTaskStore` 增加 `compareAndSet(id, expectedStatus, task)`，或在 `A2aServer` 内按 taskId 加锁后重读）；`apply` 前检查库中当前状态是否为 `canceled`，是则保留 `canceled` 并跳过终态写入

### [严重] `a2a.pushConfig.set` 接受任意 URL，服务端主动 POST：可被用作 SSRF；`pushConfig.get` 把 token 回传给任何调用者

- **位置**：`f_a2a/src/server/A2aServer.cj:151-163`（`pushSet`，只校验非空）、`f_a2a/src/server/A2aServer.cj:165-176`（`pushGet` 返回 token）、`f_a2a/src/server/A2aEvents.cj:47-56`（`HttpClient(url).post(body)`）
- **来源**：存量
- **判据**：review-checklist §10 安全性（SSRF、敏感数据）、§11「契约与实现不符」
- **证据**：静态确定 —— `pushSet` 对 `url` 没有任何 scheme/host 校验，也没有私有地址/回环地址拦截；`notifyTerminal`（`A2aServer.cj:284-297`）无条件 POST
- **描述**：任意能调到 `a2a.pushConfig.set` 的客户端都可注册 `http://169.254.169.254/...`、`http://127.0.0.1:port/...` 等地址，任务终态时由服务端代发请求，构成典型 SSRF（回调 body 里还带 token）。`pushGet` 把 `token` 原样返回，token 作为「回调来源校验」的共享秘密失去意义，知道 taskId 的任何人都能读到。宿主是否加鉴权可缓解，但 URL 校验不应由宿主替协议层兜底
- **建议**：`https` + 可配置 host 白名单；解析 URL 后拒绝 loopback / link-local / 私网 / 非 http(s)；`set` 响应只回一次 token、`get` 不回传；把发送下沉到已有的 `notifier` 注入口，由宿主实现出站策略

### [一般] `safeRegister` 吞掉所有 `JsonRpcException`，第二个 `A2aServer` 实例的 9 个方法全部静默失效，`registrationCount()` 却恒为 9

- **位置**：`f_a2a/src/server/A2aServer.cj:68-97`（`registered = true` 在注册之前、`registrations = METHOD_COUNT` 在 94-96）、`f_a2a/src/server/A2aServer.cj:183-190`（空 catch）、`f_a2a/src/server/A2aServer.cj:41` / `192-196`（计数器）
- **来源**：存量
- **判据**：review-checklist §3「静默吞异常」、§1「恒真恒假」、§11「契约与实现不符」
- **证据**：静态确定 —— `JsonRpcServer.addMethod` 对重复方法名抛 `JsonRpcException(INTERNAL_ERROR)`（`f_jsonrpc/src/server/JsonRpcServer.cj:56-59`），`safeRegister` 把它吞成 `()`；`registrations` 不做累加，直接赋 `METHOD_COUNT`
- **描述**：同一进程里 `f_a2a` 自己的服务端与 `f_llm` 的 `LoomA2a`（`f_llm/src/loom/A2aBridge.cj:105-106`）都会 `new A2aServer(...).register()`。后注册的实例 9 次注册全部被吞，其 `executor` / `card` / `store` / `pushConfig` 永不生效，请求仍由第一个实例处理——静默串台，无任何日志。`register()` 先把 `registered` 置真再注册，一旦中途非 `JsonRpcException` 失败，后续调用直接返回、无法补救。测试 `A2aServer_test.cj:176-181` 只断言 `registrationCount() == METHOD_COUNT`（常量），是空断言，无法发现上述任何一种失败
- **建议**：注册冲突按 fountain 基线 §4「同名注册启动直接失败」处理，或至少 `warn` 并让 `register()` 返回实际成功数；`registrations` 按成功次数累加；`registered = true` 放在全部注册成功之后；幂等测试改为断言全局方法表中 handler 归属本实例（或按名查询后比较 `METHOD_COUNT` 之外的可观测状态）

### [一般] 终态回调在 `store.save` 之前发出，回调方立刻 `tasks/get` 会拿到 `-32020`；默认 notifier 不校验状态码、异常路径不 `close`

- **位置**：`f_a2a/src/server/A2aServer.cj:215-217`（`send` 先 notify 后 save）、`f_a2a/src/server/A2aServer.cj:116-118`（`stream` 同样）、`f_a2a/src/server/A2aServer.cj:284-297`、`f_a2a/src/server/A2aEvents.cj:47-56`
- **来源**：存量
- **判据**：review-checklist §11「错误处理 / 资源不对称」、§3「静默吞异常」
- **证据**：静态确定 —— 顺序可从行号直接读出；`notify` 只 `post` 不读响应状态；`client.close()` 在 `post` 之后、不在 `finally`（`Resource` 只在 `try-with-resource` 中自动释放，见 `std/core/core_package_api/core_package_interfaces.md:1343-1354`）
- **描述**：A2A 回调的常见处理是收到通知后立刻 `tasks/get`；当前 `send` 在 `save` 之前回调，对方会收到「任务不存在」。`cancelTask` 是「先 save 后 notify」，两条路径顺序不一致，属于重复实现导致的漂移。`A2aEvents.notify` 任何不抛异常的响应（含 4xx/5xx）都返回 `true`，失败被当成功、不记 warn；`post` 抛异常时 `HttpClient` 不会关闭
- **建议**：统一「先 `store.save` 再 `notifyTerminal`」；检查 `response.status` 是否 2xx；`try { post } finally { client.close() }`

### [一般] `a2a.tasks.resubscribe` 读 `id` 参数、只补发一条状态事件，没有按 `taskId` 重订阅，也没有 `Last-Event-ID` 透传

- **位置**：`f_a2a/src/server/A2aServer.cj:135-144`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 实现只有 `store.get(id)` + 一次 `publish`；函数体内不建立任何订阅，也没有 `lastEventId` 参数
- **描述**：doc/a2a-protocol.md:38 写「按 `taskId` 重订阅，带 `Last-Event-ID` 补发」，spec.md:112-119 把它列为 MUST；实现要求参数名 `id`，客户端按文档传 `taskId` 会得到 `-32020`。SSE 断线补发实际由 `f_jsonrpc` 的 `GET /rpc/stream`（`SseHub.subscribe` 的 `lastEventId`）完成，RPC 方法本身不具备该能力，代码注释也把它降级成「返回任务并补发一条当前状态事件」
- **建议**：参数名与 A2A 对齐（`taskId`，兼容 `id`）；文档改成「补发当前状态后由客户端自行订阅 `/rpc/stream`」；若要真做重订阅，则接收 `lastEventId` 并回放 `SseHub` 缓冲

### [一般] `send` 忽略 `params.taskId` / `params.contextId`，「带同一 contextId 续跑」不成立

- **位置**：`f_a2a/src/server/A2aServer.cj:299-322`（`parseMessage` 只读 `message`）、`f_a2a/src/server/A2aServer.cj:324-330`、`f_a2a/src/client/A2aClient.cj:52-54`、`f_a2a/src/server/A2aStream_test.cj:67-69`
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」、§14.1「半成品」、§1「读了不用」
- **证据**：静态确定 —— `send` 每次都 `A2aTask(id: nextId(), contextId: contextOf(message))`，从不查 store 中的旧任务，也不合并 history；`A2aClient.send` 额外写入的顶层 `contextId`、测试里写入的顶层 `taskId` 在全仓没有任何读取点
- **描述**：README.md:121 与 doc/a2a-protocol.md:97 承诺「`input-required` 后带同一 `contextId` 再发即可续跑」，实际是新建一个同 `contextId` 的独立任务：旧任务的 id、history、statusMessage 全部丢失，客户端拿不到「同一个任务继续」的语义。`A2aClient.send` 的顶层 `contextId` 与 `A2aStream_test` 的顶层 `taskId` 是死参数，误导调用方以为服务端会处理
- **建议**：从 `params` 读 `taskId` / `contextId`；`taskId` 命中且状态为 `input-required` 时复用该任务、追加 history 与新一轮产物；否则删除 `A2aClient` 里的顶层 `contextId` 写入并把文档改成「同 contextId 的新任务」

### [一般] README / 设计文档承诺 `-32024` 拒绝码，实现里 `reject()` 从不产生该码，且全仓零调用

- **位置**：`f_a2a/src/server/A2aExecutor.cj:52-55`（`reject`）、`f_a2a/src/server/A2aServer.cj:274-276`（映射为 `FAILED`）、`f_a2a/README.md:40`、`f_a2a/README_en.md:40`、`f_a2a/doc/a2a-protocol.md:51`、`design.md:53`
- **来源**：存量
- **判据**：review-checklist §13「API / 错误码与源码不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全仓 `grep "reject("` 只有定义处 `A2aExecutor.cj:53`；`TASK_REJECTED` 只出现在定义（`A2aModels.cj:50`）与测试断言（`A2aModels_test.cj:103`）；`A2aServer.apply` 无任何抛 `-32024` 的分支
- **描述**：客户端按 README 错误码表对 `-32024` 分支永远不会命中；`reject()` 的真实语义是「任务 failed + `statusMessage='rejected: …'`」。对外声明与行为不一致，且 `reject()` 作为公开工厂无人调用（对外可达，不判死代码，但属于未接线能力）
- **建议**：二选一并写进文档——(a) 删除 `-32024` / `reject()`（公开 API，需用户拍板）；(b) 保留工厂但明确「reject 是任务状态不是协议错误」，README 错误码表移除 `-32024`

### [一般] `send` 与 `stream` 近似重复，已出现行为漂移；三处重复构造同一个 `-32020`

- **位置**：`f_a2a/src/server/A2aServer.cj:100-128` vs `199-219`；重复抛错 `A2aServer.cj:137-141`、`222-228`、`232-238`
- **来源**：存量
- **判据**：review-checklist §2「近似重复 / 字面量复制」（两块逐行对齐，差异只在 publish 与 save 位置）
- **证据**：静态确定 —— 两段「建任务 → 置 working → 时间戳 → history → try/catch executor → apply → notify → updatedAt → save → toJson」完全同构
- **描述**：后续任何修复（例如「先 save 再 notify」）都必须改两遍，且当前 notify/save 顺序在 `send`、`stream`、`cancelTask` 三处已经不一致（见上一条）。`getTask` / `cancelTask` / `resubscribe` 各自手写 `JsonRpcException(TASK_NOT_FOUND, 'task not found: ${id}', data: JsonString(id))`，错误文案与 data 结构一旦调整容易漏改
- **建议**：抽 `executeAndFinish(message, publishEvents: Bool)` 单一实现；抽 `requireTask(id): A2aTask` 统一 not-found 抛错

### [一般] `pushConfig` 注册表无容量上限、无 TTL、不校验 taskId 是否存在，`set` 接受任意 key

- **位置**：`f_a2a/src/server/A2aPushConfig.cj:35-48`、`f_a2a/src/server/A2aServer.cj:151-163`
- **来源**：存量
- **判据**：review-checklist §5「无界容器 / 缓存键无界」、§11「边界校验缺失」
- **证据**：静态确定 —— `HashMap` 只增不删（`remove` 仅由客户端显式调用），`set` 前不查 `store.get(taskId)`；无容量常量、无过期时间、任务终结后无清理
- **描述**：任意 RPC 调用者可用随机 `taskId` 灌入无限条目，每个 entry 常驻到进程退出；正常业务路径下任务完成后 entry 也不会被清理，长期运行是单调增长的常驻内存。按 entry ≈ 3 个字符串 + 对象头估算，百万级 key 即为百 MB 量级（具体取决于 taskId 长度），属于可被外部输入触发的无界增长
- **建议**：容量上限 + LRU/TTL 淘汰；`set` 时校验任务存在；推送成功或任务删除后清理 entry；或把配置挂到任务记录上随任务生命周期释放

### [一般] 设计基线 `doc/a2a-protocol.md` 的 API 名与示例与实现不符

- **位置**：`f_a2a/doc/a2a-protocol.md:69`（`streaming` 恒 false）、`:144`（`init(agentCard: …)`）、`:150`（`A2aExecutionResult.text(...)` / `needsInput(...)`）、`:170`（`A2aAgentCard.json(server.card)`）
- **来源**：存量
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例代码不能用」
- **证据**：静态确定 —— 实现是 `A2aCapabilities.streaming = true`（`A2aModels.cj:221`，测试 `A2aModels_test.cj:88` 断言 true）；构造参数名是 `card`（`A2aServer.cj:46`）；没有 `text` / `needsInput` 工厂，只有 `done` / `input` / `failed` / `reject`（`A2aExecutor.cj:43-59`）；`json()` 是实例方法，`A2aAgentCard.json(server.card)` 语法不成立
- **描述**：这份文档自称「实现按本文逐条落地」，但示例照抄会编译失败；`streaming` 的能力位描述与实现相反（同一文件 `:288` 的测试矩阵又写 `streaming=true`，文档内部自相矛盾）
- **建议**：按实现回写：`streaming=true`、参数名 `card`、工厂名 `done/input/failed/reject`、卡片示例改为 `server.card.json()`

### [一般] README（中英）客户端示例 `parts: [A2aPart(...)]` 类型不匹配，`cjpm test # 32/32` 已过期，依赖清单缺 `f_config` / `f_mvc`

- **位置**：`f_a2a/README.md:109`、`f_a2a/README_en.md:109`、`f_a2a/README.md:129`、`f_a2a/README_en.md:132`、`f_a2a/README.md:19-26`
- **来源**：存量
- **判据**：review-checklist §13「示例代码不能用」「文档过期」
- **证据**：静态确定 —— `A2aMessage.init(parts!: ArrayList<A2aPart>)`（`A2aModels.cj:103`），而 `[...]` 只构造 `Array`（仓颉文档 `basic_data_type/array.md:26`「使用字面量来初始化一个 Array」），`ArrayList` 需要 `ArrayList<A2aPart>([...])`；本模块 `@TestCase` 实为 35 个（8+10+5+4+5+3，见 `A2aStream_test.cj` 等 6 个测试文件）；`cjpm.toml` 依赖 7 个，README 只列 5 个
- **描述**：两版 README 的客户端示例直接复制无法编译（服务端示例正常）；测试计数比实际少 3；依赖清单漏 `fountain::f_config` 与 `fountain::f_mvc`（E2E 测试 `A2aE2E_test.cj:28,31` 实际使用）
- **建议**：示例改成 `A2aMessage(parts: ArrayList<A2aPart>([A2aPart(text: '…')]))`；计数改为 35；补全依赖表

### [轻微] 4 处未使用 import

- **位置**：`f_a2a/src/server/A2aEvents.cj:18`（`std.collection.*`）、`f_a2a/src/server/A2aExecutor.cj:18`（`std.collection.*`）与 `:21`（`fountain::f_data.*`）、`f_a2a/src/client/A2aClient.cj:18`（`std.collection.*`）
- **来源**：存量
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 三个文件正文均未出现 `ArrayList` / `HashMap` / `JsonValue` 等对应符号（`A2aEvents` 只用 `JsonObject` / `JsonValue` 来自 `f_data`，`A2aClient` 只用 `JsonObject`）
- **描述**：无功能影响，增加编译期噪声
- **建议**：删除这 4 行

### [轻微] `A2aJson.partsOf` / `messagesOf` / `artifactsOf` 逐行同构，只差元素类型与解析函数

- **位置**：`f_a2a/src/model/A2aJson.cj:105-136`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 三个函数都是「新建 ArrayList → `arrayOf(obj, key)` → 逐个 match `xxxOf` → add → 返回」
- **描述**：合并可减少三份重复的容错语义（目前三处都对 `None` 静默跳过，行为一致，暂无漂移）
- **建议**：抽 `private static func collect<T>(items, parse: (JsonValue) -> ?T): ArrayList<T>`；泛型 lambda 若带来额外间接层，也可接受现状，仅记录

### [轻微] `agentMessage` 用文本长度生成 `messageId`，不同内容会撞 id

- **位置**：`f_a2a/src/server/A2aServer.cj:355-359`
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」（A2A 的 `messageId` 用于去重/定位，应唯一）
- **证据**：静态确定 —— `messageId: 'reply-${text.size}'`，同一任务里 `'完成'` 与 `'失败'` 都是 2 个字符，id 相同
- **描述**：客户端若按 `messageId` 去重或关联，会混淆两条不同回复；跨任务更是大量重复
- **建议**：用 `'reply-${task.id}-${nextSeq()}'` 或 `task.id` + history 下标

### [轻微] README 公开 API 清单遗漏若干 public 成员

- **位置**：`f_a2a/README.md:138-152`、`f_a2a/README_en.md:141-155`
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化」
- **证据**：静态确定 —— 未出现的 public 声明：`A2aServer.card`（`A2aServer.cj:34`）、`A2aServer.pushConfig`（`:44`）、`A2aAgentCard.extensions`（`A2aModels.cj:275`）、`A2aPushConfigStore`（`A2aPushConfig.cj:35`，`set/get/remove` 均无文档）、`A2aPushConfigEntry`（`:22`）、`A2aExecutionResult.done/input/failed`（`A2aExecutor.cj:43-59`）
- **描述**：`A2aAgentCard.extensions` 是启用 `x-a2a-extensions` 的唯一入口，只靠「扩展卡片」段落猜字段名；`A2aServer.pushConfig` 是提前注册回调的唯一入口。属于「不知道有这个能力」
- **建议**：补进「其他公开 API」分组，或在扩展卡片段落点名 `extensions` 字段

### [轻微] `A2aCapabilities` 注释称 `pushNotifications`「视注册表是否启用」，实现固定 `false` 且从不更新

- **位置**：`f_a2a/src/model/A2aModels.cj:219-232`
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— 字段只有默认值 `false` 与构造参数，`A2aServer` 任何路径都不改它；`A2aPushConfigStore.set` 也不联动
- **描述**：卡片对外声明「不支持推送」，而模块实际实现了 pushConfig 与终态回调，能力位与能力相反
- **建议**：注释改为「默认 false，由宿主按是否装配回调能力自行设置」；或在 `A2aServer` 构造时按 `pushConfig` 注入口自动置位

### [轻微] `stream` 只为 `artifacts[0]` 发产物事件，其余产物静默丢失

- **位置**：`f_a2a/src/server/A2aServer.cj:121-126`
- **来源**：存量
- **判据**：review-checklist §11「只处理部分输入」
- **证据**：静态确定 —— 固定取 `task.artifacts[0]`；`A2aTask.artifacts` 是 `ArrayList`，执行器拿到的 `task` 是可变的，可以追加多条
- **描述**：内置 `apply()` 只加一条，所以默认路径不受影响；宿主执行器若直接往 `task.artifacts` 追加，订阅方只能收到第一条的 id，其余产物只能靠 `tasks/get` 补取
- **建议**：遍历全部 artifacts 逐条 publish

## 优化可行性方案

### [CPU] 用显式拷贝替代存储层的 JSON 往返拷贝

- **现状**：`A2aJson.copyOf`（`f_a2a/src/model/A2aJson.cj:33-38`）先 `toJson()` 再 `fromStr`/`taskOf` 重建整棵对象；`InMemoryA2aTaskStore.save/get/list`（`A2aTaskStore.cj:45,52,65`，第 2 部分）每次调用都做一次。一次 `send` 落库 1 次，客户端随后 `get` 再 1 次；`list` 按条各 1 次。history 有 N 条消息时每次 O(N) 字符串分配
- **方案**：为 `A2aTask` / `A2aMessage` / `A2aPart` / `A2aArtifact` 增加显式 `copy()`（复制 `ArrayList`，`String` 不可变可共享），存储层改用它；`copyOf` 保留给「从 JSON 恢复」场景
- **预期**：去掉每请求 2 次 JSON 编解码与随之产生的临时字符串/对象；收益随 history 长度线性增长
- **代价**：新增并维护 4 个 `copy()`（字段增删要同步）；`copy()` 的正确性需要一条「改副本不影响原对象」的用例兜底（已有 `A2aJson_test.cj:73-79` 可迁移）
- **验证**：`cjpm bench -O2`，任务 history 10 条，对比 save+get 的 p50/p99 与 `getAllocatedHeapSize()`；同 SDK 同机
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 把终态回调移出 JSON-RPC 请求线程

- **现状**：`notifyTerminal`（`A2aServer.cj:284-297`）在 `send`/`stream`/`cancelTask` 内同步调用 `A2aEvents.notify`，一次 `HttpClient` 建连 + POST + close；`a2a.message.send` 的响应时间 = 执行器耗时 + 回调 RTT。回调目标不可达时还要等连接超时
- **方案**：终态后把 `(url, body)` 投递到有界队列，由单一/小规模 worker 发送，队列满则丢弃并 warn；`A2aServer` 已有 `notifier` 注入口，可默认实现改成异步
- **预期**：`send` 的 p99 不再包含回调 RTT；慢回调不再占用 RPC 工作线程
- **代价**：语义从「终态时发」变成「终态后异步发」；需要队列上限与关闭时的 drain 策略；进程退出可能丢最后几条通知
- **验证**：回调端点注入 50ms / 200ms 延迟，对比 `a2a.message.send` 的 p50/p95 与线程占用；并发 50 请求
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `A2aJson.copyOf` 的 JSON 往返是 `send`/`get` 的主要分配来源 | `f_a2a/src/model/A2aJson.cj:33-38` | 分配量与 CPU 自耗时占比 | `cjprof heap` + `getAllocatedHeapSize()`，跑 10k 次 send/get，history 10 条 |
| 2 | 同步 push 回调占 `send` 端到端延迟的可观比例 | `f_a2a/src/server/A2aServer.cj:116,215` | 分段计时（executor / notify / save） | 回调端点注入 50/200ms 延迟，记录 p50/p95 |
| 3 | `SseHub.publish` 的全局锁在并发流场景下产生等待 | `f_a2a/src/server/A2aEvents.cj:42-44`（锁在 `f_jsonrpc/src/server/SseHub.cj:94-116`） | 线程 BLOCKED 时间与并发度 | 100 个并发 `a2a.message.stream`，采样线程状态；CPU profile 看不到锁等待 |
| 4 | 存储锁内 `copyOf` 使 get/save 串行化（第 2 部分文件，此处仅提示） | `f_a2a/src/server/A2aTaskStore.cj:43-56` | 临界区时长、锁等待 | 压测 save/get 混合，记录锁等待与 p99 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_a2a/README.md` | .md | ✅ | 示例类型错误、测试计数过期、API 清单遗漏（发现 #11/#15） |
| 2 | `f_a2a/README_en.md` | .md | ✅ | 与中文版同源同问题，无单独新增偏差 |
| 3 | `f_a2a/doc/a2a-protocol.md` | .md | ✅ | 与实现不符：streaming、工厂名、示例（发现 #10） |
| 4 | `f_a2a/doc/spec/add-f-a2a/design.md` | .md | ✅ | 归档变更；D1 文件清单/D3 `copy()` 与现状不同，按「当时结论」看其余自洽 |
| 5 | `f_a2a/doc/spec/add-f-a2a/proposal.md` | .md | ✅ | 归档变更；范围与实现一致 |
| 6 | `f_a2a/doc/spec/add-f-a2a/specs/a2a-protocol/spec.md` | .md | ✅ | 归档变更；内部矛盾：`:25` 要求非文本 -32023，`:136-149` 要求 file/data 必须支持 |
| 7 | `f_a2a/doc/spec/add-f-a2a/tasks.md` | .md | ✅ | 归档变更；1.2 勾选框与「已完成」文字不一致，无实质影响 |
| 8 | `f_a2a/src/A2a.cj` | .cj | ✅ | 门面包，三个 public import，无问题 |
| 9 | `f_a2a/src/A2aE2E_test.cj` | .cj | ✅ | 端口探测存在 TOCTOU、探测失败仍返回端口；测试基础设施，未单列 |
| 10 | `f_a2a/src/client/A2aClient.cj` | .cj | ✅ | 顶层 `contextId` 死参数（#6）、依赖 server 包取常量、未使用 import（#12） |
| 11 | `f_a2a/src/client/A2aClient_test.cj` | .cj | ✅ | 覆盖参数组装/错误透传，未覆盖 `close()` 与真实 URL |
| 12 | `f_a2a/src/model/A2aJson.cj` | .cj | ✅ | 三个同构 collect 函数（#13）、copyOf 往返拷贝（优化方案） |
| 13 | `f_a2a/src/model/A2aJson_test.cj` | .cj | ✅ | 往返/坏 JSON/副本独立性覆盖到位 |
| 14 | `f_a2a/src/model/A2aModels.cj` | .cj | ✅ | `pushNotifications` 注释不符（#16）、streaming 默认 true 与文档冲突（#10） |
| 15 | `f_a2a/src/model/A2aModels_test.cj` | .cj | ✅ | 状态表/卡片/错误码断言完整 |
| 16 | `f_a2a/src/server/A2aEvents.cj` | .cj | ✅ | SSRF 出口（#2）、失败判定与 close（#4）、未使用 import（#12） |
| 17 | `f_a2a/src/server/A2aExecutor.cj` | .cj | ✅ | `reject()` 全仓零调用（#7）、未使用 import（#12） |
| 18 | `f_a2a/src/server/A2aPushConfig.cj` | .cj | ✅ | 无界注册表（#9） |
| 19 | `f_a2a/src/server/A2aServer.cj` | .cj | ✅ | 主要缺陷集中地：#1/#3/#4/#5/#6/#8/#14/#16/#17 |
| 20 | `f_a2a/src/server/A2aServer_test.cj` | .cj | ✅ | 取消用例靠预置 store 绕过真实路径；幂等断言是常量（#1/#3） |

合计：`.cj` 13 个 / `.md` 7 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #1/#6、设计 #3/#6/#11、语言特性 #6（顶层参数无效）、安全性 #2、可读性 #8/#10；无注入类 SQL/命令拼接 |
| §1 死代码 | 1 | 逐个 private / internal / protected 符号搜引用，均有调用者；`A2aStates.isValid`、`A2aError.UNSUPPORTED` 全仓零引用但属对外可达 public，仅作信息不判死代码；未使用 import 4 处（#12）；`A2aServer.registrationCount` 仅测试引用，属 public，记「可见性建议」不判死代码 |
| §2 重复逻辑 | 2 | `send` vs `stream` 近似重复且已漂移（#8）；`partsOf/messagesOf/artifactsOf` 只改类型名（#13）；测试里的 `oneMessage`/`sendParams` 属测试准备代码，豁免 |
| §3 空实现 | 1 | `safeRegister` 空 `catch` 吞 `JsonRpcException`（#3）；`A2aJson` 的 `case None => ()` 为文档写明的容错策略，不算空实现 |
| §4 栈溢出 | 0 | 模块内无递归、无自引用结构遍历；JSON 解析深度由 std 库承担，不在本模块 |
| §5 OOM | 1 | `pushConfig` 无界注册表（#9）；任务存储无界属第 2 部分 `A2aTaskStore.cj` |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，任何「热点」均不成立，已列入待验证假设 1-3 |
| §6.2 大粒度锁 | 0 | 模块内锁只保护计数器与注册表；store 锁内 JSON 拷贝属第 2 部分，已在范围外提示与假设 4 |
| §6.3 并发串行 | 0 | 模块内无 `spawn`；同步 push 回调串行占用请求线程已进优化方案，缺延迟数据不定为缺陷 |
| §6.4 低效算法 | 0 | 无嵌套循环 / 热点 `contains` / `remove(at:0)`；JSON 往返拷贝属分配优化，进优化方案 |
| §7 降堆内存方案 | 0 | 无改前/改后峰值数据，未写成方案；只保留 CPU 优化两条 |
| §8 降 CPU 方案 | 2 | copyOf 改显式拷贝、push 回调异步化，均为「无基线（待验证）」 |
| §9 local mode 可行性 | 0 | 请求级对象全部逃逸进 store / SSE / 返回值，`@local` 不成立；无峰值内存数据，不做改造建议 |
| §11 现有代码的 BUG（存量） | 6 | #1 执行中任务不可见/丢失取消、#2 SSRF、#4 回调顺序与成功判定、#6 contextId 续跑、#7 -32024、#14 messageId 冲突 |
| §12 并发安全与锁粒度 | 2 | #1 丢失更新（两次 save 无版本校验）、#3 `registered` 先置位后注册；其余共享状态均有 `Mutex` 或不可变 |
| §14 功能完备性与 README 覆盖 | 4 | #5 resubscribe 语义、#6 续跑、#7 -32024、#15 README 公开 API 遗漏；`register()` 接线完整、模块已在 `.modules` 与根 README 登记 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完，无缺失 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 9 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

## 总评

协议主链路（模型序列化、状态机、9 个方法注册、客户端透传）结构清晰，模型与 JSON 层职责划分合理，测试对成功/失败/input-required/未知任务等常规路径覆盖到位。阻塞项集中在「执行期任务不可见」与「回调出站无校验」两处：前者让 `cancel` / `get` 在真实并发下失效，并使设计文档里的「流中取消」无法实现；后者把任意 URL 变成服务端出站请求。次一级的问题集中在文档与实现脱节（`-32024`、`resubscribe` 参数、`contextId` 续跑、`streaming` 能力位、README 示例），会直接误导接入方。`send`/`stream` 的复制粘贴与注册表的“假计数”是后续修复容易漏改、测试容易误判的结构性原因，建议与上述阻塞项一并排期。存量缺陷 17 条，是否纳入修复待用户决定。

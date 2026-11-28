# f_a2a 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_a2a`（22 个文件：15 个 .cj + 7 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_a2a.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [严重][存量] 任务存储只增不减：接口无删除/淘汰，每次 `send`/`stream` 的新任务永久驻留

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:24-28`（接口无 remove/clear/淘汰）、`:43-47`（`save` 只写不删）、`:71-75`（只能计数）；放大路径 `f_a2a/src/server/A2aServer.cj:118`、`:217`
- **来源**：存量 —— `git blame` 显示 `A2aTaskStore.cj:20-76` 全部来自 `7c593d47b`（2026-11-10），工作区无改动
- **判据**：review-checklist §5「无界容器 / 缓存键无界：用户 ID / 请求 ID 做 key，没有容量、TTL、淘汰」；严重度表「无界增长导致 OOM」
- **证据**：静态确定 —— `A2aTaskStore` 只有 `save` / `get` / `list` 三个方法，文件内搜 `remove|delete|clear|evict|expire|ttl` 零命中；`A2aServer` 每次 `send` / `stream` 都用 `nextId()`（`A2aServer.cj:340-342`：`now()` 秒 + 单调 `seq`，进程内必然唯一）新建任务并 `save`，而 `f_a2a` 内对 `A2aTaskStore` 的调用只有 `store.save` / `store.get`，没有任何删除调用（`f_llm` 里的 `store.remove` 属于 Loom / 元数据存储，与 `A2aTaskStore` 无关）；同包 `A2aPushConfig.cj:56` 有 `remove`，说明「可删除」并非本模块的全局约定，而是任务存储单独缺失
- **描述**：每个任务连同 `history`（用户消息 + agent 回复）与 `artifacts` 永久留在 `HashMap` 里，进程生命周期内没有任何回收路径，外部也无法删除（接口没给方法）。按每任务约 1KB（2 条消息 + 1 个产物）估算，百万次请求 ≈ 1GB 常驻（量级估算，精确值需压测），长跑服务必然 OOM 且无拒绝路径：既没有容量上限、TTL，也没有分页之外的保护
- **建议**：接口补 `remove(id: String): Bool` 与按时间范围查询；`InMemoryA2aTaskStore` 增加构造参数 `maxTasks` / `ttl`，超出时按 `createdAt` 淘汰（或 LRU）；被淘汰的 id 再次 `get` 继续走 `-32020`，契约不变；同时在接口注释与 README 写明「默认无上限，生产需自行设限或换持久化实现」

### [一般][存量] 锁内做整棵对象的 JSON 序列化/重建：`save`/`get`/`list` 全部串行在 O(history) 工作上

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:43-47`、`:49-56`、`:58-69`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §6.2「锁内做 I/O / DB / 序列化 / 正则 / 日志」、§12.2「缩小临界区：只保护不变量本身」
- **证据**：静态确定（临界区内容）—— `save` 在 `synchronized(mutex)` 内调用 `A2aJson.copyOf`，而 `copyOf` 是 `toJson()` + `taskOf()` 的整棵对象重建（`f_a2a/src/model/A2aJson.cj:33-38`）；`list` 在锁内逐条 `copyOf`。锁等待占比：需实测
- **描述**：一把 `Mutex` 保护整个 `HashMap`，而每次持锁期间都在做与任务体积成正比的 CPU 工作（序列化 + 重新分配 ArrayList/JsonObject）。并发 `send` + `get` 越多，锁队列越长，吞吐上限被这把锁压住；`list` 更是一次持锁做 N 次重建，长时间阻塞所有读写
- **建议**：锁内只做 map 读写与引用交换，`copyOf` 移到锁外——存入的是私有副本且之后不再原地修改，因此"锁内取引用、锁外复制"是安全的；配合 part1 建议的显式 `A2aTask.copy()` 后收益更大（见「优化可行性方案」）

### [一般][存量] 存储只提供「整对象 save + 副本 get」，读-改-写跨两次加锁，缺少条件更新

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:24-28`、`:43-47`；触发方 `f_a2a/src/server/A2aServer.cj:234-246`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §12.1「检查-然后-写入」、§11「并发正确性」
- **证据**：静态确定 —— 接口没有 `update` / `compareAndSet` / version / ETag 任何一个原语；`get` 返回副本，调用方改完后整体 `save`
- **描述**：`cancelTask` 的 `get → 改 → save` 与 `send` 末尾的 `save` 是两次独立加锁，谁后写谁赢，中间没有任何版本校验。第 1 部分发现 #1 的「取消被终态整体覆盖」在存储侧的表现就是这里：接口层面无法表达"仅在仍是 working 时写入 canceled"，自定义 `A2aTaskStore`（持久化实现）也补不上这个能力。这是把「丢失更新」固化成 API 形状的问题，不只是服务端少写一行判断
- **建议**：接口增加原子更新，例如 `compareAndSet(id: String, expectedStatus: String, task: A2aTask): Bool` 或 `update(id: String, f: (A2aTask) -> A2aTask): ?A2aTask`；`InMemoryA2aTaskStore` 在同一个 `synchronized` 内完成读-判-写。与 part1 #1 同根，合并报告时并入该条

### [一般][存量] 接口注释未声明「实现必须线程安全」「返回值必须是副本」两条契约

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:23-28`；对照 `f_a2a/doc/a2a-protocol.md:180-184`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §12.1「契约与实现不符 / 缺失同步手段」、§14.1「接线 / 契约缺失」
- **证据**：静态确定 —— 接口注释只有一句「默认内存实现，需要跨重启保留时换成自己的实现」；副本语义只写在实现类注释（`:30-35`），接口本身没有。`doc/a2a-protocol.md:184` 明确写「并发安全由 store 的实现负责（内存版用 Mutex）」，责任被推给实现方却没写进接口
- **描述**：第三方照着接口注释实现一个裸 `HashMap` 版本即可编译通过，随后在多线程 JSON-RPC 处理下直接数据竞争；同理，实现若返回内部引用，`A2aServer.cj:243-246` 的原地修改会污染库里的对象（`statusMessage`、`artifacts` 都会被外部改到）。两条契约都只存在于某个实现类的注释里，属于契约缺失而非风格问题
- **建议**：接口注释补两段：`save/get/list` 必须线程安全（或明确声明由调用方串行化，但当前 `A2aServer` 不串行化）；`get/list` 返回的对象由调用方独占，实现不得再持有同一实例。README 的「实现 `A2aTaskStore` 注入」段落同步这两条

### [轻微][存量] `list(limit)` 契约未定义：迭代序任意、`limit<=0` 全量物化、无协议入口、无用例

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:58-69`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§5「一次性物化」、§14.1「半成品」
- **证据**：静态确定 —— 遍历 `HashMap`（迭代序未定义），没有按 `createdAt`/`updatedAt` 排序；`limit > 0` 才截断，`limit <= 0` 会复制全部任务；`A2aServer.register()` 注册的 9 个方法（`A2aServer.cj:76-93`）里没有 `tasks/list`，全仓搜 `store.list` 零命中
- **描述**：方法名暗示"列出最近任务"，实际返回任意子集，调用方无法据此做分页；`limit=0` 会一次性把全部任务复制成新对象（叠加每条的 `copyOf`），在大存量下是峰值内存尖峰。目前既无调用方也无协议入口，属于未接线的半成品 API
- **建议**：要么明确契约（按 `createdAt` 倒序、`limit` 必须 > 0、上限截断到常量），要么删掉该接口方法；若保留给宿主直接调用，README 注明"服务端未注册 `tasks/list`，仅库内可用"

### [轻微][存量] `count()` 不在接口内、全仓零调用零用例，README 却把它当作存储 API 列出

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:71-75`；`f_a2a/README.md:152`、`f_a2a/README_en.md:155`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §14.2「公开 API 未文档化 / 文档与契约不一致」
- **证据**：静态确定 —— `count` 只定义在 `InMemoryA2aTaskStore` 上，`A2aTaskStore` 接口（`:24-28`）没有；`f_a2a` 内搜 `count(` 只命中定义处这一行，`src/` 与测试零调用，只有两份 README 把它列为 API
- **描述**：README 把 `count` 列为 `InMemoryA2aTaskStore` 的公开方法，但注入自定义 store 后宿主/服务端拿不到计数；也没有任何用例覆盖。按死代码判据它属于「对外可达的 public 成员」，不计死代码，但当前既无消费方也无回归基线——将来按 S1 加淘汰策略时，没有用例能证明计数正确（同 id 覆盖不应 +1）
- **建议**：要么上移到 `A2aTaskStore` 接口并在监控/淘汰里真正用起来，要么从 README 移除；补一条用例：`save` 3 条 → `count()==3` → 覆盖同 id → 仍为 3

### [轻微][存量] 流测试先断言 `size >= 2` 再索引 `[1]`，缺事件时以越界异常失败

- **位置**：`f_a2a/src/server/A2aStream_test.cj:91-94`
- **来源**：存量（`dfb31f384b`）
- **判据**：review-checklist §11「边界差一 / 断言不严」
- **证据**：静态确定
- **描述**：`@Expect(recorder.events.size >= 2, true)` 允许 size 恰为 2，也允许 3、4；后续直接取 `[0]`/`[1]`，一旦只发出 1 条（例如终态事件丢失），用例抛 `IndexOutOfBounds`，报错信息里看不到"少了一条事件"，定位成本高于断言失败
- **建议**：改为 `@Expect(recorder.events.size, 2)`，再逐条断言 method/state

### [轻微][存量] 产物事件用例未校验「在状态事件之后」，与 `A2aServer` 的顺序契约脱钩

- **位置**：`f_a2a/src/server/A2aStream_test.cj:99-113`（注释在 `:98`）；契约在 `f_a2a/src/server/A2aServer.cj:119`
- **来源**：存量（`dfb31f384b`）
- **判据**：review-checklist §11「注释承诺 A，实现校验 B」
- **证据**：静态确定 —— 用例只统计包含 `METHOD_ARTIFACT` 的事件条数，不比较下标
- **描述**：用例名与注释写的是「产物事件在状态事件之后单独发一条」，但断言等价于"恰好一条产物事件"。把 `publish` 的两段顺序对调（先产物后终态）后该用例仍通过，而 `A2aServer.cj:119` 的注释明确承诺"先状态后产物，客户端不会先看到产物"——这条顺序契约目前没有用例保护
- **建议**：断言产物事件的下标大于终态 status 事件的下标，或断言 `events.last()` 为 artifact

### [轻微][存量] 回调失败用例未断言回调实际发生过，`notifyTerminal` 提前返回时用例仍通过

- **位置**：`f_a2a/src/server/A2aStream_test.cj:192-202`
- **来源**：存量（`dfb31f384b`）
- **判据**：review-checklist §11「测试空断言 / 错误处理未覆盖」
- **证据**：静态确定 —— `notifier.ok = false`，用例只断言任务 `status == completed`
- **描述**：若 `notifyTerminal` 因任何原因没有调用回调（例如 `pushConfig.get` 未命中、提前 return），`calls` 为空，用例照样通过。用例声称覆盖"回调失败不影响任务状态"，实际只验证了"发送成功"，失败分支（`A2aServer.cj:291-294` 的 warn 且不回滚状态）没有被真正执行
- **建议**：补 `@Expect(notifier.calls.size, 1)`；如需覆盖 warn 分支，可断言返回值/false 之后 `status` 仍为 `completed`

> 本部分存量缺陷 9 条（严重 1 / 一般 3 / 轻微 5），是否纳入修复待用户决定。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [CPU] 把副本构造移出临界区，并把任务表按 id 分片

- **现状**：`save`/`get`/`list` 每次在唯一一把 `Mutex` 内做一次 O(history) 的 JSON 往返（`A2aTaskStore.cj:43-69` → `A2aJson.cj:33-38`）；一次 `send` 落库 1 次，客户端随后 `get` 再 1 次，`list` 按条各 1 次。所有并发请求共用这把锁
- **方案**：①锁内只做 `tasks[id] = task` / 取引用，`copyOf` 移到 `synchronized` 外；②任务量增大后把 `HashMap` 拆成 N 个分片（按 `hash(id) % N`），每片一把锁，`count` 改为跨片求和
- **预期**：锁持有时间从 O(history) 降到 O(1)，`get`/`save` 混合负载下吞吐随线程数近线性；具体降幅需实测，不做数字承诺
- **代价**：①依赖"存进去的对象之后不再原地修改"这一不变量（当前成立：`save` 存的是副本，`get` 返回副本）；②分片后 `list`/`count` 需要跨片遍历，语义不变但实现变复杂；③分片数与容量上限（见 S1）要一起定
- **验证**：8 / 16 线程混合 `save`+`get` 压测，记录锁等待时长与 p99；`cjpm bench -O2` 同机对照，取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `A2aJson.copyOf` 的 JSON 往返是 `send`/`get` 的主要分配来源 | `f_a2a/src/model/A2aJson.cj:33-38` | 分配量与 CPU 自耗时占比 | `cjprof heap` + `getAllocatedHeapSize()`，跑 10k 次 send/get，history 10 条 |
| 2 | 同步 push 回调占 `send` 端到端延迟的可观比例 | `f_a2a/src/server/A2aServer.cj:116,215` | 分段计时（executor / notify / save） | 回调端点注入 50/200ms 延迟，记录 p50/p95 |
| 3 | `SseHub.publish` 的全局锁在并发流场景下产生等待 | `f_a2a/src/server/A2aEvents.cj:42-44`（锁在 `f_jsonrpc/src/server/SseHub.cj:94-116`） | 线程 BLOCKED 时间与并发度 | 100 个并发 `a2a.message.stream`，采样线程状态；CPU profile 看不到锁等待 |
| 4 | 存储锁内 `copyOf` 使 get/save 串行化（第 2 部分文件，此处仅提示） | `f_a2a/src/server/A2aTaskStore.cj:43-56` | 临界区时长、锁等待 | 压测 save/get 混合，记录锁等待与 p99 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 存储锁内 `copyOf` 已成为 `send`/`get` 的串行段 | `f_a2a/src/server/A2aTaskStore.cj:43-56` | 临界区时长、锁等待占比 | 8 线程混合 `save`/`get` 压测 10 分钟，分段计时 + 线程状态（BLOCKED 占比），history 10 条 vs 100 条各跑一轮 |
| 2 | 任务表长期增长速率决定 OOM 触顶时间 | `f_a2a/src/server/A2aTaskStore.cj:38,45` | 单任务实际占用字节、QPS | 连续 10k 次 `send`，每 1k 记录 `getUsedHeapSize()` 与 RSS 差值，除以任务数得单任务占用 |
| 3 | `list(0)` 全量物化在大存量下造成内存尖峰 | `f_a2a/src/server/A2aTaskStore.cj:58-69` | 1k/10k 任务时的分配量与峰值 | 预置 1k、10k 任务后调用 `list(0)`，对比调用前后 `getAllocatedHeapSize()` |

## 文件覆盖

> 与 `files/f_a2a.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_a2a/README.md` | .md | ✅ | — |
| 2 | `f_a2a/README_en.md` | .md | ✅ | — |
| 3 | `f_a2a/doc/a2a-protocol.md` | .md | ✅ | — |
| 4 | `f_a2a/doc/spec/add-f-a2a/design.md` | .md | ✅ | — |
| 5 | `f_a2a/doc/spec/add-f-a2a/proposal.md` | .md | ✅ | — |
| 6 | `f_a2a/doc/spec/add-f-a2a/specs/a2a-protocol/spec.md` | .md | ✅ | — |
| 7 | `f_a2a/doc/spec/add-f-a2a/tasks.md` | .md | ✅ | — |
| 8 | `f_a2a/src/A2a.cj` | .cj | ✅ | — |
| 9 | `f_a2a/src/A2aE2E_test.cj` | .cj | ✅ | — |
| 10 | `f_a2a/src/client/A2aClient.cj` | .cj | ✅ | — |
| 11 | `f_a2a/src/client/A2aClient_test.cj` | .cj | ✅ | — |
| 12 | `f_a2a/src/model/A2aJson.cj` | .cj | ✅ | — |
| 13 | `f_a2a/src/model/A2aJson_test.cj` | .cj | ✅ | — |
| 14 | `f_a2a/src/model/A2aModels.cj` | .cj | ✅ | — |
| 15 | `f_a2a/src/model/A2aModels_test.cj` | .cj | ✅ | — |
| 16 | `f_a2a/src/server/A2aEvents.cj` | .cj | ✅ | — |
| 17 | `f_a2a/src/server/A2aExecutor.cj` | .cj | ✅ | — |
| 18 | `f_a2a/src/server/A2aPushConfig.cj` | .cj | ✅ | — |
| 19 | `f_a2a/src/server/A2aServer.cj` | .cj | ✅ | — |
| 20 | `f_a2a/src/server/A2aServer_test.cj` | .cj | ✅ | — |
| 21 | `f_a2a/src/server/A2aStream_test.cj` | .cj | ✅ | — |
| 22 | `f_a2a/src/server/A2aTaskStore.cj` | .cj | ✅ | — |

合计：`.cj` 15 个 / `.md` 7 个 / 共 22 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：整对象覆盖写丢更新（#3）；设计：接口契约缺失（#4）；语言特性：`copyOf` 走 JSON 往返而非显式 copy（#2）；安全性：无外部输入拼接，`copyOf` 的静默降级在当前数据上不可达 |
| §1 死代码 | 0 | 机械过完：`private mutex`/`tasks` 同文件使用；`A2aTaskStore` 三个方法为对外接口契约；`count()` 属「对外可达 public」，按硬原则不判死代码（仓内零引用记入 #6）；测试文件 `EventRecorder`/`RecordingNotifier` 及其 `public var` 在同文件使用，`streamCard`/`paramsOf`/`idOf` 三个 private 函数均有调用；两文件 import 均实际使用 |
| §2 重复逻辑 | 0 | 存储 4 个函数输出/副作用各不相同；测试 helper（`paramsOf`/`idOf`/`streamCard`）与 `A2aServer_test.cj:46-69` 的 `sendParams`/`idParams`/`card` 近似重复，属 checklist §2「测试准备代码」误报边界，不报；`copyOf` 的三处调用是同一函数的复用，不是重复实现 |
| §3 空实现 | 0 | `init()` 空体是无状态构造；`save`/`get`/`list`/`count` 均有实现；无 `TODO`/`FIXME`/`catch {}` |
| §4 栈溢出 | 0 | 唯一的递归面是 `copyOf`→`toJson`/`taskOf`，深度固定为 task→message→part 三层，不随输入增长（parts 是平铺数组） |
| §5 OOM | 1 | 任务表无界增长（#1）；`list` 全量物化（#5 附带说明） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，锁内 `copyOf` 只按临界区内容判定（#2），耗时占比列入待验证假设 #1 |
| §6.2 大粒度锁 | 1 | 单锁保护整表且锁内做序列化（#2） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get`；串行化来源是锁，已归 §6.2 |
| §6.4 低效算法 | 0 | 遍历为单层 O(n)；`copyOf` 是每条约定的深拷贝，不是重复计算 |
| §7 降堆内存方案 | 0 | 本部分可降的是"总量无界"，属缺陷 #1 的修法，不作为优化方案重复统计 |
| §8 降 CPU 方案 | 1 | 锁外复制 + 分片（证据状态：无基线） |
| §9 local mode 可行性 | 0 | `copyOf` 产物必然逃逸（返回给调用方），不满足 local region 逃逸检查；无收益证明路径 |
| §11 现有代码的 BUG（存量） | 9 | 本部分 9 条发现全部为存量，已逐条给 `git blame` 依据；重点核对过 `save`/`get`/`list`/`count` 的边界（空 id、`limit<=0`、空表）与并发路径 |
| §12 并发安全与锁粒度 | 3 | #2（锁粒度）、#3（读改写非原子）、#4（契约未声明线程安全）；共享路径已指明：`A2aServer` 单实例持有 `store`，由 JSON-RPC 线程池并发调用 |
| §14 功能完备性与 README 覆盖 | 2 | #5（`list` 无协议入口、半成品）、#6（`count` 不在接口却被 README 列出） |
| 文件覆盖（§13 等） | 2/2 | 本部分清单 2 个文件全部读完；`.md` 一致性结论见第 1 部分（本部分无 `.md`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 12 |
| 轻微 | 11 |
| 其中存量 | 9 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：协议主链路（模型序列化、状态机、9 个方法注册、客户端透传）结构清晰，模型与 JSON 层职责划分合理，测试对成功/失败/input-required/未知任务等常规路径覆盖到位。阻塞项集中在「执行期任务不可见」与「回调出站无校验」两处：前者让 `cancel` / `get` 在真实并发下失效，并使设计文档里的「流中取消」无法实现；后者把任意 URL 变成服务端出站请求。次一级的问题集中在文档与实现脱节（`-32024`、`resubscribe` 参数、`contextId` 续跑、`streaming` 能力位、README 示例），会直接误导接入方。`send`/`stream` 的复制粘贴与注册表的“假计数”是后续修复容易漏改、测试容易误判的结构性原因，建议与上述阻塞项一并排期。存量缺陷 17 条，是否纳入修复待用户决定。

**第 2 部分**：存储层代码很短（76 行），形态也干净：单锁 + 副本返回 + 接口与内存实现分离，`copyOf` 的字段覆盖经核对是完整的（`A2aTask` 7 个字段在 `toJson`/`taskOf` 里都有往返），`get` 的副本语义确有用例证明。真正的问题不在实现细节，而在**契约形状**：接口只提供"整对象写 + 副本读"，既没有删除/淘汰（#1，长跑必然 OOM），也没有条件更新（#3，让第 1 部分的"取消被覆盖"在存储层无解），而并发与副本这两条最关键的约定只写在实现类注释和 `doc/a2a-protocol.md` 里，没有落到接口上（#4）。次一级是锁内做整棵对象的序列化（#2），单请求看不出，但它是 `send`/`get` 并发度的上限，且改法明确、风险低。

`A2aStream_test.cj` 覆盖了流式主链路（working→completed、产物事件、重订阅、扩展卡片、推送生命周期、回调失败、非文本 part），方向正确但三处断言偏弱（#7/#8/#9），其中"产物在状态之后"和"回调失败"两条恰好是 `A2aServer` 注释里明确承诺的顺序/错误契约，却没有被真正锁住。

建议排期：优先 #1（容量上限 + 淘汰，或明确文档化"生产必须换持久化实现"）与 #3（接口加条件更新，与 part1 #1 一起改），#2/#4 可同批；#5-#9 随测试补强一起做。本部分存量缺陷 9 条，是否纳入修复待用户决定。

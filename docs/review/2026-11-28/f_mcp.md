# f_mcp 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_mcp_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_mcp`（53 个文件：33 个 .cj + 20 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_mcp.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] 英文版把内置限流后端写成「5 种」，实现只有 4 种

- **位置**：`f_mcp/README_en.md:250`、`f_mcp/README_en.md:263`（对照 `f_mcp/README.md:247`）
- **来源**：存量（快照模式无基线，`git blame` 无对比对象）
- **判据**：review-checklist §13「API / 配置与源码不符」「`README_en.md` 与 `README.md` 结论相反」
- **证据**：静态确定 —— `f_mcp/src/server/McpRateLimit.cj:319-324` 的 `RateLimitBackends.static init()` 只 `register` 了 `TokenBucketRateLimitBackend` / `LeakingBucketRateLimitBackend` / `SlidingWindowRateLimitBackend` / `UnlimitedRateLimitBackend` 四个；`any-moment` 已在中文版 `README.md:261-262` 明确写「已移除」。`README_en.md:252-257` 的表格自身也只有 4 行，与同页「Five」自相矛盾
- **描述**：英文读者会去找不存在的第 5 种算法（最可能猜 `any-moment`，而它引用即报错）；同时英文版 `README_en.md:263` 整段删掉了中文版关于「SPI 只有 acquire 没有 release，所以移除 any-moment」的说明，读者无法理解为什么没有「任意时刻放行」这一档
- **建议**：`250` 改 `Four`、`263` 改 `the four built-in implementations`，并把中文版 `261-262` 的 any-moment 说明补译到英文版；若后续新增第 5 种实现，改为「见 `RateLimitBackends` 注册表」而不再写死数字

### [一般][存量] 英文版丢掉 `@McpToolMeta` 的 `-1` 继承语义，且与自己的迁移表冲突

- **位置**：`f_mcp/README_en.md:132`（对照 `f_mcp/README.md:131`、`f_mcp/README_en.md:798`）
- **来源**：存量
- **判据**：review-checklist §13「参数 / 默认值与源码不符」「README_en 少整段语义」
- **证据**：静态确定 —— `f_mcp/src/server/McpAnnotations.cj:27-30` 五个限流字段默认值均为 `-1`；`f_mcp/src/server/McpRegistry.cj:235-241` 的 `mapLimit` 把 `<0` 映射为 `None`（= 继承服务级），`>=0` 映射为 `Some`（`0` 由 `f_mcp/src/server/McpRateLimit.cj:141-143` 的 `rpm <= 0` 分支放行 = 不限制）。中文版 `README.md:131` 写全了「`-1`（默认）沿用服务级配置、`0` 表示不限制、`>0` 表示限额」，英文版只剩「`0` means unlimited」；而英文版 `798` 又写「numeric default `0` → `-1`」，同页两处口径不一致
- **描述**：英文读者只知道 `0` = 不限制，会把 `0` 当成「不覆盖、沿用服务级」来写，实际却把该维度限流彻底关掉；也不知道 `-1` 是继承值
- **建议**：`132` 补成 `` `-1` (default) inherits the service policy, `0` disables the limit, `>0` sets it ``，与中文版逐句对齐

### [一般][存量] 多个 `@Mcp` 类时 `serverInfo.name` 互相覆盖，README 未提示

- **位置**：`f_mcp/README.md:127-128`、`f_mcp/README_en.md:128-129`（行为证据在 `f_mcp/src/macros/Mcp.cj:73`、`f_mcp/src/server/McpRegistry.cj:201-203`、`f_mcp/src/server/McpServer.cj:279-287`）
- **来源**：存量
- **判据**：review-checklist §14.2「缺关键段落 / 限制与注意事项」；判「文档遗漏」的承诺源与缺失证据见下
- **证据**：静态确定 —— 承诺源 `README.md:128`「属性 `@Mcp['kb-server']` 或 `@Mcp[kbServer]` 指定 `serverInfo.name`」+ `README.md:127`「一个进程可以有多个 `@Mcp` 类」；缺失证据：`Mcp.cj:73` 每个类展开都调用 `McpRegistry.serverInfo(name)`，`McpRegistry.cj:201-203` 写入的是同一个共享 `McpServerBuilder`，`McpServer.cj:279-287` 直接赋值 `serverName`，无去重、无告警、无「多 server」概念
- **描述**：一个进程里放两个 `@Mcp['a']` / `@Mcp['b']` 类时，`server/discover` 只会返回其中一个名字（取决于 dylib 加载顺序，属于未定义行为），而 README 的表述会让读者以为每个 `@Mcp` 类各自是一套服务。当前实现下 tool / resource / prompt 确实会累计，只有名字被后者覆盖
- **建议**：在 `127-128` 补一句「`serverInfo` 全进程唯一，多个 `@Mcp` 类的 name 后注册者覆盖先注册者；需要多套 MCP 服务请直接用 `McpServer.builder()`」；或在 `McpRegistry.serverInfo` 里对「已设置且不同名」抛 `McpException`（实现侧决策，不属于本部分修改范围）

### [轻微][存量] 工具名允许字符集写成含单引号，实现不允许

- **位置**：`f_mcp/README.md:606`、`f_mcp/README_en.md:613`（另见 `f_mcp/README.md:528` 未写字符集，仅列注解字段）
- **来源**：存量
- **判据**：review-checklist §13「参数限制与源码不符」
- **证据**：静态确定 —— `f_mcp/src/base/McpProtocol.cj:45-56` 的 `isToolName` 只接受 `A-Z a-z 0-9 _ - .`；`f_mcp/src/server/McpTool.cj:122-123` 的报错文案同为 `1~128 chars of A-Z a-z 0-9 _ - .`。文档代码块 `` `A-Za-z0-9_-.'` `` 的字符类里多了一个 `'`
- **描述**：按文档写带 `'` 的工具名（如 `kb.search's`）会在 `build()` 抛 `McpException`，属于「照着文档写反而报错」
- **建议**：两处统一为 `` `A-Za-z0-9_-\.` ``，或直接改成散文「字母、数字与 `_ - .`」

### [轻微][存量] `CallToolResult.content` 的类型描述与同文 API 块矛盾

- **位置**：`f_mcp/README.md:401`（对照 `f_mcp/README.md:475`）、`f_mcp/README_en.md:403`（对照 `f_mcp/README_en.md:478`）
- **来源**：存量
- **判据**：review-checklist §13「文档内部不一致」
- **证据**：静态确定 —— `f_mcp/src/base/McpContent.cj:111` 为 `public let content: ArrayList<ContentBlock>`；同文 API 块 `README.md:475` 写的也是 `ArrayList<ContentBlock>`
- **描述**：`401` 写成「`CallToolResult.content` 是 `ContentBlock`」，读者会按单值访问（`result.content.kind()`），实际元素在列表里
- **建议**：改为「`content` 是 `ArrayList<ContentBlock>`，未知内容块类型不会被丢弃」

### [轻微][存量] 把以 `/` 开头的绝对路径称为「相对路径」，与同文「不带 `/` 的路径抛异常」冲突

- **位置**：`f_mcp/README.md:620-621`（对照 `f_mcp/README.md:216`）、`f_mcp/README_en.md:628-629`（对照 `f_mcp/README_en.md:217`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」/ 术语与行为描述不一致
- **证据**：静态确定 —— `f_mcp/src/server/McpResource.cj:119-139` 的 `validateUri` 只接受 `http(s)/ftp` 全 URL 或以 `/` 开头的路径，其余一律抛 `McpException`；`McpResource.cj:62-74` 的 `resolved` 也只对 `uri.startsWith('/')` 拼 `publicBaseUrl`
- **描述**：`620` 写「相对路径需要 `publicBaseUrl`，构建服务时拼成绝对 URL」，紧接的却是「以 `/` 开头的绝对路径」；而 `216` 明确「不带 `/` 的相对路径」在构建期抛异常。读者按 `620` 写 `McpResource.builder('doc', 'doc')` 会直接失败
- **建议**：两处统一措辞：「站内路径必须写成以 `/` 开头的绝对路径（构建时拼 `publicBaseUrl`）；不带 `/` 的路径一律在构建期抛 `McpException`」

### [轻微][存量] 「其他公开 API」清单不全：`McpConfig`、`ConcurrencyGate.close/size`、再导出的 `convert`

- **位置**：`f_mcp/README.md:820-832`、`f_mcp/README_en.md:832-844`（对照 `f_mcp/README.md:22`）
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化」
- **证据**：静态确定 —— `grep -n "McpConfig" README.md README_en.md` 无命中，而 `f_mcp/src/server/McpConfig.cj:37` 是 `public class McpConfig`，提供 `version()` / `publicBaseUrl()` / `rateLimit()` / `rateLimitBackendName()` / `trustForwardedFor()` 五个 public 静态方法（业务代码想在非 Builder 场景读同一份配置时会用到）；`f_mcp/src/server/McpRateLimit.cj:433-442` 的 `ConcurrencyGate.close()` / `size()` 为 public，但 `README.md:825` 只列了 `sweepNow`；`f_mcp/src/exports.cj:23` 还 `public import fountain::f_data.convert`，而 `README.md:22` 只列了 `lookup` / `BeanFactory` / `TypeInfo` / `ArrayList` / `JsonValue`
- **描述**：`820` 段自称「以下声明未在上文展开」，读者会把它当完整清单；`McpConfig` 整类缺失，`ConcurrencyGate` 的生命周期方法（`close`）缺失，容易让人以为闸门无需释放
- **建议**：清单补 `McpConfig`（含 5 个方法）、`ConcurrencyGate` 的 `close` / `size`，`22` 的再导出列表补 `convert`

### [轻微][存量] `MCP-Protocol-Version` 请求头的校验语义未进 README

- **位置**：`f_mcp/README.md:28`、`f_mcp/README.md:230`、`f_mcp/README_en.md:29`、`f_mcp/README_en.md:231`（实现：`f_mcp/src/server/McpServer.cj:804-826`）
- **来源**：存量
- **判据**：review-checklist §14.2「关键协议行为缺文档」
- **证据**：静态确定 —— `McpServer.cj:804-826` 对 `MCP-Protocol-Version` 头做了三段判定：头不受支持 → `-32022`；头与 `params._meta` 版本不一致 → `-32602`（`data.header` / `data.body`）；头缺失则只校验 body。`grep -n "Protocol-Version" README.md README_en.md` 无命中，README 只说「逐请求 `_meta` 校验」
- **描述**：这是对客户端可见、且会产生不同错误码的契约；文档缺这段，客户端在头/body 不一致时拿到 `-32602` 无法从文档定位原因
- **建议**：在「规范版本」段补一行头语义（可选头、缺省按 body、不一致 `-32602`、不受支持 `-32022`）

**存量 8 条，是否纳入修复待用户决定。**

### 范围外提示（不计入本部分统计）

- `f_mcp/src/server/McpRegistry.cj:38-40`、`211-215` 重建时直接丢弃旧 `McpServer`，未调用其 `close()`；旧 `ToolResultStore` / `ConcurrencyGate` / `RateLimitBackend`（含 limiter 池）不会主动释放，而 `@Mcp` 每个类展开都会触发一次 `build()`（`f_mcp/src/macros/Mcp.cj:103`）——属第 5 部分 `.cj` 审查范围，此处仅记录。
- `f_mcp/src/server/McpServer.cj:439-444` 的 `close()` 会关闭注入的 `RateLimitBackend`；README `README.md:326` 与 `README.md:816` 推荐的「多 server 共享一个 backend」用法在进程内共享时会互相影响——同属第 5 部分范围。
- `f_mcp/src/server/McpServer.cj:540-545` 的 `legacyData()` 对 `notifications/initialized` 也返回 `legacyMethod: "initialize"`，与 README `README.md:35` 「data 带 legacyMethod」并不矛盾，但字段值与方法不符——属第 5 部分范围。

<!-- 第 2 部分 -->

### [一般][存量] 能力集里的 `prompts`：现行设计文档自相矛盾，且与实现相反

- **位置**：`f_mcp/doc/f_mcp模块设计.md:93`、`:589`、`:740`、`:751`、`:2213`、`:2324`（均写"不声明 / 没有 `prompts` 键"）；同文件 `:717`（方法表写"✅ 已实现、能力含 prompts"）、`:2428`（对照表"prompts 保留"）；`f_mcp/doc/spec/add-f-mcp/design.md:42`（D3）与 `:108-110`（D14）互斥；`f_mcp/doc/spec/add-f-mcp/specs/mcp/spec.md:44`（MUST NOT）与 `:141-148`（Requirement: prompts）互斥；`tasks.md:21` 与 `:80` 互斥；实现 `f_mcp/src/server/McpServer.cj:566-579`、`:527-528`
- **来源**：存量 —— 文档最后修改 `669f4c6bf`（2026-10-25）/ `f29c8cc9d`（2026-10-24）；`McpServer.cj` 之后仍有 `940c3e573`、`4b980bfa8`、`86643306a`、`7506429b3`（至 2026-11-22），正文未随实现回填
- **判据**：review-checklist §13「规格与实现漂移」「文档过期」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— `capabilities()` 无条件写入 `prompts.listChanged=false`（`McpServer.cj:576-578`），`prompts/list` / `prompts/get` 均已注册（`:527-528`）；而设计文档 6 处写"首版不声明 / 完全没有 prompts 键"，`specs/mcp/spec.md:44` 更写成 MUST NOT，`tasks.md:21` 的验收用例仍是"discover 且没有 prompts"
- **描述**：同一字段在四份文档内出现互斥结论，连同一份 spec 内部都冲突（`:44` 禁止 vs `:141` 要求）。实现选择了"声明并实现"。后果：①按 `spec.md:44` 实现客户端的调用方会认定该服务端不合规；②按 `spec.md:141` 实现又要求 `prompts` 必须出现，两者不能同时满足；③§5.4.1 整节的"不声明空壳"原则被自己 §5.4 的表否掉，读者无法判断当前能力集。文档末尾的「文档与实现对照」表（`:2428`）虽写"prompts 保留"，但位于 2400 行之后，正文与 spec 均未同步
- **建议**：以实现为准回填现行设计文档 §0:93、§5.4.1:740-751、§9:2213/2221、§12.1:2324；`specs/mcp/spec.md:44`、`tasks.md:21`、`design.md:42` 属上一代变更，至少在文件头加一行"历史口径：`prompts` 后由 `fix-jsonrpc-mcp-review-findings` 改为声明并实现（见模块设计 §5.4）"

### [一般][存量] 服务端 API 文档示例与实现不符：照抄会编译失败

- **位置**：`f_mcp/doc/f_mcp模块设计.md:558-578`（`Builder` 的 `name`/`version`/`instructions`/`path`/`addTool`/`addResource`）、`:585`（`close()` 说明）、`:1156`（`purgeExpiredResults()`）、`:1686-1693`（controller 示例返回 `Array<Byte>` 并调 `McpRegistry.server().handle(raw, ctx)`）；实现 `f_mcp/src/server/McpServer.cj:262-360`、`:423`、`:439-444`、`f_mcp/src/server/McpController.cj:54-63`、`f_mcp/src/server/McpResultStore.cj:155`
- **来源**：存量（文档 `669f4c6bf`；实现后续多次修改）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例代码不能用」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— 实际 `McpServerBuilder` 只有 `serverInfo(name, version)` / `rateLimit` / `publicBaseUrl` / `pageSize` / `resultStore` / `rateLimitBackend` / `trustForwardedFor` / `maxSubscribers` / `subscriberQueueCapacity` / `subscriberDetachedTtl` / `tool` / `resource`，**没有** `name` / `version` / `instructions` / `path` / `addTool` / `addResource`；`close()` 释放的是 `resultStore` / `gates` / `backend` / `hub`，不是文档写的"限流桶 + 淘汰线程"；全仓搜 `purgeExpiredResults` 只在文档与 4 个 `.worktrees` 副本命中，`src/` 零命中，等价能力是 `ToolResultStore.sweep()`（`McpResultStore.cj:155`），需先 `resultStoreRef()`（`McpServer.cj:431`）取实例；`McpController.handle` 返回 `Any` 并调 `server.jsonRpcServer().handle(raw, ctx: ctx)`（`McpController.cj:54-62`）
- **描述**：5.1 是"服务端 API"的唯一入口章节，六个方法名在实现里一个都不存在（等价能力用另外的签名提供）；6.4 的 controller 示例返回类型与调用方式也与实现不同（`McpServer` 上没有 `handle` 方法）。照文档写代码会连续报"成员不存在"。其中 `purgeExpiredResults()` 属"文档承诺、代码无此 API"（能力实际在 `ToolResultStore` 上），是功能完备性问题而非笔误
- **建议**：5.1 按 `McpServerBuilder` 实际方法重写，并在缺项处写明"不支持 `instructions`，路由固定 `/mcp`"（与变更设计的 Non-Goal 一致）；6.4 示例改为 `Any` + `jsonRpcServer().handle(raw, ctx: ctx)`；`purgeExpiredResults()` 要么在 `McpServer` 上补一个转发方法，要么改成"`resultStoreRef().sweep()`"并注明线程语义

### [一般][存量] 客户端 `input_required` 多轮 API 在实现中不存在（`InputRequiredMode` / `onInputRequired` / `callTimeoutMs` / `roundTimeoutMs`）

- **位置**：`f_mcp/doc/f_mcp模块设计.md:405`（`opts!`）、`:477-492`（枚举与 `McpClientOptions` 字段）、`:515-525`（多轮伪代码）、`:531-533`（"总超时覆盖全部轮次"）；实现 `f_mcp/src/client/McpClient.cj:30-47`、`:276`、`:331-335`
- **来源**：存量（文档 `669f4c6bf`；`McpClient.cj` 之后独立演进）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例代码不能用」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全仓搜 `InputRequiredMode` 零命中；`McpClientOptions` 实际字段为 `timeout` / `protocolVersion` / `clientName` / `clientVersion` / `capabilities` / `maxRounds` / `headers` / `maxResponseBytes` / `keepAlive` / `retryOnConnectFailure`；多轮入口是独立方法 `callToolAuto(name, arguments, handler!, maxRounds!)`；`McpClient.http` 的具名参数是 `options!` 而非文档的 `opts!`
- **描述**：文档设计"默认 `Manual`，可配 `Auto(handler, maxRounds)`"，实现改成"`callTool` 单轮 + 独立 `callToolAuto`"，方向合理但文档未改：①枚举与两个超时字段不存在，示例无法编译；②4.4.2 的第 3 条硬规则"总超时覆盖全部轮次"在实现里没有对应参数（`timeout` 作用于单次 RPC），按文档调参会以为设了 60 秒总上限，实际是每轮 60 秒，轮数多时总耗时成倍超出预期
- **建议**：4.1 / 4.4 按实现重写：删 `InputRequiredMode`，写清 `callTool` 原样透传 `input_required`、`callToolAuto(..., maxRounds)` 自动重试；`opts!` 改 `options!`；4.4.2 第 3 条改为"当前无总超时，`timeout` 按单次请求计，调用方需按轮数折算"，或补实现

### [一般][存量] 自适应配置章节自相矛盾：`adaptive: None` 示例不可编译，配置项数量 9 / 12 / 13 三种说法

- **位置**：`f_mcp/doc/f_mcp模块设计.md:18`（"12 个"）、`:101`（"13 项"）、`:1278`（"9 项"）、`:2348`（"13 项"）、`:1573`（`adaptive: None`）、`:2343`（"`adaptive: None` 可关"）、`:1284-1295`（struct 定义）；实现 `f_mcp/src/server/McpResultStore.cj:27-31`
- **来源**：存量（`669f4c6bf`）
- **判据**：review-checklist §13「示例代码不能用」「API / 默认值与源码不符」
- **证据**：静态确定 —— `ResultStoreOptions.adaptive` 是 `Bool = true`，传 `None` 无法通过类型检查（`:1573`、`:2343` 两处）；实际可配字段 9 个（`maxEntries`/`maxBytes`/`ttlMillis`/`adaptive`/`windowMillis`/`rejectRateThreshold`/`floor`/`ceiling`/`shrinkConfirmWindows`），5.6.6.5.3 的"9 项"才对
- **描述**："怎么关掉自适应"是使用者最常查的一节，给出的示例编译不过（正确写法 `adaptive: false`）。数量口径三处不一致会让读者怀疑还有未列出的配置项，而决策表 `#28` 又强调"13 项全部可配、无写死魔数"，与 struct 实际 9 字段直接冲突
- **建议**：`:1573`、`:2343` 改 `adaptive: false`；`:18`、`:101`、`:2348` 统一为 9 项；若坚持 13 项，需把步长（25% / 12.5%）与冷却窗口真实暴露为字段

### [一般][存量] 限流配置模型文档与实现不符：字段可空性、`maxConcurrency` 缺失、`maxResultBytes` 归属矛盾

- **位置**：`f_mcp/doc/f_mcp模块设计.md:1770-1792`（`RateLimitPolicy` 非空字段带默认 600/120/6000/8，`ToolRateLimit` 含 `maxResultBytes`）、`:1216-1220`（5.6.6.4 把 `maxResultBytes` 写进 `RateLimitPolicy`）、`:1779-1780`（7.2.1 注释又说"`maxResultBytes` 不在这里"）；实现 `f_mcp/src/server/McpRateLimit.cj:24-40`、`f_mcp/src/server/McpTool.cj:49`、`f_mcp/src/server/McpServer.cj:1096`
- **来源**：存量（`669f4c6bf`）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」；§2「重复逻辑」的文档侧表现（同一事实两处写法不同）
- **证据**：静态确定 —— 实现的 `RateLimitPolicy` / `ToolRateLimit` 字段全部 `?Int64 = None`，并多出 `maxConcurrency`（全局总并发）与 `perCallerConcurrency`；`maxResultBytes` 只存在于 `McpTool`（`McpTool.cj:49`、`McpToolBuilder.maxResultBytes`），服务端取 `tool.maxResultBytes ?? 1 MiB`（`McpServer.cj:1096`）
- **描述**：文档的配置示例不可编译（`RateLimitPolicy(perCallerRpm: 600)` 中 `600` 不能赋给 `?Int64`，实际需 `Some(600)` 或省略），`ToolRateLimit(maxResultBytes: ...)` 字段不存在；5.6.6.4 与 7.2.1 对 `maxResultBytes` 归属互相矛盾。更实质的是默认值语义：文档暗示"不配也有 600/120/6000/8"，实现是 `None`（该维度不限制），默认值只由 `McpConfig.rateLimit()` 提供，直接决定"什么都不配"时的防护强度
- **建议**：按实现重写两个 struct 示例（可空 + `maxConcurrency`）；5.6.6.4 代码块改 `McpTool(maxResultBytes: ...)`；补一句"`RateLimitPolicy()` 全 `None` 时该维度不限流，默认值来自 `mcp_rateLimit`"

### [一般][存量] 调用方识别：文档写"token 优先 + XFF 取最右侧"，实现是"XFF 优先 + 取第一段"

- **位置**：`f_mcp/doc/f_mcp模块设计.md:2106-2113`（7.2.5）；实现 `f_mcp/src/server/McpServer.cj:916-937`
- **来源**：存量（文档 `669f4c6bf`；`McpServer.cj` 后续有 `4b980bfa8` 等提交）
- **判据**：review-checklist §13「契约与实现不符」、§12.1「共享状态 / 越权」相关判据
- **证据**：静态确定（不一致本身）—— 文档顺序：1) `Authorization: Bearer` 的 token 取 SHA-256 前 16 字节 2) XFF "最右侧非代理 IP" 3) TCP 对端；实现：1) `X-Forwarded-For` **第一段**（仅 `trustForwardedFor`）2) 整条 `Authorization` 头的 SHA-256 前 32 个 hex 字符 3) `remoteAddr`。安全后果需实测（取决于前置代理是否覆写 XFF）
- **描述**：三处差异都有后果：①顺序不同，同时带 token 与 XFF 的请求在文档与实现下进入不同限流桶；②"最右侧"是防伪造的常见做法（左侧段由客户端可控），实现取第一段，一旦 `trustForwardedFor` 打开且代理是"追加"而非"覆写"，调用方可轮换第一段获得无限多个 `perCaller*` 配额；③文档说对 token 取摘要，实现对整条头（含 `Bearer ` 前缀与大小写）取摘要，同一 token 的不同书写会落在不同桶
- **建议**：先定正确语义（建议按文档：token 优先、XFF 取最右侧并配可信代理列表），再让代码与文档对齐；若保留现有顺序，文档必须改写并补一条部署约束"开启 `trustForwardedFor` 时前置代理必须覆写 XFF"

### [一般][存量] 限流后端与依赖描述过期：`f_cache.HeapCache`、`f_process`、"5 种内置限流器"

- **位置**：`f_mcp/doc/f_mcp模块设计.md:104`（依赖含 `f_process`）、`:1761`/`:1764`（"限流：三层配置 + `f_cache` 存储"）、`:1991-1993`（"决定：用 `f_cache.HeapCache`"）、`:2160`（"5 种内置 `RateLimitBackend`"）、`:2256`（P5 "f_cache 桶 / 10 万 key 淘汰"）、`:2286`（风险表"依赖 `f_cache`"）、`:62` 与 `:2433`（"4 种"）；实现 `f_mcp/cjpm.toml:1-9`、`f_mcp/src/server/McpRateLimit.cj:21-23`、`f_mcp/src/server/McpRateLimit_test.cj:110-113`
- **来源**：存量（`669f4c6bf`）
- **判据**：review-checklist §13「文档过期」「API / 配置与源码不符」
- **证据**：静态确定 —— `cjpm.toml` 依赖为 `f_bean`/`f_concurrent`/`f_config`/`f_data`/`f_jsonrpc`/`f_log`/`f_macros`/`f_mvc`，**无 `f_cache`、无 `f_process`**；`f_mcp` 内搜 `HeapCache` 零命中；限流后端实际 4 个（`token-bucket` / `leaking-bucket` / `sliding-window` / `unlimited`），单测逐一断言
- **描述**：7.2 整节（含 7.2.4 的 `maxLife` 语义分析、7.2.4.3 的 `HeapCache.close()` 要求）描述的是已被替换的 `f_cache` 方案，实际用 `f_concurrent` + 有界池；读者会去找不存在的依赖并复刻"每 Server 一份 HeapCache + 淘汰线程"。stdio 走 `std.process.launch`，不需要 `f_process`；而变更设计 `design.md:7` 又写"不引入 f_cache / f_process"、`verify-report.md:19` 写"增加 f_mvc"，三份文档对依赖三种说法。"5 种"与同文件 `:62`、`:2433` 的"4 种"冲突
- **建议**：7.2 以 `f_concurrent` 重写（保留结论，`HeapCache` 分析移入"历史方案"附录）；§0 依赖行去掉 `f_process`；`:2160` 改"4 种"；`design.md:7` 补一句"后续为 controller / 限流 / 配置已引入 `f_mvc` / `f_concurrent` / `f_config`（见 cjpm.toml）"

### [一般][存量] 变更设计的 Non-Goals 与风险表与本轮追加能力相反（自适应调容、stdio）

- **位置**：`f_mcp/doc/spec/add-f-mcp/design.md:79`（D8 "**不做自适应调容**（Non-Goal）"）、`:125`（"未做 stdio"）、`:126`（"未做自适应调容"）；相反口径同文件 `:92-98`（D10 stdio）、`:100-102`（D12 自适应）、`tasks.md:76-79`
- **来源**：存量（`f29c8cc9d`）
- **判据**：review-checklist §13「规格与实现漂移」；§14.1「只做了一半的分支」的反向形态（能力已做，文档说没做）
- **证据**：静态确定 —— 同一份 D 系列决策里 D10 描述 stdio 客户端、D12 描述自适应调容细节，而 D8 与风险表仍写"不做 / 未做"；实现里 `McpClient.stdio`（`McpClient.cj:280`）、`ResultStoreOptions.adaptive`（`McpResultStore.cj:29`，默认 `true`）都在，`tasks.md:76-79` 也已勾选
- **描述**：Non-Goals 与 Risks 是评审最先读的两块。当前版本会让评审者得出"stdio 与自适应都没做"的结论，与 D10/D12、tasks、verify-report 第 7 行、实现全部相反；若这份文档被当作验收依据，会直接判"承诺未达成"
- **建议**：D8 删掉"不做自适应调容"，只保留"不做可配置 HTTP 路由 / 不做跨进程强一致限流"；风险表两行改为"已实现，见 D10 / D12"或删除；文首补版本说明（v1 初版 / v2 追加 stdio、Auto 多轮、自适应、SSE、prompts、分布式限流 SPI）

### [一般][存量] `data.scope`：现行设计文档只列 5 个（§9 更旧写 4 个），实现是 6 个

- **位置**：`f_mcp/doc/f_mcp模块设计.md:2137-2143`（7.2.6 表列 `caller`/`caller_tool`/`tool`/`concurrency`/`concurrency_tool`）、`:2342`（12.1 #24 "五个值"）、`:2226`/`:2256`（§9 "四种取值"）；实现 `f_mcp/src/server/McpServer.cj:1014`、`:1019`、`:1024`、`:1043`、`:1051`、`:1058`
- **来源**：存量（文档 `669f4c6bf`）；`concurrency_caller` 由后续变更引入
- **判据**：review-checklist §13「API / 配置与源码不符」；§11「契约与实现不符」
- **证据**：静态确定 —— 六个 `RateVerdict.reject` 的 scope 实参为 `caller`、`caller_tool`、`tool`、`concurrency`、`concurrency_tool`、`concurrency_caller`；文档最全的 7.2.6 表也只列前五个，§9 又写"四种"
- **描述**：`concurrency_caller`（调用方×工具并发子限额）是**重试语义不同**的一类：`concurrency` 要等当前请求返回，`concurrency_tool` 要换工具，`concurrency_caller` 要降低对该工具的并发但可用别的工具。文档缺这一类，按文档实现的客户端落到 `_ => 默认`，会把"你对该工具并发了太多"误判为普通限流而盲目退避。§9 的"四种"更旧，连 `concurrency_tool` 都没有
- **建议**：7.2.6 表补 `concurrency_caller` 行与建议动作；12.1 #24 改"六个值"；§9:2226/2256 改"六种"；并在协议文档中说明新增 scope 的兼容策略（客户端遇到未知 scope 应保守退避）

### [轻微][存量] 两代 spec 并存且无交叉指引：`-32002`/`-32040`、429 与否

- **位置**：`f_mcp/doc/spec/add-f-mcp/specs/mcp/spec.md:96`、`:106`、`f_mcp/doc/spec/add-f-mcp/design.md:54`（资源不存在 = `-32002`）；`f_mcp/doc/spec/add-f-mcp/proposal.md:40`、`design.md:71`、`:128`（限流"不映射 429"）；对照 `f_mcp/doc/f_mcp模块设计.md:921`、`:2117`、`:2429`（`-32040` 与 429）与实现 `f_mcp/src/base/McpProtocol.cj:39`、`f_mcp/src/server/McpServer.cj:1083`
- **来源**：存量（`add-f-mcp` 为上一代变更；`-32002`→`-32040` 与 429 由 `doc/spec/fix-jsonrpc-mcp-review-findings` 的 R6-4 / R6-2 改定，该目录不在本部分文件清单内，仅作范围外取证）
- **判据**：review-checklist §13「规格与实现漂移」；归档豁免按「当时结论是否自洽」核对——本项属"同一 `doc/spec` 树下两代结论相反且无指引"
- **证据**：静态确定 —— `add-f-mcp` 内 `-32002` 与"不做 429"各自自洽（当时口径），但同目录后来新增的 `fix-jsonrpc-mcp-review-findings` spec 已改为 `-32040` 与 429；`add-f-mcp` 文件头没有任何"已被取代"标注，`f_mcp模块设计.md:2429` 的迁移说明埋在文末
- **描述**：读者从 `doc/spec/add-f-mcp/` 入门时，会实现"资源不存在判 `-32002`""限流错误永远 HTTP 200"，与当前服务端行为相反。归档豁免能解释"为什么没改"，不能解释"为什么没有任何指向新口径的路标"
- **建议**：给 `add-f-mcp` 的 4 份文件头部各加一行"状态：已被 `doc/spec/fix-jsonrpc-mcp-review-findings` 取代，错误码与 429 以该变更为准"；或在新旧 spec 之间加索引页

### [轻微][存量] spec 的订阅生命周期"关闭即注销"与实现的"detach 可重连"不一致

- **位置**：`f_mcp/doc/spec/add-f-mcp/specs/mcp/spec.md:157`（"连接关闭 MUST 注销订阅"）；实现 `f_mcp/src/server/McpSse.cj:28`、`:84`、`:104`、`f_mcp/src/server/McpServer.cj:117-140`、`:182-190`；设计文档对照表 `f_mcp/doc/f_mcp模块设计.md:2435`
- **来源**：存量（`f29c8cc9d`；`4b980bfa8` 之后实现改为"创建即计时、detach 幂等"）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— SSE 流结束调 `hub.detach(subscriber)`，订阅者保留 `detachedTtl`（默认 60s）供同一 `subscriptionId` 重连，`pruneLocked` 才真正移除；这段时间仍占 `maxSubscribers`
- **描述**：实现语义更好（可重连），但 spec 的 MUST 未同步；客户端若按 spec 假设"关闭即释放"，会在 `maxSubscribers=1024` 附近遇到 `-32003`（`OVERLOADED`）却找不到原因。属"实现优于 spec"，只需改文档
- **建议**：spec 改为"连接关闭后 MUST 进入 detached，`detachedTtl` 后注销；同一 id 在 TTL 内可重连"，并补容量语义（detached 也占 `maxSubscribers`）

### [轻微][存量] 摘要 / 测试表里另有多处已失效的结论（SSE、二进制截断、平台限制、注释常量）

- **位置**：`f_mcp/doc/f_mcp模块设计.md:96`（"首版不做 SSE"）、`:2281`（风险"SSE 未实现"）、`:2232`（"二进制超限转 `resource_link`、文本被截断"）、`:2221`（"未声明 `prompts` 时 `prompts/list` 返回 `-32601`"）、`:323`（stdio "仅 Linux / OHOS"）、`:1012`（`maxEntries: Int64 // 500`）
- **来源**：存量（`669f4c6bf`）
- **判据**：review-checklist §13「文档过期」；§14.2「版本与命令过期」
- **证据**：静态确定 —— `/mcp/sse` 已注册（`f_mcp/src/server/McpController.cj:30`）；大结果策略是"配了 baseUrl 一律转 link、未配才截断"（5.6.6），不是"二进制转 link / 文本截断"；`prompts/list` 已注册（`McpServer.cj:527`）；stdio 用 `std.process.launch`，`cjpm.toml` 覆盖 7 个 target（含 mingw / darwin），代码无 `@When` 平台守卫；`ResultStoreOptions.maxEntries` 默认 256
- **描述**：单条影响不大，但集中在"结论摘要"与"测试要点"两张最先被读的表上；例如照 `:2232` 写用例会断言"文本被截断"，与 5.6.6 的"文本也转 link"冲突
- **建议**：逐条替换（SSE 已实现、大结果统一转 link、`prompts` 已声明）；stdio 平台限制删掉或在代码补守卫后再写；`// 500` 改 `// 256`

### [轻微][存量] 游标编码描述与实现不符（"base64url / 十六进制" vs 标准 base64 的 `offset:<n>`）

- **位置**：`f_mcp/doc/spec/add-f-mcp/design.md:46`（D4）；实现 `f_mcp/src/base/McpProtocol.cj:58-60`、`:67-80`
- **来源**：存量（`f29c8cc9d`）
- **判据**：review-checklist §13「API 与源码不符」
- **证据**：静态确定 —— 实现是 `toBase64String("offset:${offset}".toArray())`，`stdx.encoding.base64` 的标准字母表（含 `+` `/` `=`），既不是 base64url，也不是十六进制；解码侧空串视为首页，非法输入返回 `None` 由调用方转 `-32602`
- **描述**：游标按协议是不透明字符串，客户端本不该解析，影响有限；但文档同时给出"内部结构"与"编码方式"两个错误细节，容易被用来做兼容性假设（例如以为可 URL 直接拼接而不转义）
- **建议**：改为"`base64(\"offset:<n>\")`，标准 base64，不是 base64url"，或只写"不透明，客户端不得解析"并删掉内部结构

<!-- 第 3 部分 -->

### [一般][存量] 从 JSON 还原时对无法解析的字段/条目静默丢弃，客户端拿到"少内容"的结果且无任何诊断

- **位置**：
  - `f_mcp/src/base/McpContent.cj:148` `CallToolResult.fromJson`：`content` 数组中非 `JsonObject` 的条目被 `case _ => ()` 丢掉（149-155）；
  - `f_mcp/src/base/McpContent.cj:208` `ResourceContent.fromJson`：`blob` 不是字符串 → `None`；是字符串但 base64 解码失败 → `fromBase64String` 返回 `None` 后直接落下 `None<Array<Byte>>`（208-215），不抛错、不记日志；
  - `f_mcp/src/base/McpContent.cj:216` / `245`：`uri` 缺失或非字符串经 `stringOf` 变 `''`（`f_mcp/src/base/McpModels.cj:502-511`），`content` 缺失经 `PromptMessage.fromJson` 变空文本块（249），同样无提示。
- **来源**：存量（快照模式无基线，全部为既有代码）
- **判据**：review-checklist §3（`case None => ()` 兜底把错误吃掉）、§11（错误处理缺失或静默；数据丢失）、§13（与 `specs/mcp/spec.md:417`「内容块与结构字段不得丢失」「语义等价」不符）
- **证据**：静态确定 —— `fromBase64String(data: String): Option<Array<Byte>>`「解码失败会返回 None」（`cangjie-doc` stdx base64 包函数文档 `libs_stdx/encoding/base64/base64_package_api/base64_package_funcs.md`），代码对该 `None` 不做任何分支；其余三处为显式 `case _ => ()` / `stringOf` 的 `''` 默认值。
- **描述**：服务端发来一个内容块不是对象（例如某些实现对 `content` 直接放字符串）、`blob` 不是合法 base64、或缺 `uri`，`fromJson` 都会产出一个「字段为空」的模型对象并正常返回。调用方无法区分"服务端没给"与"我们解不出来"，也不会触发任何重试或告警；随后 `toJson()` 再序列化时这些内容就永久消失了（`ResourceContent.toJson()` 在 `text`/`blob` 都为 `None` 时只输出 `{"uri":""}`，连 MCP 要求的 `text`/`blob` 二选一都不满足，见 `McpContent.cj:219-235`）。
- **建议**：`ResourceContent.fromJson` 在 `blob` 解码失败时抛 `McpException(INTERNAL_ERROR, "invalid base64 blob", data: uri)`（或至少 `log.warn` 并保留原始字符串字段）；`CallToolResult.fromJson` 对非对象条目改为「按 `text` 兜底」或抛错，不要静默 `continue`；`uri`/`type` 缺失时给出明确错误而不是空串。

### [一般][存量] 同一变更内「`@Mcp` 是否在模块加载期 `build()`」的规格、设计、任务三者互相矛盾，且任务已勾选但代码未按设计改

- **位置**：
  - `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp/spec.md:379`：`@Mcp` 展开 **MUST** 在加载期完成注册后调用 `McpRegistry.build()`；
  - `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/design.md:121`（R3-12）：决策为「**删除**宏内 `build()`；首次 `server()` 才构建」；
  - `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/tasks.md:392-393`（T38.4，已勾选 `[x]`）：Green 项写明「删除宏内 `McpRegistry.build()`」；
  - `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/tasks.md:518`（V7，已勾选）：声称代码注释已「去掉『最后调用 `McpRegistry.build()`』」；
  - 实现：`f_mcp/src/macros/Mcp.cj:103` 仍 `body += quote(McpRegistry.build())`，`f_mcp/src/macros/Mcp.cj:30` 注释仍写「最后调用 `McpRegistry.build()`」。
- **来源**：存量（该变更产物与实现同属工作区快照）
- **判据**：review-checklist §13（`doc/spec/**` 规格与实现漂移；同一变更内两份产物结论相反）、§14.1（承诺/任务标记与实际接线不一致）
- **证据**：静态确定 —— 四处文本与一处代码直接比对；`McpRegistry.build()` 的实现与注释见 `f_mcp/src/server/McpRegistry.cj:205-215`（每次全量重建，注释明确「不能在请求处理中调用——会丢掉结果缓存与订阅状态」）。
- **描述**：规格（MUST 加载期 build）与设计/任务（MUST 删除 build）互斥，只有一个能成立。实现与规格一致（每个 `@Mcp` 类展开后 build 一次），与设计和 T38.4 相反，因此 T38.4 的勾选是"未落地却已勾选"，V7 的注释清理也未发生。后果不在启动正确性（`McpRegistry.configure` 在 `built.isSome()` 时会重建，见 `McpRegistry.cj:35-42`，所以「`@Mcp` + `configure` 共存」仍成立），而在于：产物失去可信度——下一轮读者无法判断哪条是契约；且"每类重建一次"在多 `@Mcp` 类时会让先建的缓存/订阅状态被丢弃（启动期无流量，影响有限）。
- **建议**：先定结论再统一。若保留加载期 build（当前实现），就把 `design.md:121` 改为「保留 build + `configure` 重建兜底」，并给出为什么"首次 `server()` 才构建"不可行；若采纳删除，则改实现 `Mcp.cj:102-103`、同步 `spec.md:379` 的 MUST 与 `tasks.md` 的 T38.4 勾选说明。

### [轻微][存量] `CallToolResult.toJson()` 会凭空补一个 text 块：`fromJson`→`toJson` 不幂等，且 `structuredContent` 被完整序列化两次

- **位置**：`f_mcp/src/base/McpContent.cj:167-199`（合成逻辑在 177-181）
- **来源**：存量
- **判据**：review-checklist §13（模型往返语义等价）、§2/§8（同一份数据重复转换）；`specs/mcp-guardrails/spec.md:159`「`tools/call` MUST 只为『量字节』序列化一次；小结果路径 MUST NOT 重复序列化」
- **证据**：静态确定 —— 只要 `structuredContent` 非空且 `content` 里没有 `kind() == 'text'` 的块，就 `blocks.add(ContentBlock.text(structured.toString()).toJson())`；`JsonValue.toString()` 即 `toJsonString(false)`（`f_data/src/json/JsonValue.cj:153-155`），随后整条结果再被 `toString()` 序列化一次（`f_mcp/src/server/McpServer.cj:1099`）。
- **描述**：`CallToolResult.fromJson(x).toJson() != x`（多出一个 text 块）；`f_mcp/src/base/McpModels_test.cj:59-78` 之所以断言 `content` 仍是 2 条，是因为该用例的输入本来就带 text 块，未覆盖"只有 structuredContent"的形态。另一面：只返回 `structuredContent` 的工具（非 `@Mcp` 宏路径）在 `tools/call` 里会先把 `structuredContent` 转成一个完整字符串放进 text 块，再序列化整条结果，等于同一份 JSON 生成两遍；`maxResultBytes` 的判定也按放大后的体积算（`McpServer.cj:1097-1100`），使这类结果更早被转成 `resource_link` 或截断。
- **建议**：把"补 text 块"从 `toJson()` 里挪到服务端出口（只在真正写响应时决定是否补），或加显式开关参数；`toJson` 保持纯序列化，恢复往返幂等。若要保留现行为，至少在 `McpModels_test` 增加"仅 structuredContent"用例把语义固定下来。

### [轻微][存量] `ContentBlock` / `CallToolResult.fromJson` 直接持有入参 `JsonObject`，`toJson()` 又把它原样交回

- **位置**：`f_mcp/src/base/McpContent.cj:44-46`（`ContentBlock.fromJson(obj)` 把 `obj` 当 `payload`）、`f_mcp/src/base/McpContent.cj:36-38`（`toJson()` 返回同一个引用）、`f_mcp/src/base/McpContent.cj:146-165`（`CallToolResult` 的 `structuredContent`/`inputRequired`/`requestState` 均为入参子对象的引用）
- **来源**：存量
- **判据**：review-checklist §10（仓颉引用语义 / 可维护性）、§12.1（共享可变对象无保护）
- **证据**：静态确定 —— 构造函数 `private ContentBlock(kind, payload)` 直接赋值，无拷贝；`toJson()` 直接 `payload`。
- **描述**：`ContentBlock.fromJson` 是公开 API，调用方拿到 `block.toJson()` 后可改写其中的对象，即改写自己解析出来的 JSON 树，也会影响同一 `ContentBlock` 的后续 `toJson()`；若一个 `ContentBlock` 被放进两个 `CallToolResult` 并共享，修改会串味。设计文档只对 `tools/list` 的缓存条目约定「只读」，未覆盖 base 内容模型（`design.md:402`）。
- **建议**：在 `ContentBlock` 的类注释里写明「`fromJson` 不复制入参、`toJson` 返回内部引用，调用方 MUST NOT 修改」，或对 `toJson` 返回浅拷贝（成本可见、行为确定）。

### [轻微][存量] `ContentBlock.resource()` 与 `ResourceContent.toJson()` 重复实现同一份 resource 载荷

- **位置**：`f_mcp/src/base/McpContent.cj:71-90`（`ContentBlock.resource` 构造 `{uri, mimeType, text, blob}`）与 `f_mcp/src/base/McpContent.cj:219-235`（`ResourceContent.toJson` 构造同一组键）
- **来源**：存量
- **判据**：review-checklist §2（字面量/结构复制：同一组字段名与同一套「有则加」分支散落两处）
- **证据**：静态确定 —— 两处键名与 `match (opt) { case Some(v) => add(...) }` 分支逐行对应，仅外层是否包 `{type:"resource", resource: ...}` 不同。
- **描述**：MCP 侧 `resource` 载荷的字段集合（`uri`/`mimeType`/`text`/`blob`）在两处各维护一遍；将来加字段（如 `title`、`size`）或改编码（`blob` 的 base64 口径）必然漏一处，产生"嵌入式资源"与"`resources/read` 结果"两种形状不一致。另：`ContentBlock.resource` 在本仓内零调用（`grep ContentBlock.resource(` 无命中），是纯对外 API，缺陷只会在下游暴露。
- **建议**：`ContentBlock.resource(uri, mimeType, text!, blob!)` 内部改为 `ResourceContent(uri, mimeType, text, blob).toJson()` 后包一层 `{type:'resource', resource: ...}`，把字段集合收敛到 `ResourceContent` 一处（`ResourceContent` 在 `base` 同包，不引入依赖方向问题）。

### [轻微][存量] `tasks.md` 对 `ResultStoreOptions` 字段数自相矛盾（8 vs 9）

- **位置**：`f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/tasks.md:432`（T43.2「`ResultStoreOptions` 改为实际 **8** 个字段」）vs 同文件 `tasks.md:514`（V7「按实际 **9** 个字段重写」）
- **来源**：存量
- **判据**：review-checklist §13（`doc/spec/**` 内部不自洽、与实现不符）
- **证据**：静态确定 —— `f_mcp/src/server/McpResultStore.cj:27-31` 的 `ResultStoreOptions` 有 9 个字段（`maxEntries` / `maxBytes` / `ttlMillis` / `adaptive` / `windowMillis` / `rejectRateThreshold` / `floor` / `ceiling` / `shrinkConfirmWindows`）。
- **描述**：T43.2 是早期口径（当时 8 字段），V7 收口时按实现改成 9，但 T43.2 的旧数字残留在同一文件里，读者按任务清单核对文档会得出"设计文档写错"的错误结论。
- **建议**：把 `tasks.md:432` 的「8 个字段」改为「9 个字段」，或直接删掉数字改为「按 `McpResultStore.ResultStoreOptions` 实际字段重写」。

### [轻微][存量] 大结果阈值口径与规格不符：规格说「content 总字节」，实现按整条结果 JSON 字节

- **位置**：`f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp-guardrails/spec.md:150`（「`tools/call` 的 **content 总字节**超过 `maxResultBytes`」）vs `f_mcp/src/server/McpServer.cj:1097-1100`（`encoded.toString().size`，即包含 `isError` / `resultType` / `structuredContent` / `data` 的整条结果）
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现口径不一致）、§11（契约与实现不符）
- **证据**：静态确定 —— `applyLargeResult` 的判据是 `json.size <= limit`，`json` 为 `result.toJson()` 的完整序列化文本；`design.md:404-424` 的伪代码同样用整条 `json`，说明是实现先定、规格文字没跟上。
- **描述**：当结果接近 `maxResultBytes` 时，两类体积会得出不同结论：content 未超限但整条结果（含 `structuredContent` 与 `data`）超限时，实现仍会转 `resource_link` / 截断，而按规格文字不应触发。反之 4 字节级包装开销差异会造成边界不一致的对外行为说明。
- **建议**：把规格改为「结果 JSON 序列化后的总字节」，或实现改为只累计 `content` 块字节；两者选一，并同步 `README` 的 `maxResultBytes` 描述。

### [轻微][存量] `$ref` / `$defs` 构建期报错缺「位置」，未满足规格场景

- **位置**：`f_mcp/src/server/McpTool.cj:140-150`（`checkSchema(value, path)` 已算出 `path`，但异常消息为 `"inputSchema contains unsupported $ref (fail-closed)"`，不含 `path`）vs `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp/spec.md:85`（「`build()` 抛异常，消息含 `$ref` **与位置**」）
- **来源**：存量
- **判据**：review-checklist §13（规格场景与实现不符）、§14.1（半成品：位置信息算了不用）
- **证据**：静态确定 —— `path` 参数在递归中拼接（`'${path}/${key}'`）却在报错文案里未使用。
- **描述**：深嵌套 schema 里出现 `$ref` 时，使用者只得到"inputSchema 含不支持的 `$ref`"，得自己逐层找；`path` 已经算好，丢弃它纯属浪费。规格把「含位置」写成了验收条件，属可判定的偏差。
- **建议**：消息改为 `"inputSchema at ${path} contains unsupported $ref (fail-closed)"`，`$defs` 同理。

<!-- 第 4 部分 -->

### [一般][存量] 1. stdio 传输会把并发请求中「别人的响应」当 stale 丢弃，导致该请求空等到超时

- **位置**：`f_mcp/src/client/McpClient.cj:126`（`send` 持锁等待）、`:129`（`lines.remove(at: 0)`）、`:169-205`（`classify`）、`:187-188`（丢弃分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入 / 同步缺失）、§11（契约与实现不符）
- **证据**：静态确定 —— 两个并发访问者与同步手段都能指出来，见下
- **描述**：
  1. 访问者 A、B 分别是两个线程上的 `McpClient.callTool` → `JsonRpcClient.call`（`f_jsonrpc/src/client/JsonRpcClient.cj:82-95` 全程无锁）→ `StdioJsonRpcTransport.send`。
  2. 两者都已把请求写进 stdin（`:114-118`，受另一把 `writeMutex` 保护），A 先拿到 `mutex`（`:126`）并进入等待，B 阻塞在 `:126` 之外。
  3. MCP 服务端允许并发处理请求，回包乱序（先 B 的 id=2、后 A 的 id=1）。B 的响应行先被 `consumeStdout` 入队（`:212`）；A 取出后 `classify` 判 id 不等（`:184`）→ 打一条 `stale stdio response` 日志 → `Skip`（`:187-188`），**该行被永久丢弃**。
  4. A 取到自己的响应返回；B 进入临界区时 `lines` 已空，只能等到 `timeout`（`:139-141`，默认 30s，`McpClient.cj:31`）抛 `IOException('stdio response timeout')`。
- **后果**：并发调用 stdio transport 时出现随机的、与业务无关的 30s 超时；响应内容丢失。单线程顺序调用不触发。
- **建议**：`classify` 命中「id 不等但形态是响应」时不要丢，改为按 id 存入 `HashMap<String, String>` 待取表，`send` 先查表再等；或者干脆在 `send` 入口用一把串行锁把 stdio 请求排成单飞（stdio 本来就是单管道），并在类注释里写明「并发调用在客户端串行」。

### [一般][存量] 2. stdio 的 `lines` 只增不减：通知无人消费时无界增长，且 `remove(at: 0)` 是 O(n)

- **位置**：`f_mcp/src/client/McpClient.cj:96`（`lines` 声明）、`:129`（`remove(at: 0)`）、`:211-213`（`consumeStdout` 无条件入队）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（无界容器）、§6.4（`remove(at: 0)` 当队列头）
- **证据**：静态确定（增长路径与消费路径只有这一处，读代码即可定）
- **描述**：`lines` 的唯一消费者是 `send`（`:128-134`），而生产者在 `consumeStdout` 里对**每一行** stdout 无条件 `add`。服务端推送的 `notifications/*`（tools/list_changed、progress、日志）没有任何请求在途时照样入队；`classify` 的跳过逻辑只在 `send` 内部执行，所以「没有人在等响应」时队列只增不减。
  - 量化：单行通知约 100-300 B。10 条/s 的常驻通知 → 约 7 MB/小时；100 条/s → 约 70 MB/小时，直到 OOM。触发面是「长期只监听、很少发请求」的客户端（典型 MCP 订阅场景）。
  - 积压 n 行时每次 `send` 的消费成本是 O(n²)（`ArrayList.remove(at: 0)` 每次搬移剩余元素）。
- **建议**：`consumeStdout` 里对「无 `id`」的行直接丢弃（或交给通知回调），只把有 `id` 的行入表，并按 id 建 `HashMap` 而不是 FIFO；若必须保序，改用索引队列（不删除元素，只推进读指针）。

### [一般][存量] 3. `close()` 与在途 `send` 抢同一把 `mutex`：关闭最长被阻塞一个 `timeout`（默认 30s）

- **位置**：`f_mcp/src/client/McpClient.cj:148-155`（`close` 取锁 + `notifyAll`）、`:126-145`（`send` 持锁 `cond.wait`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（同步缺失 / 条件等待）、§11（资源释放不对称）
- **证据**：静态确定
- **描述**：`send` 在 `synchronized(mutex)` 内做 `cond.wait(timeout: timeout - elapsed)`，最长持有 30s。`close()` 第一件事就是 `synchronized(mutex)`（`:149`），因此无法执行 `cond.notifyAll()`（`:154`）去唤醒等待者，只能等 `send` 自己超时释放锁；`close()` 随后才 `terminate()`。结果是「取消一个卡住的 stdio 请求」在客户端侧不可行，关闭动作被在途请求拖住。
- **建议**：把「是否关闭」拆成独立的 `AtomicBool`/单独锁，`close()` 先置位并 `notifyAll()`，或先关 stdin / `terminate()` 让 `consumeStdout` 走到 EOF 分支（`:219-222`）由它 `notifyAll`，再取 `mutex` 收尾。

### [一般][存量] 4. `/mcp/sse` 的查询串按「字节当码点」解码，非 ASCII 的 `topics` / 参数静默变乱码

- **位置**：`f_mcp/src/server/McpController.cj:119-138`（`decodeComponent`，关键在 `:125-127`）、调用点 `:33` / `:44` / `:100-117`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约不符）、§2（重复实现，见同条「建议」）
- **证据**：静态确定；文档对照：`stdx` `URL.decodeComponent`（`cangjie_stdx/doc/libs_stdx/encoding/url/url_package_api/url_package_classes.md:988-1016`）与 `URL.queryForm`（同文件 `:685-716`，示例把 `name=张三` 正确解成 `张三`）
- **描述**：`decodeComponent` 把 `%XX` 直接还原成一个 `Rune(UInt32(hi*16+lo))`，等价于按 Latin-1 解码。标准客户端会把 `topics=%E8%B5%84%E6%BA%90`（「资源」的 UTF-8）发上来，这里得到 3 个乱码字符，`SubscriptionHub.matches` 永不命中 → 订阅建立成功但一条事件都收不到，且没有任何诊断。`+` → 空格、非法 `%` 原样保留的处理是对的，问题仅在多字节编码。
- **建议**：直接用 `http.request.url.queryForm`（`Form.get`）或 `URL.decodeComponent` 取代 `queryOf` + `decodeComponent`（顺带消掉这 38 行重复实现）；若要保留自有实现，必须先把 `%XX` 聚合成 `Array<Byte>` 再 `String.fromUtf8`。

### [一般][存量] 5. `/mcp/sse` 无任何调用方校验：可接管他人 `subscriptionId`、可无认证占满订阅池

- **位置**：`f_mcp/src/server/McpController.cj:30-52`（`sse()`，`:39` 的 `attach`、`:44` 的直连订阅）、配合 `f_mcp/src/server/McpServer.cj:194-208`（`attach` 只判 id 与 `!attached`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（越权）、§12.1（有界性）、§10 安全性
- **证据**：静态确定（整条 GET 路径无 caller 派生、无凭据校验）；利用面取决于部署（`McpController.handle` 派生 caller 的 `X-Forwarded-For` / `Authorization` 逻辑只用在 `/mcp`）
- **描述**：
  - 带 `subscriptionId` 时直接 `server.hub().attach(id)`：`attach` 只看 `id` 相等且 `!attached`，不校验调用方。订阅 id 是 `AtomicInt64` 从 1 递增（`McpServer.cj:122`、`:164`），可枚举，因此任何人可以「猜号」接管别人尚未连接的订阅并收到其通知。
  - 不带 `subscriptionId` 时按 `topics`（缺省 = 全部）建订阅，同样无认证；`maxSubscribers` 默认 1024（`McpServer.cj:127`），1024 个匿名 GET 即可把池占满，使正常 `subscriptions/listen` 收到 `-32003`。
  - 附带：`catch (e: McpException) → status(400)`（`:46-49`）把「订阅池满 / 限流」也映射成 400，语义上应是 503 / 429；`throw e` 之后框架是否仍保留 400 与 JSON 错误体，本部分无法确认（属 5 部分/框架行为）。
- **建议**：`subscriptions/listen` 建订阅时记录派生出的 caller，`attach(id)` 增加 `caller` 参数并比对不一致即 403；直连路径同样先做 caller 派生（复用 `/mcp` 的逻辑）；对 `OVERLOADED` 单独映射 503 + `Retry-After`。

### [一般][存量] 6. `@McpPromptArg[required: false]` 配非 `Option<T>` 参数时，「可选」在调用期必然失败

- **位置**：`f_mcp/src/server/McpRegistry.cj:177-190`（`:186` 用 `JsonNull.instance` 占位）、`f_mcp/src/macros/Mcp.cj:183`（生成 `McpConvert.argument<T>(__mcp_raw[$count])`）、`f_mcp/src/server/McpConvert.cj:38-43`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14（承诺与实现不符）、§11（契约不符）
- **证据**：静态确定（类型与调用链可逐行追；`String.tryFromData(DataNone) => None<String>` 见 `f_data/src/base/DataString.cj:51`，`Option<T> <: DataFields` 见 `f_data/src/base/OptionData.cj:18-31`）
- **描述**：注册期允许 `required: false`，缺参时塞 `JsonNull`；调用期 `McpConvert.argument<T>` 对 `JsonNull.toData() == DataNone` 走 `convert<T>`，普通类型（`String` / `Int64` / `@DataAssist` 类）都拿不到值 → 抛 `McpException(-32602, 'invalid argument: null')`。于是 `prompts/list` 里声明 `required: false` 的参数实际必填，客户端按声明省略就一定报参数错误。只有把参数类型写成 `Option<T>` 才能成立（README:133 是这样建议的），但注册期不校验这个约束，属于埋雷。
- **建议**：`registerPromptMeta` 在 `required == false` 且参数类型不是 `Option<...>` 时直接 `throw McpException(INTERNAL_ERROR, ...)`（构建期失败优于运行期静默失败）；或在 `argument` 层对 `DataNone` 明确返回 `None<T>`/默认值，并同步文档。

### [一般][存量] 7. `ConcurrencyGate` 的 `sweep` 与 `tryAcquire` 存在 check-then-act 竞态，清理窗口内可超额放行

- **位置**：`f_mcp/src/server/McpRateLimit.cj:396-413`（`tryAcquire` 取条目后 CAS 计数）、`:449-469`（`sweep` 删除 `count == 0 && 空闲` 的条目）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入 / 容器线程安全不等于复合操作原子）
- **证据**：静态确定（时序可逐步构造，见下）
- **描述**：`tryAcquire` 先 `counts.get(key)` 拿到 `GateEntry` 引用（`:395-399`），再做 `load` + `compareAndSwap`（`:405-413`）。在这两步之间，另一线程的 `sweep`（每 256 次操作触发一次，`:402-404`）可能因为 `count == 0 && idle` 把该 key 从 map 里删掉（`:451-453`）。此后 `tryAcquire` 的 CAS 打在**已脱离 map 的对象**上并成功返回 `true`，而 `counts` 里该 key 已不存在：新来的请求会新建一个 `count = 0` 的条目再放行一个，实际并发度可短暂超过 `limit`；`release(key)` 找不到 key（`:417-430`）也不会回补。类注释（`:371-376`）明确写了「删 key 会与并发的 tryAcquire 竞态，导致新条目从 0 开始计数」，但 `sweep` 仍然在删，只有「count 非 0 不删」这一层保护挡不住上面的窗口。
- **建议**：删除动作改成 CAS 式「只有仍然 count==0 且版本未变才删」（给 `GateEntry` 加版本号/用 `remove(key, entry)` 语义），或 `sweep` 只做标记、由下一次 `tryAcquire` 自己重建；`tryAcquire` 在 CAS 前用 `compute`/`getOrCreate` 原子拿到条目而不是先 `get` 再 CAS。`LimiterPool.acquire`（`:140-157`）同一模式，同样建议统一。

### [轻微][存量] 8. `classify` 只按 `id` 判响应：服务端发来的「请求」若 id 撞上就直接当响应

- **位置**：`f_mcp/src/client/McpClient.cj:182-188`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（协议语义）、与 README:33「未实现 sampling/roots」的能力声明比对
- **证据**：静态确定（判定条件只有 `id.toString() == expected.toString()`）
- **描述**：JSON-RPC 双向的两套 id 空间是独立的。服务端若发 `roots/list` / `sampling/createMessage`（`id` 从 1 开始也很常见），只要数值等于当前在途请求 id，就会被判为 `Response` 交回 `JsonRpcClient`；该对象没有 `result`/`error`，客户端抛 `malformed json-rpc response: missing result`（`f_jsonrpc/src/client/JsonRpcClient.cj:90-94`），而真正的响应被留在 `lines` 里当成 stale 丢掉。README:33 已声明 `sampling` / `roots` 未实现，所以这条当前是「未实现能力下的误判」，但误判路径本身是确定的。
- **建议**：`classify` 判响应时要求「有 `id` 且（有 `result` 或 `error`）且无 `method`」；对服务端请求显式回 `-32601`（而不是只打 DEBUG 日志后 `Skip`，`:189-199`）。

### [轻微][存量] 9. `ToolPage` / `ResourcePage` / `PromptPage`（及 `ReadResourceResult`）的 `fromJson` / `toJson` 是同一份代码只换了类型名

- **位置**：`f_mcp/src/base/McpModels.cj:291-317`、`:329-355`、`:367-393`、`:403-425`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（「只改类型名」形态）
- **证据**：静态确定（把四个函数体压成摘要：`obj[key]` → 过滤 `JsonObject` → 逐项 `X.fromJson` → `X(..., optionalStringOf(obj,'nextCursor'))`，逐行对齐）
- **描述**：三处 `fromJson` 只差「字段名（`tools` / `resources` / `prompts`）+ 元素类型 + `X.fromJson`」，三处 `toJson` 只差同样的字面量；`ReadResourceResult` 是同一形态的第四份（字段 `contents`，无 `nextCursor`）。差异点只有字段名与元素类型，没有语义差异（可空性、排序、错误处理都一致），属可合并的重复。
- **建议**：加一个包内私有辅助 `func pageOf<T>(obj: JsonObject, key: String, fromJson: (JsonObject) -> T): Array<T>`（`toJson` 同理），public 类型与签名保持不变；`ReadResourceResult` 复用同一个 helper。

### [轻微][存量] 10. `RateLimitBackends.of` 与 `fromConfig` 是同一段查表逻辑的两份实现

- **位置**：`f_mcp/src/server/McpRateLimit.cj:336-341`、`:344-353`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同一语义、仅错误文案不同）
- **证据**：静态确定
- **描述**：两者都是 `backends.get(normalize(name))` → `factory()`，唯一差异是错误消息里写 `mcp_rateLimitBackend` 还是裸名字。`fromConfig` 完全可以 `of(name)` 后再把异常包一层带配置键的提示，行为不变。
- **建议**：`fromConfig` 里 `try { of(name) } catch (e: IllegalArgumentException) { throw IllegalArgumentException("unknown ${McpConfig.RATE_LIMIT_BACKEND} '${name}'") }`，或把「查表 + 构造」抽成 `private static func create(name: String, errorLabel: String): RateLimitBackend`。

### [轻微][存量] 11. 三个 `get*Meta` 是同一份反射逻辑，且「查不到」时静默跳过注册

- **位置**：`f_mcp/src/server/McpRegistry.cj:47-54`、`:57-64`、`:67-74`；静默跳过的消费点 `f_mcp/src/macros/Mcp.cj:203-209`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名）、§11（静默失效）
- **证据**：静态确定（`catch (_: InfoNotFoundException) { return None }` → 宏里 `if (meta.isSome())` 才注册，否则既无日志也无构建错误）
- **描述**：三份函数体除注解类型外完全相同。更值得注意的是失败路径：`TypeInfo.of<T>().getInstanceFunction(name, args)` 一旦因为参数类型 `TypeInfo` 与声明不完全一致（例如参数类型是别名、或跨模块的 `@DataAssist` 类型）抛 `InfoNotFoundException`，工具/资源/提示词会**无声消失**，`tools/list` 里看不到、启动也不报错，只能靠人肉比对注册代码。
- **建议**：抽成 `private func annotationOf<T, A>(name: String, args: Array<TypeInfo>): ?A`（若反射 API 的泛型约束允许），并在 `None` 分支至少记一条 WARN 并带上 `name` 与 `args` 的类型名；`@Mcp` 展开侧对「有注解但拿不到元数据」直接 `diagReport(ERROR)`。

### [轻微][存量] 12. `rpcCall` 的 `McpException` 与 `JsonRpcException` 两个 catch 分支逐行同构

- **位置**：`f_mcp/src/client/McpClient.cj:416-427`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复）
- **证据**：静态确定（两分支的 `if (code == UNSUPPORTED_VERSION && tried.isNone()) { negotiate; retry }` 完全一致）
- **描述**：`McpException <: JsonRpcException`（`base/McpException.cj:22`），所以后一个 `catch` 已经覆盖前者；两个分支的唯一差异是「`McpException` 原样抛出 vs 包装成 `McpException`」。这是可合并的近似重复，且当前写法容易在改一处时漏改另一处（例如以后要按 code 分类处理）。
- **建议**：只留 `catch (e: JsonRpcException)`，内部 `if (e is McpException) { throw e }`，否则 `throw McpException(e.code, e.message, data: e.data)`。

### [轻微][存量] 13. `listAllTools` 的两个硬上限与错误文案对不上，且不可配置

- **位置**：`f_mcp/src/client/McpClient.cj:300-319`（`:304` 的 `rounds < 100 && all.size < 1000`、`:315-317` 的报错）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与文案不符）、§10（可配置性）
- **证据**：静态确定
- **描述**：实际触发抛错的条件有两个：`rounds` 到 100 **或** 累计 1000 条仍有 `nextCursor`；但消息固定写 `exceeded 100 pages`。服务端每页 50 条时会在第 20 页就因为 1000 条上限报「100 页」，排查时会被误导。两个上限也无法从 `McpClientOptions` 调整。
- **建议**：把两处上限放进 `McpClientOptions`（`maxListPages` / `maxListItems`），错误消息按实际触发的那条拼（`exceeded ${limit} pages` / `exceeded ${limit} items`）。

### [轻微][存量] 14. 后端同名注册静默覆盖，与项目基线「同名注册启动直接失败」相反

- **位置**：`f_mcp/src/server/McpRateLimit.cj:331-333`（`backends.add(normalize(T.name), T.new)`）
- **来源**：存量（快照模式无基线）
- **判据**：`references/fountain-baseline.md` §4（同名注册：启动直接失败，不做隐式优先级）；review-checklist §11（契约）
- **证据**：静态确定（`ConcurrentHashMap.add` 覆盖同键，代码注释也写明「同名重复注册会覆盖」）
- **描述**：两个模块各自 `register<MyBackend>()` 且 `name` 相同（或与内置 `token-bucket` 撞名）时，后注册者静默生效，配置里写同一个名字会随加载顺序改变行为。基线的约定是启动期直接失败。
- **建议**：`if (backends.contains(normalized)) { throw IllegalArgumentException(...) }`；确有「覆盖内置」需求时单开 `replace<T>()` 并在 README 写明。

### [轻微][存量] 15. 关闭 / 吞异常路径不对称：`consumeStderr` 无 try、`close` 吞掉全部异常、`UnlimitedRateLimitBackend.close` 空实现无说明

- **位置**：`f_mcp/src/client/McpClient.cj:156-166`（两处 `catch (_: Exception) {}` 与 `let _ = process.wait(...)`）、`:225-230`（`consumeStderr` 无异常保护）、`:216-217`（`consumeStdout` 吞异常）；`f_mcp/src/server/McpRateLimit.cj:310`（`close() {}`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默吞异常 / 无注释的空 no-op）、§11（资源释放不对称）
- **证据**：静态确定
- **描述**：（1）`close()` 把 `stdInPipe.close()` 与 `terminate()` 的异常全部吞掉，且 `process.wait(timeout: 2s)` 的返回值被丢弃——子进程 2s 内没退出时既不重试也不记录，等于留下一个可能仍存活的子进程。（2）`consumeStdout` 有 `try/catch`，孪生的 `consumeStderr` 没有，管道异常会以未捕获异常的形式打死该 `spawn` 线程（不会崩进程，但日志是栈而不是一行 WARN），两处行为不一致。（3）`UnlimitedRateLimitBackend.close()` 是空 no-op，属可接受的 Null Object，但没有一句注释说明「无需释放」，按 §3 需要注释。
- **建议**：`close()` 里对 `wait` 结果判 `false` 时记 WARN 并再 `kill()`；两个 `consume*` 统一 `try/catch` + WARN；给空 `close()` 补 `// 无内部资源`。

### [轻微][存量] 16. `McpController` 构造期缓存 `McpRegistry.server()`，`configure` 的「立即生效」对 HTTP 路径不成立

- **位置**：`f_mcp/src/server/McpController.cj:28`（`private let server = McpRegistry.server()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§14（接线缺失）
- **证据**：待确认 —— 需确认 `@Controller`（= `@Bean`，默认 `BeanScope.singleton`，`f_bean/src/BeanMeta.cj:26`）实例的创建时机；`McpRegistry.configure` 的契约是「已经 `build()` 过时立即重建，新注册马上生效」（`McpRegistry.cj:30-34`、README:547-549）
- **描述**：控制器把 `McpServer` 在字段初始化时取一次并永久持有；`McpRegistry.configure` 之后 `built` 被换成新实例，但 HTTP 路由仍打到旧实例上，新注册的 tool / resource / prompt 对 `/mcp` 不可见（对直接 `McpRegistry.server()` 的调用方可见）。文档虽写着「只应在启动阶段调用」，同一段又承诺「立即重建、马上生效」，两者对使用者是矛盾的。若在控制器创建之后再 `build()`，还会把结果缓存与订阅状态按文档所说丢掉，却没有任何提示。
- **建议**：`McpController` 改成每次请求 `McpRegistry.server()`（或持有 `() -> McpServer` 的取值函数）；若坚持缓存，就在 `configure`/`build` 时把「已存在控制器持有的旧实例」显式作废（例如 `built` 加版本号，控制器比对版本后重取），并把文档统一成「仅启动期有效」。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分仅两份 README，不含可测量的性能/内存改动，故无堆内存 / CPU 方案（0 / 0）。

- 说明：文档层面的「减少重复段落」属于可维护性建议而非性能优化，且限流顺序在 `README.md:238`、`README.md:661` 两处同义表述当前一致，暂不构成缺陷。

<!-- 第 2 部分 -->

本部分为 7 个文档，无源码路径、无输入规模与测量手段，不产出堆内存 / CPU 优化方案（性能结论必须有改前基线 + 改后对照，见 reviewer.md 铁律）。文档类改进已按缺陷计入「发现」，不重复统计。

<!-- 第 3 部分 -->

### [堆内存] `CallToolResult.toJson()` 合成 text 块时的整串副本

- **现状**：`toJson()` 在「有 `structuredContent`、无 text 块」时执行 `ContentBlock.text(structured.toString())`（`McpContent.cj:179`），该字符串与 `structuredContent` 字段同时存活到整条结果序列化完成，峰值约为结构化内容的两份文本 + 一份转义副本；每条结果一次性、不跨调用复用。
- **方案**：把合成推迟到真正写响应处（`McpServer` 出口），或直接不合成、由客户端按 `structuredContent` 渲染；`toJson()` 只做字段映射。
- **预期**：该路径峰值从「≈2× 结构化文本」降到「≈1×」；具体字节数取决于工具返回体大小，未测。
- **代价**：行为变更（响应 `content` 可能为空数组），需与客户端兼容性一起评估；实现复杂度低。
- **验证**：构造 1 MiB `structuredContent` 且无 text 块的工具，`tools/call` 前后取 `getAllocatedHeapSize()` 与 RSS，对比改前改后；同时断言响应语义不变（`structuredContent` 仍在）。需 `-O2`、同一输入、多轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

> 不是缺陷。两条都**没有改前/改后对照数据**，只作为下一轮补数据的候选。

### [堆内存] `withMeta` 每请求复制一次 `params` 并新建两个 `JsonObject`

- **现状**：`McpClient.withMeta`（`f_mcp/src/client/McpClient.cj:439-456`）对每次调用新建 3 个 `JsonObject`（`obj` / `meta` / `info`），并把 `params` 的全部字段逐个 `add` 复制一遍；`clientInfo` 的 `name` / `version` 与 `capabilities` 是不变的。
- **方案**：把 `info` 与 `meta` 的固定部分在 `McpClient` 构造期建成模板（`capabilities` 按引用共享，序列化时只读），每请求只 `obj.add(META, metaTemplate)`；`params` 若调用方保证不复用，可直接在入参对象上补 `_meta`（需文档说明会修改入参）。
- **预期**：每请求少 2 个短生命周期对象 + 一次字段拷贝；大 `params`（如 `arguments` 里带大对象）时省掉一次浅拷贝的哈希表扩容。
- **代价**：模板共享要求 `capabilities` 不被调用方并发修改（当前 `McpClientOptions.capabilities` 是公开可变 `var`，模板共享会把这层风险放大）；直接改入参会改变 API 语义。
- **验证**：`cjpm bench -O2`，同一 8 线程、10k 次 `callTool`（参数含 100 字段对象），对照 `getAllocatedHeapSize()` 与单次耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `LimiterPool.sweep` / `ConcurrencyGate.sweep` 超容量时用「全表扫描找最旧」淘汰，最坏 O(n²)

- **现状**：`f_mcp/src/server/McpRateLimit.cj:186-204` 与 `:455-468` 在 `size > maxSize` 时每淘汰一个 key 就整表扫一遍找最小 `lastUsed`；`maxSize` 默认 10_000，`sweep` 每 256 次 `acquire` 触发一次（`:153-155`、`:402-404`）。
- **方案**：改成采样淘汰（随机/固定取 16 个候选取最旧，Redis 风格），或维护一个按 `lastUsed` 排序的近似 LRU 索引；只要保证「最终有界」，不要求精确最旧。
- **预期**：超容量窗口内从 O(n²) 降到 O(n·k)（k = 采样数）；稳态下 `sweep` 由全表 O(n) 降到只清 TTL 条目。
- **代价**：淘汰不再严格 LRU，可能提前淘汰刚用过的 key（对限流只是配额重置，可接受）；需要并发压力测试断言 `size <= maxSize`。
- **验证**：`cjprof record` 跑「10 万不同 caller、`perCallerRpm=60`」的压测，对照 `sweep` 自耗时占比与 P99 延迟；同时断言最终 `gate.size()`/`pool.size` 不超上限。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

本部分无性能类结论，故无待验证假设；`f_mcp` 的性能/内存条目统一由包含 `src/**` 的第 3-5 部分提出。

<!-- 第 2 部分 -->

本部分无源文件，不产生可测量的性能假设。文档中与性能相关的断言（如"10 万桶后被淘汰""每 5 分钟一条日志成本可忽略"）属设计意图，需在 part1/part3 的源码审查中用 `cjprof record` / 压测复核，不在本部分登记。

<!-- 第 3 部分 -->

> 无性能测试数据支撑，只用于下一轮补数据；不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「只有 `structuredContent`」的工具结果，序列化与内存开销约为普通结果的两倍，可能是大结果路径的实际瓶颈之一 | `f_mcp/src/base/McpContent.cj:177-181`、`f_mcp/src/server/McpServer.cj:1097-1100` | 该形态的调用占比、单次自耗时占比、峰值分配 | 用 1 MiB `structuredContent` 构造工具，`cjprof record` 跑 1000 次 `tools/call`（`-O2`），对比"带 text 块"与"仅 structuredContent"两组 |
| 2 | `resources/read` 对二进制资源每次重新 base64 编码，可能在高频读取下成为 CPU 热点 | `f_mcp/src/base/McpContent.cj:230-232`（`ResourceContent.toJson` 每次 `toBase64String`），调用点 `f_mcp/src/server/McpServer.cj:678-680` | 单次编码耗时、读取频次、blob 大小分布 | `cjprof record` + 分段计时，读取 1 MiB / 8 MiB blob 各 1000 次，`-O2` |
| 3 | `ContentBlock.image/audio`（`toBase64String` 全量展开）在大附件下把峰值抬到 1.33× 以上 | `f_mcp/src/base/McpContent.cj:63-69` | 附件大小分布、峰值内存 | 构造 8 MiB / 32 MiB 图片内容，测 `getAllocatedHeapSize()` 峰值与 RSS |

<!-- 第 4 部分 -->

> 无性能测试数据支撑，只用于下一轮补数据；不计入模块统计，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sweep` 的全表扫描在「大量不同 caller」场景下成为限流路径热点 | `f_mcp/src/server/McpRateLimit.cj:178-205`、`:449-469` | 自耗时占比、`sweep` 调用频次、`limiters`/`counts` 平均 size | `cjprof record` 跑 10 万 caller / 30 分钟、`maxSize=10000`，看 `sweep` self time 与 size 分布 |
| 2 | stdio `send` 的「持锁串行」把并发吞吐压成 1，客户端并发调用收益为零 | `f_mcp/src/client/McpClient.cj:126-145` | 单请求 RTT、并发 1/2/4/8 下的 QPS 与 P99 | 本地起假 stdio 服务端（`McpStdio_test.cj` 的脚本可直接复用），`cjpm bench -O2` 跑 4 组并发度 |
| 3 | `McpModels` 的 `fromJson` 在 `tools/list` 大页（500 条）下分配量偏高（每条 1 个描述对象 + 1 个 `ArrayList` 拷贝） | `f_mcp/src/base/McpModels.cj:291-317` | 单次解析分配量与耗时、页大小分布 | 分段计时 + `getAllocatedHeapSize()`，100/500/2000 条三档、每档 1000 轮取中位数 |

## 文件覆盖

> 与 `files/f_mcp.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mcp/README.md` | .md | ✅ | — |
| 2 | `f_mcp/README_en.md` | .md | ✅ | — |
| 3 | `f_mcp/doc/f_mcp模块设计.md` | .md | ✅ | — |
| 4 | `f_mcp/doc/spec/add-f-mcp/design.md` | .md | ✅ | — |
| 5 | `f_mcp/doc/spec/add-f-mcp/proposal.md` | .md | ✅ | — |
| 6 | `f_mcp/doc/spec/add-f-mcp/specs/mcp-guardrails/spec.md` | .md | ✅ | — |
| 7 | `f_mcp/doc/spec/add-f-mcp/specs/mcp/spec.md` | .md | ✅ | — |
| 8 | `f_mcp/doc/spec/add-f-mcp/tasks.md` | .md | ✅ | — |
| 9 | `f_mcp/doc/spec/add-f-mcp/verify-report.md` | .md | ✅ | — |
| 10 | `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/design.md` | .md | ✅ | — |
| 11 | `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/proposal.md` | .md | ✅ | — |
| 12 | `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp-guardrails/spec.md` | .md | ✅ | — |
| 13 | `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp/spec.md` | .md | ✅ | — |
| 14 | `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/tasks.md` | .md | ✅ | — |
| 15 | `f_mcp/doc/spec/optimize-mcp-truncate-utf8/design.md` | .md | ✅ | — |
| 16 | `f_mcp/doc/spec/optimize-mcp-truncate-utf8/proposal.md` | .md | ✅ | — |
| 17 | `f_mcp/doc/spec/optimize-mcp-truncate-utf8/specs/mcp-truncate-utf8/spec.md` | .md | ✅ | — |
| 18 | `f_mcp/doc/spec/optimize-mcp-truncate-utf8/tasks.md` | .md | ✅ | — |
| 19 | `f_mcp/doc/spec/rework-jsonrpc-macro-and-demos/specs/mcp/spec.md` | .md | ✅ | — |
| 20 | `f_mcp/doc/spec/rework-jsonrpc-macro-and-demos/verify-report.md` | .md | ✅ | — |
| 21 | `f_mcp/src/Mcp.cj` | .cj | ✅ | — |
| 22 | `f_mcp/src/base/McpContent.cj` | .cj | ✅ | — |
| 23 | `f_mcp/src/base/McpException.cj` | .cj | ✅ | — |
| 24 | `f_mcp/src/base/McpModels.cj` | .cj | ✅ | — |
| 25 | `f_mcp/src/base/McpModels_test.cj` | .cj | ✅ | — |
| 26 | `f_mcp/src/base/McpProtocol.cj` | .cj | ✅ | — |
| 27 | `f_mcp/src/client/McpClient.cj` | .cj | ✅ | — |
| 28 | `f_mcp/src/client/McpClient_test.cj` | .cj | ✅ | — |
| 29 | `f_mcp/src/client/McpStdio_test.cj` | .cj | ✅ | — |
| 30 | `f_mcp/src/exports.cj` | .cj | ✅ | — |
| 31 | `f_mcp/src/macros/Mcp.cj` | .cj | ✅ | — |
| 32 | `f_mcp/src/macros/imports.cj` | .cj | ✅ | — |
| 33 | `f_mcp/src/server/McpAnnotations.cj` | .cj | ✅ | — |
| 34 | `f_mcp/src/server/McpConfig.cj` | .cj | ✅ | — |
| 35 | `f_mcp/src/server/McpConfig_test.cj` | .cj | ✅ | — |
| 36 | `f_mcp/src/server/McpController.cj` | .cj | ✅ | — |
| 37 | `f_mcp/src/server/McpConvert.cj` | .cj | ✅ | — |
| 38 | `f_mcp/src/server/McpHttp_test.cj` | .cj | ✅ | — |
| 39 | `f_mcp/src/server/McpMacro_test.cj` | .cj | ✅ | — |
| 40 | `f_mcp/src/server/McpPrompt.cj` | .cj | ✅ | — |
| 41 | `f_mcp/src/server/McpRateLimit.cj` | .cj | ✅ | — |
| 42 | `f_mcp/src/server/McpRateLimit_test.cj` | .cj | ✅ | — |
| 43 | `f_mcp/src/server/McpRegistry.cj` | .cj | ✅ | — |
| 44 | `f_mcp/src/server/McpRegistry_test.cj` | .cj | ✅ | — |
| 45 | `f_mcp/src/server/McpResource.cj` | .cj | ✅ | — |
| 46 | `f_mcp/src/server/McpResultStore.cj` | .cj | ✅ | — |
| 47 | `f_mcp/src/server/McpResultStore_test.cj` | .cj | ✅ | — |
| 48 | `f_mcp/src/server/McpServer.cj` | .cj | ✅ | — |
| 49 | `f_mcp/src/server/McpServer_test.cj` | .cj | ✅ | — |
| 50 | `f_mcp/src/server/McpSse.cj` | .cj | ✅ | — |
| 51 | `f_mcp/src/server/McpSse_test.cj` | .cj | ✅ | — |
| 52 | `f_mcp/src/server/McpTool.cj` | .cj | ✅ | — |
| 53 | `f_mcp/src/server/TruncateUtf8_test.cj` | .cj | ✅ | — |

合计：`.cj` 33 个 / `.md` 20 个 / 共 53 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无 `.cj`；作为取证读到的代码只用于核对文档承诺，其缺陷按第 3-5 部分统计，范围外问题已在「范围外提示」列出 |
| §1 死代码 | 0 | 无代码符号可判；README 中出现的每个类型 / 方法名已回查到定义（唯一例外 `McpConfig` 是「文档缺失」而非死代码，见 #7） |
| §2 重复逻辑 | 0 | 中英双份是刻意翻译而非重复实现；两版的差异已作为 #1 / #2 单独报出，未按出现次数刷数量 |
| §3 空实现 | 0 | 文档承诺的每个能力都能在 `src/**` 找到实现（含 `resources/subscribe`、`sampling`、`roots`、`logging`、`completions` 被明确声明为未实现），未发现「承诺了但为空」 |
| §4 栈溢出 | 0 | 本部分无递归代码；`McpToolBuilder.checkSchema` 的递归深度由 schema 结构决定，属 `.cj` 范围 |
| §5 OOM | 0 | 本部分无容器与分配；结果存储 / 订阅队列有界性在 `.cj` 部分评估 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，本部分无任何热点结论，也未写入待验证假设 |
| §6.2 大粒度锁 | 0 | 文档未描述锁；`SubscriptionHub` / `ToolResultStore` 的临界区属 `.cj` 部分 |
| §6.3 并发串行 | 0 | 同上 |
| §6.4 低效算法 | 0 | 同上 |
| §7 降堆内存方案 | 0 | 文档不持有内存；无基线数据，不提出方案 |
| §8 降 CPU 方案 | 0 | 同 §6.1 |
| §9 local mode 可行性 | 0 | 无函数内临时大对象的证据，且本部分不含代码 |
| §11 现有代码的 BUG（存量） | 0 | 本部分未审 `.cj` 缺陷；取证中读到的 3 处实现问题按「范围外提示」单列，不占用统计 |
| §12 并发安全与锁粒度 | 0 | 本部分无共享状态；文档声称的「限流/闸门为进程内」「SSE 空闲零轮询」与实现一致（`McpRateLimit.cj:377-470`、`McpSse.cj:86-116`） |
| §13 文档一致性 | 5 | #1 后端数量、#2 `-1` 语义、#4 工具名字符集、#5 `content` 类型、#6「相对路径」术语——均给出双位置（文档行 + 代码行） |
| §14 功能完备性与 README 覆盖 | 3 | #3 多 `@Mcp` 的 `serverInfo` 覆盖未提示、#7 公开 API 清单不全、#8 协议版本头未文档化；其余顶层 public 声明已逐个在 README 检索到（除 #7 点名的三类） |
| 文件覆盖（§13 等） | 2/2 | — |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 安全性 1（#6 调用方识别）；契约正确性 2（#9 scope 枚举、#1 能力集）。本部分无代码，"语言特性 / 可读性"不适用 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可搜；文档中"承诺但无实现"的 API（`purgeExpiredResults`）按 §14 计入 #2，不重复计死代码 |
| §2 重复逻辑 | 0 | 已比对 7 个文档间的 5 组重复事实（能力声明、错误码、限流后端数量、配置项数量、`maxResultBytes` 归属），漂移归入 §13 的 #1/#4/#5/#7/#9；文档重复叙述本身不算代码重复 |
| §3 空实现 | 0 | 无代码；spec 中无"占位未实现"的 Requirement（prompts / SSE / stdio 均有实现） |
| §4 栈溢出 | 0 | 无递归代码 |
| §5 OOM | 0 | 无容器 / 分配代码；文档中的容量参数（256 条 / 256 MB / 1024 订阅者）与实现一致 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，本部分也不含可测代码 |
| §6.2 大粒度锁 | 0 | 无锁代码；文档 7.2.4 的"锁内无 I/O"属设计描述，已随 `HeapCache` 方案过期（#7） |
| §6.3 并发串行 | 0 | 无并发代码 |
| §6.4 低效算法 | 0 | 无算法代码 |
| §7 降堆内存方案 | 0 | 无源码，未产出方案 |
| §8 降 CPU 方案 | 0 | 无源码，未产出方案 |
| §9 local mode 可行性 | 0 | 无函数级临时对象；文档未承诺 local mode |
| §11 现有代码的 BUG（存量） | 0 | 本部分不含代码；比对中发现的实现差异均按 §13 文档一致性记，源码问题属 part1/3/4/5 |
| §12 并发安全与锁粒度 | 0 | 无共享状态代码；#6 只报"文档与实现的识别策略不一致"，其并发后果需实测 |
| §14 功能完备性与 README 覆盖 | 1 | `purgeExpiredResults()` 文档承诺、代码无此 API（并入 #2）；README 不在本部分文件清单内，未评 |
| 文件覆盖（§13 等） | 7/7 | 无缺文件 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：#1、#3；语言特性/设计：#4（引用语义与别名）；安全性：本部分无外部输入解析之外的注入面，`McpException` 只透传 code/message/data，未见凭据进日志 |
| §1 死代码 | 0 | 逐个核对：`ContentBlock` 私有构造与 `binary` 均被同文件工厂调用；`type_`/`payload` 有读取；`Mcp.cj` 三条 `public import` 都是重导出；`McpException` 仓内 55 处构造。`ContentBlock.image/audio/resource` 仓内零引用（`CallToolResult.error` 有测试与 `f_llm/src/mcp/McpToolSource_test.cj:39` 使用），且均为对外可达的 `public`，按硬原则一不判死代码（仅作信息） |
| §2 重复逻辑 | 1 | 见 #5（resource 载荷两处实现）。已两两比对 `McpContent.cj` 全部 21 个函数/构造体：`CallToolResult.text` / `error` 仅差 `isError` 一个参数，属可读性展开，不报；`match(opt){Some=>add}` 的 3 行惯用法重复 8 次，抽 helper 收益低于可读性损失，不报 |
| §3 空实现 | 1 | #1 的 `case _ => ()` / 解码失败落 `None` 属"静默吞掉"（计入 #1，不重复计数）；本部分无空函数体、无 TODO/FIXME、无 `throw UnsupportedException` 占位 |
| §4 栈溢出 | 0 | 本部分无递归；`truncateUtf8` 为单层迭代扫描（`McpServer.cj:1153`），`checkSchema` 的递归不在本部分文件内 |
| §5 OOM | 0 | 本部分无无界容器与按不可信长度预分配：`ContentBlock.image/audio` 的 base64 展开与输入同阶（1.33×），`CallToolResult` 只在服务端 `maxResultBytes` 约束下使用；量化收益缺数据，已列待验证假设 #3 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 profile / bench 数据，热点不成立；三个疑点写入待验证假设 #1-#3（含工具、输入规模、采法） |
| §6.2 大粒度锁 | 0 | 本部分文件内无锁、无 synchronized、无共享可变状态 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 任务队列 |
| §6.4 低效算法 | 0 | 遍历均为单遍线性；`ContentBlock.resource` / `ResourceContent.toJson` 无嵌套循环或热点 `contains`；重复序列化问题归 #3 与待验证假设 #1（属实现选择而非复杂度） |
| §7 降堆内存方案 | 1 | 见「优化可行性方案」（`toJson` 合成 text 块的整串副本），证据状态 `无基线（待验证）` |
| §8 降 CPU 方案 | 0 | 本部分无已证实的 CPU 热点；`toJson` 重复序列化归 #3（契约/行为）与假设 #1（性能待测），不单列 CPU 方案 |
| §9 local mode 可行性 | 0 | 候选 `truncateUtf8` 的输出 `String` 逃逸到 `CallToolResult` 并经 public 边界返回（`McpServer.cj:1126-1133`），逃逸检查不通过；`docs/LocalMode.md:436/1061` 同样把它列为次选 |
| §11 现有代码的 BUG（存量） | 8 | 本部分 8 条发现全部为存量（快照模式无基线）：已核对 3 个 `.cj` 的边界/空值/错误处理路径，`McpContent` 5 条、文档 3 条 |
| §12 并发安全与锁粒度 | 0 | 本部分代码无线程共享路径：`ContentBlock` / `CallToolResult` / `ResourceContent` 均为每次调用新建的值对象；唯一共享风险是 #4 的"入参对象被多处持有"，已按引用语义报告，不构成数据竞争（无跨线程共享证据） |
| §14 功能完备性与 README 覆盖 | 1 | #2（任务标记与接线不符）。README 覆盖属其他部分文件，本部分不重复判；`truncateUtf8` 无 public API 变化，与 `optimize-mcp-truncate-utf8` 契约一致 |
| 文件覆盖（§13 等） | 14/14 | 与 `files/f_mcp.part3.txt` 逐行一致，无缺读 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1（并发丢响应）、#3（关闭阻塞）、#4（解码错）、#8（协议误判）；安全性：#5（`/sse` 无鉴权）。语言特性：`synchronized` 尾随 lambda 里的 `return` 只返回 lambda 值，`send`（`McpClient.cj:126-145`）与 `close`（`:149-155`）的写法都靠「lambda 值即函数值」成立，已核实（`cangjie_docs/docs/dev-guide/source_zh_cn/function/lambda.md:92`），非缺陷；`Option<T> <: DataFields` 已按 `f_data/src/base/OptionData.cj:18` 核实 |
| §1 死代码 | 0 | 机械过了一遍：`private`/`internal` 符号逐名全仓搜过（`stringOf` 等 6 个 JSON 辅助、`parseSubscriptionId`、`parseTopics`、`queryOf`、`decodeComponent`、`hexValue`、`LimiterPool`/`LimiterEntry`/`GateEntry`/`ResolvedRateLimit`/`RateVerdict`/`ConcurrencyLease`、`serverNameOf`/`expand`/`asFunc`/`shortName`/`annotationKinds`/`declaredName`/`generateFunction`）均有调用者；`ConcurrencyGate.tryAcquire:414` 的尾 `false` 在 `while (true)` 之后不可达，但是仓颉返回检查所需（不是兼容残留），不算兼容残留；`LimiterPool.size`/`sweepNow`、`ConcurrencyGate.size`/`sweepNow` 只被测试引用——`LimiterPool` 是 `internal` 类，按硬原则二本应判死代码，但仓内确有测试使用（§1「仅测试使用」只算可见性建议），故记为可见性建议不计数；`McpClient.versionRewrites`、`McpPrompt.listJson` 均有生产代码读取 |
| §2 重复逻辑 | 4 | #9（三类 Page + `ReadResourceResult`）、#10（`of`/`fromConfig`）、#11（三个 `get*Meta`）、#12（`rpcCall` 两个 catch）。另外已比对并排除：`McpConvert` 的 4 组重载（语义分支不同，非重复）、`LimiterPool`/`ConcurrencyGate` 的「TTL + 容量淘汰」（结构相似但 `close()` 语义与并发不变量不同，硬合并会破坏 `count` 不变量，只把「超限全表扫描」写进优化方案）、`McpModels` 的 `toJson` 与 `fromJson` 镜像（读写不同向）；`queryOf`/`decodeComponent` 对标 `stdx.URL` 的重复并入 #4 一并给建议，不重复计数 |
| §3 空实现 | 1 | #15（`close()` 吞异常、`UnlimitedRateLimitBackend.close()` 空 no-op 无注释）。测试替身（`FakeMcpRpc.close`、`AlwaysUnsupportedRpc.close`、`McpAnyPathDistributor.register`、`ObservableLimiter.exec`）属接口实现，不计；本部分无 `TODO`/`FIXME`/`UnsupportedException` 占位 |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构：`decodeComponent`/`hexValue`/`queryOf`/`isToolName`/`fromJson` 全是单层循环或线性扫描；宏展开侧 `asFunc`/`annotationKinds`/`declaredName` 的递归只沿 `MacroExpandDecl.macroInputDecl` 下降，深度由注解嵌套层数（作者可控、常量级）决定 |
| §5 OOM | 1 | #2（`lines` 无界 + O(n) 头删）。其余容器均有界：`LimiterPool`/`ConcurrencyGate` `maxSize` 默认 10_000、TTL 10 min；`ToolPage` 等按服务端页大小（`pageSize`）物化，上限在服务端 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 `cjprof` / `cjpm bench` 数据，热点不成立；三个疑点写入「待验证假设」#1-#3（均给了工具、输入规模、采法） |
| §6.2 大粒度锁 | 0 | `McpRegistry` 的 `Mutex` 只保护启动期注册与 `built` 快照，临界区内 `builder.build()` 不在请求主路径（`configure` 文档限定启动阶段）；stdio `send` 的临界区含 `cond.wait` 但那是协议要求的单管道读，不是「锁里做 I/O」——I/O 已移到 `writeMutex` 与独立读线程 |
| §6.3 并发串行 | 0 | 本部分只有 `spawn` 两个读线程（`McpClient.cj:104-109`），无「spawn 后立刻 get」；stdio 请求串行是单管道语义（已作为 #1 的替代修法提及） |
| §6.4 低效算法 | 1 | #2 的 `remove(at: 0)`。`sweep` 的超限全表扫描只在优化方案与假设 #1 里，不重复计入发现（无测量数据） |
| §7 降堆内存方案 | 1 | 「优化可行性方案」的 `withMeta` 模板化，证据状态 `无基线（待验证，不进 tasks）` |
| §8 降 CPU 方案 | 1 | 「优化可行性方案」的采样淘汰，证据状态 `无基线（待验证，不进 tasks）` |
| §9 local mode 可行性 | 0 | 候选只有 `decodeComponent`/`withMeta` 的短命对象，但前者在请求路径上量级极小（查询串 < 100 B），后者返回的 `JsonObject` 会逃逸到 `JsonRpcClient.requestBody` 并序列化成字节（跨函数返回，逃逸检查不通过）；无峰值内存对照数据，不成立 |
| §11 现有代码的 BUG（存量） | 16 | 本部分 16 条发现全部为存量（快照模式无基线）。已核对的边界/空值/错误处理：`decodeCursor`（空串/非法/超上限）、`parseSubscriptionId`（负数/非数）、`parseTopics`（空串/全空段）、`rateLimit`（空段/负数/小数/超限/未知键）、`publicBaseUrl`（全空/三斜杠）、`listAllTools`（页上限/空页/重复游标）、`callToolAuto`（`maxRounds=0` 立即抛错，按 `maxRounds>0` 的判定属预期）、`getOrThrow` 竞态（`LimiterPool:151` 有窗口但需 `sweep` 恰好淘汰刚插入项，概率极低，并入 #7 的同一类不再单列） |
| §12 并发安全与锁粒度 | 3 | #1（stdio 响应被别的线程消费）、#3（`close` 与 `send` 抢锁）、#7（gate 清理竞态）。共享路径已列清：`McpClient` 的 `versionMutex`/`protocolVersion`/`versionRewrites` 均在锁内写、`options` 只读（`McpClientOptions` 可外部改写属使用约束，已在「优化可行性方案 · 堆内存」的代价里点出，不单列）；`McpRegistry.built` 读写都在同一 `Mutex` 内 |
| §14 功能完备性与 README 覆盖 | 2 | #6（`required:false` 未真正实现，承诺源 README:531 + `McpAnnotations.cj:23`，缺失证据 = 调用期必然 -32602）、#16（`configure`「立即生效」在 HTTP 路径不成立，承诺源 README:547-549）。README 逐符号对照属 1 部分文件，本部分只核对了与本部分符号相关的段落（`exports.cj`↔README:18-22、`RateLimitBackends`↔README:257、`isToolName`↔README:606），无其它遗漏 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_mcp.part4.txt` 逐行一致，无缺读；本部分不含 `.md`，§13 文档一致性由 1-3 部分承担 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 21 |
| 轻微 | 24 |
| 其中存量 | 45 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：两份 README 与实现的一致性整体良好：协议版本常量与错误码、`server/discover` 响应结构、限流三层合并与六级检查顺序、`RateLimitBackend` SPI 签名、结果外链与 UTF-8 截断语义、`ToolResultStore` / `SubscriptionHub` 的全部默认值与 `McpServerBuilder` / `McpClientOptions` 的每个默认值都逐项核对通过，未发现「承诺了但没实现」的能力。主要风险集中在英文版未跟上中文版与实现：内置后端数量写错（5 vs 4）、`@McpToolMeta` 的 `-1` 继承语义整段丢失，后者会直接导致英文读者把 `0` 当「继承」用而关掉限流。其次是多 `@Mcp` 类场景下 `serverInfo.name` 被静默覆盖这一关键限制没有任何提示，多服务进程容易在 `server/discover` 上看到错误的服务名。其余为术语与清单类笔误（工具名字符集、`content` 类型、相对路径措辞、公开 API 清单、协议版本头）。本部分无阻塞项，8 条均为存量，是否纳入修复待用户决定。

**第 2 部分**：本部分 7 个文档覆盖 MCP 协议语义、护栏、变更规格与校验报告，设计密度高、决策记录完整（D1–D16、30 条已定事项、日志字段稳定性承诺都是加分项）。核心问题不是"设计错了"，而是**文档没有随实现收敛**：模块设计文档最后更新停在 2026-10-25，`f_mcp/src` 之后仍持续重构（限流换 `f_concurrent`、客户端多轮改 `callToolAuto`、能力集加入 `prompts`、错误码迁到 `-32040`、限流改为 429）。文末的「文档与实现对照」表本意是兜底，却把差异集中到第 2424 行之后，正文与 spec 未回填，形成"同一事实多种口径"。

阻塞项（建议合并前处理）：#1 能力声明（现行设计文档 6 处说没有 `prompts`，实现已声明）、#2 服务端 API 示例（六个方法名全部不存在，另含一个不存在的 `purgeExpiredResults`）、#3 客户端多轮 API（枚举与两个超时字段不存在，示例编译不过）。

可排期：#4 自适应配置示例（`adaptive: None` 编译不过）、#5 限流模型字段、#7 限流存储/依赖/后端数量、#8 变更设计 Non-Goals 回填、#6 调用方识别（含 XFF 伪造面，建议先定语义）、#9 `data.scope` 补第六个取值。

轻微项（#10–#13）属文档卫生与归档指引，可批量修订。整体看代码侧演进方向合理，修订成本低于代码返工；但 `specs/mcp/spec.md`（prompts MUST NOT）与 `data.scope` 枚举会持续误导下游客户端实现，优先级应高于其他文档项。

**第 3 部分**：本部分（`Mcp.cj` + `base/McpContent.cj` + `base/McpException.cj` 与 3 组变更产物）代码量小、职责单一，协议模型（`content` / `structuredContent` / `resultType` / `inputRequired` / `requestState` / `data`）与 `specs/mcp` 的口径基本对得上，`McpException` 的错误码透传路径也正确。主要风险集中在两处：一是 `fromJson` 的静默降级（#1），它会让客户端在服务端数据稍不合规时"安静地少内容"，且无法从返回值区分，建议优先改成显式报错或留原始字段；二是变更产物自身的不自洽（#2），`@Mcp` 的 `build()` 位置在规格里是 MUST、在设计里是 MUST 删除、任务已勾选删除而代码仍是加载期 build，这比任何单行缺陷都更容易误导下一轮实现与验证。

其余 5 条轻微项（`toJson` 往返不幂等与重复序列化、JSON 对象别名、resource 载荷重复、`tasks.md` 字段数、阈值口径与 `$ref` 报错位置）不阻塞发布，可随下次文档收口一并处理。本部分无严重项、无死锁/数据竞争、无栈溢出与无界增长。存量缺陷 8 条（本部分全部为存量），是否纳入修复待用户决定。

**范围外提示**：`docs/LocalMode.md:436` 仍写「先改成 UTF-8 字节边界切片（结构性，收益确定）」，而 `truncateUtf8` 已按 `runes()` 改造完成，同文件 `:317` 也已标注「已改」——该文件不在本模块文件清单内，仅记录一句。

**第 4 部分**：本部分覆盖 `f_mcp` 的协议常量与模型、客户端（HTTP/stdio 共用消息层）、宏展开入口、注解、配置、HTTP 入口、参数/返回值转换、prompt 与限流注册表，共 4777 行。整体分层是清楚的：`base` 只放协议模型与常量，`client` 把消息层完全委托给 `f_jsonrpc`（`McpRpc` 接缝只有 20 行），`server` 的注册/构建/限流三段职责没有互相穿透；`exports.cj` + `src/Mcp.cj` 的重导出与 README 的门面包说明一致；限流的多维合并（`RateLimitPolicy.overlay` → `ToolRateLimit` → `ResolvedRateLimit`）与「并发拒绝不消耗令牌」的语义在代码里是自洽的。

风险主要有两处，都集中在「会话/连接生命周期」上：**一是 stdio 客户端把「一次只有一个等待者」当成前提，但 `JsonRpcClient.call` 无锁、`McpClient` 又用 `Mutex` 保护版本号暗示了多线程可用**，于是出现 #1（别人的响应被当 stale 丢掉，随机 30s 超时）与 #3（`close()` 无法取消在途请求），这两条一起构成「客户端在并发下不可靠」的阻塞项，建议优先修——修法不复杂（按 id 建待取表 + 关闭走独立标志位）。**二是 `/mcp/sse` 这条旁路完全没有调用方校验**（#5），订阅 id 可枚举、订阅池可被匿名占满，属需要按部署模型定级的安全面；它与 #4 的乱码解码同处 `McpController`，一并改成复用 `caller` 派生与 `stdx.URL` 解析即可收敛。

#2（`lines` 无界）与 #7（并发闸门清理竞态）是典型的「长期运行才暴露」问题，量级已经按通知速率算过，可排期处理。其余 9 条轻微项（Page 模型/后端查表/反射查注解/两个 catch 分支的重复、`listAllTools` 文案、同名注册静默覆盖、关闭路径吞异常、控制器缓存 server）都不影响功能正确性，可随下一次收口一起做。

本部分无严重项、无栈溢出、无死锁；`§1 死代码` 与 `§2 重复逻辑` 均已机械过一遍并给出结论（0 / 4）。存量缺陷 16 条（本部分全部为存量），是否纳入修复待用户决定。

**范围外提示**：`f_jsonrpc/src/client/JsonRpcClient.cj:82-95` 的 `call` 对 `transport.send` 无任何串行化，这是 #1 能够发生的前提；该文件属 `f_jsonrpc` 模块，仅记录一句，不计入本轮统计。

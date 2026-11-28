# f_mcp 模块审查报告

> **模块第 2/5 部分**（分报告）。本部分只覆盖 `f_mcp/doc/` 下的 7 个文档（模块设计文档 + `doc/spec/add-f-mcp/**`）；
> 同模块的 33 个 `.cj` 与其余 `.md` 见 `parts/f_mcp.part1/part3/part4/part5.md`，最终模块报告由主 Agent 合并。
> 本部分不含源码，结论以「文档与 `f_mcp/src` 的实际契约」比对为主；引用的源码行号仅作取证，不重复审源码。

- **审查日期**：2026-11-28
- **模块路径**：`f_mcp`（本部分 7 个 `.md`；全模块 33 个 `.cj` + 20 个 `.md`）
- **基线**：工作区快照（无 diff），本部分全部文件按「存量」计
- **审查重点**：MCP 协议正确性、会话与资源生命周期、并发安全、死代码、重复逻辑、存量 BUG；本部分聚焦文档契约与实现一致性（§13 / §14）
- **报告版本**：v1

## 发现

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

## 优化可行性方案

本部分为 7 个文档，无源码路径、无输入规模与测量手段，不产出堆内存 / CPU 优化方案（性能结论必须有改前基线 + 改后对照，见 reviewer.md 铁律）。文档类改进已按缺陷计入「发现」，不重复统计。

## 待验证假设

本部分无源文件，不产生可测量的性能假设。文档中与性能相关的断言（如"10 万桶后被淘汰""每 5 分钟一条日志成本可忽略"）属设计意图，需在 part1/part3 的源码审查中用 `cjprof record` / 压测复核，不在本部分登记。

## 文件覆盖

> 与 `{workdir}/files/f_mcp.part2.txt` 一一对应，7 行全部读完。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mcp/doc/f_mcp模块设计.md` | .md | ✅ | 2439 行全读；正文与实现系统性漂移，见 #1/#2/#3/#4/#5/#6/#7/#9 与轻微 #12/#13 |
| 2 | `f_mcp/doc/spec/add-f-mcp/design.md` | .md | ✅ | 变更设计；D3 与 D14 互斥、D8/Risks 与 D10/D12 互斥（#1/#8）、`-32002`（轻微 #10）、游标编码（轻微 #13） |
| 3 | `f_mcp/doc/spec/add-f-mcp/proposal.md` | .md | ✅ | 提案；"不映射 429"与当前实现相反（轻微 #10）；追加能力清单与 tasks 11 一致 |
| 4 | `f_mcp/doc/spec/add-f-mcp/specs/mcp-guardrails/spec.md` | .md | ✅ | 护栏 spec；五 scope 为当时口径（现为六个，见 #9），并发 `finally` 释放、自适应窗口与实现一致 |
| 5 | `f_mcp/doc/spec/add-f-mcp/specs/mcp/spec.md` | .md | ✅ | 协议 spec；`prompts` MUST NOT 与自带 Requirement 冲突（#1）、`-32002`（轻微 #10）、订阅注销（轻微 #11） |
| 6 | `f_mcp/doc/spec/add-f-mcp/tasks.md` | .md | ✅ | 任务清单；3.1 与 11.5 对 `prompts` 结论相反（#1），其余勾选与实现一致 |
| 7 | `f_mcp/doc/spec/add-f-mcp/verify-report.md` | .md | ✅ | 校验报告；"34 passed"无法在只读模式下复核，记为待确认；依赖清单为增量描述，与 cjpm 不冲突 |

合计：`.cj` 0 个 / `.md` 7 个 / 共 7 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 存量缺陷 13 条（9 一般 + 4 轻微），默认只报不修；是否纳入修复待用户决定。

## 总评

本部分 7 个文档覆盖 MCP 协议语义、护栏、变更规格与校验报告，设计密度高、决策记录完整（D1–D16、30 条已定事项、日志字段稳定性承诺都是加分项）。核心问题不是"设计错了"，而是**文档没有随实现收敛**：模块设计文档最后更新停在 2026-10-25，`f_mcp/src` 之后仍持续重构（限流换 `f_concurrent`、客户端多轮改 `callToolAuto`、能力集加入 `prompts`、错误码迁到 `-32040`、限流改为 429）。文末的「文档与实现对照」表本意是兜底，却把差异集中到第 2424 行之后，正文与 spec 未回填，形成"同一事实多种口径"。

阻塞项（建议合并前处理）：#1 能力声明（现行设计文档 6 处说没有 `prompts`，实现已声明）、#2 服务端 API 示例（六个方法名全部不存在，另含一个不存在的 `purgeExpiredResults`）、#3 客户端多轮 API（枚举与两个超时字段不存在，示例编译不过）。

可排期：#4 自适应配置示例（`adaptive: None` 编译不过）、#5 限流模型字段、#7 限流存储/依赖/后端数量、#8 变更设计 Non-Goals 回填、#6 调用方识别（含 XFF 伪造面，建议先定语义）、#9 `data.scope` 补第六个取值。

轻微项（#10–#13）属文档卫生与归档指引，可批量修订。整体看代码侧演进方向合理，修订成本低于代码返工；但 `specs/mcp/spec.md`（prompts MUST NOT）与 `data.scope` 枚举会持续误导下游客户端实现，优先级应高于其他文档项。

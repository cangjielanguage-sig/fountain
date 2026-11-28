# f_mcp 模块审查报告（模块第 3/5 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mcp`（全模块 33 个 `.cj` + 20 个 `.md`；**本部分** 14 个文件：3 个 `.cj` + 11 个 `.md`）
- **本部分范围**：`src/Mcp.cj`、`src/base/McpContent.cj`、`src/base/McpException.cj` 与 3 组 `doc/spec/**` 变更产物（`fix-jsonrpc-mcp-review-findings`、`optimize-mcp-truncate-utf8`、`rework-jsonrpc-macro-and-demos`）
- **基线**：工作区快照（未对照远端目标分支，无 diff 可比）
- **审查重点**：MCP 协议正确性、会话与资源生命周期、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本文件是分报告，不写 `docs/review/` 模块报告；由主 Agent 合并）

## 发现

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

## 优化可行性方案

### [堆内存] `CallToolResult.toJson()` 合成 text 块时的整串副本

- **现状**：`toJson()` 在「有 `structuredContent`、无 text 块」时执行 `ContentBlock.text(structured.toString())`（`McpContent.cj:179`），该字符串与 `structuredContent` 字段同时存活到整条结果序列化完成，峰值约为结构化内容的两份文本 + 一份转义副本；每条结果一次性、不跨调用复用。
- **方案**：把合成推迟到真正写响应处（`McpServer` 出口），或直接不合成、由客户端按 `structuredContent` 渲染；`toJson()` 只做字段映射。
- **预期**：该路径峰值从「≈2× 结构化文本」降到「≈1×」；具体字节数取决于工具返回体大小，未测。
- **代价**：行为变更（响应 `content` 可能为空数组），需与客户端兼容性一起评估；实现复杂度低。
- **验证**：构造 1 MiB `structuredContent` 且无 text 块的工具，`tools/call` 前后取 `getAllocatedHeapSize()` 与 RSS，对比改前改后；同时断言响应语义不变（`structuredContent` 仍在）。需 `-O2`、同一输入、多轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑，只用于下一轮补数据；不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「只有 `structuredContent`」的工具结果，序列化与内存开销约为普通结果的两倍，可能是大结果路径的实际瓶颈之一 | `f_mcp/src/base/McpContent.cj:177-181`、`f_mcp/src/server/McpServer.cj:1097-1100` | 该形态的调用占比、单次自耗时占比、峰值分配 | 用 1 MiB `structuredContent` 构造工具，`cjprof record` 跑 1000 次 `tools/call`（`-O2`），对比"带 text 块"与"仅 structuredContent"两组 |
| 2 | `resources/read` 对二进制资源每次重新 base64 编码，可能在高频读取下成为 CPU 热点 | `f_mcp/src/base/McpContent.cj:230-232`（`ResourceContent.toJson` 每次 `toBase64String`），调用点 `f_mcp/src/server/McpServer.cj:678-680` | 单次编码耗时、读取频次、blob 大小分布 | `cjprof record` + 分段计时，读取 1 MiB / 8 MiB blob 各 1000 次，`-O2` |
| 3 | `ContentBlock.image/audio`（`toBase64String` 全量展开）在大附件下把峰值抬到 1.33× 以上 | `f_mcp/src/base/McpContent.cj:63-69` | 附件大小分布、峰值内存 | 构造 8 MiB / 32 MiB 图片内容，测 `getAllocatedHeapSize()` 峰值与 RSS |

## 文件覆盖

> 与 `{workdir}/files/f_mcp.part3.txt` 一一对应（14 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/spec/fix-jsonrpc-mcp-review-findings/design.md` | .md | ✅ | 见发现 #2（R3-12 与 spec/实现互斥）、#7（阈值口径）、#3（缓存只读约定） |
| 2 | `doc/spec/fix-jsonrpc-mcp-review-findings/proposal.md` | .md | ✅ | 与实现一致（`-32040`、`subscribe=false`、`any-moment` 移除、`decodeCursor` 可空均已在代码中核实） |
| 3 | `doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp-guardrails/spec.md` | .md | ✅ | 见发现 #7（:150 口径）、#3（:159 单次序列化）；限流顺序 / scope 6 值 / 订阅上限 / 限流配置校验均已核对实现 |
| 4 | `doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp/spec.md` | .md | ✅ | 见发现 #2（:379 build MUST）、#8（:85 位置）；:346 游标、:75 缓存、:232 选项均已核对实现 |
| 5 | `doc/spec/fix-jsonrpc-mcp-review-findings/tasks.md` | .md | ✅ | 见发现 #2（T38.4 / V7）、#6（:432 字段数） |
| 6 | `doc/spec/optimize-mcp-truncate-utf8/design.md` | .md | ✅ | 与 `truncateUtf8` 实现逐行一致（`runes()` / 快速路径 / `StringBuilder(limit)`）；§10 基线为 `-O0` 且只断言分配量，口径自洽 |
| 7 | `doc/spec/optimize-mcp-truncate-utf8/proposal.md` | .md | ✅ | 现状描述（`toRuneArray`）为改造前快照，与 design §10 对得上；`docs/LocalMode.md` 引用见「范围外提示」 |
| 8 | `doc/spec/optimize-mcp-truncate-utf8/specs/mcp-truncate-utf8/spec.md` | .md | ✅ | 4 条结构性约束与实现一致；`TruncateUtf8_test.cj` 存在 |
| 9 | `doc/spec/optimize-mcp-truncate-utf8/tasks.md` | .md | ✅ | T1-T6 全部与实现/测试文件对应（`f_mcp/src/server/TruncateUtf8_test.cj` 在仓） |
| 10 | `doc/spec/rework-jsonrpc-macro-and-demos/specs/mcp/spec.md` | .md | ✅ | `/mcp/sse` chunked + `subscriptionId` 绑定，与 `McpController`/`McpSse` 实现一致 |
| 11 | `doc/spec/rework-jsonrpc-macro-and-demos/verify-report.md` | .md | ✅ | 历史 verify 记录（38 passed 等），属归档快照，不与当前用例数比较 |
| 12 | `src/Mcp.cj` | .cj | ✅ | 三包 public 重导出；`f_mcp.macros` 由 README 单独 import（与本文件注释不冲突） |
| 13 | `src/base/McpContent.cj` | .cj | ✅ | 见发现 #1、#3、#4、#5 |
| 14 | `src/base/McpException.cj` | .cj | ✅ | 与 `JsonRpcException(code, message, data!)` 签名一致（`f_jsonrpc/src/base/JsonRpcException.cj:40`）；仓内 55 处构造 |

合计：`.cj` 3 个 / `.md` 11 个 / 共 14 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

本部分（`Mcp.cj` + `base/McpContent.cj` + `base/McpException.cj` 与 3 组变更产物）代码量小、职责单一，协议模型（`content` / `structuredContent` / `resultType` / `inputRequired` / `requestState` / `data`）与 `specs/mcp` 的口径基本对得上，`McpException` 的错误码透传路径也正确。主要风险集中在两处：一是 `fromJson` 的静默降级（#1），它会让客户端在服务端数据稍不合规时"安静地少内容"，且无法从返回值区分，建议优先改成显式报错或留原始字段；二是变更产物自身的不自洽（#2），`@Mcp` 的 `build()` 位置在规格里是 MUST、在设计里是 MUST 删除、任务已勾选删除而代码仍是加载期 build，这比任何单行缺陷都更容易误导下一轮实现与验证。

其余 5 条轻微项（`toJson` 往返不幂等与重复序列化、JSON 对象别名、resource 载荷重复、`tasks.md` 字段数、阈值口径与 `$ref` 报错位置）不阻塞发布，可随下次文档收口一并处理。本部分无严重项、无死锁/数据竞争、无栈溢出与无界增长。存量缺陷 8 条（本部分全部为存量），是否纳入修复待用户决定。

**范围外提示**：`docs/LocalMode.md:436` 仍写「先改成 UTF-8 字节边界切片（结构性，收益确定）」，而 `truncateUtf8` 已按 `runes()` 改造完成，同文件 `:317` 也已标注「已改」——该文件不在本模块文件清单内，仅记录一句。

# f_mcp 模块审查报告（模块第 1/5 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mcp`（本部分 2 个文件：`README.md`、`README_en.md`，均为 `.md`）
- **基线**：工作区快照（无 diff，全部问题记为「存量」）
- **审查重点**：MCP 协议正确性、会话与资源生命周期、并发安全、死代码、重复逻辑、存量 BUG；本部分落到「文档与实现一致性（§13）+ 功能完备性与 README 覆盖（§14）」，代码文件仅作取证上下文，不计入本部分覆盖
- **报告版本**：v1（本文件是 `f_mcp` 分报告第 1/5 部分，最终合并为 `docs/review/2026-11-28/f_mcp.md`）

## 发现

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

## 优化可行性方案

本部分仅两份 README，不含可测量的性能/内存改动，故无堆内存 / CPU 方案（0 / 0）。

- 说明：文档层面的「减少重复段落」属于可维护性建议而非性能优化，且限流顺序在 `README.md:238`、`README.md:661` 两处同义表述当前一致，暂不构成缺陷。

## 待验证假设

本部分无性能类结论，故无待验证假设；`f_mcp` 的性能/内存条目统一由包含 `src/**` 的第 3-5 部分提出。

## 文件覆盖

> 与 `{workdir}/files/f_mcp.part1.txt` 一一对应（共 2 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mcp/README.md` | .md | ✅ | 与实现逐项核对通过（协议常量、限流顺序、默认值、SPI、结果存储、订阅上限）；见发现 #4-#8 |
| 2 | `f_mcp/README_en.md` | .md | ✅ | 结构与中文版一致（45 个标题相同），但语义有删减；见发现 #1-#3 |

合计：`.cj` 0 个 / `.md` 2 个 / 共 2 个，全部读完。为核对文档承诺，另行只读引用了 `src/base/McpProtocol.cj`、`src/base/McpContent.cj`、`src/base/McpModels.cj`、`src/base/McpException.cj`、`src/client/McpClient.cj`、`src/server/McpServer.cj`、`src/server/McpConfig.cj`、`src/server/McpRateLimit.cj`、`src/server/McpRegistry.cj`、`src/server/McpResultStore.cj`、`src/server/McpSse.cj`、`src/server/McpController.cj`、`src/server/McpResource.cj`、`src/server/McpTool.cj`、`src/server/McpPrompt.cj`、`src/server/McpConvert.cj`、`src/server/McpAnnotations.cj`、`src/macros/Mcp.cj`、`src/Mcp.cj`、`src/exports.cj`、`cjpm.toml`，仅作取证，不计入本部分覆盖与发现统计。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

两份 README 与实现的一致性整体良好：协议版本常量与错误码、`server/discover` 响应结构、限流三层合并与六级检查顺序、`RateLimitBackend` SPI 签名、结果外链与 UTF-8 截断语义、`ToolResultStore` / `SubscriptionHub` 的全部默认值与 `McpServerBuilder` / `McpClientOptions` 的每个默认值都逐项核对通过，未发现「承诺了但没实现」的能力。主要风险集中在英文版未跟上中文版与实现：内置后端数量写错（5 vs 4）、`@McpToolMeta` 的 `-1` 继承语义整段丢失，后者会直接导致英文读者把 `0` 当「继承」用而关掉限流。其次是多 `@Mcp` 类场景下 `serverInfo.name` 被静默覆盖这一关键限制没有任何提示，多服务进程容易在 `server/discover` 上看到错误的服务名。其余为术语与清单类笔误（工具名字符集、`content` 类型、相对路径措辞、公开 API 清单、协议版本头）。本部分无阻塞项，8 条均为存量，是否纳入修复待用户决定。

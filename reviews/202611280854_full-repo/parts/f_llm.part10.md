# f_llm 模块审查报告（第 10/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（全模块 368 个 `.cj` + 112 个 `.md`；**本报告只覆盖模块第 10/25 部分**，即 `files/f_llm.part10.txt` 的 20 个 `.cj` + 0 个 `.md`：`src/dao/postgres/` 三个 DAO、`src/embedding/**`（含 `exception` 子包与 `imports.cj`）、`src/exception/` 三个异常类）
- **基线**：工作区快照（`master` 与 `sts/1.3.x` 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题记「存量」，`git blame` 只作引入提交依据
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 10/25 部分）

## 发现

本部分没有流式（SSE）代码：`BgeM3Transport` / `Embedding` 都是同步一次性 `readEntire`，流式契约在别的分部分。客户端侧的问题集中在**共享状态、超时与重试、错误分类**；三个 DAO 的参数化是干净的（`${arg(...)}` / `meet().IN(...)`，无拼串），问题只在分页排序键与重复样板。

### [严重][存量] `HttpEmbedder` 的单槽缓存在多线程下会返回「别的文本」的向量

- **位置**：`f_llm/src/embedding/HttpEmbedder.cj:66-74`（`responseOf`），字段 `:57-59`
- **来源**：存量（`git blame`：`:58-59`、`:66-74` 均为 `89bc5e222c` 2026-10-31 引入）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入 / 可见性）；§11（并发正确性）
- **证据**：静态确定 —— 共享链完整：`@Bean public class DefaultEmbedder`（`DefaultEmbedder.cj:27-37`）内部只构造**一个** `HttpEmbedder`（`:33-36`）；`f_bean` 默认 `scope = BeanScope.singleton`（`f_bean/src/BeanMeta.cj:26`），`BeanManager.bean` 对单例只 new 一次（`f_bean/src/BeanManager.cj:98-113`）；`HydraContentStore` 构造期 `lookupOption<Embedder>()` 取到该单例并以 `private let model: Embedder`（`f_llm/src/store/hydra/ContentStore.cj:30/37/69-75`）长期持有，被所有请求线程共用。`cachedText` / `cachedResponse` 是普通 `var`，读写**无锁、无原子、无线程封闭**，且写入顺序是「先 `:71` 写 `cachedText`，再 `:72` 写 `cachedResponse`」，读侧判据 `:67` 是跨这两个字段的复合判断。
- **描述**：线程 A 为文本 `x` 拿到响应 X，执行 `:71` 把 `cachedText` 置为 `x` 后、`:72` 前被切走；线程 B 此时用同一文本 `x` 调 `embed('x')`，`:67` 判 `cachedText == 'x'` 成立且 `cachedResponse.isSome()`（值仍是上一次文本 `w` 的响应 W）→ **直接返回 W**。调用方把 W 当作 `x` 的向量写入 `llm_memory_vector`（`ContentStore` → `MemoryRepository.upsert`），全程无异常无日志，属静默数据错误；同一竞态也会让「一次写入问三次、只发一次 HTTP」的优化互相顶掉（变成 3 次请求）。`Embedder` 接口（`f_llm/src/store/MemoryRepository.cj` 的接口声明）没有任何「非线程安全」约定，调用方无从规避。
- **建议**：把缓存收敛成**单个不可变条目**（`class Entry { let text: String; let response: EmbeddingResponse }`，一个 `var` 发布，读侧先取本地引用再比较），`text` 与 `response` 天然同代；或用一个 `Mutex` 只包「比较 + 引用拷贝」（`Embedding.cj:42-57` 已有同款用法）。更彻底的做法是去掉跨调用缓存，让写入方在一次记忆写入内调一次 `resolve(text): EmbeddingResponse` 后自行分发 dense / sparse / colbert。补并发用例：两线程交替 `embed("a")` / `embed("b")` 各 1000 次，断言首分量与文本一一对应。

### [严重][存量] `BgeM3Transport.embed` 每次调用都改写进程级 HTTP 超时，污染所有其它 HTTP 客户端

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:61-65`
- **来源**：存量（`git blame`：`:62-63` = `033799be37`、`:64` = `8a456f9545`，均 2026-10-31）
- **判据**：review-checklist §12.1（全局可变状态无保护）；`fountain-baseline.md` §5（配置只在启动读一次）
- **证据**：静态确定 —— `HttpClient.globalReadTimeout/globalWriteTimeout` 写的是 `private static var readTimeout_ / writeTimeout_`（`f_httpclient/src/httpclient.cj:29-36`），**没有任何同步**；每个 `HttpClient(url)` 构造时把这两个静态值套到自己的 builder 上（`httpclient.cj:41-48`）。因此每次向量化都会把**全进程**后续构造的客户端读/写超时改成 `llm_embeddingTimeoutMs`（默认 3000，`f_llm/src/config/LLMConfig.cj:127-130`）——包括对话链路、MCP、`f_http` 等无关客户端。
- **描述**：三层后果。①**跨组件副作用**：别的链路按自己的 SLO 设了 60s，一次向量化把它改成 3s，之后新建的客户端全部 3s 超时，表现为「偶发超时、重启即好」，与向量化无因果可循。②**数据竞争**：`readTimeout_` 是无同步 `static var`，向量化线程写、其它线程在构造函数读。③超时设在**重试循环之外**，重试期间别的线程改了全局值，本实例也不跟随，语义更乱。
- **建议**：删掉 `:62-65`，在 `postOnce` 里用实例级 API：`let client = HttpClient(url)` 之后 `client.readTimeout(Duration.millisecond * timeoutMs).writeTimeout(...)`（`httpclient.cj:106-117` 返回 `This`，可链式）。建连超时若要管，应补进 `f_httpclient` 的 `ClientBuilder`（`:57-59` 的注释已说明当前没有该入口），而不是用全局静态兜。

### [严重][存量] `BgeM3Transport` 无条件 `CertificateVerifyMode.TrustAll`，端点改 https 即关闭证书校验

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:90-92`
- **来源**：存量（`git blame`：`89bc5e222c` 2026-10-31）
- **判据**：review-checklist §10（安全性：外部端点未校验、静默降级）；§11（契约与实现不符：类注释只说是「传输层」）
- **证据**：静态确定 —— `postOnce` 对**任意** URL 都设 `tls.verifyMode = CertificateVerifyMode.TrustAll`，不按 host 判断回环、也没有配置开关；URL 来自 `llm_embeddingUrl`（`LLMConfig.cj:122-125`，默认 `http://127.0.0.1:8000/...`，`DefaultEmbedder.cj:33-36` 原样透传）。
- **描述**：默认回环 http 下无实际影响；一旦把 `llm_embeddingUrl` 指向 https 的内网 GPU 机、sidecar 或第三方 embedding API，证书链与主机名校验被静默关闭，中间人可返回任意向量 → 记忆库被投毒且不可观测（写入的是攻击者构造的 1024 维向量，检索命中与重排全被操纵）。
- **建议**：默认不设 `tlsConfig`（走 `CertificateVerifyMode.Default`）；仅在 host ∈ {`127.0.0.1`, `localhost`, `::1`} 时 TrustAll，并写成显式函数 + 注释；确需连自签远端时加配置项（如 `llm_embeddingInsecureTls`，默认 `false`）并在 README 标注。

### [一般][存量] `escape()` 手写 JSON 转义漏控制字符，含 `\t` / `\r` 的文本发出非法报文

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:102-104`（使用点 `:84-86`）
- **来源**：存量（`git blame`：`89bc5e222c` 2026-10-31）
- **判据**：review-checklist §11（边界 / 外部输入未校验）；§2（与 `f_data` 的 JSON 序列化重复，且复制件少了规则）
- **证据**：静态确定 —— `escape` 只处理 `\`、`"`、`\n` 三类，随后把结果直接插进 `'{"input":["${escape(text)}"],...}'`。JSON 要求 U+0000–U+001F 全部转义，`\t`、`\r`、`\b`、`\f` 及其它控制字符仍以原字节进入字符串字面量，报文非法。`f_data` 已有 `JsonObject` / `JsonArray`（`Embedding.cj:70-72` 正是用它构造报文）。
- **描述**：记忆正文里出现制表符（中文文档、代码片段、Markdown 缩进都带 `\t`）或 Windows 换行（`\r\n` 只有 `\n` 被处理）时，请求体不是合法 JSON，服务返回 4xx；再经 `:67-76` 重试 3 次仍失败，用户只看到「向量化失败」。
- **建议**：改为 `JsonArray` + `JsonObject` 序列化（与 `Embedding.cj:70-72` 同构），顺带消掉这处重复的转义实现；若坚持手写，至少补齐 `\r \t \b \f` 并对 `< 0x20` 统一 `\u00XX`。补用例：`embed("a\tb\rc")` 生成的 body 能通过 `JsonValue.fromStr` 反解。

### [一般][存量] 重试把确定性失败（4xx）也重试，`retries < 0` 时报错文案还会误导

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:67-80`（4xx 抛点 `:95-97`）
- **来源**：存量（`git blame`：`033799be37` 2026-10-31）
- **判据**：review-checklist §11（错误处理：失败路径分类不当）；§8 第 7 条（异常控制流放大）
- **证据**：静态确定 —— `postOnce` 对 `status >= 400` 一律抛 `IllegalStateException`，`embed` 的 `catch(e: Exception)`（`:70`）不看状态码，因此 400/401/404 都会被重试 `retries` 次，每次 `sleep(100/200ms)`；`0..(retries + 1)` 在 `retries < 0` 时是空区间，一次都不尝试，直接抛 `bge-m3 embedding failed without exception`（`:79`）。
- **描述**：4xx 是确定性失败，重试只增加延迟（默认 3 次 + 退避）与无效请求量，直接放大请求主路径的 P99；错误类型与模块既有的 `EmbeddingException`（`Embedding.cj:28-32`）不一致，调用方按类型降级会漏掉；负 `retries` 会把配置错误报成「服务没返回异常」。
- **建议**：按状态码抛可区分的异常（如 `BgeM3StatusException(status)`），只在 5xx / 429 / IO 异常时重试，4xx 立即上抛；入口做 `max(0, retries)`；兜底文案改成带 `retries` 与「未执行任何尝试」的可诊断消息。补用例：transport 返回 400，断言只调用 1 次。

### [一般][存量] `Embedding.parse` 逐分量吞异常补 `0.0`，把坏报文变成「合法」零向量

- **位置**：`f_llm/src/embedding/Embedding.cj:144-151`
- **来源**：存量（`git blame`：`ce152e5f22` 2026-10-28）
- **判据**：review-checklist §3（`catch` 静默吞掉异常，至少一般）；§11（失败当成功）
- **证据**：静态确定 —— `try { embedding.add(Float64.parse(value.toString())) } catch (_: Exception) { embedding.add(0.0f64) }`，注释明写「单个分量异常按 0 处理，长度保持不变」；之后只要 `embedding` 非空（`:155`）就返回成功，`holder.recordSuccess(conf.id)`（`:91`）照常记成功。
- **描述**：provider 换了数值格式（返回 `null`、字符串数字、不接受指数形式）时逐维填 0；整体不兼容时得到全零向量，长度仍等于维度，`Embedding.embed` 侧无维度/范数校验。零向量写进 `llm_memory_vector` 后 `MemoryDAO.cj:68` 的 `1 - (<=>)` 打分退化为常数，检索变成「随机命中」，而熔断器认为这次调用成功、不会切换候选。
- **建议**：区分「字段类型不符」（整个响应不可用 → 抛 `EmbeddingException`，走上层失败转移）与「个别 `NaN/Inf`」（置 0 + `f_log` warn）；至少加「任一分量解析失败即整条失败」的门槛，并校验最终向量非全零。

### [一般][存量] 失败转移在两条错误路径上退化：4xx 直接放弃其余候选、全熔断时 `last` 为空

- **位置**：`f_llm/src/embedding/Embedding.cj:81-94`（`throw` 在 `:87`、聚合 `:94`）
- **来源**：存量（`git blame`：`ce152e5f22` 2026-10-28）
- **判据**：review-checklist §11（契约与实现不符 / 错误处理不完善）；类注释 `:34-40` 承诺「失败转移、可重试失败记熔断」
- **证据**：静态确定 —— 非重试状态码走 `throw EmbeddingException(...)`（`:87`）而不是 `continue`，循环立刻结束；候选取全被 `holder.isCircuitOpen` 跳过时（`:67-69`），`lastError` 仍是初值 `''`，最终消息为 `all embedding confs failed for: X, last: `（`:94`）。
- **描述**：①4xx 不区分「这次请求本身错」（`input` 超长，换 provider 可能成功）与「凭据/路径错」，多候选配置下第一个候选的 400 会让整次调用失败，与注释承诺的失败转移不一致；②全熔断恰恰是运维最需要信息的场景，却只给空 `last`，日志里看不出是熔断；③消息里没有候选数量与跳过原因。
- **建议**：4xx 也走「记 `lastError` → `continue`」，只在候选耗尽后抛聚合异常；聚合消息带 `tried=n, skippedByCircuit=m, last=<原因>`；`lastError` 初值改为 `'no candidate attempted'`。若「4xx 必须终止」是有意设计，请在 `:81-88` 补注释并把初值改掉。

### [一般][存量] `MemoryDAO.list` / `listByKind` 用非唯一键 `save_time` 排序 + `OFFSET`，分页会重复或漏行

- **位置**：`f_llm/src/dao/postgres/MemoryDAO.cj:154-163`（`list`）、`:166-175`（`listByKind`）；时间来源 `:26-35`（`now()`）
- **来源**：存量（快照模式；SQL 主体早于本轮）
- **判据**：review-checklist §11（边界 / 契约不符：分页不稳定）；§6.4 仅作线索
- **证据**：静态确定 —— 两条 SQL 都是 `ORDER BY save_time DESC LIMIT ${arg(limit)} OFFSET ${arg(offset)}`，排序键不唯一且没有 `id` 作为 tie-breaker。`save_time` 由 `now()` 生成，PostgreSQL 的 `now()` 是**事务开始时间**，同一事务内批量写入的多行时间戳完全相同；等值键上行的相对顺序由执行计划决定。
- **描述**：调用方按 `offset += limit` 遍历（管理端记忆列表、导出、批量重排）时，同一行可能出现在两页、或整行被跳过；结果不可复现，且不抛异常。这是静默的可见性错误。
- **建议**：排序改 `ORDER BY save_time DESC, id DESC`（两处），必要时建 `(user_id, namespace, save_time DESC, id DESC)` 索引；更稳的是 keyset 分页（`WHERE id < ${cursor} ORDER BY id DESC`）。补集成用例：同事务插 5 行、`limit=2` 翻 3 页，断言并集正好 5 行且无重复。

### [一般][存量] 注释称「按权重挑起点」，向量化路径里 `weight` 只当启用开关

- **位置**：`f_llm/src/embedding/Embedding.cj:34-40`（注释）、`:66-93`（实现）；对照 `f_llm/src/llm/LLMConfsHolder.cj:49-57`、`:170`、`:189-222`
- **来源**：存量（`git blame`：`ce152e5f22` 2026-10-28）
- **判据**：review-checklist §11（语义与注释不符）；`fountain-baseline.md` §4（多实现选择应收敛，不在调用点各写一套策略）
- **证据**：静态确定 —— `LLMConfsHolder.candidates`（`:49-57`）只按 `weight > 0` 过滤、按 `byName` 列表顺序返回，不做加权；`Embedding.embed` 顺序 `for` 取第一个成功者；同类的加权选择器 `balancerFor`（`:189-222`）只被 `:170` 的对话侧入口使用。另外 `MetaDAO.confCandidates`（`f_llm/src/dao/postgres/MetaDAO.cj:67-75`）没有 `ORDER BY`，行序不保证稳定。
- **描述**：两个 embedding 候选配 `weight=9` / `weight=1` 时，期望 9:1 分流，实际 100% 打到行序第一个（且行序可能随 PG 更新而变）。同一份 `llm_conf` 在对话与向量化两条路径上语义不同，扩容/灰度时流量分配与预期不符，且很难发现。
- **建议**：二选一——让 `Embedding.embed` 复用 `balancerFor` 的选点（失败再按顺序兜底）；或把 `:35` 注释改成「按行序取第一个可用候选，`weight` 仅作启用开关」并同步到 embedding 配置文档。当前的双重语义必须消掉。

### [一般][存量] 向量化的 token 用量从未落库，`EmbeddingParam.agentId/session` 被静默丢弃

- **位置**：`f_llm/src/embedding/Embedding.cj:59-95`（只写 `result.usage.llmId`，`:90`）；`f_llm/src/embedding/EmbeddingParam.cj:21-26`
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（读了不用）/ §11（契约与实现不符：参数暗示了会被记录）；`fountain-baseline.md` §2（DAO 层已备好列）
- **证据**：静态确定 —— `Embedding.embed` 全程不读 `params.agentId` / `params.session`（全仓 grep `EmbeddingParam(` 的调用点都传了这两个值，如 `f_llm/src/model/entity/KnowledgeEntity.cj:25/63`、`LlmEmbeddingTransport.cj:40-42`）；`saveTokenUsage` 的调用点只有 `f_llm/src/agents/AgentTask.cj:457` 与 `f_llm/src/llm/ContextPruner.cj:71`，都是对话路径；而 `TokenUsage` 明确带 `agent_id` / `session` 列（`f_llm/src/model/po/TokenUsage.cj:39-42`），`EmbeddingResp.usage` 也一路透传出来却无人消费。
- **描述**：embedding 的 `prompt_tokens/total_tokens`（`Embedding.parse:158-163` 已解析）既不落 `llm_token_usage`，也不进任何账目；即便将来落库，`agent_id` 也会是 0、`session` 为空串——这两列的存在与调用方显式传参让人以为会记录，实际是死的。成本核算与限流按 token 计量时会漏掉向量化这一块。
- **建议**：要么在 `Embedding.embed` 成功后把 `params.agentId/session` 写进 `usage` 并调 `lookupOption<TokenUsageSaver>()?.saveTokenUsage(...)`（与 `ContextPruner.cj:71` 同构）；要么删掉 `EmbeddingParam` 的这两个字段和 `EmbeddingResp.usage`，把「向量化不计量」写成显式契约。二选一，不要保留「传了但不用」的中间态。

### [轻微][存量] `embedding/imports.cj` 有 7 条没有消费者的 `internal import`

- **位置**：`f_llm/src/embedding/imports.cj:19`（`ConcurrentHashMap`）、`:21`（`MonoTime`）、`:27`（`fountain::f_log.*`）、`:28`（`f_util.UUID`）、`:31`（`f_llm.exception.LLMException`）、`:33`（`f_llm.finder.*`）、`:35`（`f_llm.util.*`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 在 `f_llm/src/embedding/**`（含 `exception` 子包）逐个符号 grep：`ConcurrentHashMap`、`MonoTime`、`UUID`、`LLMException`、`LoggerFactory`/`f_log`、`f_llm.util`、`f_llm.finder` 全部零命中（仅 `imports.cj` 自身命中）；`BgeM3Transport.cj:93` 的 `http` 是 lambda 形参，不是 `f_llm.util` 的函数。无论 `internal import` 取「文件级」还是「包级重导出」语义（本地官方文档目录 `~/.autocode/cj/doc` 为空，作用域按 §铁律记 `待确认`），这 7 行都没有消费者——差异只是「死 import」还是「死重导出」。
- **描述**：`imports.cj` 变成 18 行里 7 行失效的清单，读者无法据此判断包的真实依赖；同时它把依赖边界放大成「包内谁都能用」。另：`EmbeddingParam.cj:18` 的 `import fountain::f_data.macros.*` 在该文件内也无任何宏使用（该类是普通 `public class`，没有 `@DataAssist`）。
- **建议**：删掉这 7 行与 `EmbeddingParam.cj:18`；后续真需要时在使用处写显式 import，不再走包级重导出。删除属安全机械清理，编译即可验证。

### [轻微][存量] 六处「`row.isEmpty()` → `None`/`Some(row)`」与两处 id→`Int64` 转换各写一遍

- **位置**：`MemoryDAO.cj:134-138`、`:147-151`；`MetaDAO.cj:31-35`、`:113-117`、`:145-149`、`:158-162`（样板 6 处）；`MemoryDAO.cj:197-203`（`daoIntOf`）vs `MetaDAO.cj:88-93`（`confPut` 内联 `match`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（跨文件复制 / 只改类型名）
- **证据**：静态确定 —— 六个 `firstToMap()` 调用点后跟的 5 行完全同构（`let row = ...; if(row.isEmpty()){ None } else { Some<Map<String, Any>>(row) }`），差异只有 SQL 与返回列；两处 id 转换的分支集合与回退值（`0`）逐字相同。
- **描述**：当前无行为漂移（已逐分支比对），但新增一个查询就要再抄 5 行：任何一处加过滤/日志，其余 5 处即漂移。`daoIntOf` 与 `confPut` 的内联 `match` 也是同一语义的两份实现（PG 驱动可能回 `Int32`，回退 0）。
- **建议**：在 `dao/postgres` 内加 `private func optionOf(row: Map<String, Any>): ?Map<String, Any>`（先按 `fountain-api-lookup` 核对 `f_orm` 是否已有同类能力），六处收敛成一行；id 转换统一走 `daoIntOf`，放到同包一个 `RowValues.cj`（不新建跨层共享包）。合并时要保留差异点：`characterGet` 等返回列不同，`isEmpty` 判定语义一致。

### [轻微][存量] 五个异常类逐字重复，`LLMException` / `RoleException` 还在两个包里各存一份

- **位置**：`f_llm/src/exception/LLMException.cj:18-30`、`RoleException.cj:18-32`、`FunctionCallingException.cj:18-30`、`FunctionNotFoundException.cj:18-30`、`IllegalPathException.cj:18-30`；重复副本 `f_llm/src/embedding/exception/LLMException.cj:18-30`、`RoleException.cj:18-32`
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（只改类型名）；§10 设计合理性（包划分）
- **证据**：静态确定 —— 类体都是同一份 4 个构造器（`()` / `(String)` / `(Exception)` / `(String, Exception)`），唯一差异是类名；`fountain::f_llm.embedding.exception` 这个包在全仓**没有任何 import**（`grep -rn "embedding.exception"` 只命中这两个文件自身），即两份副本无人使用；同包内 `RoleException.cj:18` 显式 `import fountain::f_base.BaseException`，`LLMException.cj:18` 不 import 却能用（依赖父包 `embedding/imports.cj:23` 的 `f_base.*`，这一条同时说明包级重导出的隐式性，见上一条 `待确认`）。
- **描述**：异常层级是调用方做降级的唯一抓手，现在既重复又分散：同一失败面有 `IllegalStateException`（`HttpEmbedder.cj:79`、`BgeM3Transport.cj:96`）、`EmbeddingException`（`Embedding.cj:63/87/94/156`）、`LLMException` 三种类型；两份同名的 `LLMException` 分居两包，catch 一处漏另一处，且副本一旦改动就会漂移。
- **建议**：`BaseException` 已有 4 个构造器（`f_base/src/BaseException.cj:44`），子类可省掉全部构造器，只留 `public class XxxException <: BaseException {}`；删掉 `f_llm/src/embedding/exception/` 整个目录（全仓零引用，属对外不可达的重复副本，删除前请确认无下游依赖），异常统一到 `fountain::f_llm.exception`；传输层改抛 `EmbeddingException` 或其后代。

### [轻微][存量] 注释与实现不符两处：重试退避时间、`lexical_weights`「同 token 取最大」

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:54-60`（注释「退避 100ms / 300ms」）vs `:73`（`100 * (attempt + 1)` ⇒ 100ms、200ms）；`:36-39`（注释「同 token 取最大」）vs `:121-126`（`sparse[Int64.parse(token)] = ...` 直接覆盖）
- **来源**：存量（`git blame`：`033799be37` / `89bc5e222c`，2026-10-31）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— `retries=2` 时 `attempt ∈ {0,1,2}`，`attempt < retries` 时 sleep `100*(attempt+1)`，两次退避为 100/200ms；`lexical_weights` 解析是 HashMap 赋值（后者覆盖前者），「取最大」是服务端 `_process_token_weights` 的行为，客户端没有 `max`。
- **描述**：退避时间是容量评估与 SLO 的可观测参数，注释差 100ms 会让人算错重试窗口；「取最大」若被当成客户端保证，服务端一旦返回重复 key，权重会随 JSON 字段顺序变化。
- **建议**：注释改成「退避 100ms、200ms（`100ms × attempt` 递增）」；「同 token 取最大」改成「服务端已按 token 聚合，客户端同 key 覆盖（依赖服务端保证）」，或在客户端补 `max(...)` 兜底。

### [轻微][存量] `postgres/MemoryDAO.cj` 尾部挂着描述「MySQL 记忆 DAO」的文档注释

- **位置**：`f_llm/src/dao/postgres/MemoryDAO.cj:190-196`（注释）与 `:197-203`（实际被注释的 `daoIntOf`）
- **来源**：存量（`git blame`：`cdea037a40` 2026-10-30）
- **判据**：review-checklist §13（文档与代码不一致）；§10 可读性
- **证据**：静态确定 —— 注释讲「MySQL 记忆 DAO …… 唯一例外是 MyVector 的 `MYVECTOR_IS_ANN` / `myvector_construct` …… 只能内联数值字面量」，本文件只有 `@DAO public interface PostgresMemoryDAO`，全文没有 MySQL DAO 或 `myvector` 调用（对应实现实际在 `f_llm/src/dao/mysql/MemoryDAO.cj`）。
- **描述**：读者会以为本文件里有 MySQL 实现或「内联字面量」的合法例外，从而在新增 SQL 时放松 `arg(...)` 参数化要求（`fountain-baseline.md` §2）。
- **建议**：把这段注释移到 `src/dao/mysql/MemoryDAO.cj`（那边才有该例外），并给 `daoIntOf` 补一行说明「`RETURNING id` 的驱动类型可能是 `Int64`/`Int32`，其它回 0」。

### [轻微][存量] `EmbeddingParam.dimension` 声明后从不读取

- **位置**：`f_llm/src/embedding/EmbeddingParam.cj:25`；使用方 `Embedding.cj:70-72`（只读 `params.input`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（死配置字段）；§11（契约不符：参数暗示了不会发生的行为）
- **证据**：静态确定 —— 全仓 grep `dimension` 只命中 `EmbeddingParam.cj:25` 与 `HttpEmbedder.cj:78-81`（后者用的是构造参数 `dim`）；`Embedding.embed` 不做任何维度校验，`HttpEmbedder.DEFAULT_DIM`（`:53`）与这里的默认值 `1024` 是两处独立常量。
- **描述**：调用方看到 `dimension: Int64 = 1024` 会以为「传 768 就按 768 校验」，实际该字段被忽略，向量维度只由传输层/构造参数决定；默认值双写，改一处漏一处。
- **建议**：`Embedding.embed` 用 `params.dimension` 校验返回长度（不一致抛 `EmbeddingException`），默认值引用 `HttpEmbedder.DEFAULT_DIM`；若确定不校验，删掉该字段。

### [轻微][存量] 冗余中转变量与空语句

- **位置**：`MemoryDAO.cj:181-185`（`removeMemory`）、`MetaDAO.cj:124-128`（`skillDelete`）、`MetaDAO.cj:165-169`（`promptDelete`）、`MetaDAO.cj:50-54`（`characterDelete` 末尾 `()`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（无作用语句）/ §10 可读性
- **证据**：静态确定 —— 三处都是 `let deleted = executor.setSql(sql).update; return deleted`（变量只用于返回），`characterDelete` 在 `update` 之后单独一行 `()`。
- **描述**：`let x = ...; return x` 暗示「做过额外加工」但并没有，读者会去找不存在的处理；`()` 同理。不影响行为。
- **建议**：三处直接以 `executor.setSql(sql).update` 作尾表达式；删掉 `characterDelete` 的 `()`。

### [轻微][存量] 连服务的用例把所有非断言异常当 SKIP，实现坏掉也会「跳过」

- **位置**：`f_llm/src/embedding/BgeM3Transport_test.cj:26-40`
- **来源**：存量（`git blame`：`89bc5e222c` 2026-10-31）
- **判据**：review-checklist §3（`catch` 静默吞异常）；§11（失败当成功）
- **证据**：静态确定 —— 只对 `AssertException` 重新抛出（`:34-36`），其余 `catch(e: Exception)` 一律 `println("SKIP ...")` 后正常返回；服务在但返回 500、JSON 结构变了、维度不符，都会被 `IllegalStateException` 吃掉，用例仍「通过」。
- **描述**：这是三路（dense/sparse/colbert）真实可用性的唯一集成验证；服务升级改字段名时 CI 仍绿，问题要到生产检索退化才暴露。
- **建议**：先做一次轻量探测（`embed('ping')` 或健康检查）判断「服务是否存在」，不存在才 SKIP；探测通过后所有异常一律上抛。或按连接层异常类型白名单 SKIP（如连接拒绝），其余失败。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分没有任何 `cjprof` / `cjpm bench` 数据，三条一律 `无基线（待验证）`，不进 `tasks.md`。

### [堆内存] 去掉 `HttpEmbedder` 的跨调用缓存，改为「一次写入一次解析」

- **现状**：`HttpEmbedder.cachedResponse` 持有一整份 `EmbeddingResponse`：`dense` 1024×8B ≈ 8KB；`colbert` 为 N×1024×8B（8192 token 时约 64MB）；`sparse` N 项。生命周期 = 从最后一次调用到下一次不同文本进来（进程级单例，可能长期常驻）。
- **方案**：让写入方在一次写入内调一次 `resolve(text): EmbeddingResponse`，再从同一对象取 dense / colbert / sparse；`Embedder` 三方法保留兼容，默认实现不再跨调用缓存。退一步：缓存只留 `dense` + `sparse`，`colbert` 用完即弃。
- **预期**：常驻堆从「最坏 64MB + JSON 原文」降到 0（无缓存），同时消除严重 #1 的共享可变状态。
- **代价**：调用方需改成一次取值（可在 `Embedder` 加默认方法保持兼容）；若上游确实分三次、每次不同文本，会重新变成 3 次 HTTP（当前缓存在这种情况下也不命中）。
- **验证**：记忆写入压测（8k token 长文本 × 并发 8），改前/改后 `getUsedHeapSize()` 与 RSS 峰值 + HTTP 调用计数，`-O2` 同环境取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] JSON 分量转换从 `toString() + Float64.parse` 改为数值直取

- **现状**：`BgeM3Codec.floatsOf`（`BgeM3Transport.cj:144-147`）对每个分量做 `toString()`（分配一个临时 `String`）再 `Float64.parse`；一次请求 = 1024（dense）+ N×1024（colbert）个临时串，8k token 约 840 万个。`Embedding.parse`（`Embedding.cj:144-151`）同型，1024 次 `parse` 外还叠了 `try/catch`。
- **方案**：改用 `f_data` 的数值直取（`JsonValue` 的 decimal/int 取值接口，落地前用 `cangjie-doc-lookup` 核对签名），避免字符串往返；`Embedding.parse` 同时用 `ArrayList` 预容量或直接 `Array` 避免 `toArray()` 的第二次分配。
- **预期**：单次请求临时分配减少约 2 个对象/分量，GC 压力与 CPU 同步下降；幅度取决于数值转换本身开销。
- **代价**：`Decimal → Float64` 不是零成本，极端情况下可能持平；需覆盖 `1e-3`、`0.1` 等格式的精度一致性用例。
- **验证**：`cjpm bench -O2` 对照 `BgeM3Codec.parse`（固定 fixture 1024 + 32×1024），取中位数与 P95；`cjprof` 看 `toStr`/`parseFloat` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU / 延迟] 每次 `postOnce` 新建 `HttpClient`，连接与 TLS 握手无法复用

- **现状**：`postOnce` 每次 `HttpClient(url)`（`BgeM3Transport.cj:87`），`resource` 结束即关闭（`:93-99`）；`f_httpclient` 的 `send` 每次 `builder.build()`（`httpclient.cj:133-137`）。不同文本、不同线程之间不共享连接。
- **方案**：`BgeM3Transport` 持有一个长生命周期 `HttpClient`（连接池，`poolSize` 可配），请求间复用，关闭交给容器 / `close()`。
- **预期**：省掉每请求 TCP 建连（回环开销小）与 TLS 握手（https 时通常毫秒级），对 3s 超时下的 P99 可能有改善；占比需分段计时。
- **代价**：`HttpClient` 当前实现把 `request` / `client` 当实例可变字段（`httpclient.cj:37-39/133-137`），**看起来不可并发共享**——采用前要么先给 `f_httpclient` 加线程安全契约，要么改成每线程一份（ThreadLocal 需清理，见 `mem §8.2`），属跨模块改动。
- **验证**：分段计时（构造 / `send` / `readEntire`）在单线程与并发 8 两组下跑 1000 次，取 P50/P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求新建 `HttpClient` 使建连/握手占 `embed` 端到端延迟的可观比例（https 更甚） | `BgeM3Transport.cj:87-99` | 建连 vs 读响应的分段耗时占比 | 在 `postOnce` 内打 3 段计时，本地 BGE-M3，1000 次取 P50/P95 |
| 2 | `toString()+Float64.parse` 是 `BgeM3Codec.parse` 的主要自耗时 | `BgeM3Transport.cj:144-147` | self time 占比 | `cjprof record` 跑 `BgeM3Codec.parse`，fixture 1024+32×1024，重复 1000 次 |
| 3 | 单槽缓存命中率在并发下远低于设计的 2/3 | `HttpEmbedder.cj:66-74` | 命中率与 HTTP 调用次数 | 加 `calls`/`hits` 计数，8 线程各写 1000 条记忆 |
| 4 | 长文本（接近 8192 token）时 `colbert` 单次响应峰值达数十 MB，是记忆写入路径的峰值内存主项 | `BgeM3Transport.cj:128-135`；`HttpEmbedder.cj:59` | 峰值 RSS / 单次分配量 | 8k token 文本连续 100 次，采 `getAllocatedHeapSize()` 与 RSS 峰值，对照 `8192×1024×8B ≈ 64MB` |
| 5 | `ORDER BY save_time` 在批量写入后确实产生翻页重复/漏行 | `MemoryDAO.cj:154-175` | 同 `save_time` 行数与翻页重叠行数 | 单事务插 5 行、`limit=2` 翻页，统计并集/交集（功能验证，非性能） |
| 6 | `meet().IN()` 在 `namespaces` / `tokens` 规模较大（>100）时 SQL 生成开销显着 | `MemoryDAO.cj:59-63`、`:112` | SQL 生成耗时 | `cjprof` 跑 `searchDense` 1000 次，`namespaces` 1/10/100 三档 |

> local mode：模块已开 `--experimental --enable-local-mode`（`f_llm/cjpm.toml`）。`BgeM3Codec.parse` / `Embedding.parse` 的中间对象（`JsonValue` 树、`ArrayList<Float64>`、`Array<Array<Float64>>`）除返回的 `EmbeddingResponse` 需 `exclave` 外基本不逃逸，是候选改造点；但收益只能靠峰值内存对照证明，当前无数据 → 只作待验证，不进方案。

## 文件覆盖

> 与 `files/f_llm.part10.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/dao/postgres/MemoryDAO.cj` | .cj | ✅ | 参数化正确；分页排序键不唯一（一般 #5）、注释错挂（轻微 #5）、重复样板（轻微 #2）、冗余中转（轻微 #7） |
| 2 | `f_llm/src/dao/postgres/MetaDAO.cj` | .cj | ✅ | `isEmpty` 样板 4 处 + id 转换内联（轻微 #2）、多余 `()`（轻微 #7）、`confCandidates` 无 `ORDER BY`（一般 #6 证据） |
| 3 | `f_llm/src/dao/postgres/TokenUsageDAO.cj` | .cj | ✅ | 单条 insert、全参数化，无问题 |
| 4 | `f_llm/src/embedding/BgeM3Codec_test.cj` | .cj | ✅ | 覆盖三路解析与「3 次调用 1 次请求」，无并发用例（见严重 #1 建议） |
| 5 | `f_llm/src/embedding/BgeM3Transport.cj` | .cj | ✅ | 全局超时（严重 #2）、TrustAll（严重 #3）、`escape` 不全（一般 #1）、重试分类（一般 #2）、两处注释不符（轻微 #4） |
| 6 | `f_llm/src/embedding/BgeM3Transport_test.cj` | .cj | ✅ | SKIP 吞异常（轻微 #8） |
| 7 | `f_llm/src/embedding/DefaultEmbedder.cj` | .cj | ✅ | 单例 bean 是严重 #1 的共享路径；配置启动读一次，符合基线 §5 |
| 8 | `f_llm/src/embedding/Embedding.cj` | .cj | ✅ | 零填充（一般 #3）、失败转移退化（一般 #4）、权重语义（一般 #6）、usage 不落库（一般 #7） |
| 9 | `f_llm/src/embedding/EmbeddingParam.cj` | .cj | ✅ | `dimension` 从未读取（轻微 #6）；`f_data.macros` 未使用（并入轻微 #1） |
| 10 | `f_llm/src/embedding/EmbeddingResp.cj` | .cj | ✅ | `@DataAssist[props fields]` 用法正确；`agentId/session` 承载的数据无人消费（一般 #7） |
| 11 | `f_llm/src/embedding/Embedding_test.cj` | .cj | ✅ | 用 `LLMConfs.setHolder` + `Embedding.setTransport` 注入，用例间共享全局静态（串行执行时可用，未单列） |
| 12 | `f_llm/src/embedding/HttpEmbedder.cj` | .cj | ✅ | 缓存竞态（严重 #1）、异常类型与模块不一致（并入轻微 #3） |
| 13 | `f_llm/src/embedding/HttpEmbedder_test.cj` | .cj | ✅ | 维度校验与三路透传用例齐全；无并发用例 |
| 14 | `f_llm/src/embedding/LlmEmbeddingTransport.cj` | .cj | ✅ | 对外可达的备选实现，仓内仅注释提及；`agentId/session` 最终被 `Embedding` 忽略（一般 #7） |
| 15 | `f_llm/src/embedding/exception/LLMException.cj` | .cj | ✅ | 与 `f_llm.exception` 同名类重复且全仓零引用（轻微 #3）；未显式 import `BaseException` |
| 16 | `f_llm/src/embedding/exception/RoleException.cj` | .cj | ✅ | 同上，但显式 import，风格不一致 |
| 17 | `f_llm/src/embedding/imports.cj` | .cj | ✅ | 7 条无消费者的 `internal import`（轻微 #1） |
| 18 | `f_llm/src/exception/FunctionCallingException.cj` | .cj | ✅ | 4 构造器逐字重复（轻微 #3） |
| 19 | `f_llm/src/exception/FunctionNotFoundException.cj` | .cj | ✅ | 同上 |
| 20 | `f_llm/src/exception/IllegalPathException.cj` | .cj | ✅ | 同上 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 4（缓存竞态、零填充、失败转移退化、分页）、设计 2（异常层级、权重语义）、契约 1（usage 不落库）、安全性 2（TrustAll、转义不全）、可读性 1（注释错挂）；语言特性上 `resource`、`Option` 惯用法、`@DataAssist`、`Mutex` 用法均核对无问题；本部分无流式代码 |
| §1 死代码 | 3 | 逐个 `private` 符号全仓搜：`daoIntOf`、`text`、`responseOf`、`candidatesOf`、`isEmbedding`、`endpointOf`、`headersOf`、`embeddingIntOf`、`escape`、`postOnce`、`floatsOf` 均有调用者；`internal` 符号在本包及子包内核对；`public` 顶层声明（三个 DAO 接口、`BgeM3Transport`、`BgeM3Codec`、`HttpEmbedder`、`Embedding` 等）对外可达按硬原则一不判（`clearTokens`、`LlmEmbeddingTransport` 记「对外 API，仓内零引用」的信息，不计问题）；无 `return/throw` 后同层语句、无恒真恒假分支。命中 3 条：未使用 import（`imports.cj` 7 处 + `EmbeddingParam.cj:18`）、`EmbeddingParam.dimension` 与 `agentId/session` 读了不用、三处冗余中转变量与空语句 |
| §2 重复逻辑 | 3 | 本部分 20 个文件两两比对函数体「输入-输出-副作用」，并按错误消息 / 字面量跨文件搜：命中 `row.isEmpty()→None/Some` 6 处 + id 转换 2 处（1 条）、5 个异常类 + 2 个同名副本（1 条）、`escape` 与 `f_data` JSON 序列化重复（并入一般 #1）；另记：`Embedding.embed` 的候选循环与 `LLM.chat` 的失败转移循环同构（后者不在本部分，只作线索未计数）；`mysql/MetaDAO` 与 `postgres/MetaDAO` 的 SQL 差异是方言要求，不判重复 |
| §3 空实现 | 1 | 无空函数体 / `TODO` / `FIXME` / `UnsupportedException`；`EmbeddingResp.init()` 空体是 `@DataAssist` 数据类需要，非占位；命中 1 条：逐分量 `catch` 后补 `0.0`（静默吞异常）；另有 1 条同类（测试里的 `catch → SKIP`）计入轻微 #8 |
| §4 栈溢出 | 0 | 本部分无递归：`BgeM3Codec.parse` / `Embedding.parse` 只做单层 `data[0]` 取值，不递归 JSON 树；无自引用结构、无深拷贝；`JsonValue.fromStr` 的递归深度由 `f_data` 承担，不在本部分 |
| §5 OOM | 1 | 命中 1 条（并入优化方案/假设）：`postOnce` 用 `readEntire()` 全量读入，`colbert` 按 token×1024 预分配，`HttpEmbedder` 单槽缓存长期持有；8192 token 时 `colbert` 约 64MB，叠加 JSON 原文与 `JsonValue` 树峰值更高；未见文本长度或响应大小上限。无实测峰值数据，故不作缺陷 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，任何热点结论都不成立；三个候选（HttpClient 重建、JSON 分量转换、缓存命中率）已进「待验证假设」#1/#2/#3 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `Embedding` 的静态 `mutex`（`Embedding.cj:42-57`），只包一次引用读写、无 I/O，粒度已最小；DAO 层无线程级锁 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理；重试是同步 `sleep` 退避，属延迟问题（一般 #2），不是串行热点 |
| §6.4 低效算法 | 1 | 命中 1 条并入一般 #5：`ORDER BY 非唯一键 + OFFSET` 在深分页下随表增长线性扫描且结果不稳定；其余无嵌套循环、无 `contains` 热点、无循环拼串（`BgeM3Codec` 的 `ArrayList` → `toArray()` 是一次性复制，计入优化方案） |
| §7 降堆内存方案 | 1 | 1 条（去掉跨调用缓存），`无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 2 条（JSON 数值直取、连接复用），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 已确认模块开启 `--experimental --enable-local-mode`；`parse` 路径的中间对象多数不逃逸，但收益只能用峰值内存证明，缺改前/改后对照 → 只作待验证（见「待验证假设」后的说明），不进方案 |
| §11 现有代码的 BUG（存量） | 18 | 逐函数核对 20 个文件的边界 / 空值 / 错误处理 / 资源 / 契约：严重 3、一般 7（其中 2 条为契约不符）、轻微 8（含 2 条纯可维护性）；`TokenUsageDAO` 与 `DefaultEmbedder` 未发现缺陷；DAO 的 `arg()` 绑定顺序与占位符顺序逐条对得上（`MemoryDAO.cj:55-74`、`:105-124`） |
| §12 并发安全与锁粒度 | 2 | 共享点逐条列出：①`DefaultEmbedder`(singleton)→`HttpEmbedder.cachedText/cachedResponse`（无同步，严重 #1）；②`BgeM3Transport.embed`→`HttpClient` 静态 `readTimeout_/writeTimeout_`（无同步，严重 #2）。`Embedding.transport` 已用 `Mutex` 保护；`BgeM3Transport` 自身字段全 `let`，无实例状态；DAO 无实例状态（`@DAO` 方法每次取当前 executor） |
| §14 功能完备性与 README 覆盖 | 1 | 本部分 0 个 `.md`，README / `doc/**` 的覆盖与一致性在含 `README.md` 的分部分核算。本部分的「承诺源」是代码注释与字段：命中 1 条「传了但不用」的接线缺失（一般 #7，`agentId/session` + `EmbeddingResp.usage`）；`@Bean DefaultEmbedder` 有消费方（`ContentStore.cj:69-75`），未见「注册未触发 / 开关走进空分支」 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无跳过；本部分无 `.md`，§13 的文档一致性只覆盖注释层（轻微 #4 / #5） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 7 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

三个 DAO 是本部分质量最好的代码：SQL 全部走 `${arg(...)}` / `meet().IN(...)`，没有拼串，`searchDense` / `searchSparse` 里 `arg()` 的绑定顺序与占位符出现顺序逐条对得上（`MemoryDAO.cj:55-74`、`:105-124`），`TokenUsageDAO` 只追加不更新，语义干净。风险集中在 **embedding 客户端这一层**，而且三条严重问题同源——都是**共享状态**：

1. `HttpEmbedder` 的单槽缓存把「避免三次 HTTP」的局部优化做成了跨线程共享可变状态，两个字段分开写、判据跨字段读，最坏会返回**别的文本的向量**并静默入库。这不是性能问题而是数据正确性问题，且现有测试（`BgeM3Codec_test.cj:55-66`）只覆盖单线程。
2. `BgeM3Transport.embed` 用 `HttpClient.globalReadTimeout` 设超时，等于每次向量化都改**全进程**默认 HTTP 超时；`f_httpclient` 已提供实例级 API（`httpclient.cj:106-117`），属用错接口，修法是行级改动。
3. `TrustAll` 无条件生效：默认回环 http 下无害，一旦端点是 https 就是证书校验整体关闭，失败方式完全静默。

**阻塞项**：第 1、2 条建议下一版前修掉（数据错误 + 数据竞争 / 跨组件副作用 + 无同步静态写）；第 3 条至少收敛到「回环才 TrustAll」。**可排期**：分页排序键（一般 #5，管理端可见）、4xx 重试与失败转移（一般 #2/#4，影响 SLO 与可运维性）、零填充与 usage 不落库（一般 #3/#7，影响检索质量与成本核算，且难观测）。**可后置**：重复样板、注释漂移、错挂注释、未读字段、冗余语句（轻微 #1–#7）——维护成本，不是当前故障源。

值得肯定的是：`BgeM3Codec` 与 `HttpEmbedder` 的拆分让解析逻辑可脱网单测（`BgeM3Codec_test.cj` 全部离线），`LlmEmbeddingTransport` 作为 OpenAI 兼容备选在类注释里写清了降级后果（`LlmEmbeddingTransport.cj:22-27`），这种「把可测性与降级说明做进设计」的做法值得在模块其余部分保持。

存量缺陷共 18 条（严重 3 / 一般 7 / 轻微 8），是否纳入修复待用户决定。

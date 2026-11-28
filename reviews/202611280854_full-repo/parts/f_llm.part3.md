# f_llm 模块审查报告（模块第 3/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分：`f_llm/doc/spec/**` 共 20 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比，所有问题来源记为「存量」）
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG；本部分清单全部是变更规格/设计文档，实际落点是「文档承诺 ↔ 实现」的契约核对
- **报告版本**：v1（本部分分报告，待主 Agent 与 1–2、4–25 部分合并为 `docs/review/2026-11-28/f_llm.md`）

> 说明：本部分清单内没有 `.cj`，§1/§2/§3/§11/§12 的机械检查落在**文档点名的符号与验收场景**上——凡文档声称「有 / 默认 / 自动 / 支持」的能力，都在 `src/` 里查到实现位置或确认不存在。正文引用的代码位置只作为文档一致性的**证据**，代码本身的审查由其它子轮负责。

## 发现

### [一般] MCP 输入模式清洗口径：规格要求「只保留四个键」，实现保留全部非 `$` 键

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-tool-calling/spec.md:81-83`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— ①规格场景写「清洗后只保留 `type` / `properties` / `required` / `additionalProperties`」；②`src/mcp/McpToolSource.cj:128-152` 的 `sanitizeSchema` 只跳过 `$` 前缀键，`description` / `items` / `enum` / `default` 全部原样保留；③`McpToolSource.cj:52` 的类注释还写着「`additionalProperties` 一律剥掉」，与 `:128-131` 的实际规则相反；④`McpToolSource_test.cj:75-76` 只断言 `additionalProperties` 保留，没有任何「只保留四键」的用例。
- **描述**：规格的验收口径（只留四键）会**删掉 `description`、`items`、`enum`**——这些正是模型理解工具参数所必需的字段；实现按 2026-10-28 的修正（`design.md:294`）改成了「只剥 `$` 元信息键」，规格没跟着改。按规格做验收会判实现不合规，按实现做验收则规格的这条 Scenario 无法通过；两种读法还会导致下游对工具 schema 的预期不一致。
- **建议**：把 `spec.md:81-83` 改成与 `design.md:294` 一致的口径——「剥掉以 `$` 开头的元信息键，`additionalProperties` 与 `description` / `items` / `enum` 原样保留，`type` 为数组时取第一个非 `null` 类型」；同时修掉 `McpToolSource.cj:52` 的过期注释。

### [一般] `response.failed` 只读顶层 `message`，规格要求的「上游错误码」永远不出现在异常里

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-protocol-compat/spec.md:73-75`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现不符）+ §11（错误处理丢失上游信息）
- **证据**：静态确定 —— ①规格要求「收到 `response.failed` 或 `error` 事件 → 调用失败，异常中包含上游错误码」；②`src/llm/ResponsesStreamAccumulator.cj:62-67` 只在事件的**顶层**取 `message`，取不到就退化成字面量 `'response.failed'`，全文件没有任何读取 `code` 的分支；③异常在 `:80-82` 拼成 `responses stream failed: ${failure}`；④该 `result()` 在 `src/llm/LLM.cj:268-272` 被调用，位置在流式 `try` 块（`:231-254`）**之外**，所以它既不会被包成带 `requestId` / 阶段的 `LLMException`，也不会转移到下一个平台。
- **描述**：Responses API 的 `response.failed` 事件把错误放在 `response.error.{code,message}` 里，顶层通常没有 `message`，因此异常消息恒为 `responses stream failed: response.failed`，既没有 code 也没有上游说明。排障时无法区分「模型拒绝」「配额不足」「参数非法」；叠加 `result()` 在 try 之外，这条失败还是全模块唯一不带 `requestId` 的流式异常，且不会按「可重试」规则换平台（与 design §6 的错误语义表也不一致）。
- **建议**：`ResponsesStreamAccumulator.feed` 的 `response.failed` 分支改为读 `response.error.message` / `response.error.code`（缺省再回落顶层 `message`），并把 code 带进 `LLMException`；补一条用真实事件体（含 `response.error.code`）的用例。

### [一般] 附件发送校验未落实设计承诺的「必须是普通文件、不能是符号链接」

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/design.md:39`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（设计与实现不符）+ §10（外部输入校验）
- **证据**：静态确定 —— 设计写「校验：`canonicalize()` 后必须以某个根为前缀、`isRegular()` 为真、不能是符号链接（`Path` 的 canonical 与实际不同即视为链接）」；`src/channel/EmailChannel.cj:220-246` 的 `checkAttachment` 只有 `exists` → `canonicalize` → 前缀比较 → `isDirectory`（`:239`），`f_llm` 内 `isRegular` / `isSymbolicLink` 零命中（同仓 `f_io/src/ExtendPath.cj:86,90` 已在用 `FileInfo.isRegular()` / `isSymbolicLink()`，接口是现成的）。
- **描述**：两处承诺没落地：①没有 `isRegular`，落在允许根目录内的 FIFO / 设备文件 / socket 会通过校验并被当附件发出（`send` 只判空、越界、目录）；②没有符号链接判定，根目录内「指向同根另一文件」的链接会被放行（指向根外的链接因 canonical 越界而被拒，这部分是安全的）。结果是设计文档声称已收口的「任意读」面仍留一个特殊文件与站内链接的口子。
- **建议**：`checkAttachment` 增加 `FileInfo(Path(actual)).isRegular()` 判断，并用 `FileInfo(Path(attachment.path)).isSymbolicLink()` 直接判链接（两者都是 std.fs 现成接口，`f_io` 已在用）；或把 `design.md:39` 收窄成「只校验前缀 + 非目录」，明确特殊文件与站内链接不在防护范围。

### [一般] `Redactor` 的掩码阈值与设计相反：设计写「长度 < 12 全掩码」，实现是「≤ 8」

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:246`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §10（敏感数据进日志）
- **证据**：静态确定 —— 设计 §9 写「前 4 + `****` + 后 4（长度 < 12 全掩码）」；`src/util/Redactor.cj:25-35` 是 `if(secret.size <= 8){ '****' } else { 前4 + '****' + 后4 }`。`doc/spec/f-llm-openai-compat/tasks.md:74` 把这次偏差记成「实现取更保守的『短于等于前后可见位数就不露』」，方向说反了：`<= 8` 比 `< 12` **更宽松**。
- **描述**：9–11 字符的密钥/令牌会输出 8 个明文字符（只掩中间 4 位），而设计承诺的是整串掩码。对 `auth`、`Authorization`、`*Key*/*Secret*/*Token*` 这些字段来说，9–11 位正是短口令与部分测试 key 的常见长度；一旦进日志，等于把密文还原到只差一位。文档还让人以为实现更保守，掩盖了这个差异。
- **建议**：把阈值改回 `< 12`（与设计一致），或明确把设计改成 `≤ 8` 并在 tasks 里把「更保守」的表述纠正为「更宽松，接受 9–11 位部分暴露」；无论选哪个，都要补一条 9/11 字符密钥的断言用例。

### [一般] 配置来源的失败时机与报错方式与规格不符：规格要「启动失败 + 首载失败报错」，实现是懒加载 + 只记日志

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-conf-routing/spec.md:21-39`（未知来源要「启动阶段失败」；首载失败要「调用报错」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现不符）+ §11（错误被降级为日志）
- **证据**：静态确定 —— ①`src/llm/LLMConfs.cj:47-73` 的 `holder()` 是懒建：`createHolder()` 在第一次业务调用时才执行，全仓没有任何启动期预热调用（`grep "LLMConfs.holder()" src` 只命中 `LLM.cj:99`、`Embedding.cj:60,99`、`LLMCandidateProvider.cj:40` 这些请求路径）；②`src/llm/LLMConfsHolder.cj:259-261` 对 `source.load()` 的异常只 `log.error` 并保留旧快照，首次装载失败同样不抛；③`LLMConfsHolder.cj:111-121` 的 `ensureFresh` 只在**装载成功**时更新 `loadedAt`，失败后每次调用都会再同步打一次来源。
- **描述**：规格给出的三个承诺没有一个按原样成立：未知来源 `llm_confSource` 不会在启动阶段失败，而是在第一条业务请求上抛 `IllegalArgumentException`（`src/service/LLMConfSource.cj:168`）；文件不存在 / JSON 非法时首次装载失败只留一条 error 日志，调用方拿到的是「no available llm conf for: X, available: []」，真实原因（哪个文件、哪一行 JSON）在异常里看不到；又因为没有失败退避，配置源故障期间**每个请求**都要同步付一次失败查询的延迟。这与同仓 `fountain-baseline.md` §5「配置只在启动读一次」的预期也不一致（启动期没有任何校验点）。
- **建议**：二选一并写进文档——（a）`StoreWiring` / `ChannelBootstrap` 之类的装配入口显式调用一次 `LLMConfs.holder().ensureFresh()`，把未知来源与首次装载失败变成启动失败；（b）把规格改成「首次调用时装载，失败保留空快照并记 error」，同时把装载异常原文带进 `LLM.chatByName` 的「no available」消息，并给 `ensureFresh` 加失败退避（例如失败后 5s 内不再重试）。

### [一般] 设计称「刷新整体替换、读路径无锁」，但快照引用的读写没有同步

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:136-142`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（可见性 / 发布逸出）
- **证据**：待确认 —— 缺仓颉语言内存模型对「普通字段跨线程发布」的可见性保证。代码层面静态可见：`src/llm/LLMConfsHolder.cj:82` 的 `snapshot` 是普通 `var`；写点在 `:255`，位于 `synchronized(mutex)` 块**之外**（`:225-229` 的锁只保护 `refreshing` 置位，`:262-264` 的锁只保护复位）；读点在 `:112`（`ensureFresh`）、`:126`（`candidates`）、`:131`（`all`）、`:104-108`（`version`），全部不取锁。
- **描述**：设计把「读路径无锁」当作安全前提，正确性因此依赖引用赋值的原子性与跨线程可见性。`refreshing` 的加解锁只给写线程之间建立顺序，读者与写者之间没有 happens-before：理论上读者可以一直看到旧快照（版本号不前进 → `ensureFresh` 每请求都触发一次刷新尝试），或者看到新 `snapshot` 而 `version` 仍是旧值（`balancerFor` 的版本判断失效，权重表与配置错配）。这与该文件 §3.3「调度器必须随快照版本重建」的约束直接相关。
- **建议**：先确认语言语义（`std.sync` 是否提供原子引用 / 是否需要显式 fence）；若与 Java 普通引用一致，把快照发布改成「锁内写 + 锁内读一次引用」或原子引用，读路径仍可保持无锁（读一次不可变快照即可）。补一条多线程并发刷新 + 高频读的最终状态断言用例。

### [一般] `design.md` §5 的对外 API 与「保留 `LLMContextMediator`」均与实现相反，且与同文件附录冲突

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:194-200`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（API 与源码不符 / 文档过期）
- **证据**：静态确定 —— ①`design.md:194-198` 写 `LLM.chat(req: LLMRequest): LLMResponse`、`LLM.chatStream(req, onDelta: (LLMDelta) -> Unit)`、`LLM.respondStream(req, onEvent: (ResponsesEvent) -> Unit)`；实际门面是 `LLM.chat(candidates: ArrayList<LLMConf>, params: LLMParams): LLMResp`（`src/llm/LLM.cj:68`）、`LLM.chatByName(llmName, params)`（`:90`）、`LLM.chatStream`（`:186`）、`LLM.respondStream`（`:194`），`LLMRequest` / `LLMResponse` / `LLMDelta` 在 `src/` 内零命中；②`design.md:200` 写「`LLMContextMediator` 保留并改为按 `llmName` 访问，新增 `candidates()/peekNext()/isCircuitOpen()/refreshNow()`」，而该类已被删除——同一文件 `:307` 自述「已整体删除」，全仓仅 `src/llm/ContextPruner_test.cj:180` 的注释提到它，那四个方法实际在 `src/llm/LLMConfsHolder.cj:104-190`；③`proposal.md:3`、`:27` 已声明 `LLMRequest/LLMResponse` 未进代码，只有 §5 正文没改。
- **描述**：§5 是「对外 API」章节，是全文档被下游引用最多的一段。按它写调用会直接编译失败，且读者会以为旧中介者仍是扩展点、去 `LLMContextMediator` 上找 `candidates()/peekNext()`。同一份文档的正文与附录给出相反结论，属最容易被当成「现行契约」的一类过期。
- **建议**：§5 改为实际签名（`chat/chatByName/chatStream/respondStream` + `LLMParams`/`LLMResp`/`LLMHooks`），并把「`LLMContextMediator` 保留」一句改成「已删除，选号/熔断/刷新统一走 `LLMConfsHolder`（`candidates()/peekNext()/isCircuitOpen()/refreshNow()`）」。

### [轻微] 流式异常只区分 `connect` / `read`，设计承诺的「首包 / 中途」阶段信息不存在

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:202-212`（§6 错误语义表「流空闲超时 … 保留 `requestId` 与阶段（首包/中途）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺未落地）
- **证据**：静态确定 —— `src/llm/LLM.cj:248-253` 把**所有**流内异常统一包成 `phase: read`；`:256-261` 对 `status >= 400` 用 `phase: connect`。全文件没有「首包 / 中途」的判定，也没有记录首包时间点。
- **描述**：TTFT 超时（首包迟迟不来）与流到一半断线在日志里都是 `phase: read`，排障时无法判断是「上游没开始回」还是「回了一半断了」——而这恰好是选择「换平台」还是「重试同平台」的关键依据。规格侧 `specs/llm-protocol-compat/spec.md:53` 也只要求「带阶段信息」，两边都没落到可实现的口径上。
- **建议**：在 `stream()` 里记录 `firstDelta` 布尔（收到首个非空 delta 时置位），catch 时按它输出 `phase: first_packet` / `phase: mid_stream`；把设计 §6 的这一行改成这两个具体取值。

### [轻微] 设计 §2.4 说 `llm_confSource` 可写「实现名」，但 `static` 源无法通过配置选中

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:121-132`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（接线缺失：能力存在但无配置入口）
- **证据**：静态确定 —— 设计的内置实现表列了 `StaticConfSource`（「代码内静态注册，适合测试与嵌入式」），并写「选择方式：`llm_confSource`（默认 `database`），可写实现名或 `name:path` 形式」；`src/service/LLMConfSource.cj:153-170` 的 `createConfSource` 只认 `database` / `env` / `file:<path>`，其余一律抛 `unknown llm conf source: ..., available: database / env / file:<path>`；`StaticConfSource`（`:54`）只在测试里通过 `LLMConfs.setHolder` 使用。
- **描述**：按设计把 `llm_confSource` 配成 `static` 会在首次调用时启动失败，且错误信息里的「可用来源」也不含它。对嵌入式/测试场景，文档给了一条实际不存在的选择路径。
- **建议**：要么在 `createConfSource` 里支持 `static`（返回一个从全局注册表读的来源，并在文档里写清注册 API），要么把设计表里 `StaticConfSource` 的说明改成「仅经 `LLMConfs.setHolder` 注入，不参与 `llm_confSource` 选择」。

### [轻微] 提案正文称 `ModelCapabilities` 未进代码，实际已实现并被主路径调用

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/proposal.md:3`、`:24`、`:66`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档结论与实现相反）
- **证据**：静态确定 —— 提案三处都写「`ThinkingCapability` / `ModelCapabilities` … 未实现 / 未进代码」；实际 `src/llm/ModelCapabilities.cj:24-73` 提供 `ModelCapabilities.resolve` / `blocksTemperature` 与 `ThinkingPolicy.apply`，`src/llm/LLM.cj:142`、`:226` 在每次请求构造报文后调用 `ThinkingPolicy.apply`，`ModelCapabilities_test.cj` 覆盖三级解析。
- **描述**：同一变更的 `design.md:351`（verify 修复）已经写明「新增 `ModelCapabilities.resolve()` + `ThinkingPolicy.apply()`」，提案的「状态（2026-10-28）」与偏差表没回填。读者按提案会以为思考能力只能是 `conf.alwaysThinking` 一条规则，从而重复实现或误判线上行为（`deepseek-flash` 恒思考、`embedding-3` 不支持思考都来自这张能力表）。
- **建议**：把提案 `:3`、`:24`、`:66` 改成「`ThinkingCapability` 未实现；`ModelCapabilities` + `ThinkingPolicy` 已在 verify 阶段补齐（见 design §verify 修复）」，避免与 design 结论冲突。

### [轻微] 任务进度在两份文档里不一致：58/63 与 59/64

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/proposal.md:3`、`f_llm/doc/spec/f-llm-openai-compat/tasks.md:5`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（同一变更的文档之间口径不一致）
- **证据**：静态确定 —— 提案写「任务进度 58/63，剩余 9.2–9.6 为其他平台联调」；tasks 写「59/64 完成，5 项 deferred（9.2–9.6）」。按 `tasks.md` 逐条点数：1.x 3 + 2.x 7 + 3.x 10 + 4.x 7 + 5.x 6 + 6.x 10 + 7.x 10 + 8.x 4 + 9.x 7（含 `9.7 腾讯云 tokenhub`）= **64**，deferred 5 项 ⇒ 59 完成，tasks 侧正确，提案侧少了 9.7。
- **描述**：同一变更的两份文档给出不同的完成度，归档核对时分不清哪份是准的；9.7 是后补条目，提案侧没有同步。
- **建议**：提案的进度行改为「59/64（9.2–9.6 deferred）」，或直接删掉数字改为指向 `tasks.md`，避免二次漂移。

### [轻微] `cover-loom-test-gaps` 提案的用例数与文件数与实际不符（4 条 / 4 文件 vs 5 条 / 3 文件）

- **位置**：`f_llm/doc/spec/cover-loom-test-gaps/proposal.md:15`、`:29`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— 提案 `:15` 写「补 4 条用例（第 5 条并发见下）」，`:29` 写「4 个测试文件，新增 5 条用例」；`tasks.md:5-15` 列了 5 条用例，实际分布在 3 个文件：`src/channel/EmailChannel_test.cj:325,337`、`src/loom/LoomContextMemory_test.cj:358,376`、`src/loom/StoreFunctions_test.cj:93`。
- **描述**：「第 5 条并发」的编号暗示 5 条里有 1 条是并发用例，实际第 5 条是附件绝对路径那条，并发用例明确「不补」（design D4）。文件数 4 也多于实际的 3。数字对不上会让归档核对误以为少补了一条用例。
- **建议**：改成「补 5 条用例、涉及 3 个测试文件；并发用例不补（见 design D4）」，删掉容易误解的「第 5 条」编号。

### [轻微] `f-llm-openai-compat/design.md` 有 10 处小节标题粘在正文行尾，附录表格行断裂，另有一处脚本路径不存在

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:292`、`:294`、`:296-300`、`:305`、`:317`、`:323`、`:328`、`:333`、`:338`、`:343`、`:347`、`:355`、`:284`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档可读性 / 链接失效）
- **证据**：静态确定 —— 全文 26 个 `###` 标题里有 10 个不是行首（`:300` `### 非平台联调部分…`、`:305` `### 旧链路迁移…`、`:317` `### deepseek-flash 识图…`、`:323` `### 多模态与 embedding 迁移…`、`:328` `### 旧搜索链路清理…`、`:333` `### Responses 多模态…`、`:338` `### 腾讯云 tokenhub…`、`:343` `### 联调边界…`、`:347` `### verify 修复…`、`:355` `### verify WARNING 修复…`），全部接在上一条 bullet 末尾；`:292` 的表格行尾部直接串了 `|- 工具循环 \`LLMToolLoop\` …`，`:294` 与 `:296` 同样把两条内容并进一行；`:284` 指向的 `.autocode/tmp/fllm_db_test.sh` 在当前工作区不存在（`.autocode/tmp/` 下无 `*fllm*`）。
- **描述**：这些小节是「方言注册、多模态、余额、verify 修复」等关键结论的落点，渲染后不会出现在目录里，读者按目录跳转会漏掉整段；断行还把「工具循环放 tool 包」这类设计原因塞进表格单元格。脚本路径失效则让真库验证无法照做。
- **建议**：把 10 处标题前的空行补齐（标题独立成行），`:292` 的表格行补 `|` 收尾并把后续 bullet 拆出，`:284` 的脚本路径改成仓库内实际位置或注明「临时脚本，不入库」。

### [轻微] 归档规格的「SQL 只出现在 DAO 层」验收场景在归档时已被违反，且未记录例外

- **位置**：`f_llm/doc/spec/archive/2026-10-31-f-llm-store-wiring/specs/llm-store-wiring/spec.md:14-17`
- **来源**：存量（快照模式无基线；`git blame` 依据：`cdea037a40 2026-10-30`）
- **判据**：review-checklist §13（规格与实现漂移；归档变更按「当时结论是否自洽」核对）
- **证据**：静态确定 —— 该场景声明 `PostgresMemoryRepository` / `MySqlMemoryRepository` 源码「不出现 `SELECT` / `INSERT` / `UPDATE` / `DELETE` 字面量」；`src/store/postgres/MemoryRepository.cj:56` 与 `src/store/mysql/MemoryRepository.cj:60`、`:127` 直接 `executor(DRIVER).setSql('DELETE FROM llm_memory_token …')`，注释说明是「DAO 宏对纯 DELETE 方法生成有缺陷」的绕行。这些行由 `cdea037a40` 于 2026-10-30 引入，早于该变更 2026-10-31 的归档，而 `tasks.md:3-4`（0.1/0.2）全部勾选。
- **描述**：归档规格把一个已知不成立的验收标准记为已通过，绕行原因只写在代码注释里。后续按规格做 DAO 迁移的人会以为 Repository 层已经没有 SQL，改动 DAO 宏后也不会去检查这两处直写。
- **建议**：在该 spec 的 Scenario 后补一句例外「纯 DELETE 方法因 DAO 宏缺陷暂由 Repository 直写，待宏修复后移除」，或在归档目录里加一条偏差记录（与 `f-llm-openai-compat/design.md` 的「实现偏差」表同格式）。

### [轻微] 余额金额解析失败静默回落 0.00，与规格「不得返回 0」的口径冲突

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-balance-query/spec.md:49-52`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现不符）+ §11（失败路径被当成成功）
- **证据**：静态确定 —— 规格写「未实现或无法查询的平台 SHALL 抛出明确的『不支持』异常，SHALL NOT 返回 0 或空快照」，并在 `BalanceQuerier.cj:64-66` 的接口注释里重申「余额为 0 与『查不到』是两件事」；但 `src/balance/BalanceUnits.cj:40-47` 的 `parse` 用 `catch(_: Exception){ 0.0f64 }` 吞掉解析失败，`toYuan` 再 `format` 成 `"0.00"`，`BalanceSnapshot.totalValue` 也是 0.0。
- **描述**：上游把金额字段改成对象、带千分位、或返回 `null` 时，快照落成 `0.00` 并参与低余额判断（`BalanceQuerier.cj:135-146`：`totalValue < threshold` 就会告警）——产生**假告警**，把「字段格式变了」误报成「余额耗尽」。这正好违反规格自己写下的区分原则。
- **建议**：`parse` 改成返回 `?Float64`，`toYuan` 在解析失败时抛 `BalanceUnsupportedException`（或带平台与字段名的专用异常），让「查不到」走异常路径；`BalanceMediator.queryAll` 已有按平台 catch 并 `warn` 的逻辑，不会打断其它平台。

### [轻微] `fix-channel-attachment-safety/design.md` D4 标题与自身结论、与实现三者不一致

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/design.md:53-57`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档过期 / 语义与注释不符）
- **证据**：静态确定 —— D4 标题写「净化发生在 `receive` 调用 `save` **之前，而不是 `freeName` 内部**」（`:53`），紧接着的「替代」段却写「两层都净化。**采纳**——`save` 与 `freeName` 都调 `bareName`」（`:57`）；实现与「采纳」一致而与标题相反：`freeName` 第一行即 `bareName(filename)`（`src/channel/EmailChannel.cj:120`），`save` 自身不净化、只经 `freeName` 落盘（`EmailChannel.cj:161`，无直接 `bareName` 调用）。
- **描述**：标题是 D4 的结论行，读者只读标题会以为 `freeName` 依赖调用方先净化，从而在新增调用点重复净化或漏掉净化；而 D4 的正文已经改口，同一段落的结论与理由互相打脸。
- **建议**：把标题改成「净化在 `freeName` 内完成，`save` 只经 `freeName` 落盘」，正文保留「两层都净化」的采纳结论（与代码一致）；顺带说明 `receive` 在调用 `save` 前不做净化。

### [轻微] 已归档变更的 `tasks.md` 里 5.3/5.4 落在「移出本变更」小节下，与移出说明矛盾

- **位置**：`f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/tasks.md:43-58`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（归档文档按「当时结论是否自洽」核对）
- **证据**：静态确定 —— `:43` 的「## 5. 集成与回归」是空节；`:45` 起是「## 移出本变更（由后继变更 `f-llm-store-wiring` 承接）」，只列 5.1/5.2 并给出三条移出原因与后继范围；随后 `:57`/`:58` 又把已勾选的 `[x] 5.3 跑 fboot build + cjpm test 全量`、`[x] 5.4 把 propose 产物同步到 …` 排在同一节末尾，读起来像「5.3/5.4 也被移出」。
- **描述**：5.3/5.4 实际是在本变更内完成的集成与文档同步（`5.3` 的全量回归是该变更的收尾动作），却被排进「移出」叙述里，与 5.1/5.2 的移出结论并列。归档核对时会误以为集成与回归也没做。
- **建议**：把 5.3/5.4 移到「## 5. 集成与回归」节下，或把「移出本变更」改成独立的 `## 6.` 节。

## 优化可行性方案

> 本部分清单全部是 `.md`，不存在可改造的堆内存 / CPU 路径，因此本部分不产出优化方案（堆内存 0 条 / CPU 0 条）。涉及 `f_llm` 代码的优化方案请以第 1、2、4–25 部分的结论为准。

## 待验证假设

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**，仅用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 配置来源故障期间每个请求都同步重试装载（无失败退避），DB 抖动时延迟被按请求数放大 | `src/llm/LLMConfsHolder.cj:111-121`、`:259-261` | `load()` 调用次数、P50/P95 延迟 | 注入必失败的 `LLMConfSource`，10 QPS 跑 10 分钟，统计 `load()` 次数与端到端延迟分布（改前/改后对照，`-O2`） |
| 2 | `candidates()` 每次调用都新建 `ArrayList` 并按 `llmName` 过滤，高 QPS 下有可测的分配与 GC 压力 | `src/llm/LLMConfsHolder.cj:48-64`、`:124-132` | 每秒分配字节、GC 次数与停顿 | `cjprof heap` + 1k QPS 压测，对照「缓存按 llmName 的不可变候选列表」版本 |
| 3 | 「读路径无锁」若成立，快照发布需要原子引用；补原子后的读侧开销是否可忽略，尚未测 | `src/llm/LLMConfsHolder.cj:82`、`:255` | 原子读 vs 普通读的单次开销、`candidates()` 调用频次 | 查仓颉内存模型文档后，用 `cjpm bench -O2` 对照 1e7 次引用读；并发场景再跑 8 线程压测 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/spec/archive/2026-10-30-f-llm-memory-storage/specs/llm-meta-store/spec.md` | .md | ✅ | 归档；13 个预定义人格 key 与 `PredefinedCharacters.cj:85-91` 一致；配置键 `llm_contentStore` 现已被 `StoreSettings.cj:45` 列为废弃键，按归档豁免不判漂移 |
| 2 | `doc/spec/archive/2026-10-30-f-llm-memory-storage/tasks.md` | .md | ✅ | 归档；5.1/5.2 已显式移出并写明三条原因；5.3/5.4 位置问题见 F17；`doc/spec/f-llm-memory-storage/` 目录现不存在（归档后改名），按归档豁免不判死链 |
| 3 | `doc/spec/archive/2026-10-31-f-llm-store-wiring/design.md` | .md | ✅ | 归档；DAO/Repository 分层落地，驱动名与库名解析规则与实现一致；D3 的 `llm_contentStoreDatabase`、D6 的 `llm_embeddingBatch` 在 `src/` 无命中（归档豁免，仅记录） |
| 4 | `doc/spec/archive/2026-10-31-f-llm-store-wiring/proposal.md` | .md | ✅ | 归档；7 条 What Changes 与 design 对应，无内部冲突 |
| 5 | `doc/spec/archive/2026-10-31-f-llm-store-wiring/specs/llm-store-wiring/spec.md` | .md | ✅ | 归档；「SQL 只出现在 DAO 层」场景与归档时代码不符，见 F14 |
| 6 | `doc/spec/archive/2026-10-31-f-llm-store-wiring/tasks.md` | .md | ✅ | 归档；0.x–6.x 全勾选，与 F14 的例外未记录 |
| 7 | `doc/spec/cover-loom-test-gaps/design.md` | .md | ✅ | 与 5 条用例、3 个测试文件一致；D4「并发不补」有理由 |
| 8 | `doc/spec/cover-loom-test-gaps/proposal.md` | .md | ✅ | 用例数/文件数不符，见 F12 |
| 9 | `doc/spec/cover-loom-test-gaps/specs/loom-flow/spec.md` | .md | ✅ | 两条边界语义（空 turns → 0；knowledge 失败 → 返回 2）与 `tasks.md` 用例名对应 |
| 10 | `doc/spec/cover-loom-test-gaps/tasks.md` | .md | ✅ | 5 条用例名在 `*_test.cj` 全部命中 |
| 11 | `doc/spec/f-llm-openai-compat/design.md` | .md | ✅ | 主要设计依据；§5 对外 API 与 mediator 见 F7；`Redactor` 阈值见 F4；快照并发见 F6；错误阶段见 F8；标题粘连与死脚本见 F13 |
| 12 | `doc/spec/f-llm-openai-compat/proposal.md` | .md | ✅ | 进度与能力陈述过期，见 F10、F11 |
| 13 | `doc/spec/f-llm-openai-compat/specs/http-sse-client/spec.md` | .md | ✅ | 与 `f_httpclient/src/sse/SseReader.cj` 一致（多行 data、去一个前导空格、`[DONE]` 原样返回、`SseLineTooLongException` / `SseTimeoutException`、`<: Resource`） |
| 14 | `doc/spec/f-llm-openai-compat/specs/llm-balance-query/spec.md` | .md | ✅ | 快照字段与 `BalanceSnapshot` 一致；多币种各出一条 `BalanceQueriers.cj:91-101`、分→元换算 `:158` 均成立；解析失败口径见 F15 |
| 15 | `doc/spec/f-llm-openai-compat/specs/llm-conf-routing/spec.md` | .md | ✅ | 权重区间 `[1,total]`、`weight<=0` 过滤、按 conf 阈值均与实现一致；装载失败口径见 F5 |
| 16 | `doc/spec/f-llm-openai-compat/specs/llm-context-pruning/spec.md` | .md | ✅ | 8 个策略 + `TokenBudget_<budget>` 与 `ContextPruner.cj` 一致 |
| 17 | `doc/spec/f-llm-openai-compat/specs/llm-protocol-compat/spec.md` | .md | ✅ | 温度缺省、`actualLlmName` 填 `model`、方言回退、`instructions` 映射均一致；`response.failed` 见 F2 |
| 18 | `doc/spec/f-llm-openai-compat/specs/llm-tool-calling/spec.md` | .md | ✅ | 工具命名/64 字符上限/自动循环 8 轮一致；schema 清洗口径见 F1 |
| 19 | `doc/spec/f-llm-openai-compat/tasks.md` | .md | ✅ | 64 项条目与勾选数自洽（59/64，5 deferred）；7.5 对 Redactor 的「更保守」表述见 F4 |
| 20 | `doc/spec/fix-channel-attachment-safety/design.md` | .md | ✅ | D1 净化规则与 `bareName` 一致；D2 的 `isRegular`/符号链接未落地见 F3；D4 标题自相矛盾见 F16 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 错误处理 F2 F8 F15；安全/输入校验 F3 F4；并发与契约 F6 F7；接线缺失 F5 F9；可读性 F13 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可见性可判；改查「文档点名的符号/路径是否仍存在」：20 个文件里点名的符号（`ModelCapabilities`、`StaticConfSource`、`AttachmentSink.isRegular` 等）逐个在 `src/` 检索，命中项按 §13/§14 归类（F3 F7 F9 F10 F13），文档间无「写了但永不触发」的残留条目 |
| §2 重复逻辑 | 0 | 已把 20 个文件的 requirement / decision 段落两两比对：饱和阈值规则在 `llm-conf-routing/spec.md:101-111` 与 `llm-context-pruning/spec.md:29-39` 各表述一次、`weight<=0` 过滤在 `llm-conf-routing` 与 `llm-meta-store`（归档）各一次——均为能力边界复述（checklist §2 误报边界），措辞差异属不同视角，未判重复；同一结论在两份文档给出不同数字/签名的情形归 §13（F7 F11 F12），不重复计为重复逻辑 |
| §3 空实现 | 0 | 检查了全部 TODO/FIXME/占位表述：`fix-channel-attachment-safety/design.md:78-80` 的「附件大小上限本期不做」与 `tasks.md:113` 的「仍未做」都是显式范围声明，不是默认主路径上的空实现；5 项 deferred 平台联调有实现与单测，缺的只是真实联调 |
| §4 栈溢出 | 0 | 文档层无递归结构；文档点名的 `McpToolSource.sanitizeSchema` 递归深度由 MCP server 的 schema 决定，属代码面，记入「范围外提示」 |
| §5 OOM | 0 | 文档给出的容量约束齐全：`webFetch` 256 KiB（`LLMConfig.cj:196`）、SSE 单行上限、`llm_embeddingBatch`；未发现「按不可信长度预分配」的文档承诺缺口 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，任何热点结论都不成立；三条疑似点已写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 文档描述的是无锁快照 + 单飞刷新（`design.md:140-142`），不涉及锁内 I/O；其并发正确性另见 F6 |
| §6.3 并发串行 | 0 | 设计明确「流式采用同步回调，模块不 spawn、不建线程池」（`design.md:200`），无并发串行段可判 |
| §6.4 低效算法 | 0 | 文档层无算法描述可判复杂度；`TokenBudget` 裁剪、权重调度均为 O(n) 遍历 |
| §7 降堆内存方案 | 0 | 本部分为 `.md`，无堆对象可改；无基线数据，按要求不产出方案 |
| §8 降 CPU 方案 | 0 | 同上；无 `cjpm bench` / `cjprof` 数据 |
| §9 local mode 可行性 | 0 | 文档未承诺 local mode 改造；本部分无函数级临时对象可评估 |
| §11 现有代码的 BUG（存量） | 5 | 顺文档链路核到的存量代码缺陷：F2（错误码丢失）、F5（首载失败只记日志）、F8（阶段信息缺失）、F15（解析失败回落 0.00），以及 F3 的特殊文件放行 |
| §12 并发安全与锁粒度 | 1 | F6 快照引用发布无同步（待确认语言内存模型）；其余文档描述的并发点（单飞刷新、按 llmName 缓存调度器、熔断表）均有明确同步手段 |
| §13 文档一致性 | 10 | F1 F4 F7 F10 F11 F12 F13 F14 F16 F17（F3、F15 同时计入 §11，不重复计） |
| §14 功能完备性与 README 覆盖 | 1 | F9（`static` 来源无配置入口）；5 项 deferred 平台联调已在 `tasks.md` 显式标注，不算隐藏缺口；README / README_en 覆盖属第 1–2 部分范围，本部分不重复统计 |
| 文件覆盖（§13 等） | 20/20 | 无缺项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分 20 个文件全部是 `f_llm/doc/spec/**` 下的变更规格与设计文档，文档本身结构完整、理由写得很足（每条决策都带「替代方案 + 否决原因」，实测数据也回填了），主要问题不是「缺文档」，而是**文档与代码、文档与文档之间的口径已经分叉**：

- 阻塞级问题没有（0 条严重）。7 条一般项里，四条有实际后果：`response.failed` 丢了上游错误码（排障时只剩一句 `response.failed`）、`Redactor` 的掩码阈值比设计承诺更松（9–11 位密文几乎全露）、配置装载失败只记日志且无退避（配置源故障期间每个请求都要付一次失败查询，真实原因又不出现在调用方异常里）、`design.md` §5 的对外 API 与 `LLMContextMediator` 仍写着已不存在的类型（照文档写代码直接编译失败）。附件校验缺 `isRegular`/符号链接判定属安全加固的收尾缺口；MCP schema 清洗口径是规格没跟上 10-28 的设计修正。
- 文档侧最值得优先处理的是 `f-llm-openai-compat/design.md`：它同时保留「正文」与「附录（实现偏差）」两套事实源，而正文没回填——§5 签名、`LLMContextMediator` 去留、Redactor 阈值三处与实现相反，附录又因 10 处标题粘连而无法按条引用。改文字成本极低，但它是全文档被下游引用最多的一份。
- 快照发布无同步（F6）需要先确认仓颉内存模型再定性，若与 Java 普通引用一致，则设计「读路径无锁」的承诺不成立，应按并发缺陷处理（当前按「待确认」定为一般，不定严重）。
- 归档规格里那条「SQL 只出现在 DAO 层」的例外应在归档目录留痕，否则下一轮 DAO 迁移会再次踩到纯 DELETE 的宏缺陷；归档 tasks 的 5.3/5.4 位置（F17）顺手一起修。
- 轻微项集中在文档卫生（标题粘连、进度数字、用例计数、失效脚本路径、D4 标题），一次批量整理即可，不影响使用。

本部分问题共 17 条（一般 7 / 轻微 10），来源全部为「存量」（工作区快照无基线），是否纳入修复待用户决定。

**范围外提示**（不计入本部分统计）：
1. `src/mcp/McpToolSource.cj:126-152` 的 `sanitizeSchema` 对 MCP server 返回的 schema 做无深度上限的递归，schema 由外部 server 控制，存在栈溢出面（§4）。
2. `src/llm/LLMConfs.cj:52-56` 的 `catch(_: Exception){}` 静默吞掉 MetaStore 装配异常，回退到旧来源时没有任何日志（§3）。
3. `src/balance/BalanceQuerier.cj:164` 的 `LLMConfig_balanceLowThreshold()` 全仓无调用者（§1 死代码）。
4. `src/llm/LLMConfsHolder.cj:104-108` 的 `version` 属性读的也是未同步快照，若 F6 成立，该属性同样需要一并处理。
5. `src/embedding/HttpEmbedder.cj:58-74` 用 `cachedText` / `cachedResponse` 做单槽缓存，无同步；该实例经 `Stores` 共享时，两个线程用不同文本调用可能读到对方文本的向量（§12.1）。
6. `src/llm/ContextPruner.cj:291` 的 `RetainLastNRoundPruner.prune` 直接取 `messages[messages.size - 2 * n ..]`，消息数 < 2n 时起点为负会抛越界（§11）。
7. `src/store/MetaStoreAdapter.cj:23-24` 类注释写「没有匹配时回退到 f_store」，而同文件 `:30-33` 与 `init` 明确「不做无条件兜底」（注释与实现相反，§11）。

# f_llm 模块审查报告（模块第 12/25 部分）

> 本文件是 `f_llm` 模块拆分为 25 个子轮后的**第 12 部分**分报告，仅覆盖本部分文件清单内的 20 个 `.cj`；「文件覆盖」「覆盖自检」「模块统计」均只统计本部分，模块级结论由主 Agent 合并。
>
> 本版在同一路径上合入了前一轮（同日 13:19）的分报告结论，并补齐了客户端超时、空响应、重复逻辑三类此前缺失的取证；编号已统一，旧的「严重 #3/#4」等编号以本版为准。

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个源文件，全部 `.cj`）
- **本部分范围**：`src/llm/` 下的门面 / 配置快照 / 熔断 / 上下文裁剪 / 流式累加器 / 传输抽象（文件清单见「文件覆盖」）
- **基线**：工作区快照（`git status` 仅有未跟踪的 `docs/review/`、`reviews/`；源码无 diff）⇒ 本部分所有问题来源均为「存量（快照模式无基线）」
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v2（分报告，不单独产出 `docs/review/` 模块报告）

## 发现

### [严重][存量] 流式传输无条件 `CertificateVerifyMode.TrustAll`：模型 API Key 暴露给中间人

- **位置**：`f_llm/src/llm/LLMStreamTransport.cj:48-50`（`DefaultStreamTransport.stream`）；同根因见范围外 `f_llm/src/llm/LLMTransport.cj:46-48`
- **来源**：存量（`git blame` `LLMStreamTransport.cj:49` → `ce62d320ef` 2026-10-27，快照模式无 diff）
- **判据**：review-checklist §10 安全性；§11「契约与实现不符」
- **证据**：静态确定 —— `var tls = TlsClientConfig(); tls.verifyMode = CertificateVerifyMode.TrustAll; client.tlsConfig(tls)` 对**任意** URL 生效，没有按 host 判断回环地址的分支，也没有配置开关；同一个客户端随后把 `dialect.headers(conf)`（含 `Authorization: Bearer <api key>`，`openai/DeepSeekDialect.cj:50-53`）发出去
- **描述**：所有流式（以及非流式）请求都在关闭证书链校验的 TLS 通道上进行。攻击者只要能劫持 DNS / 出口代理，即可用任意自签证书完成中间人，拿到 Provider 的 apiKey 并读写全部对话内容；失败方式完全静默（请求照常成功）。项目内已有可配置写法（`f_mvc/src/MVCConfig.cj:90-104` 的 `TLS_VERIFY_MODE`：default / customCA / trustAll），f_llm 没有对齐。
- **建议**：新增 `llm_tlsVerifyMode`（默认 `default`，可选 `customCA` + PEM、`trustAll`），在两个 transport 构造 client 时按配置设置；只允许显式配置才关校验。若短期不改配置体系，至少只在 `127.0.0.1` / `localhost` / `::1` 才 `TrustAll` 并抽成带注释的函数。

### [严重][存量] 客户端没有自己的超时，且会被 embedding 设置的 3s 全局读超时接管

- **位置**：`f_llm/src/llm/LLMStreamTransport.cj:43-50`、`f_llm/src/llm/LLMTransport.cj:41-48`（范围外，同一模式）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「资源与契约：超时缺失」/ §6.1（I/O 等待）；`fountain-baseline` §8
- **证据**：静态确定 —— `f_httpclient/src/httpclient.cj:29-36` 定义进程级 `readTimeout_` / `writeTimeout_`，`:41-48` 在**构造函数**里套用；`f_llm/src/embedding/BgeM3Transport.cj:62-65` 每次 `embed()` 都把这两个静态值改成 `timeoutMs`（默认 3000ms，`:48`）且从不复位。两处 LLM transport 都不调用 `client.readTimeout(...)` / `writeTimeout(...)`
- **描述**：同一进程内只要发生过一次向量化，之后新建的 chat 客户端读/写超时就是 **3 秒**——`llm_streamIdleTimeout`（默认 120s，`f_llm/src/config/LLMConfig.cj:177-179`）在 socket 层被 3s 覆盖，SSE 首 token 或长回答的停顿超过 3s 就会读超时，被 `LLMErrorClassifier` 判为可重试后换平台重发或整体失败。反过来，没走过 embedding 的进程则**完全没有**读/写超时：对端接受连接后不响应，调用线程会一直被占住（`AgentTask.cj:424-435` 的 `maxElapsed` 只在两次尝试之间检查，无法打断进行中的调用）。
- **建议**：两个 transport 都显式设置超时：非流式用 `llm_requestTimeoutMs`，流式用「连接/首包超时 + `llm_streamIdleTimeout`」；`BgeM3Transport` 改用 per-client `client.readTimeout(...)`，不要改进程级 static。

### [严重][存量] `RetainLastNRoundPruner.prune` 短会话负下标切片，直接抛 `IndexOutOfBoundsException`

- **位置**：`f_llm/src/llm/ContextPruner.cj:290`（`let last = messages[messages.size - 2 * n ..]`）
- **来源**：存量（`git blame` `ContextPruner.cj:290` → `4be871f2fd` 2026-10-02，快照模式无 diff）
- **判据**：review-checklist §11「边界差一 / 越界」；`std.collection` 文档 `ArrayList` 的 `operator func [](Range<Int64>)`：「range 无效时抛 `IndexOutOfBoundsException`」
- **证据**：静态确定 —— 只要 `messages.size < 2 * n`（默认 `n = 1`，即**只有 1 条消息的首轮请求**，或空列表），`start` 为 `-1` / 更小；没有 `size <= 2*n` 的短路分支（对比 `LastNContextPruner:51` 就做了 `size > n*2` 判断）
- **描述**：这是裁剪策略里唯一没有做长度保护的实现。一旦被注册并写进 `agent.conf['pruner']`，首轮会话（只有一条 user 消息）必然崩溃；崩溃点在 `AgentTask.cj:412` 的主路径上（裁剪先于调模型），外层无 try。测试只覆盖 6 条消息（`ContextPruner_test.cj:107-113`）。
- **建议**：`let start = if(messages.size > 2 * n){ messages.size - 2 * n } else { 0 }`，或 `if(messages.size <= 2 * n){ return msgs }`；`n <= 0` 一并校验；补「空列表 / 1 条 / 恰好 2n 条」三个用例。

### [严重][存量] 流式中途失败后换平台重放，`onDelta` 已吐出的内容会重复

- **位置**：`f_llm/src/llm/LLM.cj:231-254`（try 覆盖 `236-247` 的 `onDelta` 调用；`catch` 后 `continue`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理」/ §12.1「异步语义」；类注释 `LLM.cj:202-207` 承诺「中途异常包成 `LLMException` 并带 requestId 与阶段信息」
- **证据**：静态确定 —— `onDelta` 在 transport 回调里同步调用（`:239-245`）；任何后续异常（读中断、`SseTimeoutException`、**`onDelta` 自身抛错**）都进 `catch`（`:248`）→ `continue` 换下一个候选；下一个候选新建 `ChatStreamAccumulator()`（`:228`）从零开始，再次从头回调 `onDelta`。调用方没有任何「重置」信号
- **描述**：用户会看到「候选 A 的前半段 + 候选 B 的完整段」拼在一起，正文/推理/工具参数三路都受影响；调用方回调抛异常（客户端断开、UI 报错）也会被误判成传输失败并**重发整次请求**（重复计费）。若两次都失败，最终异常里也不含已吐出内容的信息。当前仓内 `chatStream` 只被测试调用（`LLMStream_test.cj:165,187`），但它是公开入口，下游一旦使用即触发。
- **建议**：(1) 一旦有 delta 吐出就把该次请求标记为「不可转移」，失败时抛带 `partial=true` / `emittedDeltas` 的 `LLMException`；或 (2) 在 `LLMHooks` 加 `onRestart` 回调由调用方清屏。另外把 `onDelta` 调用移出 try（或置标志后重抛），避免把调用方缺陷归到网络故障。

### [严重][存量] `previewOf` 按字节切 400，落在多字节字符边界上抛 `IllegalArgumentException`

- **位置**：`f_llm/src/llm/LLM.cj:288-293`（`body[0 .. 400] + '...'`），调用点 `:155`
- **来源**：存量（快照模式无 diff）
- **判据**：`std.core` 文档：`String.size` 是 UTF-8 字节长度，`operator func [](Range<Int64>)`「起止点不是字符边界抛 `IllegalArgumentException`」；review-checklist §11「错误处理」
- **证据**：静态确定 —— 上游错误体（DeepSeek / 智谱等中文平台）通常是中文 JSON，`body.size > 400` 时第 400 个字节有约 2/3 的概率落在某个 3 字节汉字中间；该行位于 `LLMErrorClassifier.isRetryable(status)`（`:156`）**之前**
- **描述**：两个后果：① 429/5xx 这类本该换平台重试的失败，因为构造错误消息时抛异常而直接终止整次调用；② 异常类型从 `LLMException` 变成 `IllegalArgumentException`，`AgentTask` / `Memory` / `fprobe` 里 `catch (ex: LLMException)` 的调用方接不到。表现为「偶发、不可复现的 500」。
- **建议**：字符安全截断（按 rune 取前 N 个字符，或把端点回退到最近的 UTF-8 字符边界）；并把 `previewOf` 包进 try，失败时返回 `'<unprintable>'`，保证「构造错误消息」永不抛异常。补一条「中文错误体 + status=500 仍能转移到下一个候选」的用例。

### [一般][存量] 配置快照 `snapshot` 一处无锁写、多处无锁读，跨线程无同步手段

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:255`（写）↔ `:112`（`ensureFresh` 读）、`:104-108`（`version`）、`:126`、`:131`、`:171`、`:191`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性 / 发布逸出」
- **证据**：静态确定（无任何锁 / 原子 / 通道）+ 待确认（仓颉语言层对普通字段跨线程可见性的保证：本地文档只查到「原子操作、互斥锁、条件变量」三种同步机制，见 `md/doc/concurrency/sync.md:1-5`，未见通用内存模型章节）——`mutex` 只保护 `refreshing`（`:225-229`、`:261-264`），`snapshot = LLMConfsSnapshot(...)` 在 `synchronized` 块**之外**执行
- **描述**：刷新线程把新快照写进普通字段，读线程（每次 `candidates/all/peekNext` 入口）无同步读取。没有 happens-before 就没有「读到新版本」的保证；弱内存序平台（ARM）上还可能读到「引用是新的、内部字段未完全可见」的中间态。该类注释自称「刷新整体替换快照，读路径无锁」（`:29`、`:75`），但并未给出无锁发布的安全手段。
- **建议**：`snapshot` 改成 `AtomicReference<LLMConfsSnapshot>`（`std.sync` 文档确认提供 `load/store/compareAndSwap`），一个原子读 + 一个原子写即可获得发布语义，读路径依然无锁；或把读写都放进 `mutex`（成本是每请求一次短锁，需与 §6.2 的竞争一起评估）。

### [一般][存量] 刷新版本号取自调用方捕获的旧快照，可能写出重复版本，balancer 继续持有已下线的 conf

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:111-117`（`refresh(current)`）→ `:255`（`old.version + 1`）、`:189-194`（`balancersVersion != snapshot.version`）、`:215-218`（`balancer.add(chosen.weight){_ => chosen}`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」/ §11「并发正确性」
- **证据**：静态确定（需特定交错，窗口窄）—— `ensureFresh` 先读 `let current = snapshot`（`:112`）、判断 TTL（`:113`）、再 `refresh(current)`（`:116`）。线程 C 在 `:113` 之后被抢占、线程 A 完成一次刷新写出 v2，C 恢复后仍以 `old = v1` 落盘 `v2 = 1 + 1`：版本号重复，但内容是新加载的
- **描述**：`balancerFor` 用 `balancersVersion != snapshot.version` 判断是否重建（`:191`），版本号重复 ⇒ 缓存不失效 ⇒ `LoadBalance` 里 `{_ => chosen}` 闭包捕获的仍是上一份快照的 `LLMConf` 对象（`:215-218`）。之后 `peekNext` 会把**已删除 / 已停用 / url 已改**的 conf 返回给 `LLM.callByName`，请求打到旧端点（旧 key）；`conf.id` 若已不存在，熔断计数还会记到幽灵 id 上。
- **建议**：刷新成功时按「写入那一刻的当前版本」生成版本号（与 `refreshing` 同一把锁内完成），或用单调递增计数器；`balancerFor` 改为按快照引用相等判断重建，彻底不依赖版本号。

### [一般][存量] 熔断只挂在 `*ByName` 入口，流式与直接传候选的调用完全不更新熔断状态

- **位置**：`f_llm/src/llm/LLM.cj:208-285`（`stream` 里没有任何 `hooks` / breaker 调用）、`:68-82`（`chat`/`respond` 构造空 `LLMHooks()`）、`:123-126`（只有 `callByName` 建了真钩子）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「契约与实现不符」/ §14.1「接线缺失」；类注释 `LLM.cj:84-89`「选号、熔断、失败转移在这里串起来」、`CircuitBreaker.cj:29`「流中断」也算可重试失败
- **证据**：静态确定 —— 全仓 `grep onRetryableFailure|recordRetryableFailure` 的调用点只有 `LLM.cj:148,157` 与 `Embedding.cj:77,83`；`stream()` 的 `catch`（`:248`）只写 `lastError`，不记录失败，成功返回前也不回写成功；`chatStream/respondStream` 只要调用方自备 `candidates` 就绕开 `chatByName` 的选号与熔断。`LLM.chat(candidates, …)` 的唯一生产形态是 `LLMToolLoop.run`（`tool/LLMToolLoop.cj:43,49`），而该循环本身仓内也只有测试引用
- **描述**：一个持续 5xx/断流的平台，只要流量走流式或自备候选，就永远不会被熔断，也不会被 `peekNext` 跳过——与 `CircuitBreaker` 文档承诺的「流中断计入」相反。当前仓内这两条路径无生产调用者（`chatStream` 仅测试），属设计缺口而非现行故障，但对外是公开 API。
- **建议**：把钩子下沉到 `call`/`stream` 的公共层；补 `chatStreamByName/respondStreamByName`；`stream` 的 `catch` 与 `status>=400` 两个可重试分支调 `onRetryableFailure`，成功返回前调 `onSuccess`。

### [一般][存量] 流被提前截断（无 `[DONE]`、无 `finish_reason`）仍按成功返回

- **位置**：`f_llm/src/llm/LLM.cj:267-272`（直接 `chatAccumulator.result()` 返回）；`f_llm/src/llm/ChatStreamAccumulator.cj:135-172`（`result()` 不检查 `done`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「失败路径当成功」/ §3「静默」
- **证据**：静态确定 —— `ChatStreamAccumulator` 只在 `feed` 收到 `[DONE]` 时置 `done`（`:59-62`），`finished` 属性（`:47-51`）在 `LLM.stream` 里**从未被读取**；`result()` 无论 `done` / `finishReason` 是否为空都照常拼出 `LLMResp`
- **描述**：服务端在 `[DONE]` 前正常关闭 TCP（或代理按字节截断）时，`SseReader.next()` 返回 `None`、`stream()` 拿到 `<400` 状态码、`result()` 返回半截正文，`finishReason` 为空、`usageEstimated=true`。调用方无法区分「模型说完了」和「流被截断」；工具调用参数可能只收到一半（`arguments` 截断后 JSON 非法，却仍被当作合法工具调用下发）。
- **建议**：`result()` 或 `LLM.stream` 收口处校验：`!finished && finishReason.isEmpty()` ⇒ 抛 `LLMException(phase: 'truncated')`（或至少在 `LLMResp` 置 `truncated` 标记）；工具调用场景额外校验每个 `arguments` 能被 `JsonValue.fromStr` 解析。

### [一般][存量] 单个非法 SSE 帧就让整条流作废；同一帧里 `content` 与 `tool_calls` 共存时静默丢弃工具调用

- **位置**：`f_llm/src/llm/ChatStreamAccumulator.cj:63`（`JsonValue.fromStr(data).asObject()` 无保护）、`:84-98`（`content` 非空即 `return`，`tool_calls` 分支在其后）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理缺失」/「部分输入被静默丢弃」
- **证据**：静态确定 —— `feed` 的解析没有任何 `try`，`data` 为空串、非 JSON、JSON 不是对象（如 `data: true`）都会抛异常；异常沿 `onData` 冒到 `LLM.stream` 的 `catch`（`:248`）→ 换平台重放（叠加严重 #4 的重复输出）。`mergeDelta` 的判定顺序是 `content` → `reasoning` → `tool_calls`，每帧最多返回一种增量
- **描述**：① 一个坏帧 = 整条流从头再来一次（或整次失败），而 SSE 里偶发空 `data:` 很常见；② 少数实现会在同一帧里同时下发 `content`（或 `reasoning_content`）与首个 `tool_calls` 增量（带 `finish_reason: tool_calls`），此时工具调用片段被丢弃，最终参数缺失或残缺，出错方式还是隐式的
- **建议**：`feed` 内对解析失败降级为 `None` 并记一次 `warn`（带 requestId 与预览，不中断流）；`mergeDelta` 改为「先收集本帧所有增量，再统一上报」，至少保证 `tool_calls` 在任何早退之前处理。

### [一般][存量] `enabled` 开关只在数据库来源生效，`file:` / `env` 配置下停用的平台仍参与调度

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:237-250`（只过滤 `isPlaceholder`）、`:49-57`（只过滤 `weight > 0`）；来源侧 `f_llm/src/service/LLMConfSource.cj:67-71`（static）、`:92-95`（file）、`:121-146`（env）、`:99-120`（`parseConfJson`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」/ §14.1「接线缺失」；承诺源 `f_llm/doc/spec/f-llm-openai-compat/specs/llm-conf-routing/spec.md:41-43`「系统 SHALL 只装载 `enabled = true` 且 `weight > 0` 的配置」
- **证据**：静态确定 —— `LLMConf.enabled` 字段存在（`f_llm/src/model/po/LLMConf.cj:86-87`）；`enabled` 过滤只写在 SQL 里（`f_llm/src/dao/LLMConfDAO.cj:33-36`、`dao/postgres/MetaDAO.cj:58,72`、`dao/mysql/MetaDAO.cj:58,72`），`FileConfSource` / `EnvConfSource` / `StaticConfSource` 原样返回全部行，`parseConfJson` 也不看 `enabled`；holder 这一层是唯一的公共收口，却只判 `isPlaceholder` 与 `weight > 0`
- **描述**：用 `llm_confSource = file:...` 或 `env` 部署时，把一条配置改成 `enabled = false`（典型的「临时下线这个 key」）不会生效，只要 `weight > 0` 就继续分流。与 spec 的过滤器契约不一致，运维会以为已经摘掉。
- **建议**：在 `refresh` 的装载循环里补 `if(!conf.enabled){ dropped++; continue }`（复用现有 warn），并在 `LLMConfsSnapshot.candidates/all` 注释里写清「enabled 由装载层统一过滤」，避免两处判据漂移。

### [一般][存量] 刷新失败后不退避：每个请求都会重新 `load()` 一次配置源

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:111-117` + `:224-266`（失败只 `log.error`，不动 `loadedAt` / `version`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §6.1（I/O 等待）/ §11「错误处理缺失」；`mem §5.2`（重试风暴）
- **证据**：静态确定 —— 失败路径（`:259-261`）保留旧 `snapshot`（`loadedAt` 仍是上次成功时间），`ensureFresh` 的判据是 `MonoTime.now() - current.loadedAt < refreshInterval`，因此**下一次访问立刻再次过期**；`refreshing` 只保证同一时刻只有一个线程在 load，不阻止「上一个刚失败、下一个立刻再试」
- **描述**：数据库/文件不可用期间，每次 `candidates/all/peekNext`（即每个 LLM 请求，含 `AgentTask.cj:424-440` 的重试链）都会触发一次完整的 `source.load()`（可能是全表扫描或文件读），把故障放大成「DB 不可用 + 每请求一次连通超时」，日志按请求量刷 error。首次装载就失败（`version == 0`）时更严重。
- **建议**：失败时记录 `nextRetryAt = now + min(cooldown, refreshInterval * 2^n)`（指数退避，上限可配），`ensureFresh` 同时检查它；或失败时把 `loadedAt` 前推到 `now - refreshInterval/2`，把重试间隔至少拉到半个周期。

### [一般][存量] `SaturationContextPruner` 的默认 conf 选择器取「全局第一条」，与「阈值按 conf 取」的契约矛盾且结果不稳定

- **位置**：`f_llm/src/llm/ContextPruner.cj:196-203`（`defaultConfSelector` 取 `LLMCandidateProvider.candidates()[0]`）、`:182-193`（`prune` 用它的 `tokenThreshold`）；`f_llm/src/llm/LLMConfsHolder.cj:59-67`（`all()` 遍历 `byId` 这个 `HashMap`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「语义与注释不符」；类注释 `ContextPruner.cj:158-163`「阈值按 conf 取（评审 B4），不再跨平台取最小值」、`AgentTask.cj:70-74`「可以用 agentId 查询到智能体使用的大模型，进而确定饱和 token 数」
- **证据**：静态确定 —— `LLMCandidateProvider.candidates()` 返回 `LLMConfs.holder().all()`，`all()` 不看 `llmName`，只按 `weight > 0` 过滤后遍历 `HashMap<Int64, LLMConf>`；`HashMap` 迭代顺序不保证稳定。`prune(agentId, session, messages)` 签名里也没有 `llmName`，拿不到「本次请求真正会用到的 conf」，`agentId` 一路传进来却完全没用
- **描述**：饱和裁剪实际用的是「某个任意平台 / 某个任意模型」的 `tokenThreshold`：可能是 embedding 或另一条 chat 配置的阈值，也可能每次进程重启都换成另一个。填小 → 每轮白裁一次（多砍上下文，甚至丢关键历史）；填大或缺 `tokenThreshold` → 该裁不裁，直接把超长上下文发给上游拿 400。
- **建议**：把选择器参数化到「本次请求的 conf」——`prune` 增加 `llmName` / `conf` 形参，或由 `AgentTask` 在调用前把候选 conf 注入 `SaturationContextPruner`；默认实现若保留，至少固定成「按 llmName 排序后取第一条」并写进注释。

### [一般][存量] `RetainLastUserPruner` / `RetainLastNRoundPruner` 就地修改内层返回的列表（可能就是调用方入参）

- **位置**：`f_llm/src/llm/ContextPruner.cj:274`（`msgs.add(lastUser.getOrThrow())`）、`:295`（`msgs.add(all: last)`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「副作用不对称」/ §12.1「共享可变状态」
- **证据**：静态确定 —— 内层 `ContextPruner` 有多个实现直接 `return messages`（`RetainContextPruner:34-36`、`LastNContextPruner:53-55` 的未超限分支、`SaturationContextPruner:192` 的未触发分支），此时 `msgs` 与入参是同一个 `ArrayList` 实例，`add` 会改到调用方持有的列表上；`ArrayList` 切片返回新对象（`std.collection` 文档：「切片操作返回的 ArrayList 为全新的对象」），所以只有「原样返回」的实现会中招
- **描述**：`AgentTask.cj:412-413` 把 `params.messages` 传进去又接回同一个变量，当场看不出问题；但任何缓存/复用同一份 `messages` 的调用方（例如多轮重试复用同一 `params`）每裁剪一次就会往自己的列表尾部追加一份「最后一条 user」/「最后一轮」，消息数随调用次数单调增长，直到超上下文。这也让「裁剪」变成非纯函数，难测试。测试用的是 `LastNContextPruner(n: 0)`（返回副本），未覆盖。
- **建议**：两个装饰器都先复制（`let out = ArrayList<ChatMessage>(msgs); out.add(...)`）再返回；或在接口注释里写死「装饰器不得原地改内层结果」，并补一个「内层返回入参」的用例断言入参长度不变。

### [一般][存量] `ContextLLMPruner.prune` 取「最后一条消息」无保护，并强改其 role

- **位置**：`f_llm/src/llm/ContextPruner.cj:72-74`（`let msg = msgs[msgs.size - 1]; msg.role = ROLE_USER; return msgs`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「空集合未处理」/「语义与命名不符」
- **证据**：静态确定 —— `ChatCompletionsMapper.parse`（`:147-163`）只在 `choices` 非空且带 `message` 时 `appendMessage`，上游返回 `choices: []`（内容审核拒绝、空响应）时 `LLMResp.messages` 为空，`msgs[-1]` 抛 `IndexOutOfBoundsException`；`msg.role = ROLE_USER` 是对**解析出来的消息对象**的就地改写，该对象还带着上游的 `reasoning_content`、`tool_calls`
- **描述**：摘要/关键词裁剪在上游返回空 choices 时会崩在裁剪里，而不是给出可诊断的错误；把 assistant 消息改标成 user 后，如果这条消息带 `tool_calls`，后续请求会出现「user 消息带 tool_calls」的非法报文（OpenAI 协议要求 `tool_calls` 只出现在 assistant 上）。
- **建议**：`if(msgs.isEmpty()){ return ArrayList<ChatMessage>() }`（或抛带 provider/model 的 `LLMException`）；返回时新建一条 `UserMessage` 承载内容，而不是复用解析出的对象。

### [一般][存量] 非流式 200 响应体不是 JSON 对象 / `choices` 为空时，异常不包装、空消息直落下游

- **位置**：`f_llm/src/llm/LLM.cj:164-168`（`JsonValue.fromStr(response.body).asObject()` 无 try）；`f_llm/src/llm/ChatCompletionsMapper.cj:147-158`（空 choices 返回空 `messages`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理」/「失败路径当成功」；§10 契约
- **证据**：静态确定 —— 解析不在任何 try 内，且 `result` 的 `messages` 可能为空；`call` 的注释只承诺「可重试状态码或传输异常 → 换下一个候选」「其余 4xx 立即抛出」
- **描述**：三种现实情况都走不到正常失败路径：① 网关/WAF 返回 200 + HTML、模型下线返回纯文本 → 抛原生解析异常，既不是 `LLMException` 也不会转移；② 上游返回 JSON 数组 → `asObject()` 抛错，同上；③ 200 + `choices: []`（审核拦截/空响应）→ 返回一个 `messages` 为空的 `LLMResp`，被当成成功，下游 `messages[0]`（`f_llm/src/memory/Memory.cj:70`）与 `ContextLLMPruner:73` 再崩一次，堆栈离真实原因很远。
- **建议**：解析包 try，失败转成可重试的 `LLMException`（带 status 与 `previewOf(body)`）；`messages` 为空时按「上游未返回内容」失败，或在 `LLMResp` 显式标记 `empty` 让调用方判断。

### [一般][存量] 饱和阈值判定在两处各写一遍，且口径已经分叉

- **位置**：`f_llm/src/llm/ContextPruner.cj:182-193`（`SaturationContextPruner.prune`）↔ `f_llm/src/llm/LLMConfsHolder.cj:139-146`（`saturated`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「跨层复制 / 只改类型名」
- **证据**：静态确定 —— 两处都是「`threshold = conf.tokenThreshold`；`threshold <= 0` 返回 false / 不裁；`HeuristicTokenCounter().count(conf, messages) >= threshold`」；差别只有返回类型（`Bool` vs 直接返回裁剪结果）和 conf 来源。`grep saturated` 显示 holder 版本只被测试调用（`LLMByName_test.cj:138-140`），生产走 pruner 版本
- **描述**：同一业务判据两份实现。`HeuristicTokenCounter` 换算法、`tokenThreshold` 改成「占比」或加 0.9 折算时很容易只改一处——这正是两者现在已经分歧的起点（一个用调用方传入的 conf，一个用全局第一条 conf，见上一条）。另外 `TokenCounter` 约定「无法计数返回 -1、由调用方决定」（`TokenCounter.cj:28-29`），这两个调用点都没有处理 -1。
- **建议**：保留 `LLMConfsHolder.saturated(conf, messages)` 作为唯一实现，`SaturationContextPruner.prune` 改为调用它；同时补「`count` 返回 -1 时按 0.9 折算或保守不裁」的分支。

### [一般][存量] `LLMCandidateProvider.defaultSupplier` 吞掉所有异常返回空列表，裁剪阈值静默失效

- **位置**：`f_llm/src/llm/LLMCandidateProvider.cj:37-44`（`try{ LLMConfs.holder().all() }catch(_: Exception){ ArrayList<LLMConf>() }`）；`f_llm/src/llm/LLMConfs.cj:52-57`（同类静默回退，无日志）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §3「`catch` 静默吞异常」
- **证据**：静态确定 —— 失败路径既无日志也无标记，返回空列表；唯一生产消费者是 `ContextPruner.cj:196-203` 的 `defaultConfSelector`，`list.isEmpty()` ⇒ `None` ⇒ `SaturationContextPruner` 直接返回原消息（`:183-191`）。`LLMConfs.createHolder` 的 MetaStore 分支失败时也静默掉到旧来源，同样无日志，可能读到与 MetaStore 不同的一份配置（split-brain）
- **描述**：配置库瞬时不可用 / `LLMConfs.holder()` 初始化抛异常时，饱和裁剪会被静默关闭，随后超长上下文打上游拿 400；排障时日志里只有 `LLMConfsHolder` 的 error，看不出「裁剪因此被跳过」。这也与「无法计数返回 -1」的显式约定相反——这里选择了「假装没有候选」。
- **建议**：两处 `catch (e: Exception)` 都记 `warn`（带 `e`）后再回退；`defaultConfSelector` 在 `None` 时记 `debug`「saturation pruner skipped: no conf」。

### [一般][存量] `max_tokens` 默认 65536 且无条件写进每个请求报文，没有任何按模型收敛的逻辑

- **位置**：`f_llm/src/llm/LLMParams.cj:31`（`private var max_tokens: Int64 = 65536`），序列化点 `f_llm/src/llm/ChatCompletionsMapper.cj:37`（`JsonValue.from(params.toData())` 整对象转 JSON）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」/ §14.1「半成品：只支持部分输入」/ §1「读了不用」
- **证据**：待确认（需一次真实请求确认上游是否拒绝）—— 代码层静态可见：`grep max_tokens` 在 `f_llm/src` 只命中定义处，`ChatCompletionsMapper` / `ResponsesMapper` / `ModelCapabilities` / `ProviderDialect` 都没有读取或裁剪它；`JsonValue.from(params.toData())` 会把所有字段（含默认值）转成报文，因此 `max_tokens: 65536` 会出现在每个非流式与流式请求里
- **描述**：多数平台的 `max_tokens` 上限远低于 65536（DeepSeek 8192、GLM-4 4096 量级）。若上游严格校验，所有请求会在 400 上失败并触发整串候选转移；若上游只做截断，则该字段等于永不起作用，用户也无法通过配置表达「本次最多要多少 token」——两种情况下这个默认值都没有实际意义。
- **建议**：默认改为不发送（`max_tokens <= 0` 时 `body.remove('max_tokens')`），由 `ModelCapabilities` / `LLMConf.conf['maxTokens']` 提供按模型上限收敛（`min(请求值, 模型上限)`）；补 mapper 用例：默认参数不出现 `max_tokens`、显式设置后按上限收敛。

### [轻微][存量] 错误诊断信息在失败路径上被丢弃或标错

- **位置**：`f_llm/src/llm/LLM.cj:173-183`（`details` 构造后被 `lastError` 分支丢弃）、`:249-252`（所有异常恒标 `phase: read`）、`:256-259`（流式 4xx 异常不含错误体）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理缺失」/ §14.1「半成品」
- **证据**：静态确定 —— `call` 先拼好 `tried: [a, b]` 再 `if(let Some(error) <- lastError){ throw error }`，`details` 在这条分支永远用不到；`stream` 的 `catch` 不含阶段判别，连接/DNS/TLS 失败与读中断都写成 `phase: read`；流式 4xx 只带 `status`，没有非流式那条 `previewOf(body)`
- **描述**：排障时「为什么没连上」与「读到一半断了」不可区分；同一份报文两个入口的异常信息量不对称，流式更难查。
- **建议**：把 `tried` 拼进 `lastError.message`（或在 `LLMException` 上加 `tried` 字段）；`catch` 里按异常类型分 `connect` / `read`（`SseTimeoutException` 单标 `idle-timeout`）；流式 4xx 也带截断后的响应体。

### [轻微][存量] 冗余判断、无用构造与未使用 import

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:201`（重复判 `weight > 0`）、`:171`（为取 `count` 复制整表）、`:135-137`（`getTokenThreshold` 纯转手）；`f_llm/src/llm/LLMCandidateProvider.cj:21`（未使用的 `import fountain::f_bean.*`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §1「未使用的 import / 读后不用」、§6.4「已知规模却多走一趟」
- **证据**：静态确定 —— `snapshot.candidates(llmName)` 已过滤 `weight > 0`（`:49-57`），`balancerFor` 再判一次；`getTokenThreshold` 与 `saturated`（`:139-146`）内的 `conf.tokenThreshold` 完全等价；`LLMCandidateProvider.cj` 全文未使用 `f_bean` 任何符号（无 `@Bean`、无 `lookup*`）
- **描述**：`getTokenThreshold` 还制造了「阈值有独立入口」的错觉（实际没有任何附加逻辑），与 `saturated` 形成第二个入口。
- **建议**：删掉未用 import 与 `getTokenThreshold`（`LLMByName_test.cj:141` 改断言 `conf.tokenThreshold`）；`balancerFor` 直接用 `snapshot.candidates()` 的结果。

### [轻微][存量] 空响应仍造消息、熔断无半开探测、`isFatal` 把成功码也算 fatal

- **位置**：`f_llm/src/llm/ChatStreamAccumulator.cj:138-141`、`f_llm/src/llm/CircuitBreaker.cj:54-68`/`:77-99`、`f_llm/src/llm/LLMErrorClassifier.cj:37-39`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「边界 / 语义与命名不符」
- **证据**：静态确定 —— `result()` 在 `order.isEmpty()` 时无条件 `response.messages.add(AssistantMessage(content))`，`content` 可能为空串；`isOpen` 冷却到期即把 `openUntil` / `failures` 全部清零，没有「先放一个探测请求、成功再全开」的状态；`isFatal = !isRetryable`，`isFatal(200)` 返回 `true`
- **描述**：空 assistant 消息会进入下一轮历史（部分平台拒收空 `content`）；冷却结束瞬间所有并发流量同时回到刚恢复的平台，容易再次打挂；`isFatal` 的名字与语义不一致，误用会把成功响应当失败。
- **建议**：`result()` 在 `content`/`reasoning` 都为空且无工具调用时不加消息（或标 `finishReason='empty'`）；熔断加 `HalfOpen` 状态（只放 1 个探测）；`isFatal` 改为 `status >= 400 && !isRetryable(status)`，或删掉这个没有生产调用者的包装（仅 `ChatCompletionsResponse_test.cj:214` 使用）。

### [轻微][存量] `LLMConfs.holder()` 在全局锁内做存储初始化

- **位置**：`f_llm/src/llm/LLMConfs.cj:61-71`（`synchronized(mutex)` 内调 `createHolder()`）→ `:49-59`（`StoreSettings.load()`、`MetaStoreAdapter()` 构造）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §6.2「锁内 I/O」
- **证据**：静态确定 —— `createHolder` 的 `StoreSettings.load()` 与适配器构造都可能触达文件/存储，且整段在 `LLMConfs.mutex` 内；仅在首次初始化执行，之后走缓存
- **描述**：首个 LLM 请求会持锁完成存储初始化，同刻的其它请求全部排队；若初始化抛异常，每次请求都会重试一遍（`current` 仍为 `None`），错误放大方式与 `LLMConfsHolder.refresh` 相同但没有日志。
- **建议**：锁外构造、锁内二次检查后发布；构造失败加一次 `warn` 与退避（与 `LLMConfsHolder` 的刷新退避共用策略）。

### [轻微][存量] 测试桩与全局单例互相污染

- **位置**：`f_llm/src/llm/ContextPruner_test.cj:167-171`、`:181-183`；`f_llm/src/llm/LLMByName_test.cj:28-49`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」；`LLMConfSource` 接口约定「必须整体返回一份快照，不要返回内部可变结构」（`service/LLMConfSource.cj:32`）
- **证据**：静态确定 —— 测试向进程级单例 `ContextPrunerMediator.instance` 注册 `TokenBudget_999` 且不注销；`StaticSource.load()` 直接返回构造时传入的同一个 `ArrayList`（对比生产 `StaticConfSource.load` 会复制，`service/LLMConfSource.cj:67-71`）；`FixedTransport` 在 `statuses` 为空时走 `statuses[statuses.size - 1]` = `[-1]`，`calls` 为非原子 `var`
- **描述**：注册表与全局 holder/transport 被测试改写后不还原，用例并行或重复执行时结果依赖顺序；`StaticSource` 违反接口的「返回快照」约定，被其他测试复用时会出现跨用例的列表污染。
- **建议**：`StaticSource.load()` 复制一份；`FixedTransport` 对空 `statuses` 直接抛断言；把 mediator 的注册改为可注入实例或在 `@AfterEach` 里清理。

### [轻微][存量] `ContextSummaryPruner` 与 `ContextKeywordsPruner` 除提示词外逐行相同

- **位置**：`f_llm/src/llm/ContextPruner.cj:89-107` 与 `108-126`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「近似重复：只改字面量」
- **证据**：静态确定 —— 两个类的 `init` 参数表、`super(...)` 调用、`name` 拼装方式完全一致，差异只有默认 `promptsGenerator` 文案与 `CONTEXT_PRUNER_SUMMARY` / `KEYWORDS` 常量
- **描述**：两份实现同时承担「参数默认值 + 名称规则」，以后给摘要加 `max_tokens` 限制或改提示词插值方式时容易只改一处。
- **建议**：抽一个带 `namePrefix` 与 `defaultPrompt` 的基类（或让 `ContextLLMPruner` 接受 `nameSuffix`），两个子类只提供常量与默认提示词。

### [轻微][存量] `LLMParams.cj` 内三处近重复：`Property` 与手工拼的字段、两个 `addProperty`、`addFunctions`/`addFunction`

- **位置**：`f_llm/src/llm/LLMParams.cj:105-110` 与 `111-119`（两个 `addProperty`）、`44-48` 与 `49-51`（`addFunctions` / `addFunction`）、`123-127`（`Property`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「字面量复制 + 子集实现」
- **证据**：静态确定 —— `addProperty(name:type:description:)` 手写的 `'type'` / `'description'` 键与 `Property` 的字段一一对应；`addFunction` 就是 `addFunctions` 的单元素版本；`Property` 全仓零引用（`grep -rn "\bProperty\b" --include=*.cj` 只命中定义处，属对外可达 public，**不算死代码**，仅记「仓内无引用」）
- **描述**：JSON 字段名散落在两处，字段改名时容易只改一边，生成上游不认的 schema；两个 `addProperty` 重载里「没有则新建对象」的分支也是重复的。
- **建议**：`addProperty(name:type:description:)` 内部委托给 `addProperty(name:propName:propValue:)`；`addFunction` 改成 `addFunctions([function])`；`Property` 要么用于构造，要么标 `@Deprecated` 留到下一个大版本删。

### [轻微][存量] README 对裁剪策略的两处描述与实现相反（文档侧属其他部分）

- **位置**：实现侧 `f_llm/src/llm/ContextPruner.cj:51-52`（`LastN` 取 `2 * n` 条）、`48-56` / `223-244`（不保留首条 system）；文档侧 `f_llm/README.md:199`（「保留最近 N 条」）、`README.md:206-207`（「各策略都以保留首条 system 为约定」）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §13「文档与实现相反」
- **证据**：静态确定 —— 规格侧与实现一致：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-context-pruning/spec.md:16-19` 明确 `LastN_2` 在 6 条输入上保留最后 4 条；README 与规格冲突
- **描述**：按 README 配 `LastN_2` 会得到「最近 4 条」而不是「最近 2 条」；`LastN` / `TokenBudget` 也确实会丢掉首条 system 消息（`TokenBudgetContextPruner` 只看尾部预算）。**文档侧文件不在本部分清单内**，此处登记以便与 README 所属部分合并去重。
- **建议**：README 改为「N 轮 = 2N 条」，并把「保留首条 system」限定到 DRC/Summary 等实际保证的策略。

> **范围外提示**：`AgentTask.cj:54-75` 注释把 `LastN_*` / `Summary_*` / `DRC_*` / `Saturation_*` 描述成可直接配置的名字，但 `ContextPrunerMediator.ensureLoaded`（`ContextPrunerMediator.cj:28-38`）只登记 `@Bean`（当前仅 `RetainContextPruner`），`register` 全仓只有测试调用（`ContextPruner_test.cj:168,171`）——生产要用其余策略必须自行注册。该行为已被项目文档记录（`docs/fountain实现思想与应用/…第16弹….md:246,559`），本次不展开、不计数，交由 `AgentTask.cj` 所属部分判定注释是否要补一句。

## 优化可行性方案

### [CPU] 把 `balancers` 与版本判断前移到快照发布时

- **现状**：每次 `peekNext`（即每次 `chatByName/respondByName`）都要进 `balancerFor`（`LLMConfsHolder.cj:189-222`）拿 `balancerMutex`，做一次 `balancersVersion != snapshot.version` 判断和一次 `HashMap<String, …>` 查找；同一次请求里 `LLM.callByName` 还会再遍历一次 `holder.candidates()` 并逐个 `breaker.isOpen`（各自一把锁）。所有 llmName 的所有请求共用这一把 `balancerMutex`。
- **方案**：把 `balancers` 做成快照的一部分——`refresh` 成功时（已在写路径）为每个 llmName 预建 `LoadBalance`，随 `LLMConfsSnapshot` 一起原子发布；`peekNext` 只读快照，读路径零锁。
- **预期**：省掉每请求一次全局锁（临界区含一次 `HashMap` 查 + 一次 `candidates()` 复制的比较），把选择逻辑从「多线程串行点」变成纯读；具体降幅未知。
- **代价**：`RoundRobin` 的游标改为挂在快照上（版本切换即重置游标，需要确认可接受）；刷新时多一次 O(conf 数) 的 balancer 构建。
- **验证**：`cjpm bench -O2` 对比 `peekNext` 在 1/8/32 线程下的吞吐与 p99；`cjprof` 看 `balancerFor` 与 `Mutex` 等待占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 候选列表每次调用都整份复制

- **现状**：`LLMConfsSnapshot.candidates(llmName)`（`:49-57`）与 `all()`（`:59-67`）每次都新建 `ArrayList` 并逐条 `add`；单次 `chatByName` 会调用 `holder.candidates()`（`LLM.cj:101`）+ `snapshot.candidates()`（`peekNext` 里为取 `count`，`:171`）两次；`Embedding.embed`、`WebSearchFunction` 等也走同一入口。列表元素是 `LLMConf` 引用，复制成本是 N 个引用 + 两次数组分配。
- **方案**：快照里按 llmName 预先存好「已过滤 `weight>0`」的不可变列表（`Array<LLMConf>` 或只读 `ArrayList`），`candidates()` 直接返回该引用；`peekNext` 用 `list.size` 而不是复制。
- **预期**：每请求少 2 次 O(N) 复制与 2 次容器分配（N = 该 llmName 的 conf 数，通常 1-5），减少的是短命小对象，对 GC 压力的贡献需实测确认。
- **代价**：返回值不再是可以安全 `add/remove` 的副本，调用方若有原地修改会破坏快照（当前 3 个调用点都是只读，需逐个确认）。
- **验证**：稳态负载下 `getAllocatedHeapSize()` 速率与 GC 次数前后对照，`-O2`、同输入同并发。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `result()` 为估算 token 先把两段正文拼成新串

- **现状**：`ChatStreamAccumulator.result()`（`ChatStreamAccumulator.cj:165`）执行 `content.toString() + reasoning.toString()`，在流结束时产生 2 个 `String` + 1 个拼接串，大小约等于本次输出字节数（`max_tokens` 默认 65536，实际几百字节到几十 KB）；这三个临时串只用于取 `.size`
- **方案**：给 `estimateTokens` 增加按字节数的重载（`estimateTokensOfBytes(bytes: Int64)`）；`feed` 里对 `append` 的片段累加字节数，`result()` 直接用累计值，零拷贝
- **预期**：每次流式请求少 2～3 份 N 字节临时对象（按 4KB 输出约 12KB 瞬时分配）
- **代价**：`ChatStreamAccumulator` 多一个 `Int64` 计数；`estimateTokens` 保留原签名供 `TokenCounter` 复用
- **验证**：同一 SSE 回放脚本跑 1000 次，`getAllocatedHeapSize()` 差值与峰值 RSS 对照（`mem §1.2`）
- **证据状态**：`无基线（待验证）`

### [CPU] 每次请求两次取全局锁拿 transport

- **现状**：`LLM.getTransport()` / `getStreamTransport()`（`LLM.cj:49-66`）每次调用 `synchronized(mutex)`，`nextRequestId()`（`LLM.cj:295-300`）共用同一把锁；单次持有极短（读字段 / 自增），高 QPS 下是纯竞争点
- **方案**：transport 改为 `AtomicReference`（仅测试注入时替换，读路径无锁）；`counter` 改 `AtomicInt64`
- **预期**：每请求少 2～3 次互斥进入；消除唯一跨请求的共享锁
- **代价**：依赖 `std.sync` 原子类型；`setTransport` 语义从「锁内替换」变成「原子替换」（对本场景等价）
- **验证**：200 并发 × 60s 压测，线程状态采样看 BLOCKED 次数与 P99（锁竞争在 CPU profile 里看不到，需线程状态证据）
- **证据状态**：`无基线（待验证）`

## 待验证假设

> 没有性能测试数据支撑，只用于下一轮补数据；**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 流式每帧一次 `JsonValue.fromStr` + 两次 `StringBuilder` 追加 + `argumentsChunk +=`，是流式会话的主要分配源 | `ChatStreamAccumulator.cj:58-133` | 单会话分配字节、GC 次数、`feed` 自耗时占比 | 单会话灌 10 万 delta（含 5% tool_calls），`cjprof record` + `getAllocatedHeapSize()` 前后差 |
| 2 | `balancerMutex` 在高并发下成为选择路径的串行段 | `LLMConfsHolder.cj:189-222` | 锁等待时长、BLOCKED 线程数、`peekNext` p99 | 32 线程压 `chatByName`（桩 transport），线程状态采样 + `cjprof` |
| 3 | 每请求 2 次 `candidates()` 复制对分配速率有可测贡献 | `LLMConfsHolder.cj:49-67`、`LLM.cj:101` | 每请求分配字节占比 | 同上压测，对比「返回缓存列表」补丁前后的分配量与 RSS |
| 4 | 无同步发布 `snapshot` 在实测中是否真的读到旧版本 / 中间态 | `LLMConfsHolder.cj:112`、`:255` | 交错频率、旧版本持续时长 | 加版本号埋点（读到 vX、当前 vY），在 60s 刷新周期下跑 10 分钟高并发，统计 vX<vY 的样本比例 |
| 5 | 3s 全局读超时实际打断 chat 的频率（首 token / 长停顿） | `LLMStreamTransport.cj:43-50`、`BgeM3Transport.cj:62-65` | 超时次数 / 请求总数、首 token 分布 | 在 transport 捕获读超时并计数，连续 24h 真实流量；同时记录 TTFT P50/P99 |
| 6 | `stream()` 内累加器与 body 不逃逸，可用 local mode 降峰值 | `LLM.cj:208-247` | 逃逸分析结论、峰值内存 | 先 `cjprof heap` 记录峰值，再按 `--enable-local-mode`（模块已开，`f_llm/cjpm.toml:9`）给 `ChatStreamAccumulator` 加 `@local` 对照峰值与 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/llm/ChatStreamAccumulator.cj` | .cj | ✅ | 流式归并；见严重 #4、一般 #4/#5、轻微 #3、优化 3 |
| 2 | `f_llm/src/llm/CircuitBreaker.cj` | .cj | ✅ | 熔断状态机；无半开探测（轻微 #3） |
| 3 | `f_llm/src/llm/CircuitBreaker_test.cj` | .cj | ✅ | 4 个用例覆盖阈值/清零/冷却/清理，无缺陷 |
| 4 | `f_llm/src/llm/ContentPart.cj` | .cj | ✅ | 与 `ChatCompletionsMapper.toWirePart` 形状一致 |
| 5 | `f_llm/src/llm/ContextPruner.cj` | .cj | ✅ | 8 个策略；见严重 #3、一般 #8/#9/#10/#12、轻微 #6 |
| 6 | `f_llm/src/llm/ContextPrunerMediator.cj` | .cj | ✅ | 注册表；同名注册即失败，符合基线 §4 |
| 7 | `f_llm/src/llm/ContextPruner_test.cj` | .cj | ✅ | 覆盖 8 策略 + 注册冲突；测试污染见轻微 #5 |
| 8 | `f_llm/src/llm/LLM.cj` | .cj | ✅ | 门面；见严重 #4/#5、一般 #3/#4/#11、轻微 #1 |
| 9 | `f_llm/src/llm/LLMByName_test.cj` | .cj | ✅ | 候选/失败转移/零权重用例；测试桩缺陷见轻微 #5 |
| 10 | `f_llm/src/llm/LLMCandidateProvider.cj` | .cj | ✅ | 见一般 #13、轻微 #2 |
| 11 | `f_llm/src/llm/LLMConfs.cj` | .cj | ✅ | 懒建 holder（构造在锁内，含存储 I/O）；见一般 #13、轻微 #4 |
| 12 | `f_llm/src/llm/LLMConfsHolder.cj` | .cj | ✅ | 见一般 #1/#2/#6/#7/#12、优化 1/2 |
| 13 | `f_llm/src/llm/LLMConfsHolder_test.cj` | .cj | ✅ | 4 个用例覆盖 TTL/失败保留/占位行丢弃 |
| 14 | `f_llm/src/llm/LLMDelta.cj` | .cj | ✅ | 值对象，无缺陷 |
| 15 | `f_llm/src/llm/LLMErrorClassifier.cj` | .cj | ✅ | 见轻微 #3（`isFatal` 语义） |
| 16 | `f_llm/src/llm/LLMHooks.cj` | .cj | ✅ | 默认 no-op 是有意设计，注释已说明 |
| 17 | `f_llm/src/llm/LLMParams.cj` | .cj | ✅ | 见一般 #14（`max_tokens`）、轻微 #7 |
| 18 | `f_llm/src/llm/LLMResp.cj` | .cj | ✅ | 字段与 mapper 写入点一致 |
| 19 | `f_llm/src/llm/LLMSelection_test.cj` | .cj | ✅ | 轮询/权重/熔断跳过用例；权重断言区间宽松但可接受 |
| 20 | `f_llm/src/llm/LLMStreamTransport.cj` | .cj | ✅ | 见严重 #1/#2 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_llm.part12.txt` 逐行一致，本部分清单中无 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 15 | 正确性 9（截断当成功、坏帧丢工具调用、就地改入参、越界、空 choices、200 非 JSON、token 估算口径、conf 选择、enabled 失效）；设计 3（熔断只挂 byName、饱和判定两处、balancer 版本）；安全性 2（TrustAll、无界超时）；可读性 1（`phase: read` 恒标、tried 丢弃）。语言特性上 `Option`/`synchronized`/`resource` 用法均正确，`String` 字节切片是唯一踩坑点（严重 #5） |
| §1 死代码 | 1 | 逐个核对了本部分全部 `private`/包级符号：`ToolCallFragment`、`fillStreamUsage`、`estimateTokens`、`defaultConfSelector`、`callByName`、`call`、`stream`、`previewOf`、`nextRequestId`、`balancerFor`、`refresh`、`createHolder`、`defaultSupplier` 均有调用者。命中：`LLMCandidateProvider.cj:21` 未使用的 `import fountain::f_bean.*`；`LLMParams.cj:123` `Property` 全仓零引用（对外 `public`，只记信息，不算死代码）。对外可达的 `public`（`CircuitBreaker.size`、`LLMErrorClassifier.isFatal`、`LLMConfs.isConfigured`、`LLMConfsHolder.getTokenThreshold`、`LLM.getStreamTransport`、`LLM.respondStream`、`ChatStreamAccumulator.finished`、`ContentPart.init()`）仓内零引用或仅测试引用，按硬原则一**不判**死代码，仅作可见性信息 |
| §2 重复逻辑 | 3 | 同文件两两比对：`LLM.call` 与 `LLM.stream` 的「遍历候选 + 建 body + decorate + ThinkingPolicy + 错误分类」同构，但可操作部分是钩子漂移（已计入一般 #3），不重复计数；`RetainLastUserPruner` 与 `RetainLastNRoundPruner` 的「倒序遍历 + 追加」结构相似但语义不同（一条 vs 一段），不合并。命中：饱和阈值两处（一般 #12）、Summary/Keywords 近似重复（轻微 #6）、`LLMParams` 三处近重复（轻微 #7）。`estimateTokens(content)+4` 在 `ContextPruner.cj:229` 与 `TokenCounter.cj:47` 各写一遍（后者属第 13 部分，只记一句范围外提示） |
| §3 空实现 | 1 | 全部分支体均已实现；`LLMHooks` 的 no-op 默认值有注释说明（Null Object，不算问题）。命中：`LLMCandidateProvider.cj:41` / `LLMConfs.cj:54` 的 `catch → 空列表/回退`（静默吞异常，一般 #13） |
| §4 栈溢出 | 0 | 本部分无递归：裁剪是线性遍历，`ChatStreamAccumulator` 归并按帧循环，`CircuitBreaker`/holder 无自调用。`JsonValue.fromStr` 的递归深度由上游报文决定，不在本部分实现内 |
| §5 OOM | 0 | 未发现无界容器：`fragments` 按 `tool_calls.index` 有界，`content/reasoning` 由模型输出（`max_tokens`/`streamMaxLineBytes` 1MB 限定），`states`/`balancers` 由配置条数决定且刷新时清理；`LLMConfsHolder` 每次刷新新建快照（旧快照随在途请求释放）。一般 #7 放大的是「装载次数」而非内存 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`bench` 数据，任何「热点」结论都不成立；四个可疑点（流式每帧 JSON 解析、balancer 全局锁、候选列表复制、transport 短锁）全部降级进「待验证假设」#1-#3 |
| §6.2 大粒度锁 | 1 | `LLMConfs.holder()`（`LLMConfs.cj:61-71`）在 `synchronized(mutex)` 内调用 `createHolder()` → `StoreSettings.load()` + `MetaStoreAdapter()` 构造（可能是文件/DB I/O）；只影响首次初始化，属低频但确实「锁内 I/O」。`LLMConfsHolder.balancerFor` 的锁内只做内存操作，未达大粒度锁判据（竞争影响进优化 1） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future.get`；单飞标志（`refreshing`）是有意的合并策略，不构成串行热点证据 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)`、无循环拼串；`LLM.callByName` 失败分支的 `names.contains`（`LLM.cj:117`）是 O(n²) 但只在抛异常前执行一次，规模=配置条数，不成立为缺陷 |
| §7 降堆内存方案 | 2 | 候选列表每请求复制（优化 2）、`result()` 拼接临时串（优化 3）；其余候选缺少分配量基线，只进待验证假设 #1 |
| §8 降 CPU 方案 | 2 | balancer 全局锁与版本判断前移（优化 1）、transport 全局锁（优化 4） |
| §9 local mode 可行性 | 0（1 条待验证） | `ChatStreamAccumulator` / `ResponsesStreamAccumulator` 确在 `stream()` 内创建，但被 transport 回调闭包捕获、且缺逃逸分析与峰值数据 → 只列假设 6，不写成方案 |
| §11 现有代码的 BUG（存量） | 26 | 逐函数核对了 20 个文件的边界/空值/错误处理/资源/并发/契约：严重 5、一般 14、轻微 7（含 1 条测试质量）。另核对了 `CircuitBreaker` 冷却/清理的算术、`LastNContextPruner`/`TokenBudgetContextPruner` 的边界（均有保护）、`DRCContextPruner` 的分组顺序、`ContextPrunerMediator` 的并发注册（check-then-act 在锁内，正确），未发现其它缺陷 |
| §12 并发安全与锁粒度 | 3 | 逐点给出共享路径与同步手段：`LLM.transport/streamTransport/counter`（`Mutex` 保护，读路径也是短锁，正确）、`CircuitBreaker.states`（`Mutex`，正确）、`ContextPrunerMediator.pruners`（`ConcurrentHashMap` + `Mutex`，重复保护但安全）、`LLMCandidateProvider.supplier`（`Mutex`，正确）、`LLMConfsHolder.snapshot`（**无同步**，一般 #1/#2）、`HttpClient` 的进程级 static 超时被跨模块改写（严重 #2）。`ChatStreamAccumulator` 为单线程栈对象（transport 回调同线程），线程封闭 |
| §14 功能完备性与 README 覆盖 | 2 | `enabled` 开关未接线到 file/env 来源（一般 #6）、流式无 by-name/熔断接线（一般 #3）。README/`doc/**` 的覆盖问题属第 1/2 部分，本部分只记录实现侧缺失；`LLMConfs.isConfigured` 这类公开但仓内无调用的入口不算缺失 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完；无 `.md` 文件，§13 唯一命中是轻微 #8（README 属其他部分，跨部分去重） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 14 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

**存量缺陷共 27 条（严重 5 / 一般 14 / 轻微 8），是否纳入修复待用户决定。**

## 总评

本部分代码整体结构清晰：门面（`LLM`）与传输（`LLMTransport`/`LLMStreamTransport`）、配置快照（`LLMConfsHolder`）、熔断（`CircuitBreaker`）、裁剪策略（`ContextPruner` 家族）职责划分合理，`Option`/`synchronized`/`resource` 的用法基本正确，`CircuitBreaker`、`LLMConfsHolder`、`ContextPruner` 都有针对性用例。

阻塞项五个：① `TrustAll` 让所有模型请求裸奔，属安全底线问题，修复只需几行；② 客户端没有自己的超时，且会被 embedding 的 3s 全局读超时接管，流式长回答会被误判为传输失败；③ `RetainLastNRoundPruner` 的负下标会让首轮会话必然崩溃；④ 流式中途失败的重放会向用户输出重复内容，属对外契约级错误；⑤ `previewOf` 的字节切片会在中文错误体上抛异常，恰好让「本该重试」的 429/5xx 变成硬失败。这五条都在主路径或公开 API 上，建议优先处理。

其余问题集中在两处设计缝隙：一是「读写共享状态的同步策略不统一」——快照无锁发布、失败不退避、版本号按旧快照递增，三者叠加会让「配置刷新」在高压下表现不稳定；二是「同一判据多处实现」——饱和阈值、候选过滤（`weight > 0` / `enabled`）、熔断记录都各有两个入口，已经出现 `enabled` 失效与默认 conf 选错这种可观测的分叉。这两类建议在合并报告里按根因一起排期，而不是逐条改。

性能方面本轮没有任何 `cjprof` / `cjpm bench` 数据，所有可疑点（流式每帧解析、balancer 全局锁、每请求候选复制、transport 短锁）都只写进「待验证假设」与「优化可行性方案」，未计入缺陷，也未给出收益百分比。

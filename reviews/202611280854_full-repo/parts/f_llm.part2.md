# f_llm 模块审查报告（模块第 2/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分：`f_llm/doc/**` 共 20 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（`sts/1.3.x`，`git diff` 为空，所有问题来源记为「存量」）
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（本部分分报告；同日 11:32 已有一份同名分报告，本轮按「全量重读 + 重新取证」重写，旧报告仅作线索）

> 本部分清单内没有 `.cj`，§1/§2/§3/§11/§12 的机械检查落在**文档点名的符号与契约**上：凡文档声称「有 / 默认 / 自动 / 保证」的能力，都在 `src/` 里找到实现位置或确认不存在。代码位置只作为文档一致性的证据，代码本身的缺陷由其它子轮定级。
> 本部分核对到的跨部分同源项（执行期上下文全局态[严重]、启动索引重建未接线[严重]、`listByKind` 下推不成立[严重]、裁剪器名不可用[一般]）已分别由第 15/14 部分、第 21 部分（两条）、第 1 部分按代码侧报出；为遵守「同一根因合并成一条」，这里只补文档位置，列在「跨部分同源（合并提示）」，**不重复计入本部分统计**。

## 发现

### [一般][存量] §2.8 的错误处理口径与实现相反：不可重试错误不换候选、也不记熔断

- **位置**：`f_llm/doc/f_llm.md:142-145`（§2.8）；同源表述 `:95-96`（§2.3）、`:581`（§10「单个平台失败 → 换下一个候选」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §11（错误处理语义与命名不符）
- **证据**：静态确定 —— ①`LLM.call` 对 `status >= 400` 只在 `isRetryable` 为真时 `continue`，否则 `throw error` 直接终止整个候选循环（`src/llm/LLM.cj:153-161`），不会「立即换候选」；②该分支不调用 `hooks.onRetryableFailure`，异常直接抛出，熔断器收不到这次失败（`CircuitBreaker.recordRetryableFailure` 只被 `LLM.cj:148/157` 调用）；③`chat(candidates, params)` / `respond(...)` 传入的是空 `LLMHooks()`（`LLM.cj:68-82`），连可重试失败也不记熔断，只有 `chatByName` 建真钩子（`:123-126`）；④`llm_accessTryingCount` / `llm_accessTryingElapsed` 的唯一读取点是 `src/agents/AgentTask.cj:415-416` 的自建重试循环，LLM 门面从不读它们（全仓 grep 仅 `LLMConfig.cj:245-250` 定义 + `AgentTask` 使用）。
- **描述**：文档让调用方以为「4xx（鉴权/参数错）会自动换下一个平台重试，且所有失败都进熔断」。真实行为是：非可重试 4xx 立即失败、不换候选、不记熔断；普通 `chat/respond` 即使 5xx 失败也不进熔断；「重试预算」是 `AgentTask` 层的概念，与候选调度无关。排障时会得到「换平台也没用 / 熔断计数不动」的错误预期。
- **建议**：把 `doc/f_llm.md:144-145` 改成实际口径——「可重试（408/409/425/429/5xx）换下一个候选；其余 4xx 立即抛出且不计熔断；候选循环没有重试预算，预算只在 `AgentTask.accessLLM`」；若希望「两者都记熔断」，在 `LLM.cj:161` 前补一次 `onRetryableFailure` 或在 `LLMException` 上带 `fatal` 标记，由钩子区分统计。

### [一般][存量] `platform-channel` 规格的「模块加载后 `platforms()` 至少含 `email`」与实现相反

- **位置**：`f_llm/doc/spec/add-channel-mediator/specs/platform-channel/spec.md:41-44`；相关表述 `f_llm/doc/loom.md:61`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）+ §14.1（验收场景不成立）
- **证据**：静态确定 —— `ChannelMediator.platforms()` 遍历的是 **instances**（`src/channel/ChannelMediator.cj:118-130`），provider 表由另一个方法暴露：`providerPlatforms()`（`:71-80`）。`llm_channels` 未配置时 `ChannelBootstrap.install` 在空串处直接返回（`src/channel/ChannelBootstrap.cj:46-51`），`LoomWiring.wire` 调用 `installFromConfig()` 后实例表仍为空（`src/loom/LoomWiring.cj:119`），所以 `platforms()` 返回空数组。
- **描述**：规格的 MUST 场景「进程加载 f_llm 且未做任何手工注册 → `platforms()` 至少包含 `email`」无法通过。`loom.md:61` 又用 `platforms()` 表达「只列已实现平台」，把「能力清单」与「已装配账号」两个口径混在同一个方法名上。调用方按规格写「从 `platforms()` 里挑一个去 send」会拿到空列表，误判成部署没有任何通道能力。
- **建议**：规格改成「`providerPlatforms()` 至少含 `email`；`platforms()` 表示已装配账号的平台」；`loom.md:31-37` 的组件表把两个方法并列写清（`providerPlatforms()` = 能力清单，`platforms()` = 实例清单）。

### [一般][存量] `LoomA2aClient` 规格要求 `send` / `get` / `cancel`，实现只有 `ask`

- **位置**：`f_llm/doc/spec/add-loom-a2a/specs/loom-a2a/spec.md:41-44`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）+ §14.1（MUST 能力未实现）
- **证据**：静态确定 —— `src/loom/A2aBridge.cj:136-169` 的公开面只有 `init()` / `init(send:)` / `ask(url, text)`；`LoomA2aClient` 上没有 `get` / `cancel`（`A2aClient` 自身有，但规格点名的是 `LoomA2aClient`）。同目录 `tasks.md:18` 只承诺 `ask`，说明是规格写宽了而没有回头收窄。
- **描述**：按规格使用 `LoomA2aClient.get(taskId)` / `cancel(...)` 的下游代码会编译失败；`input-required` 之后继续同一任务、异步取任务结果这两类流程无法通过该类完成。规格还要求「协议错误原样上抛（保留 code）」，`ask` 在无文本时抛的是 `LoomException`（`A2aBridge.cj:167`），与协议错误是两种异常。
- **建议**：二选一——在 `LoomA2aClient` 补 `get` / `cancel` 两个薄转发（并保留 `JsonRpcException.code`），或把 `spec.md:41-44` 收窄成「`ask`：发送并取第一个文本产物；协议错误由底层 `A2aClient` 原样抛出」。

### [一般][存量] A2A 与 Supervisor 的开关耦合未文档化，且「`wire` 末尾启动 A2A」与真实装配顺序不符

- **位置**：`f_llm/doc/loom.md:666-671`；`f_llm/doc/spec/add-loom-a2a/proposal.md:18-24`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）+ §14.1（前置条件/接线缺失）
- **证据**：静态确定 —— ①`LoomWiring.wire` 在 `:117` 调 `LoomA2a.startIfEnabled()`，`:121` 才 `installSupervisor(...)`，不是文档说的「末尾」；②`SupervisorAgent()` 在 `execute` 时才取 `Supervisor.current()`，取不到就返回 `NO_USABLE` + `message='loom supervisor is not installed'`（`src/loom/A2aBridge.cj:35-42`）；③`LLMConfig.a2aEnabled()`（`src/config/LLMConfig.cj:66-68`）与 `supervisorEnabled()`（`:70-72`）互相独立，`startIfEnabled` 没有任何「需要 supervisor」的校验（`A2aBridge.cj:86-111`）。
- **描述**：只设 `llm_a2aEnabled=true`（`llm_supervisor` 保持默认 false）时，9 个 A2A 方法照常注册——等于对外开了一个**永远返回失败**的入口；调用方无法从协议层区分「能力没开」与「没有可用流程」。文档既没写这个前置条件，也没写启动顺序，排障时容易误判为路由表为空。启动瞬间还存在「A2A 已注册、Supervisor 尚未安装」的窗口。
- **建议**：`loom.md:666` 补一句「`llm_a2aEnabled=true` 且 `llm_supervisor=true` 才具备派发能力，否则每次调用返回 `loom supervisor is not installed`」；或在 `LoomA2a.startIfEnabled()` 里判 `supervisorEnabled()==false` 时 `warn` 并直接返回 false（不注册半残入口），并把 `:671` 的「末尾」改成实际位置（host 装配之后、Supervisor 之前）。

### [一般][存量] `known-limitations` 说「所有配置只在启动读一次、`LLMConfsHolder` 定死」，与 §2.2 的 60 s 懒刷新相反

- **位置**：`f_llm/doc/known-limitations.md:8`、`:14`、`:16`；对照 `f_llm/doc/f_llm.md:87`、`:91`
- **来源**：存量
- **判据**：review-checklist §13（文档内部矛盾、与实现不符）+ §2（同一事实两处写法冲突）
- **证据**：静态确定 —— ①`LLMConfsHolder.load()` 每次取快照先比 TTL：`current.version > 0 && MonoTime.now() - current.loadedAt < refreshInterval` 才复用，否则 `refresh(current)`（`src/llm/LLMConfsHolder.cj:113-116`）；`refresh` 重新 `source.load()` 并整体替换快照（`:224-260`）；②TTL 来自 `LLMConfig.getConfRefreshInterval()`，默认 60 秒（`src/config/LLMConfig.cj:101-103`）；③`LLMConfView` 的 provider/llmName/actualLlmName/weight/enabled/llmUrl/auth/temperature 都在每次 `source.load()` 里重建（`src/store/StoreModels.cj:167-193`），所以在 database / `StoreMetaConfSource` 来源下，改库里的权重/密钥/端点在 60 秒内生效，无需重启；`env` / `file:` 来源本身是静态的，刷新读到的仍是同一份内容；④真正「启动期定死」的是 `llm_memoryStore` / `llm_metaStore` / `llm_embeddingUrl` 这类环境变量，以及 `CircuitBreaker` 在构造时读取的 `llm_failureThreshold` / `llm_cooldownSeconds`（`CircuitBreaker.cj:46-52`，holder 只建一次）。
- **描述**：`known-limitations` 的结论「改权重必须重启」「`LLMConfsHolder` 首次使用时定死」是错的。运维按它理解会错过「密钥轮换 / 权重调整已经生效」；反过来，改熔断阈值却确实要重启，文档没写。两条文档对「配置能否热更新」给出相反答案，属于最容易在事故复盘时扯皮的那类不一致。
- **建议**：把 §0 拆成两层写清：**部署配置**（存储/端点/embedding 地址）启动读一次；**模型配置**（`llm_confSource` 来源的 LLMConf 行）按 `llm_confRefreshSeconds`（默认 60 s）懒刷新，权重/密钥/url 实时生效；**熔断阈值与冷却**只在进程启动构造 `CircuitBreaker` 时读取。`f_llm.md:91` 补一句默认 60 s 与「哪些字段会被刷新」。

### [一般][存量] §10 说演进任务抛错有「调度器日志」，实际被静默吞掉，违反 §0 的「降级要留观测点」

- **位置**：`f_llm/doc/f_llm.md:586`（§10 失败与降级表）；对照 `:21-25`（§0 硬约束 3）
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）+ §13（文档承诺的观测点不存在）
- **证据**：静态确定 —— `SkillEvolutionJob.schedule` 的任务体 `try { … } catch (error: Exception) { () }`（`src/loom/SkillEvolutionJob.cj:387-405`）；`SkillEvolutionJob.cj` 全文没有任何 `Logger` / `log` 调用（grep 零命中）。`TicktockScheduler` 只是把闭包交给 `f_ticktock`；`f_ticktock` 的 `executeOne` 只在异常**逃出** `task.run()` 时才 `LOGGER.warn`（`f_ticktock/src/Ticktock.cj:279-288`），而这里已经被内层 catch 吞掉，所以调度器日志也不会出现。
- **描述**：演进任务失败（租约异常、模型失败、存储失败）时进程里没有任何日志、计数或状态可查，文档却说「调度器日志」可看。这与模块自定的「任何静默退回都必须有可查询的计数或标记」直接冲突，也是「技能一直不演进」最难排查的一类故障。
- **建议**：在 `catch` 里 `LoggerFactory.getLogger<SkillEvolutionJob>().warn('skill evolution failed: ${error.message}')`，并给 `SkillEvolutionLedger` 或状态存储加一个 `lastError` / `failedRuns` 计数；若确定不记录，就把 `:586` 改成「吞掉，无日志（已知缺口）」，不要写成已有观测点。

### [一般][存量] §6.6 与 `loom.md` 承诺「步骤超时由 `LoomTimeout` 控制、失败向下传」，实际 `LoomTimeout` 只包记忆写入，流程步骤没有超时

- **位置**：`f_llm/doc/f_llm.md:403`（§6.6 第 5 条）；`f_llm/doc/loom.md:204-206`
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现相反）+ §11（超时语义）
- **证据**：静态确定 —— ①`LoomTimeout` 的唯一生产调用点是 `MemoryRecorderTask.recordWithTimeout`（`src/loom/BackgroundTasks.cj:44`），全仓再无其它调用（grep `LoomTimeout` 仅定义 + 该处）；②`LoomRunner.runCompiled` 的步骤执行路径（`runSync` / `runAsync`）没有任何超时包装，`runAsync` 里 `waiter.get()` 也是无参阻塞（`src/loom/LoomRunner.cj:307`）；③`loom.md:206` 的「这一步记为失败，不会挂死整条流程」因此没有实现依据，和第 15 部分报出的「并行步骤异常/挂起会永久阻塞」正好相反。
- **描述**：文档把「记忆写入的超时保护」误写成「流程步骤的超时保护」。按文档排期的用户会认为长步骤有 3 s/可配超时兜底，实际只有记忆落库有；步骤本身可以无限期阻塞。`LoomTimeout` 的语义说明（调用方按时返回、被调用方后台继续）本身正确，但适用范围被放大了。
- **建议**：把 `f_llm.md:403` 改成「流程步骤没有内置超时；`LoomTimeout` 仅用于 `MemoryRecorderTask.recordWithTimeout`」，或在 `LoomRunner` 的步骤闭包外加可配超时（与第 15 部分的 `waiter.get(timeout)` 修复一起做）；`loom.md:204-206` 同步限定适用范围。

### [轻微][存量] §9 自称「全部环境变量」，实际漏 5 个键（其中一个全仓无文档且零调用）

- **位置**：`f_llm/doc/f_llm.md:566-575`（§9 配置表）
- **来源**：存量
- **判据**：review-checklist §13（配置项表与源码不符）+ §14.2（配置项遗漏）
- **证据**：静态确定 —— 表头写「全部环境变量，启动时读一次」，但 `LLMConfig.cj` 里另有 5 个键未列：`llm_channelSendRoots`（`:37`，`EmailChannel.send` 用它做附件白名单，`:205`）、`llm_a2aEnabled`（`:66-68`）、`llm_memoryUserId`（`:32`，`Memory.cj:126` 读取）、`llm_faithfulMemoryPath`（`:40`，`FaithfulMemory.cj:34` 读取）、`llm_auto`（`:34`）。前四个在 README / `loom.md` 有零散记载；`llm_auto` 在 README / README_en / `doc/**` 全部检索不到，`LLMConfig.isAuto()`（`:47-49`）也零调用者。
- **描述**：按「全部」理解会漏配通道附件根目录与 A2A 开关；`llm_auto` 则是既无文档、也无内部使用者的暗配置。
- **建议**：补齐 4 个在用键；`llm_auto` 与 `isAuto()` 要么接线（明确谁该读它）要么删除并在启动时 `warn`（与 §4.1 处理废弃键的方式一致）。

### [轻微][存量] §1 模块结构把 mapper 与 dialect 的目录写反，且漏了 `channel/` 包

- **位置**：`f_llm/doc/f_llm.md:42-43`（结构树 `:30-64`）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 结构描述与实现不符）
- **证据**：静态确定 —— `src/llm/` 下是 `ChatCompletionsMapper.cj`、`ResponsesMapper.cj`、`ChatStreamAccumulator.cj`、`ResponsesStreamAccumulator.cj`；`src/llm/openai/` 只有 `ProviderDialect.cj` / `ProviderDialects.cj` / `DeepSeekDialect.cj`。文档把两组写到了相反的位置。同节结构树也没有 `channel/`，而 `src/channel/` 已有 6 个 `.cj`（含 `ChannelMediator` / `EmailChannel`）。
- **描述**：结构树是新人定位代码的第一入口，写反会让人在 `openai/` 里找不到 mapper、在 `llm/` 里找不到方言；通道能力在总览里完全不可见。
- **建议**：把 42、43 两行对调，并在结构树补 `channel/  第三方平台通道（契约/中介者/邮件/工具）`。

### [轻微][存量] 「`memory.search` 与 `knowledge.search` 保持一致」不成立

- **位置**：`f_llm/doc/f_llm.md:425`（§6.7 约定）
- **来源**：存量
- **判据**：review-checklist §13（返回结构与实现不符）
- **证据**：静态确定 —— memory 返回 `{id,title,content,kind,score}`（`src/loom/LoomStoreGateway.cj:199-204`），knowledge 返回 `{docId,seq,score,content}`（`:118-129`）。两者的共同点只是「都带正文」。
- **描述**：字段名不同，模型按 `id` 取 knowledge 结果会取空；`doc/loom.md:558-559` 的两行反而是准确的，两份文档口径互相矛盾。
- **建议**：把 `:425` 改成「两者都带正文可直接喂模型，字段名不同（memory：id/title/kind；knowledge：docId/seq）」。

### [轻微][存量] §4.4 键布局表与 §4.5 表清单不完整

- **位置**：`f_llm/doc/f_llm.md:249-263`（§4.4）、`:269-280`（§4.5）
- **来源**：存量
- **判据**：review-checklist §13（关键信息缺失）
- **证据**：静态确定 —— 未列实际在用的 `f_llm:evo-lease:evolution`（`src/store/EvolutionLease.cj:174`，正是 §7.7 租约的落点）、`f_llm:meta:seq:conf`（`FStoreMetaStore.cj:83`）、`f_llm:meta:skill:title:`（`:238`）；`:269-280` 的「基础表」只列 8 张，`tables-pg.sql` 实际 20 张（`llm_memory_token` 倒排表、`llm_skill_version`、`llm_channel_binding` 等未出现）。
- **描述**：这两张表是运维排查「数据落在哪」的索引，缺项会让人误判「租约不在 f_store」「没有倒排表」。
- **建议**：补 3 个键；表清单改成「示例 + 以 `tables-pg.sql` 为准」，或列出全部 20 张。

### [轻微][存量] `known-limitations` §11 的「零代码引用」清单有一项不成立，两个默认常量取值与文档相反

- **位置**：`f_llm/doc/known-limitations.md:135-141`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）+ §1（零引用结论须有全仓搜索依据）
- **证据**：静态确定 —— ①`PlanDto` 被 `src/loom/Planner.cj:152,164,260,278` 引用（`DataObject<PlanDto>.populate` 与三个 `planOf/questionsOf/assumptionsOf` 形参），不是「零调用方」；②`Stores.DEFAULT_CONTENT` / `DEFAULT_META` 的值是 `postgres` / `postgres`（`src/store/Stores.cj:31-32`），而文档与 `StoreSettings` 的默认实现是 `f_hydra` / `f_store`（`src/store/StoreSettings.cj:39-40`）。
- **描述**：这节的作用是「别删这些符号」，但其中一项判据错误；另两个常量若被外部宿主当默认值用，会得到与文档相反的结果（无库部署直接启动失败）。
- **建议**：把 `PlanDto` 从清单移除或改述为「由 `DataObject` 反射填充、字段不直接按名访问」；`DEFAULT_*` 改为引用 `StoreSettings.DEFAULT_*`，或在本节明确「历史值，不要用于选型」。

### [轻微][存量] `perf-baseline` 的自证公式与自己的第一个数据点矛盾

- **位置**：`f_llm/doc/perf-baseline.md:16-17`
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不自洽）
- **证据**：静态确定 —— 列出 5 个探针值后总结「即 `4 × rune 数 + 4,112 B`」，但 `1,000 rune: 4,064 B` 按该公式应为 8,112 B（实际只多 64 B）。其余四点（10,000 / 100,000 / 1,000,000 / 2,097,152）都与公式吻合。
- **描述**：这个公式正是「说明」里推导 2 MiB 理论峰值 8,392,720 B、进而论证「比 8 MiB 预算多 4,112 B 可接受」的依据；首个点对不上会让读者怀疑整套口径，也让下一轮复测无法判断哪个数可信。
- **建议**：核对 1,000 rune 的探针是否漏计（或改成「小规模下头/对齐开销约 64 B，稳定尺寸后为 4,112 B」），把公式与数据的适用范围写清。

### [轻微][存量] `perf-baseline` 说 ohos 上「不构建」，`cjpm.toml` 却配了该目标

- **位置**：`f_llm/doc/perf-baseline.md:45`
- **来源**：存量
- **判据**：review-checklist §13（文档与工程配置不符）
- **证据**：待确认 —— `f_llm/cjpm.toml:79-87` 明确给出 `[target.aarch64-linux-ohos]` / `[target.x86_64-linux-ohos]` 的 `compile-option`（`--dy-std -ldl`，即去掉 local-mode）与 `bin-dependencies`；仓库的 `docs/LocalMode.md:850` 只说「ohos 构建需要条件编译排除，或保留独立非 local 路径」，没有「本模块不构建」的结论。未跑构建，无法判定「不构建」的依据。
- **描述**：若实际能构建，正确表述应是「ohos 目标不启用 local mode」；若确实不构建，应说明卡在哪（工具链 / 依赖），否则读者会以为没有 ohos 产物。
- **建议**：改成「ohos 目标不启用 local mode（`cjpm.toml` 的 target 段覆盖 compile-option，需条件编译排除 local 路径）」，或补一句排除机制的出处。

### [轻微][存量] spec 引用不存在的 `ChannelProviders` 类型与 `fromConf` 工厂

- **位置**：`f_llm/doc/spec/add-channel-mediator/design.md:40`；`f_llm/doc/spec/add-channel-mediator/tasks.md:12,13,25`
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用 / API 名不存在）
- **证据**：静态确定 —— 全仓无 `ChannelProviders` 类；provider 表在 `ChannelMediator.registerProvider`（`src/channel/ChannelMediator.cj:55`）、`providerPlatforms()`（`:71`）、`create(conf)`（`:83`，只收 `conf`、不收 `platform`）；`EmailChannel.cj:388` 的顶层自动注册用的也是 `ChannelMediator.registerProvider`。`EmailChannel` 没有 `fromConf` 静态工厂（grep 零命中），生产实现由 `FEmailTransport` + 构造器组装。
- **描述**：tasks 里 4 条已勾选任务都以 `ChannelProviders` 为验收对象，读者照它写第三个平台实现会编译失败；`create(platform, conf)` 与实现 `create(conf)` 的签名差也只写在 design 里。
- **建议**：把 4 处改名为 `ChannelMediator.registerProvider` / `providerPlatforms` / `create`，design D2 的示例代码同步改成实际的 `ChannelMediator.registerProvider(...)` 与 `EmailChannel(...)` 构造方式。

### [轻微][存量] A2A 规格两处细节与实现不符：正文回落取流程名、自动流程名格式不同

- **位置**：`f_llm/doc/spec/add-loom-a2a/design.md:40-42`；`f_llm/doc/spec/add-loom-supervisor/design.md:76`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— ①规格要求「`outcome.message` 为空时用流程结果的事件文本」，`SupervisorAgent.map` 实际回落 `outcome.flow`（`src/loom/A2aBridge.cj:60-73`），即返回流程名而非产出；②设计写自动流程名 `auto-<yyyyMMddHHmmss>`，实现是 `auto-${秒级时间戳}`（`Supervisor.cj:233-246`），`loom.md:117` 的「秒级时间戳」才与实现一致。
- **描述**：A2A 客户端在 `message` 为空时会拿到一个流程名当结果正文；按设计文档做日志/审计规则的人会解析不到预期的 14 位时间格式。两处都不影响主链路，但属于「规格已归档、实现未对齐」。
- **建议**：`map` 为空时改用 `outcome.result` 的 `data`（与规格一致），或把规格改成 `outcome.flow`；设计文档的命名格式改成 `auto-<epoch 秒>` 并说明撞名顺延规则。

### [轻微][存量] `loom.md` 说 `MAX_TURNS` 保留「开头几步 + 最后几步」，实现只保留最后 200 条

- **位置**：`f_llm/doc/loom.md:244`
- **来源**：存量
- **判据**：review-checklist §13（注释/文档与实现不符）
- **证据**：静态确定 —— 超过上限时 `LoomContextLog.record` 只从 `turns.size - (MAX_TURNS - 1)` 开始拷贝，然后追加本条（`src/loom/LoomContextLog.cj:79-88`），即丢掉全部早期轮次，保留「最后 199 条 + 当前」，没有「开头几步」的保留逻辑。
- **描述**：文档用这个理由解释「长流程快照不会无限增长」。实际语义是「只留尾部」，提炼看不到流程开头（系统提示、首步事实），与文档给出的质量预期不符。
- **建议**：改成「超出后只保留最近 200 轮，开头轮次被丢弃（如需保留首轮，另行实现采样策略）」；若要保留开头，改成「首轮 + 最近 N-1 轮」。

## 优化可行性方案

> 本部分无 `.cj` 文件，不提堆内存 / CPU 改造方案。`perf-baseline.md` 已给出 KnowledgeChunker 的 local / 堆对照（同 SDK、`-O2`、3 次采样），可作为 `store/` 子轮的现成证据，本部分不重复评估。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ohos 目标是否真的「不构建」（文档说本模块在 ohos 上不构建，`cjpm.toml` 却给了两个 ohos target 段） | `f_llm/doc/perf-baseline.md:45` vs `f_llm/cjpm.toml:79-87`；`docs/LocalMode.md:850` 只说「ohos 需条件编译排除」 | 构建是否成功、失败点是否为 local-mode 语法 | 在有 ohos SDK 的环境执行 `cd f_llm && cjpm build --target aarch64-linux-ohos`，记录首条错误；同时确认 CI 是否排除该目标 |
| 2 | `perf-baseline` 的 local 峰值公式对 1,000 rune 不成立，是否探针漏计 | `f_llm/doc/perf-baseline.md:16-17` | 1,000 / 10,000 rune 的同口径复测值 | 用文档描述的独立探针（`ArrayList<Rune>(total) @ local!` + 精确容量 `add`）重跑 1k/10k/100k，记录 `getAllocatedLocalObjectSize()` 与头开销 |
| 3 | 配置刷新是否真的覆盖 `LLMConf.weight` 与 `LLMConf.url`（而非只有部分字段） | `src/llm/LLMConfsHolder.cj:224-260`；`f_llm/doc/f_llm.md:87-91` | 改库后 60 s 内的一次真实调用观测 | 用可注入的 `LLMConfSource` 改一份 conf 的 weight/url，`sleep 61s` 后 `holder.candidates(name)`，断言返回新对象；再改 `llm_failureThreshold` 验证仍不生效 |

## 跨部分同源（合并时请并入这些条目，不重复计数）

| # | 同源根因 | 已由哪部分定级 | 本部分可补充的文档位置 |
| --- | --- | --- | --- |
| S1 | 执行期上下文是进程级静态（`LoomContextLog.turns/active`、`LoomHostApi.values/personaText/skillText`），文档却写「严格绑在一次执行上」 | 第 15 部分 #1（严重）、第 14 部分 S1（严重） | `f_llm/doc/loom.md:231-245`（生命周期图）、`:434`（「挂到本次执行上」）、`:510`（渲染快照）。并发/嵌套执行会串人格、技能、步骤输出与记忆，跨用户泄漏；文档应改为「进程级单例，同一进程同一时刻只允许一条流程执行」，或随代码改成执行期对象 |
| S2 | `llm_rebuildIndexOnStart` 全链路未接线，启动重建不生效；`known-limitations` 自己又说「需手工触发」 | 第 21 部分「启动索引重建根本没接线」（严重） | `f_llm/doc/f_llm.md:319-321`（「启动时重建」）与 `known-limitations.md:120-121`（「没有启动任务/定时任务」）互相矛盾，两处必须统一 |
| S3 | `ContextPrunerName` 表里 7/8 个策略没有注册，配置即抛异常 | 第 1 部分 #6（一般，README 同源） | `f_llm/doc/f_llm.md:127-138`：除 `Retain` 有 `@Bean`（`src/llm/ContextPruner.cj:27-28`）外，`LastN`/`Summary`/`Keywords`/`DRC`/`Saturation`/`RetainLastUser`/`RetainLastRound` 均无 `@Bean`、也无生产 `register` 调用；`TokenBudget` 连常量都没有，实际注册名是 `TokenBudget_<budget>`（`:210-221`）；`Agent.pruner` 默认空串（`src/model/po/Agent.cj:44-45`），`AgentTask.cj:412` 直接 `prune('')` 也查不到 |
| S4 | 流式中途失败换候选会重放已回调的 delta、流式不记熔断、`[DONE]` 缺失被当成功 | 第 1 部分 #8、第 12 部分「流式中途失败后换平台重放」「熔断只挂在 *ByName」「流被提前截断」三条 | `f_llm/doc/f_llm.md:103-104`（只写空闲超时/单行上限，未写重放与作废语义）、`:144-145`（「两者都记入熔断」对流式不成立） |
| S5 | `chat/respond` 没有显式读超时，且会被 embedding 的全局 3 s 超时串改 | 第 13 部分「非流式 HTTP 传输没有显式超时」、第 10 部分「`BgeM3Transport` 全局超时」 | `known-limitations.md:20-30` 只写了 embedding 的「建连超时」，没有记录「LLM 对话没有自己的超时、且可能继承 3 s 全局值」；应在已知限制里补一条 |
| S6 | `LoomGatewayHolder.get` 先查后写、无锁，并发首次调用会建两个网关 | 第 16 部分 #3（`LoomWiring.cj:38-54`） | `f_llm/doc/loom.md:219`「懒建一次…共用同一实例」是文档承诺，实现存在竞态；修代码或改文档二选一 |
| S7 | `listByKind` 的 SQL 下推不成立（适配器没转发），`loom.md` 却写「PG/MySQL 下推到 SQL」 | 第 21 部分「`MemoryRepositoryAdapter` 未转发 `listByKind`」（严重） | `f_llm/doc/loom.md:567` 需加「当前适配器未下推时按近似实现」；`f_llm.md:233` 与 `:611` 的谨慎表述应作为统一口径 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_llm.part2.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/doc/f_llm.md` | .md | ✅ | 设计总览；错误处理见 G1、配置刷新见 G5、步骤超时见 G7；配置表/结构树/检索字段/键布局见 M1-M4；§4.9/§2.7 的严重同源问题见合并提示 S2/S3 |
| 2 | `f_llm/doc/known-limitations.md` | .md | ✅ | §1/§2/§3/§4/§6/§7/§9/§10 逐条与实现核对一致；§0 与 `f_llm.md` §2.2 冲突（G5）、`f_llm.md` §10 的日志承诺不成立（G6）、§11 有误（M5）、§5 的重建口径与 `f_llm.md` §4.9 冲突（S2） |
| 3 | `f_llm/doc/loom.md` | .md | ✅ | 通道/附件/Supervisor/存储/租约/SkillCatalog 逐节抽查一致；A2A 装配顺序与开关前置见 G4、步骤超时承诺见 G7、`MAX_TURNS` 保留策略见 M10；平台清单口径见 G2；懒建网关竞态见 S6 |
| 4 | `f_llm/doc/perf-baseline.md` | .md | ✅ | 方法与实测表可复核；公式与首个探针值不一致见 M6；ohos「不构建」待确认见 M7 + 假设 1 |
| 5 | `f_llm/doc/retrieval-eval.md` | .md | ✅ | 数据集 50 文档 / 622 用例 / 300 hard / 12 multi / 10 负样本与 `eval/*.tsv`、`run_eval.sh`、`RetrievalEvalRunner.run` 签名逐项一致，未发现缺陷 |
| 6 | `f_llm/doc/spec/add-channel-mediator/design.md` | .md | ✅ | 设计决策与实现一致；示例代码引用不存在的 `ChannelProviders.register` / `EmailChannel.fromConf` 见 M8 |
| 7 | `f_llm/doc/spec/add-channel-mediator/proposal.md` | .md | ✅ | 包划分、默认无实例、`f_email` 依赖均与实现一致 |
| 8 | `f_llm/doc/spec/add-channel-mediator/specs/platform-channel/spec.md` | .md | ✅ | `platforms()` 场景不成立见 G2；其余收发/附件/不置已读要求与 `EmailChannel`/`FEmailTransport` 一致 |
| 9 | `f_llm/doc/spec/add-channel-mediator/tasks.md` | .md | ✅ | 4 条已勾选任务以不存在的 `ChannelProviders` 为验收对象，见 M8 |
| 10 | `f_llm/doc/spec/add-loom-a2a/design.md` | .md | ✅ | 状态映射与 `SupervisorAgent.map` 基本一致；「正文为空时用流程结果事件文本」与实现取 `outcome.flow` 不符，见 M9 |
| 11 | `f_llm/doc/spec/add-loom-a2a/proposal.md` | .md | ✅ | 开关默认 false、双向桥、工具与实现一致；「卡片由 LLMConfig 拼出」已被第 13 部分按代码侧报出，本部分不重复 |
| 12 | `f_llm/doc/spec/add-loom-a2a/specs/loom-a2a/spec.md` | .md | ✅ | 客户端三方法未实现见 G3；开关前置条件见 G4 |
| 13 | `f_llm/doc/spec/add-loom-a2a/tasks.md` | .md | ✅ | 任务只承诺 `ask`，与实现一致，但与 spec 不一致（G3 的另一侧证据） |
| 14 | `f_llm/doc/spec/add-loom-supervisor/design.md` | .md | ✅ | D1-D9 与 `Supervisor.cj`/`LoomWiring.cj` 逐条核对通过；仅自动命名格式与实现不符（M9） |
| 15 | `f_llm/doc/spec/add-loom-supervisor/proposal.md` | .md | ✅ | 两个开关、生命周期联动、host 复用与实现一致 |
| 16 | `f_llm/doc/spec/add-loom-supervisor/specs/loom-supervisor/spec.md` | .md | ✅ | 9 条需求逐条核对通过（含陈旧路由摘除 `Supervisor.cj:182-192`） |
| 17 | `f_llm/doc/spec/add-loom-supervisor/tasks.md` | .md | ✅ | 与实现一致（`tap` 的澄清态跳过、`wire` 播种均可落位） |
| 18 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/design.md` | .md | ✅ | 已归档；按「当时结论自洽」核对，D12→D13 的取代关系写清，无内部矛盾 |
| 19 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/proposal.md` | .md | ✅ | 已归档；BREAKING 键替换与 `StoreSettings.DEPRECATED_KEYS` 的 4 个旧键一致 |
| 20 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/specs/llm-content-store/spec.md` | .md | ✅ | 已归档；按当时口径自洽。注：其「内存实现不得出现在可选值列表」与当前 `StoreWiring.cj:60` 无条件注册 `inMemory` 不同，属归档后演进，不按 §13 判缺陷 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | G1（错误处理契约）、G5（配置刷新）、G7（超时语义）为「文档承诺 vs 实现」的正确性命中；流式响应侧的「重放/已输出内容作废/熔断/截断」在 S4 列出文档位置（代码侧第 1/12 部分已报），本部分不重复计数。安全性方面本部分文档未新增错误承诺，TLS `TrustAll` 已由第 1/12/13 部分按代码侧报出，本部分只记「known-limitations 未收录」 |
| §1 死代码 | 3 | 逐项核对了文档点名的「零引用/保留」符号：`PlanDto` 实际被 `Planner.cj:152/164/260/278` 使用（M5）；`ChannelProviders` / `EmailChannel.fromConf` 全仓不存在（M8）；`llm_auto` / `LLMConfig.isAuto()` 全仓零调用且无文档（M1）。`MemoryIndexRebuilder`/`KnowledgeIndexRebuilder` 的「生产零调用」结论成立，属 S2（跨部分） |
| §2 重复逻辑 | 3 | 同一事实多文档重复且结论冲突：G5（配置只读 vs 60 s 刷新）、M3（memory/knowledge 返回字段）、S2（启动重建 vs 手工重建）；其余重叠段落（存储选型、网关 op 表、附件语义、Supervisor 路由、技能演进）已两两比对，差异属「设计总览 vs 使用说明」的分工，不算重复 |
| §3 空实现 | 1 | G6：演进任务的 `catch { () }` 静默吞异常，且文档声称有日志。另：`llm_rebuildIndexOnStart` 打开后走空分支，属 S2（跨部分，代码侧已计） |
| §4 栈溢出 | 0 | 文档描述的切块是滑窗迭代（`KnowledgeChunker.splitImpl`），编排是拓扑序 + 事件派发，未承诺任何按输入深度递归的遍历 |
| §5 OOM | 0 | 文档写出的上限与实现一致：`llm_streamMaxLineBytes`=1 MiB、`llm_toolResultMaxBytes`=64 KiB、`llm_fetchMaxBytes`=256 KiB、`LoomContextLog.MAX_TURNS`=200、KnowledgeChunker local 预算 8 MiB / 2 MiB 内容门限；未发现无上限承诺 |
| §6.1 热点瓶颈 | 0 | 本部分唯一性能材料是 `perf-baseline.md`，口径是单次运行的堆增量 / `VmHWM`，没有 `cjprof` 自耗时与调用路径，不构成热点结论；缺什么见假设 2 |
| §6.2 大粒度锁 | 0 | 文档只承诺「`LoomContextLog`/`Supervisor`/`LoomRegistry` 用 `Mutex`」；抽查实现临界区均为内存操作，无 I/O / 日志 / 回调 |
| §6.3 并发串行 | 0 | 文档对并发的承诺只有「`parallel=true` 换 `AsyncFlow`」「`JoinBarrier` 汇聚」，未出现「spawn 后立刻 get」这类描述；实际 `waiter.get()` 无超时属第 15 部分范围 |
| §6.4 低效算法 | 0 | 文档提到的复杂度只有 `listByKind` 近似分页与索引重建 O(记录数)，均已标为已知限制；与实现的偏差见 S7（代码侧） |
| §7 降堆内存方案 | 0 | 本部分无源码；`perf-baseline.md` 的方案已落地并有改前/改后对照，不重复提方案 |
| §8 降 CPU 方案 | 0 | 同上，且文档明确「不以吞吐量验收」，没有 CPU 基数 |
| §9 local mode 可行性 | 0 | 已核对试点结论与实现一致：门限 8 MiB / 4 B = 2 MiB（`KnowledgeChunker.cj:21-26`）、local/堆窗口循环拆成两个 helper、`maxChars=400`/`overlap=50` 默认值一致；未发现新的改造面 |
| §11 现有代码的 BUG（存量） | 3 | G1、G6、G7 是文档侧可静态确定的行为/契约错误；另核对文档给出的默认值（`maxTurns=20`、`skillTopK=3`、`minSamples=3`、`0.8`、`86400/172800`、`DEFAULT_MAX_ROUNDS=8`、`MAX_TURNS=200`、`idleTimeout=120s`）全部与实现一致 |
| §12 并发安全与锁粒度 | 1 | 命中 G4 的启动窗口（A2A 已注册、Supervisor 未安装）；执行期上下文的「严格绑在一次执行上」承诺不成立属 S1（严重，已由第 15/14 部分按代码侧定级，本部分不重复计），网关懒建竞态属 S6（第 16 部分已计） |
| §14 功能完备性与 README 覆盖 | 3 | G2（`platforms()` MUST 场景不成立）、G3（`LoomA2aClient` 三方法未实现）、M8（规格引用的 `ChannelProviders` / `fromConf` 根本不存在） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 另有 1 条严重项（S1 执行期上下文全局态）与 2 条严重项（S2 索引重建、S7 `listByKind` 下推）属跨部分同源，已分别计入第 15/14、21 部分，本部分不重复统计。
> 存量共 17 条（7 一般 + 10 轻微），是否纳入修复待用户决定。

## 总评

这 20 份文档的分工清楚、可读性好：`f_llm.md` 是当前实现总览，`loom.md` 是使用与边界，`known-limitations.md` 是不可解限制，`perf-baseline.md` / `retrieval-eval.md` 是可复核的数据材料，三份 spec 四件套的决策记录也基本能对上代码。真正的问题集中在两类：

1. **契约口径没有跟着实现收口**：§2.8 把「4xx 立即失败」写成「换候选 + 记熔断」；§6.6 / `loom.md` 把「记忆写入超时」写成「步骤超时」；`known-limitations` 把「模型配置 60 s 刷新」写成「全部启动读一次」。这三条都会让运维/调用方按错误的前提排障，是本次建议优先修的文档项（G1、G5、G7）。
2. **规格里的 MUST 比实现大**：`platforms()` 的「加载即含 email」、`LoomA2aClient` 的 `send/get/cancel`、A2A 与 Supervisor 的开关前置条件，都是规格先写好、实现收窄后没有回改（G2、G3、G4）。它们不一定影响主链路，但会让按规格写代码的下游直接编译失败或拿到空能力清单。

本部分没有新增严重缺陷：文档最坏后果是误导与排障成本。但必须提醒合并方，**执行期上下文全局态（S1）** 在文档里被明确承诺为「绑在一次执行上」，这是本模块最危险的一处「文档说安全、代码不安全」，合并报告时应把它放在最高优先级，并把 `loom.md:231-245/434/510` 列进位置清单。

未做：未运行任何构建或测试（任务约束只读）；`perf-baseline.md` 的数值未复测；ohos 目标是否可构建记为待确认（假设 1）。

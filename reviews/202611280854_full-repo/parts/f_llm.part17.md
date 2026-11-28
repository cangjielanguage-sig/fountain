# f_llm 模块审查报告（模块第 17/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（全模块 368 个 `.cj` + 112 个 `.md`；**本部分 20 个源文件**，全部为 `f_llm/src/loom/` 下的技能目录 / 演进流水线 / Supervisor 路由 / 存储入口）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全
- **报告版本**：v1-part17（只覆盖第 17 部分；模块报告由主 Agent 合并，不写入 `docs/review/`）

## 发现

### [一般][存量] SkillMatcher 在技能循环内重复编码同一条经验，外部 embedding 调用放大为「素材数 × 技能数」

- **位置**：`f_llm/src/loom/SkillMatcher.cj:132-145`（第 137 行 `encodeSafely(embedderValue(embedder), item.content)` 位于第 135 行 `for(skill in usable)` 之内）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.4（同一输入重复解析 / 重复计算）、§8-2（减少分配与跨边界调用）
- **证据**：静态确定 —— 外层 `for(item in experiences)`（132）× 内层 `for(skill in usable)`（135），内层每次重新调用编码器，`item.content` 被编码 `usable.size` 次；`skillVectors` 已缓存技能侧向量，素材侧没有缓存
- **描述**：`SkillCatalog.embeddingEncoder`（`SkillCatalog.cj:120-122`）走 `Embedding.embed`，是远程模型调用。默认 `limit=500` 条素材 × N 个技能 = 500N 次编码，正确只需 500 次；编码器抛错时同一个失败也要重复 N 次。演进任务在定时线程里跑，调用量随技能数线性放大，直接放大耗时与接口成本
- **建议**：把素材编码提到内层循环外（每条经验编码一次，`match` 后再遍历 `skillVectors`）；顺带把 `embedderValue(embedder)` 也提到循环外（当前每次迭代都重走一次 `match`，`None` 分支还会新建空闭包）

### [一般][存量] 知识「还没沉淀成技能」就被写死为已消费，模型一次失败或开关关闭即永久丢弃

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:196-203`（`state.markKnowledge(usedKnowledge.toArray())` 无条件执行）；配合 `96-106`（按 `consumed` 过滤）与 `184-193`（建技能可能失败）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（失败路径当成功）、§3（失败被吞后状态被写死）
- **证据**：静态确定 —— `usedKnowledge` 由**全部** `freshKnowledge` 构成，与 `created` / `rejected` 无关，写入点在本轮所有分支之后、无任何条件
- **描述**：三种情况会把「未被使用」的素材永久记账：(1) `nameCandidates=false`（`177`）时候选簇只上报不建技能；(2) `SkillNamer.propose` 返回 `None`（`185-191`，模型不可用或输出非法）只记一行 `rejected`；(3) 从下一轮起 `consumed.contains(item.source)`（`103`）把它们挡在 `freshKnowledge` 之外，而知识 `at=0` 不会再由水位线带回来。另一个同源缺口：`source` 为空的知识（`103` 允许通过）永远进不了 `usedKnowledge`（`199`），会**每轮重复参与聚类**，`nameCandidates=true` 时可能反复建同名技能
- **建议**：只把「本轮真正落地」的知识记入 `markKnowledge`——按簇是否成功 `emit`、是否被现有技能吸收来选；`rejected` 与 `nameCandidates=false` 的簇保留 `docId` 待下轮。`source` 为空的知识改用内容哈希生成稳定键

### [一般][存量] 空轮 / 读失败轮把水位线直接推进到 `now`，未处理的素材下一轮被永久跳过

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:234-242`（`} else if (now > 0) { state.markRun(now) }`）；失败入口 `279-283`、`320-324`、`337-341`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（失败路径当成功、数据被永久跳过）、§3（异常吞成空集合）
- **证据**：静态确定 —— `advanced` 只由本轮 `fresh*` 的 `at` 求 max；网关读失败时三个列表都为空 → `advanced == 0` → 走 `else` 分支把 `lastRunAt` 写成 `now`。下一轮 `fresh()` 用 `at > since` 过滤，`at ∈ (since, now]` 的记录全部落在窗口外
- **描述**：这一分支本意是「只有知识文档（`at=0`）的轮次也要推进轮次」，但它无法区分「本轮确实没有新素材」和「本轮没读到素材」。存储抖动/超时一次（异常被 `'[]'` 吞掉），水位线就推进到当前时刻，此前未处理的成功/失败经验从此不会被任何一轮看见；只有手工把水位重置为 0 才能恢复。上面第 215-217 行的注释正是为了防止这类跳过，但 `else` 分支把它绕过去了
- **建议**：`load` 失败时让 `run` 拿到显式的失败信号（返回带 `error` 的报告或抛异常），失败轮**不推进**水位；只有 `materials` 非空或明确读到「空结果」时才走 `markRun(now)`，并把「空结果」与「读失败」分开记账

### [一般][存量] 网关 / 存储异常被吞成空集合，检索静默返回「没有技能」、演进静默空转，无日志无计数

- **位置**：`f_llm/src/loom/SkillCatalog.cj:188-196`（`catch → ArrayList<Skill>()`）；`f_llm/src/loom/SkillEvolutionJob.cj:279-283`、`320-324`、`337-341`（网关异常 → `'[]'` / `''`）、`209-213`（台账写失败 → `()`）、`401-404`（定时任务整体异常 → `()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（`catch → ()` 静默吞异常）、§14.1（失败没有任何可观测出口）
- **证据**：静态确定 —— 六处 `catch` 的返回值与「本来就没有数据」完全同形；同模块 `LoomWiring.cj:96` 已有 `LoggerFactory.getLogger<LoomWiring>().warn(...)` 的惯例，这六处都没有
- **描述**：`SkillCatalog` 专门为「装了编码器却跑关键词」加了失败计数（`52-54`、`85-92`），但**存储不可用**这条更常见的降级路径没有任何计数：`search` 返回空列表，调用方无法区分「技能库为空」和「读失败」，模型会在没有技能的情况下跑完整条流程。演进侧更严重：`memory.list` 失败 → 素材为 0 → 本轮什么都不做，而租约已被消耗（`391-394`）、水位线还会被推进到 `now`（见上一条），当天不会再重试
- **建议**：`skillsOf` 增加与 `queryEmbedFailures` 同级的 store 失败计数；`experiencesOf` / `knowledgeOf` 区分「空结果」与「读取失败」；六处 `catch` 至少补一条 `warn`（`LoomWiring` 已示范）

### [一般][存量] StoreInvoker 用「抛 LoomException」判断网关未安装，注入网关的业务错误会被当成「没装」并回落到默认库

- **位置**：`f_llm/src/loom/StoreFunctions.cj:85-93`（`case None => try { LoomHostApi.callStore(...) } catch (error: LoomException) { LoomStoreGateway().call(...) }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误分类错误导致走错分支）、§3（失败路径被当成「未安装」）
- **证据**：静态确定 —— `LoomHostApi.callStore` 只在未安装时抛 `LoomException`（`LoomHostApi.cj:170-179`）；而 `LoomStoreGateway.call` 对未列出的 op（`LoomStoreGateway.cj:358`）、`prompt.put` 缺 name（`298`）、`prompt.remove` 缺 version（`315`）、`evolution.*` 未装配（`342`）也抛同一个类型。`catch` 无法区分两者
- **描述**：模型通过 `loomStoreCall` 传了一个网关不支持的 `op`（或宿主注入的网关对某个 op 有业务校验），`invoke` 会把它当成「没装网关」，转而 `new` 一个按全局配置构造的默认网关再查一次库。后果：错误文案变成默认网关的（排障指向错误方向），更严重的是**读到了另一套存储**——注入的是测试库/隔离库时，会静默命中生产默认库；每次回落还会新建网关（`buildCount++`）
- **建议**：给 `LoomHostApi` 加 `hasStore(): Bool`（或让 `callStore` 返回 `?String`）判定「未安装」；兜底只兜「未安装」，业务异常原样上抛

### [一般][存量] Supervisor 把 status 查询异常当作「流程未编译」，永久摘除一条有效路由

- **位置**：`f_llm/src/loom/Supervisor.cj:184-192`（`let stillCompiled = try { service.status(chosen) == LoomStatus.COMPILED } catch (e: Exception) { false }`，随后 `unregister(chosen)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（把不确定当确定）、§12.1（共享状态在错误路径上被破坏）
- **证据**：静态确定 —— 异常与「status != compiled」共用 `false`，紧接着 `unregister`（`324-340`）直接 `table.remove(at: found)`，没有恢复路径。`LoomService.status`（`LoomService.cj:150-155`）走 `registry.get`，是一次存储读取
- **描述**：数据库抖动/超时一次，就会把一条 `compiled` 的路由从内存表删除；路由表只在 `install` 播种（`105-107`）或流程状态再变化时由 `tap` 补回（`116-124`），本次进程内该流程从此不可派发，直到重启。设计意图是「摘掉真正陈旧的路由」，实现把「读不到」也算成「陈旧」
- **建议**：区分三态——`compiled` / 明确非 `compiled`（摘除）/ 查询失败（保留路由，直接返回 `NO_USABLE` 或带 `warn` 重试一次）；摘除只在明确读到非 `compiled` 时执行

### [一般][存量] SkillCatalog 技能侧编码失败就把该技能从检索结果剔除，与类注释「编码失败退回关键词」不符

- **位置**：`f_llm/src/loom/SkillCatalog.cj:160-167`（`case None => noteSkillFailure()`，技能未进入 `scored`）；类注释承诺见同文件 `42-43`，query 侧降级见 `168-172`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13 / §11（契约与实现不符）、§10（降级路径不对称）
- **证据**：静态确定 —— 类注释写「没装 embedder（**或编码失败**）时，退回词面包含度」，实现只在 **query** 编码失败时整体降级，**技能**侧失败只累加计数；全部技能编码失败时 `scored` 为空，`search` 直接返回空列表，完全不降级
- **描述**：向量模式下某个技能的正文触发编码器报错（超长、限流、非法字符），该技能在本次检索中彻底消失，其它技能正常返回——调用方看到的是「这个技能不相关」而不是「这个技能没被评估」。计数只加一个总数，无法定位是哪个技能
- **建议**：`case None =>` 分支对单技能走一次 `keywordScore` 兜底打分并计入 `scored`（与 query 侧对称）；`noteSkillFailure` 带上技能标识或改成去重集合，避免同一技能每次检索都累加

### [一般][存量] SkillImport.readAll 读取失败时文件句柄不关闭

- **位置**：`f_llm/src/loom/SkillImport.cj:121-126`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源不对称：打开未关、异常跳过释放）
- **证据**：静态确定 —— `File(path, OpenMode.Read)` 之后紧接 `StringReader(file).readToEnd()`，`file.close()` 在正常路径末尾，没有 `try/finally`
- **描述**：`details.md` 读失败（磁盘错误、超大文件、编码非法）时 `readToEnd()` 抛错，句柄泄漏。调用链是 `SkillImportFunction.call`（`169-184`）→ 模型可反复触发的工具，每次失败泄漏一个 fd；`parse` 对 `skill.json` 的 `readAll`（`72`）同理
- **建议**：`try { StringReader(file).readToEnd() } finally { file.close() }`；同仓 `f_util/src/crc32_native_x86.cj:203-207` 是正确写法，可统一收敛成 `readTextFile(path)`

### [一般][存量] SkillGate 把模型调用失败当成「0 分」，旧版调用失败会让任意新版直接过关

- **位置**：`f_llm/src/loom/SkillGate.cj:90-105`（`catch(error: Exception) { '' }`，随后 `contains` 判命中）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失：失败被计为有效观测）、§3（异常吞成评分）
- **证据**：静态确定 —— 异常输出 `''` 与「模型真的没命中」在 `scoreOf` 里完全同形，`hits` 不增加，`oldScore` 得 0；`evaluate` 的判据是 `newScore < oldScore` 才拒（`78-81`）
- **描述**：A/B 门禁的意义是「新版不比旧版差」。旧版那一轮如果碰到限流/超时，`oldScore` 被记成 0，新版只要命中一条就通过并落库，`reason` 还会写成 `passed: 0.8 >= 0.0`——把一次基础设施故障当成了「新版更好」的证据。新版侧失败则相反，会把好版本误拒（并触发更长的失败冷却）
- **建议**：`scoreOf` 返回 `(score, failedCount)`；任一侧出现调用失败就本轮判定为 `inconclusive`（不落库、不写 `lastGatePassed=false`，让下一轮重试），不要用 0 分参与比较

### [一般][存量] SkillEvolutionJob.schedule 的 clock 默认返回 0，省略该参数后冷却期永不满足、水位线不推进

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:386`（`clock!: () -> Int64 = {=> 0}`）、`389`、`399`；生效点 `SkillEvolutionPolicy.cj:71-78`、`SkillEvolutionJob.cj:234-242`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（默认值导致功能静默失效）、§14.1（承诺「按水位线只处理新增」但默认参数下不成立）
- **证据**：静态确定 —— `decide` 里 `elapsed = now - lastEvolvedAt`，`now=0` 且 `lastEvolvedAt>0` 时为负，必然 `< required` 返回 `cooldown`；`markRun` 分支要求 `advanced > 0` 或 `now > 0`，两者都不成立时水位原地不动
- **描述**：生产装配显式传了 `clock: {=> DateTime.now()...}`（`LoomWiring.cj:217`），当前不触发；但这是 `public` 编排 API，任何省略该参数的调用方（示例、下游项目、测试桩）都会得到「第一轮之后永不演进」的任务，且没有任何提示。对比 `Supervisor.install` 的同类参数默认回落到 `DateTime.now()`（`Supervisor.cj:94-96`、`234-237`），项目内已有正确范式
- **建议**：默认值改为 `{=> DateTime.now().toUnixTimeStamp().toSeconds()}`；或在 `now <= 0` 时直接抛参数错误，避免静默空转

### [一般][存量] 演进水位线混用「秒级时间戳」与「记录 id」两种量纲

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:294-300`（`at: if (saveTime > 0) { saveTime } else { id }`）；消费点 `218-242`（`advanced` 取 max 后 `markRun`）与 `247-257`（`fresh` 用 `at > since`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（量纲混用导致数据被永久跳过）
- **证据**：静态确定（量纲混用）；待确认（默认网关确实回 `saveTime`，见 `LoomStoreGateway.cj:442`；只有旧数据或别的网关实现才落到 id）
- **描述**：`lastRunAt` 一旦写成秒级时间戳（默认网关下必然如此），任何 `saveTime` 缺失的记录拿到的 `at` 是自增 id（几十~几千），`fresh()` 里 `at > since` 永远为假——这批经验从此不会被任何一轮处理，而 `advanced` 只前进不后退（`236`），水位也不会回落到能覆盖它们的量级。注释把 id 当「退化排序」用，却与时间戳放进了同一个比较域
- **建议**：`saveTime` 缺失时置 `0`（`fresh` 已有「`at==0` 始终参与」的约定，`253`）；或把 `ExperienceItem` 拆成 `(at, seq)` 两字段，水位只比 `at`

### [一般][存量] 演进台账用 `split(':')[0]` 反解技能名，created 行与含冒号的标题被错键

- **位置**：`f_llm/src/loom/SkillEvolutionLedger.cj:62-73`（第 69 行）；行格式来自 `SkillEvolutionJob.cj:171`（`'${skill.title}: v…'`）与 `189`（`'${draft.title} (id=${nextId})'`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（数据派生错误，`history()` 查不到）
- **证据**：静态确定 —— `created` 行没有冒号，`title` 取到整行 `爬虫助手 (id=2)`；`evolved`/`skipped` 行标题自身含 `:` 时只取前半段
- **描述**：`SkillEvolutionLedger.history(store, '爬虫助手')`（`57-60`）依赖 `title` 列精确匹配，新建技能的记录永远查不到；标题含冒号时同一技能的记录会落到两个键上。审计表是演进唯一的留痕，键错等于留痕失效
- **建议**：让 `SkillEvolutionReport` 携带结构化条目（`title` + `action` + `detail`），不要「拼字符串再反解」；至少在 `save` 里用显式分隔符（参考 `StepSourceCodec` 的 `\u0001`）

### [一般][存量] SkillNamer 的 24「字」上限按 UTF-8 字节判定，8 字以上的中文标题被判非法

- **位置**：`f_llm/src/loom/SkillNamer.cj:44`（`MAX_TITLE = 24`）、`90-92`（`if(Int64(title.size) > MAX_TITLE)`）；契约源：同文件 `59-61` 的 prompt「不超过 24 字」、`f_llm/README.md:628`、`f_llm/doc/f_llm.md:519`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与契约不符）、§13（文档与实现口径不一致）
- **证据**：静态确定 —— `String.size` 的契约是「UTF-8 编码后的字节长度」（`api/std/core/structs/string/prop-size.md`：`public prop size: Int64`，获取字符串 UTF-8 编码后的字节长度）。中文按 3 字节/字，24 字节 ≈ 8 汉字
- **描述**：模型返回「爬虫限速重试助手」（8 字 = 24 字节，边界内）之外，任何 9 字以上的中文标题（27 字节）都会被判为超长并返回 `None`；调用方只看到 `rejected: candidate cluster: model did not return a valid name`（`SkillEvolutionJob.cj:191`），误以为是模型输出非法。结果是中文语境下大量合法标题无法建技能，且没有任何日志能说明真实原因
- **建议**：改成按字符数判定（`title.toRuneArray().size` 或 `title.runes().count()`），或把常量改名为 `MAX_TITLE_BYTES` 并把 prompt/README 的「24 字」改成「24 字节」；拒绝原因区分「超长」与「格式非法」

### [一般][存量] 新技能建库前不查重，而演进全链路以 title 作为技能身份，同名技能会互相污染

- **位置**：`f_llm/src/loom/SkillNamer.cj:49-99`（`propose` 只收 `chat` 与经验，拿不到现有技能）、`f_llm/src/loom/SkillEvolutionJob.cj:184-193`（直接 `emit(Skill(nextId, draft.title, …))`）、`118-121` / `126-129` / `134`（`owner`、`failureCounts`、`state` 全以 `skillTitle` 为键）；存储契约 `f_llm/src/store/StoreContracts.cj:93-99`（`upsert(skill)` 按 id，无 title 唯一约束）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现）、§11（契约与实现不符）
- **证据**：静态确定 + 双证 —— 承诺源：`f_llm/doc/f_llm.md:519`「名字不能与已有技能冲突」；缺失证据：`propose` 签名无 `skills` 参数，`SkillEvolutionJob` 建技能处无 title 比对，`FStoreSkillStore.upsert`（`f_llm/src/store/FStoreMetaStore.cj:246-251`）只写 `id` 主体 + title 索引，不拒绝重复 title
- **描述**：一旦出现两个同名技能（模型起名重复、人工导入后又被演进建一个），`owner` / `failureCounts` / `EvolutionStateStore` 三个 title 键容器会把两条技能的素材与成功率合并，`evolved` 只落其中一条 id，另一条从此拿不到自己的经验；`SkillMatcher` 的 `skillVectors[skill.title]`（`SkillMatcher.cj:121`）也会让同名技能共用一份向量。这类错配不报错，只表现为「某技能一直不演进 / 演进内容跑偏」
- **建议**：`SkillMatcher` 与状态存储改用 `skill.id` 作键（`SkillAssignment` 增加 `skillId`）；`SkillEvolutionJob` 在建技能前按 title 查一遍现有技能，冲突则并入既有技能；`SkillStore` 层补「title 唯一」的显式约束

### [轻微][存量] SkillCandidate.score 构造后仓内无人读取，聚类阶段却为它多算一次相似度

- **位置**：`f_llm/src/loom/SkillMatcher.cj:192-198`（第 195-196 行 `SkillCandidate(bucket, similarity(embedder, bucket[0].content, bucket[bucket.size - 1].content))`）；字段定义 `51-58`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（读了不用：派生值无消费）
- **证据**：静态确定 —— 全仓 `grep` 只有构造点一处引用，`SkillEvolutionJob` 只用 `candidate.experiences`；`score` 由「首元素 vs 末元素」得出，本身也不代表簇质量
- **描述**：每个候选簇多算一次相似度（有 embedder 时是 2 次编码 + 余弦），结果没有任何消费方。字段是对外可达的 `public let`，不按死代码处理，但这份计算是无收益的
- **建议**：删掉该参数（或改为簇内平均相似度并真正用于 `SkillNamer` 的筛选门槛）；只保留 `experiences`

### [轻微][存量] Supervisor.register 返回 `?SupervisorRoute` 但永远返回 `Some`，调用方全部丢弃

- **位置**：`f_llm/src/loom/Supervisor.cj:302-322`（第 321 行 `Some(route)`）；调用方 `106`、`121`、`225` 均为 `let _ = …register(...)`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§1（恒真分支）
- **证据**：静态确定 —— 函数体所有出口都是 `Some(route)`，没有 `None` 路径；注释只写 `@throws LoomException 流程名为空`
- **描述**：`Option` 让调用方以为「同名可能返回 None」，实际语义是「同名覆盖」。返回值既没被判断也没被使用，读代码时反而制造疑问
- **建议**：返回类型改 `Unit`，或返回被替换的旧 `SupervisorRoute`（幂等覆盖时才有信息量）

### [轻微][存量] Supervisor.install 先发布单例、后播种路由，启动窗口内 `routable()` 为空

- **位置**：`f_llm/src/loom/Supervisor.cj:102-108`（`installed = Some(supervisor)` 在 `for (flow in flows) { register(...) }` 之前）；读取点 `134-140`、`354-364`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（发布逸出：未初始化完的对象先交给其它线程）
- **证据**：静态确定 —— `current()` 只拿 `staticMutex`，可在播种循环执行期间取到该实例；`routable()` 此时读到空表
- **描述**：并发首请求正好落在 `install` 期间时，`dispatch` 选不到任何流程并返回固定文案「没有可完成此工作的流程」——把「启动未完成」表现成「没有可用流程」。窗口只有几十次 `ArrayList.add`，但重启期的探活/预热请求最容易撞上
- **建议**：先在私有实例上 `register` 完全部 `flows`，最后一步再发布 `installed`

### [轻微][存量] 三个工具类各留一个逐字相同的 `invoke` 转发

- **位置**：`f_llm/src/loom/StoreFunctions.cj:73-76`、`144-147`、`215-218`；共享实现 `StoreInvoker.invoke`（`84-95`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名的重复实现）
- **证据**：静态确定 —— 三处函数体均为 `StoreInvoker.invoke(injected, kind, op, payload)`，前两处连参数名都相同
- **描述**：注释说「三个工具共用一份，避免能力拷贝」，共享点其实已落在 `StoreInvoker` 上，这三个包装层没有差异点，只多一层栈与一个阅读分叉
- **建议**：`call` 中直接调用 `StoreInvoker.invoke(injected, …)`，删掉三个 `private func invoke`

### [轻微][存量] JSON 字符串字段提取在四处各写一遍

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:367-375`（`strField`）、`SkillGate.cj:145-154`（`SkillSamples.strOf`）、`SkillNamer.cj:125-134`（`fieldOf`）、`SkillImport.cj:128-137`（`strOf`）；同族数值版 `SkillEvolutionJob.cj:360-365`（`intField`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制：同一段「get → as JsonString → 否则空串」）
- **证据**：静态确定 —— 四段实现对「缺键 / 非字符串 / null」都返回 `''`，语义一致，只有函数名不同
- **描述**：「宽容解析」本身是行为契约（当前策略是静默空串）。四处独立演进后，一处加 `trimAscii`、一处改成抛错，同一份 JSON 在不同入口就会解析出不同结果
- **建议**：收敛到模块内一个 `JsonFields` 工具（或 `f_data` 已有的便捷取值），四个调用点统一；把「缺键是否算错误」的决策写在一处

### [轻微][存量] 相似度计算与 samples 解析各存在两套实现

- **位置**：`SkillCatalog.cj:326-343` 与 `SkillMatcher.cj:237-254`（`cosine` 逐行相同）；`SkillCatalog.cj:306-324`（`runeScore`）与 `SkillMatcher.cj:268-289`（`runeCoverage`）；`SkillGate.cj:109-143`（`SkillSamples.of`）与 `SkillNamer.cj:101-123`（`samplesOf`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名 / 近似重复）
- **证据**：静态确定 —— 两份 `cosine` 连「size 取 min、任一范数为 0 返回 0」都一致；两份 rune 覆盖唯一差异是 `runeCoverage` 跳过空格与换行；两份 samples 解析的校验条件相同（`input`/`expect` 非空才收）
- **描述**：`cosine` 两份拷贝都静默截断到较短维度，要改成「维度不符返回 0」得改两处；rune 口径不一致会让「标题覆盖率」与「正文覆盖率」在同一阈值下不可比（`SkillCatalog.cj:289-296` 同时用两个分数与 0.5 比较）
- **建议**：`cosine` / `runeCoverage` 收敛为模块内 `Similarity` 工具，空格/换行策略参数化并在调用点显式传值；samples 解析保留 `SkillGate` 一份，`SkillNamer` 复用

### [轻微][存量] PostgresLoomStore 与 MySqlLoomStore 的 4 个方法逐行同形

- **位置**：`f_llm/src/loom/SqlLoomStore.cj:124-155`（PG）与 `158-189`（MySQL）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— `save` / `get` / `list` / `remove` 的方法体逐行对齐，唯一差异是 `dao<PostgresLoomDAO>('postgres')` 与 `dao<MySqlLoomDAO>('mysql')`
- **描述**：行映射已由 `LoomRowMapper` 共享，剩下这层纯粹是方言类型的分叉；`dao<T>` 需要具体类型，泛型无法直接消除，所以列为结构性重复而非缺陷。真正的风险是「只改了一边」——例如将来给 `remove` 加审计日志，很容易漏掉另一侧
- **建议**：若 `dao<T>` 支持按名称取 DAO，收敛成一个以 `(dialect, dao)` 为参数的内部实现；否则在两个类各留一行注释指向对侧，并在评审清单里登记「双写」

### [轻微][存量] keywordScore 注释里的中文命中示例在 0.5 阈值下不成立

- **位置**：`f_llm/src/loom/SkillCatalog.cj:292-296`（注释「「帮我写日报」命中「日报助手」靠这条」，随后 `byTitle >= 0.5f64`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 查询「帮我写日报」去重后 5 个字，标题「日报助手」只覆盖「日」「报」2 个 → `runeScore = 0.4 < 0.5`，该分支不会生效；此时 token 分支也已得 0（无空格分词后整串不包含）
- **描述**：注释给出的口径与实现不一致，读者会以为短中文标题能被长描述命中，实际只有查询与标题重合度 ≥ 50% 才生效。这解释了为什么「日报助手」这类短标题在长句查询下检索不到
- **建议**：把示例换成能通过阈值的真实例子，或按「标题被查询覆盖的字数 / 标题长度」反向计算（对短标题更敏感），并补一条对应单测

### [轻微][存量] ownedBy 只做字符串前缀匹配、不校验分隔符，命名空间 'a' 会命中 'a:b' 的文档

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:314-316`（`docId.startsWith('loom:${userId}:${namespace}:')`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界校验缺失）
- **证据**：静态确定（字符串层面）—— `ownedBy('loom:7:a:b:flow:1', 7, 'a')` 返回 `true`；待确认（`namespace` 是否允许包含 `:`，当前无校验）
- **描述**：同一用户下命名空间互为前缀时（`a` 与 `a:b`），`a` 的演进任务会把 `a:b` 的知识也算进素材池；`userId` 侧因为有冒号边界不受影响。注释里「避免跨租户串味」只覆盖了用户维度
- **建议**：把 docId 解析成 `(userId, namespace, flow, seq)` 段后逐段比对，或在写 docId 时对 namespace 做转义/编码

## 优化可行性方案

### [堆内存] 方案 1：SkillCatalog 技能向量缓存按「标题#版本」只增不减

- **现状**：`private static var vectors: HashMap<String, Array<Float64>>`（`SkillCatalog.cj:51`），键 `'${skill.title}#${skill.version}'`（`233`），`writeVector`（`256-260`）只写不删。BGE-M3 1024 维 `Float64` 约 8KB/条；键数量随「技能数 × 历史版本数」增长，旧版本条目留到进程重启
- **方案**：写入前按 title 删旧版本键（同 title 只留最新 version），或改成 `HashMap<String, (Int64, Array<Float64>)>` 以 title 为键、版本做值内比较；再加条目上限做整体重建
- **预期**：稳态条目数从「技能数 × 历史版本数」降到「技能数」
- **代价**：需要一次 `keys()` 扫描或额外维护 title→key 索引；`install/reset`（`62-77`）已整体清空，语义不变
- **验证**：20 个技能各演进 50 次（桩 `chat`），对比 `getUsedHeapSize()` 稳态与 `vectors` 条目数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 方案 2：每轮演进把最多 500 篇知识正文一次性物化，并二次复制进 materials

- **现状**：`knowledgeOf`（`SkillEvolutionJob.cj:318-358`）先取 `docIds`（默认 `limit=500`），再逐条 `knowledge.get` 取全文，全部正文组成 `ArrayList<ExperienceItem>`；`run` 又把 `freshKnowledge` 复制进 `materials`（`109-115`）。单篇长度无上限（写入方控制），峰值 = 500 × 平均长度
- **方案**：取素材改成按需流式（先取 docId + 长度，聚类时按需 `get`），或把 `limit` 降到簇上限并分页推进；至少去掉 `materials` 对 `freshKnowledge` 的整表复制（直接在 `freshSuccess` 上追加）
- **预期**：峰值与文档长度解耦为 O(簇大小)；单轮峰值从「全量正文」降到「单篇 + 簇内副本」
- **代价**：`SkillMatcher` 需要接受惰性素材（接口变更）；分页会让单轮样本变少
- **验证**：500 篇 × 4KB 与 500 篇 × 40KB 两组，测 `getAllocatedHeapSize()` 峰值、RSS 峰值、单轮耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 方案 3：聚类阶段对每对（经验, 簇首）各编码两次，簇首被反复重编码

- **现状**：`SkillMatcher.cj:176-191` 对 `leftovers` 逐条与每个 `leaders[index]` 比一次，`similarity`（`223-235`）每次把左右两侧都重新 `encodeSafely`；`SkillCandidate` 的分数（`195-196`）再算一次「首元素 vs 末元素」相似度
- **方案**：进入聚类前给每条 leftover 编码一次并缓存（与 `leftovers` 同下标的向量数组，或用一个可选值持有类型），簇首复用同一份向量；`SkillCandidate.score` 若无消费方则直接不算
- **预期**：编码调用从 O(Σ leaders × 2) 降到 O(n)（n = leftovers 条数），远程嵌入场景收益与 n 成正比
- **代价**：多一份与 `leftovers` 同长的向量数组（n × 8KB，n 有上限）；编码失败时的降级路径要保持现状
- **验证**：`encodeSafely` 加计数埋点，500 条未匹配经验 + 20 个技能，对比改动前后调用次数；`cjprof` 看 `SkillMatcher.assign` 自耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `knowledgeOf` 是 1 + N 次网关调用（N 最多 500），单轮演进耗时以网络 RTT 为主 | `f_llm/src/loom/SkillEvolutionJob.cj:318-358` | 单次 `gateway.call` P50/P95、单轮耗时分解 | 分段计时统计 `docIds` 与逐条 `get` 的耗时，跑 50/200/500 三档看是否线性 |
| 2 | `keywordScore` 对每个技能做一次全文 `toAsciiLower` + 分词 + 两次 rune 扫描，开销随「技能数 × 正文长度」增长 | `f_llm/src/loom/SkillCatalog.cj:262-303` | 自耗时占比、技能数与正文长度分布 | `cjpm bench` 或分段计时：50 技能 × 2KB 正文、查询 20 字，重复 1000 次取中位数 |
| 3 | `SkillCatalog.vectors` 在长跑进程中条目数持续增长（版本键不淘汰），GC 后不回落 | `f_llm/src/loom/SkillCatalog.cj:51`、`230-260` | 条目数随时间曲线、RSS 曲线 | 按 24h 冷却节奏模拟 1 年演进（桩 chat），每小时采样 `vectors.size` 与 `getUsedHeapSize()` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/loom/SkillCatalog.cj` | .cj | ✅ | 技能侧编码失败无降级、存储异常被吞；优化 #1、待验证 #2 #3 |
| 2 | `f_llm/src/loom/SkillCatalog_test.cj` | .cj | ✅ | 4 个用例；未覆盖「单个技能编码失败」与「全部技能编码失败」 |
| 3 | `f_llm/src/loom/SkillEvolutionJob.cj` | .cj | ✅ | 知识未落地即标记消费、空轮推进水位、水位量纲混用、clock 默认 0、不查重、静默吞异常；优化 #2 |
| 4 | `f_llm/src/loom/SkillEvolutionJob_test.cj` | .cj | ✅ | 18 个用例；未覆盖 `nameCandidates=false` 时知识仍被消费、空轮推进水位 |
| 5 | `f_llm/src/loom/SkillEvolutionLedger.cj` | .cj | ✅ | 标题反解错键 |
| 6 | `f_llm/src/loom/SkillEvolutionLedger_test.cj` | .cj | ✅ | 5 个用例；`history` 只用无冒号标题，未覆盖 created 行键错 |
| 7 | `f_llm/src/loom/SkillEvolutionPolicy.cj` | .cj | ✅ | 冷却期长短档与成功率判定逻辑自洽 |
| 8 | `f_llm/src/loom/SkillEvolutionPolicy_test.cj` | .cj | ✅ | 7 个用例；`elapsed == required` 按 `<` 放行，与实现一致 |
| 9 | `f_llm/src/loom/SkillGate.cj` | .cj | ✅ | chat 失败被计 0 分；`SkillSamples.of` 与 `SkillNamer.samplesOf` 重复 |
| 10 | `f_llm/src/loom/SkillGate_test.cj` | .cj | ✅ | 7 个用例；未覆盖 chat 抛异常的场景 |
| 11 | `f_llm/src/loom/SkillImport.cj` | .cj | ✅ | 读取失败句柄泄漏；JSON 字段取值重复 |
| 12 | `f_llm/src/loom/SkillImport_test.cj` | .cj | ✅ | 4 个用例；测试目录写死 `/tmp/loom-skill-*`，Windows 本地不可跑（不影响 Linux CI） |
| 13 | `f_llm/src/loom/SkillMatcher.cj` | .cj | ✅ | 技能循环内重复编码、同名技能共用向量；优化 #3、待验证 #1 |
| 14 | `f_llm/src/loom/SkillMatcher_test.cj` | .cj | ✅ | 5 个用例覆盖归组/聚类/阈值/关键词回退/空输入 |
| 15 | `f_llm/src/loom/SkillNamer.cj` | .cj | ✅ | 标题按字节判 24、建库不查重、samples 解析重复 |
| 16 | `f_llm/src/loom/SqlLoomStore.cj` | .cj | ✅ | `StepSourceCodec` 往返自洽；PG/MySQL 两类 4 方法同形 |
| 17 | `f_llm/src/loom/StepSourceCodec_test.cj` | .cj | ✅ | 3 个用例覆盖引号/换行往返、空值、坏记录跳过 |
| 18 | `f_llm/src/loom/StoreFunctions.cj` | .cj | ✅ | StoreInvoker 误判「未安装」；三个一行转发重复 |
| 19 | `f_llm/src/loom/StoreFunctions_test.cj` | .cj | ✅ | 8 个用例；`loomStoreCall` 依赖 `LoomHostApi.installStore` 全局态 |
| 20 | `f_llm/src/loom/Supervisor.cj` | .cj | ✅ | status 异常摘路由、register 返回值恒 Some、先发布后播种 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 即上面 14 条一般级发现：正确性与契约类 12 条、错误处理类 3 条（有交叠）、注释与实现相符 1 条（「keywordScore 注释示例不成立」计入轻微）。安全性：外部字符串进 JSON 均走 `FlowPlan.jsonQuote`（`SkillEvolutionJob.cj:275-278`、`StoreFunctions.cj:134-136`），无硬编码凭据、无日志打印正文；`synchronized` 块为 Unit 语义，统一用 `*Box` 带出返回值（`SkillCatalog.cj:358-377`、`SinkBox`），与 `LoomRegistry.cj:77` 的约定一致，未发现误用 |
| §1 死代码 | 1 | 逐文件核对：8 个 `private init()` 是禁止实例化的显式手段；`SkillCatalog` 13 个 `private` 函数、`SkillEvolutionJob` 9 个、`SkillMatcher` 6 个、`Supervisor` 4 个、其余各 1-3 个，全部在文件内有调用点；`internal` 顶层类 9 个（`FactoryBox`/`EmbedderBox`/`FailureBox`/`VectorBox`/`SkillFlagBox`/`SinkBox`/`StoreInvoker`/`StepSourceCodec`/`LoomRowMapper`）均被同包使用，其 `public` 成员也在文件内有读写；无 `return`/`throw` 之后的同层语句、无 `if (false)`、无未使用 `import`（`std.convert` 供 `Int64.tryParse`，`std.math` 供 `sqrt`）。唯一命中：`SkillCandidate.score` 计算后仓内无任何读取点（字段本身对外可达故不判死代码，只记「计算无消费」） |
| §2 重复逻辑 | 4 | ① `cosine` 两份逐行相同（`SkillCatalog.cj:326-343` / `SkillMatcher.cj:237-254`）、`runeScore` 与 `runeCoverage` 仅差空格/换行跳过（`306-324` / `268-289`）、samples 解析两份（`SkillGate.cj:113-143` / `SkillNamer.cj:101-123`）；② JSON 字符串取值四处（`SkillEvolutionJob.cj:367-375`、`SkillGate.cj:145-154`、`SkillNamer.cj:125-134`、`SkillImport.cj:128-137`）；③ PG/MySQL `LoomStore` 4 个方法同形，仅 `dao<T>` 类型与方言名不同；④ `StoreFunctions.cj:73-76`、`144-147`、`215-218` 三个逐字相同的转发。已两两比对但未计入：`Supervisor.register` / `unregister` 的线性查找（3 行、无行为差异）、`SkillImport.strOf` 与 `SkillImportFunction` 的参数校验（职责不同） |
| §3 空实现 | 1 | 「网关/存储异常被吞成空集合」一条的六处 `catch → 空集合 / ()`；`SkillGate.scoreOf` 的 `catch → ''` 单列为「调用失败计 0 分」。无 `TODO`/`FIXME`/空函数体；`private init()` 是有意禁止实例化 |
| §4 栈溢出 | 0 | 无自递归、无间接递归：聚类、rune 扫描、水位线推进、`StepSourceCodec.decode` 全部迭代实现；不遍历用户可控深度的树/链表 |
| §5 OOM | 0 | 素材量受 `limit`（默认 500）与 `topK` 约束；无 `Array(n, repeat:)` 按报文长度预分配；`materials` / `scored` 作用域限于单轮。`SkillCatalog.vectors` 与知识正文物化属「可以更省」而非无界增长，列入优化方案 #1 #2 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点结论不成立；三个可疑点降为「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | 逐个临界区核对：`SkillCatalog` 锁内只有 `HashMap` 读写与计数自增（`85-114`、`248-260`），编码与打分在锁外；`Supervisor` 锁内只有 `ArrayList` 扫描/替换（`307-320`），模型调用与 `executeNow` 在锁外；`SkillEvolutionJob.emit` 锁内只拷 `sink` 引用（`429-438`） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池；`schedule` 为单定时任务串行执行，属设计意图 |
| §6.4 低效算法 | 1 | 「SkillMatcher 在技能循环内重复编码」一条。`sortDesc` 是插入排序（`345-355`），n = 技能数（几十）；`StepSourceCodec.encode` 的循环字符串拼接，n = 步骤数，均未构成问题 |
| §7 降堆内存方案 | 2 | 优化方案 #1 #2，均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案 #3（聚类阶段重复编码，无基线） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`SkillEntry`、向量、`materials`）虽在函数内产生，但向量要逃逸到 `SkillCatalog` 静态缓存，不满足 local 约束；其余收益只能靠峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 14 | 本部分 14 条一般级全部为存量（快照无 diff）。已核对未成立的边界：`SkillEvolutionPolicy` 的 `elapsed == required` 按 `<` 放行（与测试一致）；`StepSourceCodec.decode` 对空串/坏记录有守卫；`search` 的 `topK<=0` 返回空；`Float64` 除法前均有 `total/size == 0` 判断；`EvolutionLease.acquire` 返回空串表示未抢到（`EvolutionLease.cj:119-122`），`schedule` 的 `!acquire().isEmpty()` 用法正确 |
| §12 并发安全与锁粒度 | 2 | 共享路径逐点核对：`SkillCatalog` 5 个静态字段 + `SkillEvolutionJob.sink` + `Supervisor.installed` 各有专属 `Mutex`，均为「锁内取引用、锁外计算」。命中「Supervisor 把 status 查询异常当作未编译」与「install 先发布后播种」。范围外提示：`LoomStoreGateway.buildCount++`（`LoomStoreGateway.cj:47/61/69`）是无锁静态计数，「StoreInvoker 误判未安装」的每次回落都会命中 |
| §14 功能完备性与 README 覆盖 | 1 | 「新技能建库前不查重」一条（`doc/f_llm.md:519` 承诺「名字不能与已有技能冲突」）。本部分无 `.md`，公开 API 未文档化问题留待含 README/doc 的部分；`SkillCatalog.embeddingEncoder`、`SkillMatchResult.assignedCount`、`SkillEvolutionLedger.list/history`、`Supervisor.routes` 均属对外可达 API（硬原则一，不判死代码），仅记「仓内无生产引用」 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完；`files/f_llm.part17.txt` 不含 `.md`，§13 文档一致性留给含 README/doc 的部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 14 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量缺陷 23 条（严重 0 / 一般 14 / 轻微 9），是否纳入修复待用户决定。

## 总评

本部分（技能检索、演进流水线、Supervisor 路由、工具层存储入口）结构清晰，分层与命名一致，锁的用法是「锁内只碰容器、锁外做计算与回调」的正确姿势；`StepSourceCodec`、`SkillEvolutionPolicy`、`Supervisor` 路由表的边界处理与小样本用例较扎实，没有栈溢出、无界任务提交或明显的数据竞争。

主要风险集中在三处：

1. **失败语义**——多条降级路径把「失败」表达成「没有数据」：存储异常被吞成空集合、status 查询异常被当成「未编译」并永久摘路由、技能编码失败就静默退出检索、A/B 门禁把调用失败记成 0 分。这些都不报错，只表现为「技能不生效 / 流程选不到 / 演进选错版本」，是最难排查的一类。
2. **演进流水线的状态记账**——知识在未落地前就被标记消费、空轮（含读失败轮）把水位推进到 `now`、水位混用时间戳与 id、以 title 而非 id 作为技能身份、台账用 `split(':')` 反解标题。五条叠加会让「谁被演进过、为什么没演进、哪些素材没进来」在长跑后与事实不符，且部分跳过不可逆（只能手工重置水位）。
3. **确定性成本放大**——`SkillMatcher` 把 encode 放进技能循环（素材数 × 技能数 次远程编码）、聚类阶段每对重新编码两侧、`knowledgeOf` 的 1+N 取数、`SkillCandidate.score` 算了没人用。这几处不需要 profile 就能确认工作量放大，但收益比例仍需基线，故只列入优化方案与待验证假设。

没有阻塞级（严重）问题；建议优先排期第 1、2 组——它们影响「能力是否悄悄失效」与「审计是否可信」，而非性能。性能类结论（热点、收益百分比）本轮一律未成立，需下一轮补 profile 数据。

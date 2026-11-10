已读取全部 7 份 review（v1–v7），按「严重/一般」整理为 todo（跨轮重复项已合并到最早轮次）。

## R1
### [一般] 记忆写入入口发散，`Memory.remember` 绕过网关直连适配器
- **位置**：src/memory/Memory.cj:124（同族 src/loom/LoomMemoryPolicy.cj:164、src/loom/BackgroundTasks.cj:37、src/loom/StoreFunctions.cj:68）
- **描述**：5 条现行写入口各自手拼 JSON；此处写死 `namespace='global'`/`kind='session'`，与 loom 默认 `'loom'` 不一致，导致写后检索不到。
### [一般] 记忆读取存在新旧两条互不相通的链路
- **位置**：src/tool/MemoriesLoadingFunction.cj:31-57（旧）、src/loom/StoreFunctions.cj:41-80（新）
- **描述**：`MemorySummaryFinder` 与 `MemoryStore.search` 两套读写互不可见，且 `MemoriesLoadingFunction` 全仓无代码引用、无单测。
### [一般] 检索融合逻辑与权重常量在 memory/knowledge × 4 后端各写一遍
- **位置**：src/store/PostgresMemoryStore.cj:90-169（另 postgres/mysql/KnowledgeStore.cj:34、InMemoryStores.cj:248）
- **描述**：归一化+排序各写一份，`0.7/0.3`、`0.4/0.6` 内联，`LEXICAL_WEIGHT=0.1` 三处重复且不可配。
### [一般] 工具与网关 op 重叠且不对称（`memoryCall` ⊂ `loomStore`，`knowledgeIngest` ≡ `knowledge.upsert`）
- **位置**：src/loom/StoreFunctions.cj:63、:119-124
- **描述**：`memoryCall` 白名单仅 search/add/remove（缺 get/list），且每次新建网关、不走 `installStore` 注入点，替换网关后两条入口读不同的库（R2 亦提及）。
### [一般] `LoomStore` 的 PG / MySQL 实现逐行同构
- **位置**：src/loom/SqlLoomStore.cj:124-189
- **描述**：除方言 DAO 外方法体完全一致（含先查后删）；4 个实现并存，选型靠 `LoomBootstrap.storeFor` 硬编码 if 链。
### [一般] 「选实现」职责被三层适配器重复承担
- **位置**：src/store/MemoryRepositories.cj:28-33
- **描述**：`MemoryRepositoryAdapter`/`MemoryStoreAdapter`/`Stores.content()` 各写一遍「bean 优先、配置兜底」。
### [一般] `experience` / `experience_failed` 未纳入 `MemoryKinds`，kind 字面量散落
- **位置**：src/store/MemoryKinds.cj:44-50
- **描述**：`validate` 返回 false、`weightOf` 落默认 0.8；`'note'`/`'session'`/`'experience'` 全用字面量，常量形同虚设。
### [一般] 零引用 / 仅自用的 public API
- **位置**：src/store/Stores.cj:30-32
- **描述**：`DEFAULT_CONTENT/DEFAULT_META/META_KEY` 全仓零引用且与 `StoreSettings` 默认值冲突；`*IndexRebuilder` 生产零调用入口；`PlanDto` 等仅本文件使用。

## R2
### [严重] `experience.list` 丢失 kind 强制，静默返回全部 kind 的记忆
- **位置**：src/loom/LoomStoreGateway.cj:129-138
- **描述**：`list` 用 `strOf(args,'kind')` 未引用 `defaultKind`（`add`/`search` 都用了），未给 kind 时返回所有 kind，属静默错答。
### [严重] 执行期状态是进程级静态单例，并发流程互相清空注入并解除 host 绑定
- **位置**：src/loom/LoomHostApi.cj:29-31（:42-45、:97、:145；src/loom/LoomRunner.cj:207、:223-225）
- **描述**：values/persona/skill/host/`LoomContextLog` 均为 private static，`AsyncFlow` 并行、cron、Supervisor 派发重叠时互相 clear/unbind，注释里的「单线程」无运行时防线（R3、R6 亦提及）。
### [一般] `experience.search` 默认读不到 `experience_failed`
- **位置**：src/loom/LoomStoreGateway.cj:156-160
- **描述**：`kinds` 只放 `'experience'`，失败经验 `kind='experience_failed'` 永不命中，最该复用的教训读不到。
### [一般] `kind=tool` 的步骤没有任何「读知识 / 读技能 / 读经验」的工具
- **位置**：src/loom/StoreFunctions.cj:41-136
- **描述**：只有 `memoryCall` 与仅做写入的 `knowledgeIngest`，tool 步骤读不到知识库正文、技能与经验。
### [一般] `kind=jit` 的步骤不做 `{step.output}` 模板替换
- **位置**：src/loom/LoomCompiler.cj:82-88（src/loom/CodeGen.cj:111-126）
- **描述**：`compileTool`/`compileLlm` 都 render，jit 直接编译 `step.input`，「llm 产出→jit 消费」取不到值。
### [一般] 缺省 `limit` 为 0 导致 `docIds` / `memory.list` 静默返回空数组
- **位置**：src/loom/LoomStoreGateway.cj:85-88（:129-138、:341-356）
- **描述**：`intOf` 缺省 0 直接透传存储（`index < offset+limit` 恒空），与 `search` 分支 `limit<=0 → 5` 规则不一致。
### [一般] 参数校验缺失且两套入口不一致
- **位置**：src/loom/LoomStoreGateway.cj:76-96
- **描述**：仅 `prompt.put` 校验 name，`docId=''`/`userId=0` 可写入孤儿数据；`knowledgeIngest` 反而校验 docId，工具比网关严。
### [一般] `run(skills:)` 在生产入口不可达
- **位置**：src/loom/LoomRunner.cj:121-131（src/loom/LoomService.cj:133、src/loom/Plan.cj:67-76）
- **描述**：`executeNow`/`loomExecute`/`FlowPlan` 三层都没有 skills 传递路径，仅代码直调 `LoomRunner` 生效（R3 亦提及）。
### [一般] 读取路径的测试覆盖缺口
- **位置**：src/loom/LoomStoreGateway_test.cj（experience.list、experience_failed、knowledge.remove、skill.remove 无用例）
- **描述**：缺用例的分支恰包含 S1/G1 两处缺陷，jit 消费 `{output}`、`run(skills:)` 经 `executeNow` 亦无覆盖。

## R3
### [严重] `characterKey = "default"` 被当成字面人格注入 system
- **位置**：src/loom/LoomRunner.cj:171-175（:396-401）
- **描述**：`bodyOf('default')` 走 `case _ => ''` 落到第三级字面文本；`custom` 有特例、`default` 没有，与 `PredefinedCharacters`「default 表示不注入」矛盾。
### [一般] character 人格与 prompts 依赖 `LoomMemoryPolicy.userId`（默认 0），默认配置静默失效
- **位置**：src/loom/LoomRunner.cj:159-160（:406-408、src/loom/LoomMemoryPolicy.cj:52）
- **描述**：`characterOf(0)` 返回 None，既无回落人格也无 `character.prompts`，且失败无日志。
### [一般] 显式 skills 全部未命中时，自动检索被抑制
- **位置**：src/loom/LoomRunner.cj:191-203
- **描述**：`if(selected.isEmpty() && policy.autoSkills)` 只看入参不看是否加载到正文，标题全错时也不回落（R5 亦提及：该静默跳过路径无用例）。
### [一般] `prompt.get` / `prompt.remove` 未定义 `version<=0` 语义，与 `put` 不一致
- **位置**：src/loom/LoomStoreGateway.cj:243-247（:271-273）
- **描述**：`get(name,0)`/`remove(name,0)` 落到底层永远 `''`/`false`，而 `put` 是自增语义。
### [一般] 提示词条目 `content` 为空时会屏蔽内置人格
- **位置**：src/loom/LoomRunner.cj:378-386
- **描述**：命中 `content:""` 直接 `return ''`，既不下沉也不回落字面，人格被静默关掉。
### [一般] 记忆提炼把「人格 + 技能块」当事实写进记忆
- **位置**：src/loom/LoomHostApi.cj:138（src/loom/LoomMemoryPolicy.cj:183-185）
- **描述**：`LlmTurn` 存 `fullSystem`（含 persona 与技能块），摘要写入 note/knowledge，污染检索并自反馈。
### [一般] 人格 / 注入路径测试缺口
- **位置**：src/loom/LoomPersona_test.cj:45-266
- **描述**：缺 `default` 不注入、prompt version 语义、显式 skills 全未命中回落、`userId<=0`、空 content 屏蔽、嵌套流程等 6 类用例。

## R4
### [严重] `truncate` 用字节切片，中文正文大概率抛异常，整次提炼静默丢失
- **位置**：src/loom/LoomMemoryPolicy.cj:223-228（调用点 :104、:184-187）
- **描述**：`text[0..limit]` 是 UTF-8 字节区间，`limit=400` 命中非法边界的概率约 1/3；`digestOf` 在两次 write 之前执行，异常使 note 与 experience 均不写并被 catch 吞掉（`KnowledgeChunker.cj:48-50` 同写法）。
### [严重] `summarize=true` 且模型返回非法 JSON 时「回落规则提炼」实际不生效
- **位置**：src/loom/LoomMemoryPolicy.cj:106-114（:194-210）
- **描述**：`parse` 失败返回 `['','']` 被无条件覆盖，`write` 因内容空返回 false，两条都不写，与文档「非法 JSON 回落规则提炼」矛盾（R5 亦提及无用例）。
### [一般] `writeKnowledge` 的 docId 序号是进程内计数器，重启后撞号覆盖
- **位置**：src/loom/LoomMemoryPolicy.cj:126（:140-151）
- **描述**：`seq` 是 static var 不落库、不按用户分区，重启从 0 起，`upsert` 按 docId 覆盖旧文档。
### [一般] `LoomMemoryPolicy.current` 是可变态全局单例且无锁
- **位置**：src/loom/LoomMemoryPolicy.cj:68-80（装配 src/loom/LoomWiring.cj:82-85）
- **描述**：install/reset/effective 未加锁，两服务共存时后装覆盖，测试依赖全局改状态、顺序敏感。
### [一般] 演进读端与写端归属参数完全解耦，闭环易断
- **位置**：src/loom/LoomWiring.cj:57-58（写端 src/loom/LoomMemoryPolicy.cj:38-39）
- **描述**：`memoryPolicy(userId 7/work)` 与默认 `evolutionUserId 0/loom` 不一致时演进永远读不到经验，且无告警。
### [一般] 演进素材 `limit=500` 硬上限 + 水位线无条件推进，超量样本永久跳过
- **位置**：src/loom/SkillEvolutionJob.cj:258-263（:231-234）
- **描述**：每 kind 最多 500 条却无条件 `markRun(now)`，超出部分从未读取；`at` 退化为 id 时还会被 `fresh()` 判旧丢弃。
### [一般] 知识侧素材不按用户/命名空间过滤，跨租户知识进入某用户演进
- **位置**：src/loom/SkillEvolutionJob.cj:262（:299-302）
- **描述**：`knowledgeOf` 只按 offset/limit 取全部 docId，`KnowledgeDoc` 无 owner，全局知识进入所有人演进池。
### [一般] 提炼失败全程静默，无观测点
- **位置**：src/loom/LoomMemoryPolicy.cj:163-169（:130-135、src/loom/LoomRunner.cj:227-233）
- **描述**：三层 catch 吞异常、`written` 计数被丢弃，上述两个严重缺陷正被此设计藏住。

## R5
### [一般] `memoryCall` 的 remove 分支无用例，add 断言过弱
- **位置**：src/loom/StoreFunctions_test.cj:62
- **描述**：仅断言「不含 failed」，remove 完全未测。
### [一般] 附件写盘失败分支无覆盖
- **位置**：src/channel/EmailChannel.cj（`InboundAttachment.error` 路径，原文未标行号）
- **描述**：附件读写失败、路径穿越/绝对路径均无用例。
### [一般] `writeKnowledge` 写入失败的吞没分支无覆盖
- **位置**：src/loom/LoomMemoryPolicy.cj:130-135
- **描述**：该分支无用例，知识写入条数统计不准不会被发现。
### [一般] `extract` 空输入提前返回无用例
- **位置**：src/loom/LoomMemoryPolicy.cj（`turns.isEmpty() → 0` 分支，原文未标行号）
- **描述**：空 turns 提前返回无任何用例覆盖。
### [一般] Supervisor 自动新建的重名/并发竞态只有单线程顺序用例
- **位置**：src/loom/Supervisor.cj:198（:222-235，用例 src/loom/LoomWiringSupervisor_test.cj）
- **描述**：`nextFlowName` 是锁外 check-then-act，同秒两个 dispatch 同名相互覆盖，`Mutex` 范围无并发验证（R7 亦提及）。

## R6
### [严重] `loomStore(...)` 每次调用都重建整条存储链路（开本地库 / 新建传输）
- **位置**：src/loom/LoomWiring.cj:72-74（src/loom/LoomStoreGateway.cj:60-65）
- **描述**：闭包每次新建网关 → 3 次 `StoreSettings.load`、2~3 次开库/建 transport、子 store 缓存全废；`StoreFunctions.cj:74-79`、`:130-135` 同样，开销随并发线性恶化。
### [一般] `HydraKnowledgeStore.search` 每候选一次 `transport.get`（N+1）再 O(n²) 排序
- **位置**：src/store/hydra/ContentStore.cj:158-191（src/store/KnowledgeSearch.cj:71-93）
- **描述**：最多 400 次 KV 点查 + 400 次 `split`，`rank` 插入排序约 1.6e5 次比较。
### [一般] `PostgresKnowledgeStore.search` 词面召回最多 5 页 ×200 行，候选与正文全量驻留
- **位置**：src/store/postgres/KnowledgeStore.cj:123-153
- **描述**：`maxCandidates=1000` 全量 `textOf(content)`、每行新建 `docId#seq` 字符串，约 5 次 SQL + 0.5MB 临时内存。
### [一般] `LoomHostApi.render` 每次替换全表扫 `values`，且在全局锁内做字符串拷贝（O(steps²)）
- **位置**：src/loom/LoomHostApi.cj:69-87（调用点 LoomCompiler.cj:108,117）
- **描述**：Σ(i-1)≈n²/2 次 `replace`（50 步约 1225 次），渲染期间 `callTool/callStore/callLlm` 全被锁阻塞。
### [一般] `SkillCatalog.search` 每次重列技能全集、关键词路径 O(runes×len×skills)、并发重复 embed、失败不熔断
- **位置**：src/loom/SkillCatalog.cj:148（:262-324、:231-246）
- **描述**：`skillsOf()` 每次开元数据 KV，关键词路径约 2e6 次字符比较；embed 失败每次重试无负缓存，embedder 超时时单次 search 可达上百秒。
### [一般] `LoomContextLog.turns` 单次执行内无条数上限，且每轮冗余存 `fullSystem`
- **位置**：src/loom/LoomContextLog.cj:66-72（src/loom/LoomHostApi.cj:138）
- **描述**：`record` 不受 `maxTurns` 约束，`fullSystem`（含 persona+技能块）每轮完整复制，长流程可常驻约 1MB。
### [一般] `SqlMemoryStore.search` 的 rerank 分支每候选一次 `repo.colbert()`
- **位置**：src/store/PostgresMemoryStore.cj:123-133（:135-167）
- **描述**：候选 ≤4·topK 即约 40 次额外 IO、约 5e6 乘加；选择排序每比较做 2 次 HashMap 查找。

## R7
### [严重] 附件落盘文件名未净化，存在路径穿越 / 任意文件覆盖
- **位置**：src/channel/EmailChannel.cj:76（:92、:113-115）
- **描述**：`freeName` 直接 `${directory}/${filename}` 拼接，filename 来自远端邮件，含 `../` 即可写出目录，`File.create` 为截断写。
### [严重] `channelSend` 附件路径无访问约束，模型可外发宿主任意可读文件
- **位置**：src/channel/EmailChannel.cj:156-160（src/channel/ChannelFunctions.cj:82-90）
- **描述**：发送侧只 `exists()`，不校验普通文件、无目录白名单，提示注入即可外发 `~/.ssh/id_rsa`，未对齐 `SsrfGuard` 式防线。
### [严重] `AttachmentSink` 的「先探测再创建」存在 TOCTOU，可能静默覆盖已有附件
- **位置**：src/channel/EmailChannel.cj:113-116
- **描述**：`exists` 探测与 `File.create` 非原子且 create 截断，并发两个 `channelInbox` 可能同名覆盖。
### [一般] `FEmailTransport.receive` 吞掉所有异常，配置错误被伪装成「0 封邮件」
- **位置**：src/channel/EmailChannel.cj:267-271
- **描述**：IMAP/密码/主机/TLS 失败全变空列表，`channelInbox` 返回 `[]` 而非 `ok:false`，与 send 语义不对称。
### [一般] 单条附件读取失败会中断整批收信
- **位置**：src/channel/EmailChannel.cj:173（:260-262）
- **描述**：`item.read()` 异常穿透到 `channelInbox` 的 catch，整批消息丢弃并退化为一条 `ok:false`。
### [一般] 实例登记：覆盖不关闭、无 `close` 入口、空账号实例互相覆盖
- **位置**：src/channel/ChannelMediator.cj:96-101（:194-206）
- **描述**：`register` 覆盖旧实例不 close 泄漏连接，`account=''` 两实例静默互覆盖，`FEmailTransport.client` 是无锁 `var`。
### [一般] `ChannelBootstrap` 解析：`null` 变字面量 "null"、端口截断不校验、必填项不校验
- **位置**：src/channel/ChannelBootstrap.cj:88-96（:98-109、:68-73）
- **描述**：`{"account":null}` 注册出账号名 `null`，`UInt16(70000)` 截断为 44672、`"abc"` 回退 465，`smtpHost/user` 为空也计入 installed。
### [一般] `tls` 与 `extra` 解析后无人消费，配置项形同虚设
- **位置**：src/channel/ChannelContract.cj:146-147（:161-162）
- **描述**：全仓无读取点，`"tls":"starttls"` 不改变行为，易误以为已加固。
### [一般] `dispatch` 二次校验失败后不摘除陈旧路由，选路阶段仍有可外抛的存储调用
- **位置**：src/loom/Supervisor.cj:179-181（:167）
- **描述**：状态漂移只返回 `NO_USABLE` 不 `unregister`，陈旧路由反复被选中白烧 LLM；`service.status()` 在 try 外，存储不可用时异常穿透。
### [一般] `restoreFailed` 在装配路径上是死信号
- **位置**：src/loom/LoomWiring.cj:67（src/loom/LoomBootstrap.cj:23-31）
- **描述**：`wire` 丢弃 `ReloadResult`、`toString()` 不打印该字段，库晚就绪时路由表静默为空且无日志。
### [一般] `ChannelBootstrap.installFromConfig()` 未加保护，通道配置异常可中断整个 loom 装配
- **位置**：src/loom/LoomWiring.cj:78（src/channel/ChannelBootstrap.cj:84-86）
- **描述**：`LLMConfig.channelsJson()` 在 try 外求值，异常直接抛穿 `wire()`，后续 Supervisor/SkillCatalog/演进全不执行。
### [一般] 装配顺序：`wire` 覆盖调用方已装的 host，Supervisor 可能绑到不一致宿主
- **位置**：src/loom/LoomWiring.cj:76（:111-114）
- **描述**：`installHost` 无条件覆盖使自定义 host 永不生效；`LoomServices` 静态态为裸 `static var` 无锁。

TODO_READY 严重 9 条 / 一般 48 条
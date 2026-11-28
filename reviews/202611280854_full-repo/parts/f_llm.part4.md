# f_llm 模块审查报告（模块第 4/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分：`f_llm/doc/spec/**` 共 20 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比，所有问题来源记为「存量」）
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG；本部分清单全部是 5 个变更的 spec 文件（`fix-channel-attachment-safety` / `fix-channel-robustness` / `fix-evolution-watermark` / `fix-loom-experience-persona` / `fix-loom-extract-data-loss`）与 `fix-loom-memory-owner/design.md`，实际落点是「文档承诺 ↔ 实现」的契约核对
- **报告版本**：v1（本部分分报告，待主 Agent 与 1–3、5–25 部分合并为 `docs/review/2026-11-28/f_llm.md`）

> 说明：本部分清单内没有 `.cj`，§1/§2/§3/§11/§12 的机械检查落在**文档点名的符号与验收场景**上——凡文档声称「有 / 默认 / 必须 / 已验证」的能力，都在 `src/` 里查到实现位置或确认不存在。正文引用的代码位置只作为文档一致性的**证据**，代码本身的审查由其它子轮负责。
>
> 去重说明：`fix-channel-attachment-safety/design.md` 属第 3 部分，其「`isRegular` / 符号链接未落地」已由第 3 部分报为一般项；本部分只补该变更 **spec / tasks 侧**的验收口径问题，合并时并入第 3 部分对应条目。`doc/spec` 未归档、`experience` 双 kind 的网关分页、docId 唯一性、提炼静默失败已由第 5 部分覆盖；水位线「时间戳与 id 混用量纲」「`schedule` 的 clock 默认 0」已由第 17 部分覆盖，本部分不重复计数。本部分新增的 #1（取数方向导致超量场景不可达）与 #8（两份归档 spec 对分页方案结论相反）在其它部分均未出现。

## 发现

### [严重][存量] #1 水位线的「超量不丢」保证不成立：取数始终是「最新 500 条」，spec 的「超量」场景不可达

- **位置**：
  - 承诺：`f_llm/doc/spec/fix-evolution-watermark/specs/loom-flow/spec.md:15-18`（Scenario「素材超过单轮上限」：本轮只取到 500 条、最大 `at = 200`，库里还有 `at = 201…900`，水位线 200，下一轮仍能取到）
  - 取数：`f_llm/src/loom/SkillEvolutionJob.cj:266-270`（`load` 无 `since` 参数）、`:272-306`（`experiencesOf` 固定 `"offset":0,"limit":<limit>`，既不下推 `since` 也不指定顺序）
  - 过滤与推进：`f_llm/src/loom/SkillEvolutionJob.cj:247-257`（`fresh` 只留 `at == 0 || at > since`）、`:234-241`（水位线 = 本轮 `fresh*` 集合的最大 `at`）
  - 存储顺序：`f_llm/src/loom/LoomStoreGateway.cj:147-163`（走 `listByKind`）、`f_llm/src/dao/mysql/MemoryDAO.cj:141,153`、`f_llm/src/dao/postgres/MemoryDAO.cj:159,171`（均为 `ORDER BY save_time DESC`）；`f_llm/src/store/InMemoryStores.cj:122-141`（HashMap 遍历，顺序未定义）
- **来源**：存量（快照模式无基线；该 spec 与对应实现同属已归档变更 `fix-evolution-watermark`）
- **判据**：review-checklist §13（规格与实现漂移）+ §11（契约与实现不符）+ 严重度表「数据丢失」
- **证据**：静态确定 —— 查询没有 `since` 下推、SQL 明确 `save_time DESC`、水位线取「本轮结果集的最大 `at`」，三条事实串起来即可判定；spec 场景要求「取到的是最旧的一批」，与存储契约相反
- **描述**：该变更要消灭的是「单轮 `limit` 溢出导致永久跳过」，实现把水位线换成「本轮处理过的最大 `at`」，但**取数方向没改**：
  1. 某轮新增 700 条（`at = 1000..1699`），`load` 取 `ORDER BY save_time DESC LIMIT 0,500`，拿到的是 `at = 1200..1699`；
  2. `advanced = 1699`，水位线推进到 1699（`SkillEvolutionJob.cj:236`）；
  3. 下一轮 `load` 仍取最新 500 条，`fresh()` 用 `at > 1699` 过滤，`at = 1000..1199` 那 200 条**从未被取到、也永远不满足条件** → 永久跳过，且 `report.rejected/skipped` 里不会出现。

  也就是说 bug 从「since 之后的溢出」搬到了「窗口之下的溢出」，后果与原缺陷同类（静默丢样本）。`design.md:10-11` 否决分页取数的理由是「memory.list 不支持按 `at` 过滤」，但没有意识到「不支持过滤」同时意味着**无法保证返回最旧的一批**，所以 spec 的场景二在当前存储契约下不可达。放大因素：`StoreContracts.cj:48-64` 的 `listByKind` 默认实现是「取一页再过滤」，SQL 版虽带 `kind` 条件但仍是 DESC，单 kind 的实际批量会小于 500；内存后端按哈希序返回，同一份代码在不同后端下降级到哪个窗口不确定。
- **建议**：任选一条并补「新增 > `limit`」的回归用例（现有用例只覆盖单轮装得下的情形）：
  1. 给 `MemoryStore.list/listByKind` 契约加 `since`（`save_time > since`）并下推到 SQL `WHERE`，`load` 传 `state.lastRunAt()`；
  2. 或改按 `at` 升序游标取数（`ORDER BY save_time ASC, id ASC` + keyset），水位线语义不变；
  3. 或退一步：当返回条数 `== limit` 时**不推进**到该批的最大 `at`（只推进到批内最小值之前），并记 warn。
  无论哪种，都应把「返回顺序」写进 `StoreContracts.MemoryStore` 的接口注释，避免下一个调用方重踩。

### [一般][存量] #2 水位线在「本轮零素材」时仍推进到 `now`，与规格「MUST NOT 直接推进到当前时间」相反

- **位置**：`f_llm/doc/spec/fix-evolution-watermark/specs/loom-flow/spec.md:7-8`（承诺）；实现 `f_llm/src/loom/SkillEvolutionJob.cj:234-242`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）+ §11（错误处理缺失：静默跳样本）
- **证据**：静态确定 —— ①spec 写「水位线 MUST 推进到本轮实际参与处理的素材中最大的 `at`，MUST NOT 直接推进到当前时间；**没有带时间戳的素材时** MUST 保持原有按轮次推进行为」；②实现把两种情形合并成一个 `else`：`if (advanced > 0) { if (advanced > state.lastRunAt()) { state.markRun(advanced) } } else if (now > 0) { state.markRun(now) }`；`advanced == 0` 既包含「只有 `at = 0` 的知识文档」（设计 D3 认可），也包含「本轮一条新素材都没有」，后者被规格明确禁止；③design.md:17-20 只对 `at == 0` 情形给了理由，未覆盖零素材。
- **描述**：零素材那轮仍把水位线推到 `now`。`now` 在 `schedule` 里于 `run` 之前取得（`SkillEvolutionJob.cj:389`），所以本轮之后写入且 `at ≈ 真实时间` 的素材不会丢；但两类素材会被永久跳过：其一，写入方时钟慢于演进方、`at` 落在 `(lastRunAt, now)` 的回填/跨实例写入（状态存储支持 postgres/mysql 多后端，`doc/loom.md:349`；若多实例共享同一元数据库，这条成立）；其二，`at` 由别处提供（测试、导入、定时任务传固定值）而落在水位线之下。命中后该素材既不被处理也不报错，与 #1 是同一类后果。
- **建议**：把零素材与 `at == 0` 分开——只有「本轮确实取到了素材但全部 `at == 0`」才 `markRun(now)`；零素材直接不推进（或推进到 `min(now, 已观测最大 at)`）。同时补一条用例：`since = 100`、本轮零素材 → `lastRunAt()` 仍为 100；并把 spec:7-8 的「没有带时间戳的素材」写清是否包含零素材。
- **备注**：未定为严重，因为触发依赖「`at` 来源与演进进程时钟不同源或多实例提交晚于本轮读取快照」；若确认部署形态是多实例共享元数据库，本条应升为严重。

### [轻微][存量] #3 `fix-channel-attachment-safety` 的 tasks 声称「符号链接拒绝」用例已验证，实际不存在该用例

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/tasks.md:18`（3.2 验证口径「4 条（根内成功、根外拒绝、符号链接拒绝、未配置拒绝）」）；`specs/platform-channel/spec.md:7`（MUST NOT 是符号链接）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（验收口径与实现/用例不符）+ §14（承诺但未实现）
- **证据**：静态确定 —— ①`src/channel/EmailChannel_test.cj` 共 17 个用例，发送侧只有 `testSendAllowsAttachmentInsideRoots:210` / `testSendRejectsAttachmentOutsideRoots:233` / `testSendRejectsWhenRootsUnconfigured:258` / `testSendRejectsDirectoryAsAttachment:279`，全文件搜 `symlink` / `symbolic` 零命中；②实现 `EmailChannel.cj:220-246` 只做 `exists` → `canonicalize` → 前缀比较 → `isDirectory`（`:239`）；③代码侧的 `isRegular` / 符号链接缺口已由第 3 部分报为一般项（`f_llm.part3.md` 第 31 行起），本部分只计入「验收口径被替换」这一文档问题。
- **描述**：这条 tasks 勾选把一个**不存在**的用例登记为已验证，导致「安全约束已收口」的结论没有测试支撑：根目录内指向同根另一文件的符号链接、FIFO / 设备文件仍会通过 `send` 校验。第 4 条实际是「目录」用例，验收口径被悄悄替换过。
- **建议**：与第 3 部分的修复一起收口——`checkAttachment` 补 `FileInfo(...).isRegular()` + `isSymbolicLink()`，把 tasks 3.2 的「符号链接拒绝」改成真实用例（建软链 → 断言 `ok=false`、`transport.sent.size == 0`）；在补齐前把该勾去掉。

### [轻微][存量] #4 同一份 spec 对 email 必填项的口径不一致：spec 要求 `from`，实现与其它文档只要求 `user`/`smtpHost`

- **位置**：`f_llm/doc/spec/fix-channel-robustness/specs/platform-channel/spec.md:49`；实现 `f_llm/src/channel/ChannelBootstrap.cj:116-130`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（同一能力的多处文档口径分叉）
- **证据**：静态确定 —— spec 写「email 平台 MUST 校验 `from`/`user`/`smtpHost` 非空」；`validate()` 只抛 `missing smtpHost`（`:120-122`）与 `missing user`（`:123-125`），没有 `from` 分支；`doc/loom.md:59` 写的是「email 必填 `user` / `smtpHost`」，`README.md:790` 的 `llm_channels` 行也未提 `from`；同变更 `tasks.md:13` 只要求「缺 `smtpHost` → skipped」。
- **描述**：`from` 留空在实现里是**合法**的——`EmailChannel.send` 在 `from` 为空时回落到 `conf.user`（`EmailChannel.cj:322-326`），这是设计意图，不是遗漏。因此 spec 的这条 MUST 是过严描述：按 spec 验收会判实现不合规，按实现写文档则会漏掉「回落」这个真实语义。
- **建议**：把 spec:49 改成「email 平台 MUST 校验 `user`/`smtpHost` 非空；`from` 可为空，发送时回落到 `user`」；顺手在 `doc/loom.md` 通道小节点明回落规则。

### [轻微][存量] #5 `fix-loom-experience-persona` 的设计与规格仍写 `kindOf`（单值），实现已改为 `kindsOf`（成功+失败两类）

- **位置**：`f_llm/doc/spec/fix-loom-experience-persona/design.md:13`、`specs/loom-flow/spec.md:7`；实现 `f_llm/src/loom/LoomStoreGateway.cj:147-149,384-400`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（设计/规格与实现漂移）
- **证据**：静态确定 —— ①design D1 写「一行改动：`let kindFilter = kindOf(args, defaultKind)`」，spec 写「MUST 只返回 `kind=experience` 的记录」；②`list` 分支实际调 `kindsOf(args, defaultKind)`，该方法在 `defaultKind == 'experience'` 时返回 `['experience', 'experience_failed']` 两个 kind（`:391-394`）；③`doc/loom.md:294` 已把这个语义写成正式约定「不指定 `kind` 时**同时覆盖**两类经验」。
- **描述**：实现是对的（失败经验也是经验），滞后的是这份变更文档：它把一个已被后续变更取代的单值口径留在 design/spec 里，读者按它做验收会误判「失败经验不该返回」。
- **建议**：design.md:13 改为 `kindsOf`，spec.md:7 的措辞改成「只返回经验类记录（成功 `experience` 与失败 `experience_failed`）」，并指向 `doc/loom.md:294`。

### [轻微][存量] #6 `fix-loom-memory-owner` 以「≈60 字符」断言 docId 安全，但 `namespace` / `flow` 无长度与字符集约束

- **位置**：`f_llm/doc/spec/fix-loom-memory-owner/design.md:7,32`；实现 `f_llm/src/loom/LoomMemoryPolicy.cj:156,160-165`、`f_llm/src/loom/SkillEvolutionJob.cj:314-316`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（设计结论缺前提）+ §11（长度/字符集边界未校验，失败被静默吞掉）
- **证据**：静态确定 —— ①design D1 称 `loom:<userId>:<namespace>:<flow>:<stamp>-<seq>` 同时解决「跨重启不撞号 + 按前缀过滤」，风险表写「字段是 `VARCHAR(128)`，实测格式 ≈ 60 字符，安全」；②列宽证据在 `f_llm/src/store/it/KnowledgeConformance_test.cj:47`（`doc_id VARCHAR(128) PRIMARY KEY`）；③`extract` 直接拼接 `policy.namespace` 与 `flowName` 写入 docId（`LoomMemoryPolicy.cj:156`），全仓没有任何长度/字符集校验，upsert 失败被 `catch (error: Exception) { () }` 吞掉（`:160-165`）；④`ownedBy` 用 `docId.startsWith('loom:<userId>:<namespace>:')` 判归属（`SkillEvolutionJob.cj:315`）。
- **描述**：两条都由「归属塞进字符串」带来：其一，`namespace` + `flowName` 超过约 90 字符时 docId 超 128，PG/MySQL 插入失败或报错被吞，知识静默不落库（记忆与经验仍写成功，所以从流程结果看不出少了一半）；其二，`namespace` 或 `flowName` 含 `:` 时前缀判定会串味——`namespace='work:daily'` 写入的 `loom:7:work:daily:x:1-1` 会被 `ownedBy(id, 7, 'work')` 判为本租户知识，正是 D4 声称要防的「串味」。两者都不需要恶意输入，命名习惯（`team:proj` 这类带冒号的命名空间）就能触发。
- **建议**：写入侧对 docId 做长度上限校验（超限时截断 `flowName` 或抛明确错误，别让 upsert 静默失败），并禁止 `namespace` / `flowName` 含 `:`（或改用 `\u{0001}` 之类的分隔符，和 `ChannelMediator.keyOf` 的既有做法一致，`ChannelMediator.cj:47`）；`ownedBy` 同时校验分隔符位置，避免前缀误判。

### [轻微][存量] #7 `fix-loom-extract-data-loss` 提案的用例数与它自己列出的类别不符（6 条 vs 4+1+1+3 条）

- **位置**：`f_llm/doc/spec/fix-loom-extract-data-loss/proposal.md:18`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档内部不自洽）
- **证据**：静态确定 —— 原文「补 6 条用例：TextClip 四种输入、中文长正文提炼、中文长知识切块、三种 summarize 回落」，逐项相加为 4+1+1+3 = 9 条；同变更 `tasks.md:7-19` 列出的条目更多（1.1 四条、1.2 emoji、2.1、2.2 回归、3.1–3.3、4.1–4.2）；实际 `src/util/TextClip_test.cj` 有 5 个用例，也已超出「四种输入」。
- **描述**：纯计数字面错误，会让人误判补齐程度（第 3 部分也报过 `cover-loom-test-gaps` 的同类问题，说明这是模板化写作留下的固定噪声）。
- **建议**：改成「补 9 条用例」或删除具体数字，只保留分类清单。

### [轻微][存量] #8 `fix-loom-memory-owner` 的「未覆盖」条目与 `fix-evolution-watermark` 的结论相反，且未标注已被取代

- **位置**：`f_llm/doc/spec/fix-loom-memory-owner/design.md:35-37`（「演进素材 `limit=500` 与水位线无条件推进……需要把 `state.markRun(now)` 改成『推进到已处理的最大 at』，**并配分页取数**，属独立设计」）对比 `f_llm/doc/spec/fix-evolution-watermark/design.md:10-11`（「把 `load` 改成游标分页（按 `at` 递增取）。**否决**——需要改存储查询契约」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档过期 / 两份规格互斥）
- **证据**：静态确定 —— 两份归档 spec 同在 `f_llm/doc/spec/` 下，对同一后续工作给出互斥方案，前者的「未覆盖」段没有「已由 `fix-evolution-watermark` 处理」的指向
- **描述**：水位线改造已落地（`SkillEvolutionJob.cj:234-241`），分页取数被明确否决；`fix-loom-memory-owner` 仍把「分页取数」写成待办方案。读者会误以为分页是既定路线，而实际结论相反。叠加上 #1：被否决的分页/`since` 下推正是「超量不丢」缺失的那一环，两份文档合起来正好把这个决策缺口暴露出来。
- **建议**：在 `fix-loom-memory-owner/design.md` 的「未覆盖」段补一句「水位线部分已由 `fix-evolution-watermark` 处理（分页方案被否决，遗留风险见该变更）」，或删掉该段只留链接；若采纳 #1 的 `since` 下推，则两处一并更新。

### [轻微][存量] #9 `llm_channelSendRoots` 文档写「绝对路径」，实现不校验绝对性

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/proposal.md:14`（「新配置 `llm_channelSendRoots`（逗号分隔**绝对路径**）」）对比 `f_llm/src/config/LLMConfig.cj:227-244`（按逗号切分 + `trimAscii`，无绝对路径校验）；消费侧 `f_llm/src/channel/EmailChannel.cj:230-237` 直接 `canonicalize(Path(root))`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（配置约束与源码不符）
- **证据**：静态确定 —— 读取函数无路径形态校验；`canonicalize` 对相对路径按进程 cwd 解析（官方文档 `cangjie-doc/cangjie-doc/md/doc/cjapi/fs.md:13`：解析 `..` 与符号链接、返回绝对标准路径）
- **描述**：配置写成相对路径时不会在装配期报错，而是在发信时按**进程启动目录**解析成某个目录，把「允许根」变成随部署方式漂移的值；`~` 不展开，该项会 `canonicalize` 失败并在 `checkAttachment` 的 `continue`（`EmailChannel.cj:235`）里被静默跳过，极端情况下所有根都不可用而表现成「一律拒发」。
- **建议**：`channelSendRoots()` 对每项判绝对路径（`Path(item).isAbsolute()`），非绝对直接丢弃并 warn；`README.md:791` 的配置说明同步写明「必须是绝对路径，否则忽略」。

## 优化可行性方案

本部分为纯文档，未提出堆内存 / CPU 优化方案：文档侧没有可执行的分配或算法改动，且本部分无 `cjprof` / `cjpm bench` 数据，按铁律不虚列方案（实现侧的候选方案见第 1、5 部分）。

> #1 的修复（`since` 下推或升序游标）属于**查询契约变更**，不按「性能优化」立项；若顺带减少扫行数，也必须先有改前改后 `EXPLAIN` + 同数据量耗时对照，当前无基线。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | #1 的实际触发频率：真实负载下单轮新增素材是否经常超过 `limit=500` | `f_llm/src/loom/SkillEvolutionJob.cj:266` | 每轮 `memory.list` 返回条数、`at` 分布、水位线推进值 | 在 `run` 里打一条结构化日志（返回条数 / max `at` / 新水位），跑一周稳态统计「返回条数 == 500」的轮次占比 |
| 2 | `AttachmentSink` 用**单个静态** `Mutex` 串行全部目录的落盘，批量收信（多账号并行 `channelInbox`）时落盘段可能成为串行段 | `f_llm/src/channel/EmailChannel.cj:77,160-164` | 临界区单次持有时长、并发收信路数、`save` 端到端 p50/p99 | 20 路并发对同一目录各存 500 个附件，`-O2` 下记录 `save` 的 p50/p99 与吞吐；对照「按目录分片锁」版本 |
| 3 | 部署侧允许根目录里是否真有软链 / 特殊文件（决定 #3 的实际可利用面） | `f_llm/src/channel/EmailChannel.cj:220` | `llm_channelSendRoots` 指向目录的实际内容与权限 | 目标环境对每个根跑 `find <root> -type l -o -type p` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/doc/spec/fix-channel-attachment-safety/proposal.md` | .md | ✅ | 三处安全缺口与「6 条用例」与 tasks 对应；「未配置则禁用附件」在 `EmailChannel.cj:207-210` 成立；「绝对路径」无校验，见 #9 |
| 2 | `f_llm/doc/spec/fix-channel-attachment-safety/specs/platform-channel/spec.md` | .md | ✅ | 发送/接收场景逐条核对；「MUST 普通文件 / 非符号链接」未落地，见 #3（并入第 3 部分） |
| 3 | `f_llm/doc/spec/fix-channel-attachment-safety/tasks.md` | .md | ✅ | 1.1/2.1/2.2/3.1/3.3/4.x 与代码及用例一致；3.2「符号链接拒绝」无用例，见 #3 |
| 4 | `f_llm/doc/spec/fix-channel-robustness/design.md` | .md | ✅ | D1–D6 与实现逐条一致（`receive` 两分语义 `EmailChannel.cj:351-374`、`closeAll` `ChannelMediator.cj:208-219`、`strOf` 处理 `JsonNull` `ChannelBootstrap.cj:95-109`） |
| 5 | `f_llm/doc/spec/fix-channel-robustness/proposal.md` | .md | ✅ | 6 条 What Changes 均有实现落点；`tls:starttls` 拒绝见 `ChannelBootstrap.cj:126-129` |
| 6 | `f_llm/doc/spec/fix-channel-robustness/specs/platform-channel/spec.md` | .md | ✅ | 收信失败显式、附件单条隔离、替换即释放、端口/必填/tls 校验均成立；仅 `from` 必填与实现不符，见 #4 |
| 7 | `f_llm/doc/spec/fix-channel-robustness/tasks.md` | .md | ✅ | 1.1–1.3 / 2.1–2.5 / 3.1 在 `ChannelMediator_test.cj:185,200,215`、`ChannelBootstrap_test.cj:101,116,130,143`、`EmailChannel_test.cj:306` 全部命中 |
| 8 | `f_llm/doc/spec/fix-evolution-watermark/design.md` | .md | ✅ | D1 的「批大小 + 精确水位线已能保证不丢」缺「取数方向」前提，见 #1；D3 只覆盖 `at == 0`，未覆盖零素材（见 #2）；D1 的「否决分页」是 #8 的对照项 |
| 9 | `f_llm/doc/spec/fix-evolution-watermark/proposal.md` | .md | ✅ | 「limit 变批大小」与 `fresh()` 语义（`SkillEvolutionJob.cj:247-257`）一致，但「下一轮还能取到」不成立，见 #1 |
| 10 | `f_llm/doc/spec/fix-evolution-watermark/specs/loom-flow/spec.md` | .md | ✅ | 「只前进不后退」成立（`SkillEvolutionJob.cj:236`）；场景二不可达（见 #1）；「MUST NOT 推进到 now」被零素材分支违反（见 #2） |
| 11 | `f_llm/doc/spec/fix-evolution-watermark/tasks.md` | .md | ✅ | 1.1–1.3 与实现/用例对应；缺「新增 > `limit`」回归用例；2.1 的用例总数无法在快照内复核（需跑 `cjpm test`） |
| 12 | `f_llm/doc/spec/fix-loom-experience-persona/design.md` | .md | ✅ | D2/D3 与 `LoomRunner.cj:384-420` 一致；D1 的 `kindOf` 已被 `kindsOf` 取代，见 #5 |
| 13 | `f_llm/doc/spec/fix-loom-experience-persona/proposal.md` | .md | ✅ | 三条修正均已落地；「全仓仅 gateway 测试与 E2E 使用」未复核（不在本部分范围） |
| 14 | `f_llm/doc/spec/fix-loom-experience-persona/specs/loom-flow/spec.md` | .md | ✅ | 「显式 kind 优先」「default 不注入」「空 content 下沉」「未知 key 回落字面」均成立（`LoomStoreGateway.cj:386-399`、`LoomRunner.cj:394-419`）；仅「只含 experience」措辞滞后 |
| 15 | `f_llm/doc/spec/fix-loom-experience-persona/tasks.md` | .md | ✅ | 1.1–2.4 与实现/用例一一对应；3.2 的 `doc/loom.md:419-421` 已补 |
| 16 | `f_llm/doc/spec/fix-loom-extract-data-loss/design.md` | .md | ✅ | D1–D5 全部落地（`TextClip.cj:32-51`、`LoomMemoryPolicy.cj:251-253`、`KnowledgeChunker.cj:66-124`、`doc/f_llm-memory-design.md:93,98`）；Open Question 的 grapheme 口径遗留属显式声明 |
| 17 | `f_llm/doc/spec/fix-loom-extract-data-loss/proposal.md` | .md | ✅ | What Changes 5 条均有落点；用例数 6 vs 9 不符，见 #7 |
| 18 | `f_llm/doc/spec/fix-loom-extract-data-loss/specs/loom-flow/spec.md` | .md | ✅ | 三条 Requirement 与实现一致：按字符截断、按字段独立回落（`LoomMemoryPolicy.cj:130-137`）、rune 滑窗（`KnowledgeChunker.cj:107-122`） |
| 19 | `f_llm/doc/spec/fix-loom-extract-data-loss/tasks.md` | .md | ✅ | 1.1–5.3 与用例/文档对应；5.2 的「基线 585」无法在快照内复核 |
| 20 | `f_llm/doc/spec/fix-loom-memory-owner/design.md` | .md | ✅ | D2（`PolicyBox` `LoomMemoryPolicy.cj:27`）、D3、D4（`SkillEvolutionJob.cj:314`）、D5（`LoomRunner.cj:245,251`）均落地；docId 长度/字符集前提不成立（#6）；「未覆盖」段与水位线变更结论相反（#8） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 #2（水位线取数方向与零素材分支）；安全 #3（特殊文件/软链未校验，代码侧归第 3 部分）；契约口径 #4 #5 #9；设计前提 #6；可读性/计数 #7；规格互斥 #8。语言特性 0：本部分无代码 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可见性可判。改查「文档点名的符号是否仍存在并被调用」：`bareName`/`freeName`/`save`（`EmailChannel.cj:86,119,148`）、`closeAll`（`ChannelMediator.cj:208`）、`strOf`/`portOf`/`validate`、`kindOf`/`kindsOf`（`LoomStoreGateway.cj:136,149,412` 均有调用方）、`ownedBy`、`TextClip.clip`、`PredefinedCharacters.isKnown` 逐个在 `src/` 检索，全部命中；文档内无「写了但永不触发」的残留条目 |
| §2 重复逻辑 | 0 | 已把 20 个文件的 Decision / What Changes / Requirement 段落两两比对：`proposal` 与 `design` 的复述是 openspec 结构要求（checklist §2 误报边界）；唯一的语义分叉是 spec/design 与 `doc/loom.md` 对同一规则的两套口径（#4 #5）以及两份 spec 对分页方案的相反结论（#8），按「文档漂移」归类而非重复逻辑；实现侧 `KnowledgeChunker` 的 local/heap 双循环体已有注释说明为 local mode 必须拆开，不判重复 |
| §3 空实现 | 0 | 逐条核对文档声称的行为是否有实体：无 `TODO`/`FIXME` 占位；`fix-loom-extract-data-loss` 的 `catch` 无日志一项属其 Non-Goals 显式排除，且已由第 5 部分覆盖 |
| §4 栈溢出 | 0 | 文档层无递归结构；被引用的 `resolvePersona` / `ownedBy` / `split` 均为单层循环或固定层级回落（三级），无输入决定深度的递归 |
| §5 OOM | 0 | 文档给出的容量约束齐全：`docId` 128 列宽见 #6；附件落盘为单文件字节数组（`item.read()`），无整目录物化承诺；切块全文 Rune 展开的峰值问题已在第 1 部分报过。#1 是「取数窗口取错方向」而非无界增长，未按 OOM 计 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，热点结论不成立；唯一疑似点写入「待验证假设」#2 |
| §6.2 大粒度锁 | 0 | 文档唯一涉及的锁是 `AttachmentSink` 的进程内 `Mutex`，临界区只含「选名 + `File.create`」（`EmailChannel.cj:160-164`），无 I/O 写入、无回调；粒度问题降为待验证假设 |
| §6.3 并发串行 | 0 | 文档未描述「spawn 后立刻 get」类结构；`ChannelMediator.closeAll` 串行关闭是关闭路径，单一入口的低频操作，不构成热点 |
| §6.4 低效算法 | 0 | 文档层无算法描述可判复杂度；`freeName` 的 `while(true)` 线性探测文件名冲突是 O(冲突数)，冲突数由目录内容决定，无数据不判 |
| §7 降堆内存方案 | 0 | 本部分为 `.md`，无对象可改；无基线数据，按要求不产出方案 |
| §8 降 CPU 方案 | 0 | 同上；无 `cjpm bench` / `cjprof` 数据 |
| §9 local mode 可行性 | 0 | 本部分文档未主张 local mode；`KnowledgeChunker` 的 local 改造是既有实现（`local-mode-f-llm-knowledge-chunker`），不在本部分清单 |
| §11 现有代码的 BUG（存量） | 9 | #1 水位线超量场景不可达（静默丢样本）；#2 零素材推进到 `now`；#3 特殊文件/软链通过附件校验（附带的取证实测缺口）；#4 必填口径分叉；#5 单值/双 kind 口径滞后；#6 docId 无长度与字符集校验、upsert 失败静默；#7 用例数自相矛盾；#8 两份规格互斥；#9 根目录绝对路径无校验 |
| §12 并发安全与锁粒度 | 0 | 文档关于并发的三处主张均自洽：`AttachmentSink` 进程内串行（`known-limitations.md:126-129` 明确只做进程内）、`ChannelMediator` 全部状态在 `mutex` 内、`LoomMemoryPolicy` 的 `PolicyBox` 带出锁内值（`LoomMemoryPolicy.cj:89-95`）；跨进程落盘竞态已列为已知限制，文档与实现一致 |
| §14 功能完备性与 README 覆盖 | 2 | #3（spec/tasks 承诺的符号链接校验与用例缺失）、#4（`from` 必填承诺未实现）；README 配置表本身已含 `llm_channelSendRoots`（`README.md:791`、`README_en.md:782`），中英同步 |
| 文件覆盖（§13 等） | 20/20 | 无缺项；`doc/spec` 其余 40+ 个变更目录与 `archive/` 不在本部分清单，由第 2、3、5 部分覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 1 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

（存量 9 条：严重 1、一般 1、轻微 7；是否纳入修复待用户决定。）

## 总评

这 20 份文档的整体质量高于模块平均：`fix-channel-robustness`、`fix-loom-extract-data-loss` 的设计与实现几乎逐条对得上（`strOf` 的 `JsonNull`、端口区间、`receive` 两分语义、按字符截断、按字段独立回落、rune 滑窗都能在代码里找到精确落点与用例），`fix-loom-memory-owner` 的 `PolicyBox` / 默认值 / warn 文案也都落地了。本部分的问题集中在两类：

1. **一条真实的数据完整性残留（#1）**：水位线变更把「推进到 now」改成「推进到已处理的最大 `at`」，但取数仍是 `ORDER BY save_time DESC LIMIT 500`，拿到的是**最新**一批；单轮新增超过 `limit` 时，窗口之下那部分素材会被 `fresh()` 永久过滤。这正是该变更宣称消灭的「静默丢样本」，只是换了个位置，而它的验收场景（「取到 500 条、最大 `at = 200`」）在当前存储契约下不可达——用例只覆盖了「单轮装得下」，恰好绕过要修的那类负载。次一级的 #2（零素材推进到 `now`）是同一处状态记账的另一半缺口。
2. **文档与实现的细粒度漂移（#3–#9）**：符号链接用例被登记为已验证但不存在、`from` 必填口径三处不一、`kindOf` 已被 `kindsOf` 取代、docId 的 128 列宽前提没有约束兜底、用例数 6 vs 9、两份归档 spec 对「分页取数」结论相反、`channelSendRoots` 的「绝对路径」无人校验。这些都是「按文档验收会误判」的类型，改动成本低（改文案 + 补一条用例 + 加一处校验）。

阻塞项：#1 应阻塞 `fix-evolution-watermark` 的「已修复」结论——它是该变更的原始目标，且后果是静默丢素材。可排期项：#2 随下次演进变更一起改；#3 与第 3 部分的 `isRegular` 修复合并做；#4–#9 可并入同一次文档整理提交（#8 建议与 #1 的 `since` 下推决策一起定稿，避免再次互相矛盾）。

### 范围外提示（不计入本部分统计）

- `AttachmentSink.freeName` 在 `while (true)` 之后还有 `base`（`f_llm/src/channel/EmailChannel.cj:142`），不可达语句，属 channel 代码分部分。
- `LoomMemoryPolicy.cj:25-26` 两条 doc 注释都挂在 `PolicyBox` 上，第一条（「序号用持有者带出」）是 `DocSeqBox` 的残留，且 `DocSeqBox` 反而没有注释。
- `LoomWiring.cj:119` 用 `let _ = ChannelBootstrap.installFromConfig()` 丢掉装配报告，而 `README.md:790` / `README_en.md:781` 承诺「单条非法只跳过并 warn」——通道包内 `LoggerFactory` 零命中，`ChannelInstallReport.errors` / `summary()` 全仓无人消费，非法条目实际是静默的（建议在 channel / README 分部分复核）。

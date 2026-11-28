# f_llm 模块审查报告（模块第 6/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（全模块 368 个 `.cj` + 112 个 `.md`；**本部分** 20 个 `.md`，全部位于 `f_llm/doc/spec/`）
- **基线**：工作区快照（`sts/1.3.x` 工作区，无 diff 可对照）
- **审查重点**：本部分为 OpenSpec 变更文档（proposal / design / tasks / spec delta）与三份「归档后合并的主规格」。逐条回查：存储后端配置契约（键名 / 合法值 / 启动失败）、记忆种类与命名空间隔离、记忆写入走网关、loom 工具层读能力与计划 skills、模板渲染与执行期快照、检索候选上界、知识切块 local mode；并核对任务清单 `[x]` 是否属实、文档之间是否自洽
- **报告版本**：v1

> 说明 1：本部分不含 `.cj` 源文件，所有「发现」来自**逐条核对文档承诺与实现**（§13 / §14）以及核对过程中读到的既有代码（§11 存量）。
> 说明 2：本部分全部问题来源均为 **存量**（工作区快照，无基线可比；文档侧用 `git log -- <file>` 定位引入提交）。
> 说明 3：跨部分口径 —— `doc/spec/archive/2026-10-30-f-llm-memory-storage/…` 与 `…/2026-10-31-f-llm-store-wiring/…` 的**归档副本**已由 part2 / part3 审过（按「当时结论自洽」核对）；本部分审的是 `doc/spec/{llm-content-store,llm-meta-store,llm-store-wiring}/spec.md` 这三份**合并后的主规格**，它们的内容与归档副本逐行相同（仅 `# Spec Delta` → `# <name> Specification`、加 `## Purpose`、`ADDED Requirements` → `Requirements`），但主规格承担「当前契约」职责，不适用归档豁免。#5 与 part3 发现 #13 同源，合并时归一。`fix-loom-tool-coverage/design.md` 归 part5，本部分只审该变更的 proposal / spec / tasks。

## 发现

### [一般][存量] 存储后端配置键在合并主规格里仍是已删除的 `llm_contentStore`

- **位置**：`f_llm/doc/spec/llm-content-store/spec.md:10`（`系统 SHALL 读取 llm_contentStore 决定内容族实现`）、`f_llm/doc/spec/llm-store-wiring/spec.md:31`（`启动时读取 llm_contentStore / llm_metaStore`）
- **来源**：存量 —— 主规格由 `1df859449 2026-10-30`「归档 f-llm-memory-storage，主规格落 llm-content-store / llm-meta-store」一次写成，此后无提交；同日 13 个提交之后 `9f459e0c1 2026-10-30`「删除 llm_contentStore，记忆选型统一为 llm_memoryStore」把它改成废弃键
- **判据**：review-checklist §2（同一字面量散落多处、已漂移）、§13（API / 配置默认值与源码不符）
- **证据**：静态确定 —— `f_llm/src/store/StoreSettings.cj:34` `CONTENT_KEY = 'llm_memoryStore'`，`:45` 把 `llm_contentStore` 列入 `DEPRECATED_KEYS`，`:63-70` 命中后只 `warn{'deprecated config key ignored: ...'}`、`:72` 仍取 `llm_memoryStore ?? 'f_hydra'`；`f_llm/src/store/Stores.cj:29` 同名常量、`:106` 校验读的也是 `memoryStore`。`README.md:805` 已写明旧键「只识别、不生效」
- **描述**：按主规格配 `llm_contentStore=postgres` 的用户不会切到 PostgreSQL：进程只打一条 warn，实际仍用默认 `f_hydra`（进程内内容族），记忆 / 知识写进了另一个后端。规格同时还承诺「取值未知或未注册时 MUST 启动失败」，而废弃键连校验都进不去（`StoreWiring.cj:68` 调 `Stores.bootstrap()` 读的是新键），「静默回退」正是该规格明令禁止的行为。`llm-meta-store/spec.md:10` 用的键名正确，仅内容族一处漂移
- **建议**：两份主规格统一改为 `llm_memoryStore`，并把 `llm_contentStoreUrl`（远程地址）一并补进配置段；保留一句「旧键 `llm_contentStore` 只 warn 不生效」，避免读者以为两个键等价

### [一般][存量] `llm-content-store` 主规格的可选值表、记忆种类、隔离边界均与实现相反

- **位置**：`f_llm/doc/spec/llm-content-store/spec.md:110`、`:117-118`（内存实现不得出现在可选值列表）、`:34`（预定义 7 个种类）、`:22`（`namespace` 取 `global` 或 `ws-{workspaceId}`）、`:62`（权重表）
- **来源**：存量 —— 主规格 `1df859449 2026-10-30`；实现侧 `7b39bbe94 2026-10-31`（f_hydra 设为默认内容族并在 `StoreWiring` 注册 `inMemory`）、`ab7477b52 2026-11-06`（经验 kind 纳入预定义集合）
- **判据**：review-checklist §13（规格与实现漂移）、§11（契约与实现不符）、§14.1（承诺的功能与实际不符）
- **证据**：静态确定 ——
  1. `f_llm/src/wiring/StoreWiring.cj:60` 无条件 `ensure('inMemory', { => InMemoryContentStore() })`，`Stores.content('inMemory')` 因此可选中；`README.md:239` / `:764` 把 `inMemory` 列为合法内容族。规格却写「内存实现 MUST 仅用于测试，不得出现在可选值列表」「列表为 postgres、mysql、f_hydra、fhydra，不含 memory」
  2. `f_llm/src/store/MemoryKinds.cj:80-91` `predefined()` 返回 9 个（含 `experience` / `experience_failed`，`:51-53`），`:189-191` 两者权重 0.8；规格写「预定义 7 个」且权重表无经验项
  3. `f_llm/src/memory/Memory.cj:121` `remember(..., namespace!: String = 'loom')` 默认写 `loom` 命名空间；规格把隔离边界枚举为 `global` 或 `ws-{workspaceId}`，不含 `loom`
- **描述**：三点后果分别是 ——（a）`inMemory` 不落盘，选它等于**重启即丢全部记忆与知识**，而规格里那条 MUST 正是防止这种误配，现在实现与 README 都放开了、规格还写着禁止，读者无从判断哪个是准的；（b）按规格只能数出 7 种记忆种类，`experience` 系的写入与检索权重会被漏掉；（c）规格的「跨工作空间隔离」口径不覆盖 loom 默认命名空间，按它实现检索过滤会漏掉 loom 自己写的摘要
- **建议**：以 README 的配置表为准重写该主规格的取值段与种类段；`inMemory` 若要保留为可选值，就删掉那条 MUST 并显式写明「不持久化，仅用于演示 / 测试」；若要保留 MUST，则在 `Stores.bootstrap()` 里拒绝生产选择 `inMemory`（二选一，不能两边都留）

### [一般][存量] `llm-store-wiring` 主规格承诺的「MySQL 无向量索引时降级 + warn」未实现：旧版本直接抛错、无库名时静默丢 dense

- **位置**：`f_llm/doc/spec/llm-store-wiring/spec.md:96-106`（Requirement「MySQL 与 PostgreSQL 行为一致」及其 Scenario「无向量索引时降级 → 检索仍返回结果，日志含降级 `warn`」）
- **来源**：存量 —— 规格 `03cd91532 2026-10-31`；实现侧 `f_llm/src/store/mysql/KnowledgeStore.cj` 自引入起即无该分支（`git log` 无相关提交）
- **判据**：review-checklist §14.1（承诺了但没实现）、§3（静默吞掉降级）、§11（错误处理缺失或静默）
- **证据**：静态确定 —— `f_llm/src/store/mysql/KnowledgeStore.cj:97-113`：`case Some(model)` 内 `let path = annPath()`，`if (!path.isEmpty())` 才走 `chunkSearchDense`，**没有 else、没有 try/catch、没有 warn、没有应用层余弦兜底**。`annPath()`（`:189-207`）拼 `db.llm_document_chunk.content_vec`，只有库名解析失败才返回空串；库名可解析时无论服务端版本都发 `MYVECTOR_IS_ANN(...)`（`f_llm/src/dao/mysql/KnowledgeDAO.cj:104-111`），在无该函数的 9.0/9.1 上查询直接报错并向上抛（`LoomStoreGateway.cj:114-118` 的调用无 try，最终由工具层转成 `failed` 文本）。全 `src/` 无 `VECTOR INDEX` 字面量、无 MySQL 版本探测（唯一 `9\.2` 命中是 `Planner.cj:24` 的设计章节号）；`README.md:743` 反向写「VECTOR 列与 HNSW 索引需 9.2+」
- **描述**：规格承诺「低于 9.2 时降级为应用层暴力计算并记录 `warn`，不得拒绝启动，检索仍返回结果」；实现是两条相反的失败形态 —— 库名可解析但服务端无 `MYVECTOR_IS_ANN` 时**整次检索抛错**（连词面结果都拿不到）；库名解析失败时 dense 一路**静默跳过**、只剩词面 LIKE 且日志无痕。两种都不满足规格，也都没有 `degraded` 标记（对照同规格 `:45-55` 对 BGE-M3 失败要求的 `degraded=true`）
- **建议**：二选一并写进规格 —— 要么补「无 ANN → 应用层 cosine 兜底 + 一次性 `warn` + `degraded` 标记」（`VectorMath` 已有向量字面量工具），要么把 Scenario 改成「MySQL 需 9.2+，否则启动校验拒绝」并与 `README.md:743` 对齐；无论选哪条，`annPath()` 为空的分支都应留一条 `warn`

### [一般][存量] `fix-memory-write-consistency` 的任务与设计声称 kind 字面量已改用常量，三处实现仍是字面量

- **位置**：`f_llm/doc/spec/fix-memory-write-consistency/tasks.md:6`（`[x] 1.2 ... 的 kind 字面量改用常量`）、`f_llm/doc/spec/fix-memory-write-consistency/design.md:35-37`（D4「只替换三个 loom 文件里的字面量」）
- **来源**：存量 —— 文档与该提交同批落地（`ab7477b52 2026-11-06`），代码侧未做该项
- **判据**：review-checklist §13（规格与实现漂移）、§14.1（只做了一半）
- **证据**：静态确定 —— `f_llm/src/loom/LoomMemoryPolicy.cj:145-149` 仍是 `'experience'` / `'experience_failed'` 字面量；`f_llm/src/loom/LoomStoreGateway.cj:81`、`:86-87`、`:391-393` 同；`f_llm/src/loom/SkillEvolutionJob.cj:267-268` 同。全仓 `grep 'MemoryKinds.EXPERIENCE'` **零命中**，`MemoryKinds.cj:51-53` 两个新常量只在本文件的 `predefined()` / `weightOf()` 内被引用
- **描述**：任务被勾成完成，但「消除 `experience` 字面量散落」这一目标一点没做；后续读者按 tasks 会以为已收敛，改动 kind 语义时仍要满仓搜字符串。另一面：`MemoryKinds.EXPERIENCE` / `EXPERIENCE_FAILED` 是对外可达的 `public` 常量，仓内除自身外无引用（按硬原则一**不算死代码**，仅作信息），它们的价值目前只剩「给下游用」
- **建议**：补做 1.2（三处改引 `MemoryKinds.EXPERIENCE*`，行为等价、可零风险合入）；若决定不做，把 `[x]` 改回 `[ ]` 并在 tasks 里写明原因，避免任务清单继续失真

### [轻微][存量] `llm-store-wiring` 主规格的「SQL 只出现在 DAO 层」验收场景不成立（与 part3 发现 #13 同源）

- **位置**：`f_llm/doc/spec/llm-store-wiring/spec.md:19-22`（Scenario：检查两个 Repository 源码「不出现 SELECT / INSERT / UPDATE / DELETE 字面量」）
- **来源**：存量 —— 主规格 `03cd91532 2026-10-31`；越界代码 `cdea037a40 2026-10-30` 已存在（与 part3 #13 的 blame 结论一致）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— `f_llm/src/store/postgres/MemoryRepository.cj:55-58`、`f_llm/src/store/mysql/MemoryRepository.cj:59-62`、`:127` 直接 `executor(DRIVER).setSql('DELETE FROM llm_memory_token WHERE memory_id = ?')`，注释说明是「DAO 宏对纯 DELETE 方法生成有缺陷」的绕行
- **描述**：同一段文字在归档副本（part3 已报）与主规格里各有一份；主规格这份会让按契约做 DAO 迁移的人以为 Repository 层已无 SQL
- **建议**：在该 Scenario 后补一行例外说明（哪三处、为什么、何时回收）；主规格与归档副本同步修改

### [轻微][存量] `llm-store-wiring` 主规格的 Purpose 仍是归档工具留下的 TBD 占位

- **位置**：`f_llm/doc/spec/llm-store-wiring/spec.md:4`（`TBD - created by archiving change f-llm-store-wiring. Update Purpose after archive.`）
- **来源**：存量（`03cd91532 2026-10-31` 归档提交原样带入）
- **判据**：review-checklist §3（占位未填）、§14.2（缺关键段落：用途）
- **证据**：静态确定 —— 同层两份主规格 `llm-content-store/spec.md:3-4`、`llm-meta-store/spec.md:3-4` 都有实义 Purpose，只有这份留着工具提示
- **描述**：主规格的第一段就是「待办」，读者拿不到「这份契约管什么」的一句话定义
- **建议**：补一段 Purpose：记忆 / 经验 / 知识 / 文档与元数据的存储分层、选型与启动接线

### [轻微][存量] `perf-loom-render-context` 的 design D3 与同变更 spec / tasks 对「空值占位符」的结论相反

- **位置**：`f_llm/doc/spec/perf-loom-render-context/design.md:22-24`（D3：命中但值为空 → 替换成空串，「与原 `String.replace` 行为一致」）vs `f_llm/doc/spec/perf-loom-render-context/specs/loom-flow/spec.md:20-23`、`f_llm/doc/spec/perf-loom-render-context/tasks.md:7`、`f_llm/doc/spec/perf-loom-render-context/proposal.md:17`（`{start.output}` 无事件数据时**原样保留**）
- **来源**：存量（同一变更四份文档同批提交）
- **判据**：review-checklist §13（文档之间口径不一致）、§10（正确性 / 可读性）
- **证据**：静态确定 —— `f_llm/src/loom/LoomHostApi.cj:117-122`：`token == 'start.output'` 且 `fromEvent.isEmpty()` 时不置 `handled`，走 `:139-141` 只吐 `{` 并继续扫描，占位符原样保留；而对 `{stepId.output}` 命中空串则 `:129-130` 直接 append 空值。即实现是「两种占位符两套空值语义」，与 spec / tasks 一致、与 design D3 的一句话结论相反
- **描述**：D3 是「重构中最容易错的地方」那一节的配套决策，写反了会让后续维护者按它去「修正」实现，反而把 spec 钉住的 `{start.output}` 语义改坏
- **建议**：把 D3 改为「`{stepId.output}` 命中空值 → 空串；`{start.output}` 无事件数据 → 保留占位符（与原 `replace` 只在 `fromEvent` 非空时替换的实现一致）」

### [轻微][存量] `perf-retrieval-candidates` 的「知识候选 1000→400」只覆盖带 Embedder 的构造路径

- **位置**：`f_llm/doc/spec/perf-retrieval-candidates/proposal.md:15-16`、`f_llm/doc/spec/perf-retrieval-candidates/design.md:20-23`（D4「知识候选上限降到 400 … 候选与正文全量驻留不划算」）
- **来源**：存量（变更文档与实现同批）
- **判据**：review-checklist §13（文档表述与实现范围不符）、§7（有界化未覆盖全部分支）
- **证据**：静态确定 —— `f_llm/src/store/postgres/KnowledgeStore.cj:36-52`：`init()` 与 `init(pageSize:maxCandidates!: Int64 = 1000)` 两条**无语义（lexical-only）**构造仍默认 1000；只有 `init(embedder:...)`（`:58`）是 400。`f_llm/src/store/mysql/KnowledgeStore.cj:34-52` 结构相同。而 lexical-only 实例正是「未配置 Embedder」时的生产路径（`init()` 注释：测试或未配置 Embedder 时使用）
- **描述**：proposal 的 Impact 写成无条件「知识候选 1000→400」，实际未配置 Embedder 的部署仍按 1000 条候选全量驻留正文，D4 想解决的峰值内存在这条路径上没变
- **建议**：要么把 lexical-only 的默认也降到 400（与 `pageSize=200`×2 页一致），要么在 proposal / design 里注明「仅 embedder 路径」，避免读者以为上界已统一

### [轻微][存量] `perf-loom-render-context` design D1 以「`std.sync` 只有 `Mutex`」否决读写锁，依据待确认

- **位置**：`f_llm/doc/spec/perf-loom-render-context/design.md:14`（`**替代**：细粒度读写锁。否决——std.sync 只有 Mutex`）
- **来源**：存量
- **判据**：review-checklist §10（设计依据须可核）、§12.2（锁粒度取舍要给理由）
- **证据**：待确认 —— 本机无 SDK 1.3 的标准库文档（`~/.autocode/cj/doc` 不存在，`cangjie-doc-lookup` 离线资源缺失），无法核实 `std.sync` 是否提供 `RWLock` / 读写锁；若提供，该否决理由不成立。同一句的「拷贝一张小表的成本远低于锁内做字符串替换」也没有计时数据
- **描述**：这是该设计唯一支撑「为什么不是读写锁」的论据，错了会把后续同类改造也带偏；正确性上无影响（现状用 `Mutex` + 快照 + 锁外替换是自洽的）
- **建议**：核对 SDK 1.3 `std.sync` 导出清单后改写该条（或删掉「只有 `Mutex`」只留成本论证），并补一次 `values` 规模 10/100 时的「锁内拷贝 vs 锁内替换」分段计时

## 优化可行性方案

> 本部分为规格文档；文档里承诺的内存 / CPU 改造（rune 缓冲 local 化、渲染单遍扫描、检索候选上界、colbert 重排前 N）均已在实现落地，本轮没有新的可执行方案。相关收益是否成立见「待验证假设」。

## 待验证假设

> 无性能测试数据，仅用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单遍扫描把 `render` 从 `O(步数 × 模板长度)` 降到 `O(模板长度)` 后，端到端有可测收益 | `f_llm/src/loom/LoomHostApi.cj:73-145`；`f_llm/doc/spec/perf-loom-render-context/proposal.md:7-8` | `render` 自耗时占比、步数分布 | `cjprof record` 跑 50 步流程（每步 system 2 KB、含 10 个占位符），对比改前实现 |
| 2 | 知识候选 1000→400 降低了单次检索的驻留内存，且对 topK 内侧召回无损 | `f_llm/src/store/postgres/KnowledgeStore.cj:58`、`mysql/KnowledgeStore.cj:55` | 每请求驻留字节、topK 命中率 | 同一语料 5 万 chunk，测 `getAllocatedHeapSize()` 增量与 20 条查询的 recall@5 |
| 3 | colbert 只重排前 `max(topK*4,20)` 不改变最终排序质量 | `f_llm/src/store/PostgresMemoryStore.cj:118-155` | 全量重排 vs 前 N 重排的排序差异率 | 1000 候选、topK=5，比对两种做法的 P@5 与 DB 往返次数 |
| 4 | local mode 的 rune 缓冲收益是 `4n+4112` 字节级、且峰值下降可观测 | `f_llm/src/store/KnowledgeChunker.cj:66-88`；`f_llm/doc/perf-baseline.md`（参考值，单次运行含噪声） | 多轮中位数与 RSS 对照 | `-O2` 下 2 MiB ASCII 跑 20 轮，记录 peak RSS / `getAllocatedHeapSize()` 中位数与离散度 |

## 文件覆盖

> 与 `{workdir}/files/f_llm.part6.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/doc/spec/fix-loom-tool-coverage/proposal.md` | .md | ✅ | `StoreInvoker`（`StoreFunctions.cj:84-95`）、`loomStoreCall`（`:169-214`）、`FlowPlan.skills`（`Plan.cj:71/149-157`）、`executeNow(skills:)`（`LoomService.cj:122-140`）四项全部落地 |
| 2 | `f_llm/doc/spec/fix-loom-tool-coverage/specs/loom-flow/spec.md` | .md | ✅ | 7 个 Scenario 逐条核对：三类错误文案与实现逐字一致（`StoreFunctions.cj:193/196/207`）、六类 kind 网关均支持（`LoomStoreGateway.cj:92/133/214/275/321`）、技能优先级一致（`Planner.cj:176-189`） |
| 3 | `f_llm/doc/spec/fix-loom-tool-coverage/tasks.md` | .md | ✅ | 1.x/2.x 与实现一致；3.1「基线 639」无 CI 记录可复核；3.2 文档已补（`doc/loom.md:135`、`README.md:407`、`README_en.md:403`） |
| 4 | `f_llm/doc/spec/fix-memory-write-consistency/design.md` | .md | ✅ | D1/D2/D3 与实现一致（`Memory.cj:121-139`、`MemoryKinds.cj:189-191`）；D4 未落地，见发现 #4 |
| 5 | `f_llm/doc/spec/fix-memory-write-consistency/proposal.md` | .md | ✅ | 三条根因均已在实现侧修复；namespace 默认 `loom` 的迁移说明与实际一致 |
| 6 | `f_llm/doc/spec/fix-memory-write-consistency/specs/loom-flow/spec.md` | .md | ✅ | 5 个 Scenario 全部满足（网关优先 + 适配器回落 + 自定义 namespace/kind 透传） |
| 7 | `f_llm/doc/spec/fix-memory-write-consistency/tasks.md` | .md | ✅ | 2.x 与实现一致；1.2 勾选失实，见发现 #4 |
| 8 | `f_llm/doc/spec/llm-content-store/spec.md` | .md | ✅ | 主规格（与归档副本同文）；键名 / 可选值 / 种类 / 命名空间四处漂移，见发现 #1 #2；覆盖写、向量失败拒绝写入、topK×2 候选、colbert 开关等条款与实现一致 |
| 9 | `f_llm/doc/spec/llm-meta-store/spec.md` | .md | ✅ | 13 个人格 key + `custom`（`PredefinedCharacters.cj:85-91`）、`f_store` 启动补建索引（`FStoreMetaStore.cj:143-158`）、候选过滤 `enabled && weight>0`（`:112/133`）、技能 `version` 默认 1（`StoreModels.cj:116`）均一致 |
| 10 | `f_llm/doc/spec/llm-store-wiring/spec.md` | .md | ✅ | 见发现 #1 #3 #5 #6；「业务层只依赖接口」成立（`Memory.cj` 只 import `store.*` / `wiring.*`）、Repository 不持执行器字段成立 |
| 11 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/design.md` | .md | ✅ | D1–D6 与实现逐条对齐（`KnowledgeChunker.cj:21-160`：8 MiB / 4 B / 2 MiB 常量、`knowledgeChunkerUsesLocal*`、`splitImpl`、`appendChunksLocal` exclave、`countRunes`）；探针数值与 `doc/perf-baseline.md` 一致 |
| 12 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/proposal.md` | .md | ✅ | What Changes 六项全部落地；「不新增 public 声明」的评审约束成立（新增符号均 `internal` / `private`） |
| 13 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/specs/llm-knowledge-chunking/spec.md` | .md | ✅ | 门限常量 2,097,152、边界用例（2 MiB / 2 MiB+1 / 699,050 汉字）与实现及测试一致；门限 predicate 可被同包测试查询 |
| 14 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/tasks.md` | .md | ✅ | 6 组任务全勾选，与实现一致；6.3 的 SDK / ohos 说明已在 `README.md:19-25` 落地；6.4「无 openspec CLI，按 schema 手工校验」已如实记录 |
| 15 | `f_llm/doc/spec/perf-loom-render-context/design.md` | .md | ✅ | D1/D2/D4 与实现一致（`LoomHostApi.cj:79-145`、`LoomContextLog.cj:61/79-87`）；D3 与 spec 相反（发现 #7）；D1 的否决理由待确认（发现 #9） |
| 16 | `f_llm/doc/spec/perf-loom-render-context/proposal.md` | .md | ✅ | 锁外替换、单遍扫描、`MAX_TURNS=200` 三项均已落地；「输出完全不变」这一承诺对 `{start.output}` 成立 |
| 17 | `f_llm/doc/spec/perf-loom-render-context/specs/loom-flow/spec.md` | .md | ✅ | 5 个 Scenario 与实现一致（JSON 嵌套花括号走 `:139-141` 只吐 `{` 的分支）；与 design D3 冲突见发现 #7 |
| 18 | `f_llm/doc/spec/perf-loom-render-context/tasks.md` | .md | ✅ | 3.1「650→654」无记录可复核；3.2 已补（`doc/loom.md:244/510`） |
| 19 | `f_llm/doc/spec/perf-retrieval-candidates/design.md` | .md | ✅ | D1/D2/D3/D5 与实现一致（`hydra/ContentStore.cj:196-229`、`PostgresMemoryStore.cj:118-155`、`SkillCatalog.cj:148` 每次现取）；D4 的范围问题见发现 #8 |
| 20 | `f_llm/doc/spec/perf-retrieval-candidates/proposal.md` | .md | ✅ | Hydra「先紧后松」与记忆重排前 N 均已落地；「1000→400」表述范围过宽，见发现 #8 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | #3（检索降级路径缺失：旧版本抛错 / 无库名时静默丢 dense）、#7（空值语义自相矛盾）、#9（设计依据待确认）；无安全类问题（文档不含凭据、外部输入处理） |
| §1 死代码 | 0 | 文档无可见性概念；改为机械核对「文档引用的符号是否仍存在」：`StoreInvoker` / `loomStoreCall` / `StoreCallParam` / `FlowPlan.skills` / `PlanDto.skills` / `Planner.planOf` / `executeNow` / `splitImpl` / `knowledgeChunkerUsesLocal*` / `countRunes` / `LoomContextLog.MAX_TURNS` / `Stores.registerContent` / `registerMeta` / `content` / `meta` / `bootstrap` / `Memory.remember` / `MemoryKinds.predefined` / `weightOf` / `MemoryKinds.remove` / `annPath` / `maxCandidates` 共 22 组全部命中；唯一「引用但仍存在却不生效」的是 `llm_contentStore`（并入 #1）；反向检查「文档引用了已删除的符号」0 处 |
| §2 重复逻辑 | 1 | 「按配置选实现、未知值启动失败并列出可选值」这条契约在 `llm-content-store/spec.md:10` 与 `llm-store-wiring/spec.md:31` 各写一遍，键名同时漂移（#1）；另 `llm-store-wiring/spec.md:19-22` 与归档副本逐行相同（#5）。四段式 proposal/design/tasks/spec 骨架属 OpenSpec 格式要求，不算重复 |
| §3 空实现 | 1 | `llm-store-wiring/spec.md:4` Purpose 是归档工具留下的 TBD 占位（#6） |
| §4 栈溢出 | 0 | 本部分文档不涉及递归结构；被引用的实现（`render` 单遍扫描、`split` 线性滑窗、`countRunes` 单次遍历）均无递归 |
| §5 OOM | 0 | 文档描述的容器都有常量上限（`MAX_TURNS=200`、候选 400 / `max(k*4,20)`、local region 2 MiB 门限）；#8 是「上界未覆盖全部构造路径」，不是无界增长 |
| §6.1 热点瓶颈 | 0 | 本部分无任何 profile / bench 输出（`perf-baseline.md` 为单次参考值），三条收益论证降为待验证假设 #1 #2 #3 |
| §6.2 大粒度锁 | 0 | `render` 已按 spec 改成「锁内只拷快照、替换在锁外」（`LoomHostApi.cj:79-88`），临界区内无 I/O / 解析 / 回调 |
| §6.3 并发串行 | 0 | 文档未引入并发调度；Hydra「先紧后松」是串行远程调用但有明确上界（`bound` 后放宽），无数据不判热点 |
| §6.4 低效算法 | 0 | N+1（Hydra 正文、colbert 每候选一次）与全串 `replace` 都已在文档描述并落地收敛；无耗时数据，收益见待验证假设 #1 #2 #3 |
| §7 降堆内存方案 | 0 | rune 缓冲 local 化、知识候选 400、colbert 只取前 N 均已落地；本部分无新增可执行项，#8 是完成度问题 |
| §8 降 CPU 方案 | 0 | 同 §7：单遍渲染、候选上界、重排上界都已实现，无新方案 |
| §9 local mode 可行性 | 0 | 该试点已落地（`KnowledgeChunker.cj`）；design 明确把 `chunks` / `StringBuilder` 列为 Non-Goal，本轮无新增候选，也无改前改后峰值对照可证收益（待验证假设 #4） |
| §11 现有代码的 BUG（存量） | 3 | #2（`inMemory` 可选 → 重启丢记忆，与规格 MUST 相反）、#3（MySQL 无 ANN 降级缺失：9.0/9.1 检索抛错、无库名时 dense 静默跳过）、#5（Repository 直写 DELETE）属既有代码与契约不符；#1 / #4 是文档侧失真，不计入本行 |
| §12 并发安全与锁粒度 | 0 | 本部分唯一共享态是 `LoomHostApi.values`（`LoomHostApi.cj:55-88`），全部读写都在 `mutex` 内，快照拷贝与替换顺序符合 spec；`LoomContextLog.turns` 亦在 `mutex` 内且已加上限 |
| §13 文档一致性 | 7 | #1 #2 #3 #4 #5 #7 #8 |
| §14 功能完备性与 README 覆盖 | 2 | #3（承诺的降级 + warn 未实现）、#6（Purpose 关键段落缺失）；`loomStoreCall`、计划 skills、local mode 编译期要求都已进 README（`README.md:500`、`:19-25`） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分 20 份文档覆盖 5 个已完成的变更（工具层读能力、记忆写入一致性、知识切块 local mode、渲染与快照、检索候选上界）与 3 份合并主规格。**变更文档（proposal / design / tasks / spec delta）质量偏高**：几乎每条 Requirement 都能指到具体函数与行号，`fix-loom-tool-coverage`、`fix-memory-write-consistency`、`local-mode-…-knowledge-chunker`、`perf-loom-render-context`、`perf-retrieval-candidates` 的核心承诺都已落地，`[x]` 与代码基本对得上（唯一例外 #4）。

风险集中在**三份「合并主规格」**：它们由归档工具一次性生成（`1df859449` / `03cd91532`，2026-10-30、10-31），此后从未随实现更新，于是同时保留着「旧配置键」「7 种记忆种类」「内存实现不可选」这些已被推翻的结论（#1 #2 #5 #6）。这类文档最容易被当成当前契约去配环境或照做迁移，其中 #1 的后果是**配了键不生效、静默用了另一个存储后端**，#2 的后果是**选了 `inMemory` 重启即丢全部记忆**——两条都属于「不报错但结果不对」。

另一类是**承诺与实际能力不符**：#3 的 MySQL 无 ANN 分支既没有规格要求的「应用层兜底 + `warn` + `degraded`」，也没有版本探测 —— 9.0/9.1 上整次检索抛错，库名不可得时又静默只剩词面召回，两种形态都不可观测，建议优先补一条 warn 作为最小修复。

无阻塞项：本部分没有会导致崩溃、越界或并发错误的文档承诺。存量 9 条（一般 4 + 轻微 5），是否纳入修复待用户决定；其中 #1、#3、#4 改动小、收益直接（改文档 / 补 warn / 换常量引用），可优先排期。

## 范围外提示（不计入统计）

- `README_en.md:496` 的 skills 说明缺 `executeNow(skills:)` 与计划 JSON `"skills"`（`README.md:500` 有），属中英不同步，归 README 所在部分。
- `f_llm/src/store/MemoryKinds.cj:21-32` 的类注释仍写「预定义 7 值 / 预定义 7 种补种」，实际已是 9 个；源码注释漂移，归 src 部分。
- `f_llm/src/store/Stores.cj:31-32` 的 `DEFAULT_CONTENT='postgres'` / `DEFAULT_META='postgres'` 与 `StoreSettings.cj:39-40` 的 `f_hydra` / `f_store` 冲突，且全仓无引用（对外可达 `public`，不算死代码）；两份默认值并存容易误导读者，归 src 部分。

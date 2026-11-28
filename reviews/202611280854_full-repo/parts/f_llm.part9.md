# f_llm 模块审查报告（第 9/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个源文件：20 个 `.cj` + 0 个 `.md`）
- **本部分范围**：`src/constant/**`（`ThinkingSwitch.cj` / `TodoStatus.cj` / `ToolType.cj` / `imports.cj`）、`src/dao/LLMConfDAO.cj`、`src/dao/mysql/**`（9 个 DAO）、`src/dao/postgres/**` 中的 `EvolutionDAO` / `EvolutionLeaseDAO` / `EvolutionStateDAO` / `KindDAO` / `KnowledgeDAO` / `LoomDAO`（6 个 DAO）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 本部分**全部问题来源为「存量」**
- **审查重点**：客户端契约与配置、资源与超时、死代码、重复逻辑、并发安全、存量 BUG（本部分实际落在「DAO 契约 / SQL 安全 / 跨方言漂移」）
- **报告版本**：v1（分报告；模块报告由主 Agent 合并为 `docs/review/2026-11-28/f_llm_v2.md`）
- **与相邻部分的分工**：`postgres/MemoryDAO.cj`、`postgres/MetaDAO.cj`、`postgres/TokenUsageDAO.cj`、`tables-mysql.sql`、`doc/**`、`store/**`、`service/**` 均不在本部分清单内。正文只在需要作方言/调用方对照时引用其行号作**证据**，不展开审查、不计入本部分统计。

## 发现

### [严重][存量] MySQL 检索把 `namespace` / `docId` 手工拼进 SQL，转义只覆盖单引号，反斜杠可逃逸

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:49-59`（`mySearchDense` 的 filter 拼装，转义函数在 `:178-180` `daoEscape`）；`f_llm/src/dao/mysql/KnowledgeDAO.cj:93-102`（`chunkSearchDense` 的 `docIds` 拼装，转义为行内 `replace("'", "''")`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（安全性：注入 / 外部输入未校验）、§11（契约与实现不符）；`fountain-baseline.md` §2「参数化，不拼串」
- **证据**：静态确定 —— ①两处都把外部字符串插进 SQL 文本：`quoted += "'" + daoEscape(namespaces[index]) + "'"`（`MemoryDAO.cj:56`）、`quoted += "'" + docIds[index].replace("'", "''") + "'"`（`KnowledgeDAO.cj:100`）；②转义只把 `'` 换成 `''`，没有处理 `\`。MySQL 默认 `sql_mode` 不含 `NO_BACKSLASH_ESCAPES`，字符串字面量里 `\'` 是「转义后的引号」，因此以 `\` 结尾的值会吞掉收尾引号、把后半段逸出字面量（例：namespace = `x\` 时生成 `... IN ('x\')` 之后的文本被当作 SQL 而非字符串）；③值确实是外部输入且在生产主路径上：`namespace` 来自模型工具入参 `strOf(args, 'namespace')` → `MemoryQuery.namespaces`（`f_llm/src/loom/LoomStoreGateway.cj:176-186`）→ `MySqlMemoryRepository.searchDense`（`f_llm/src/store/mysql/MemoryRepository.cj:52-55`）→ `mySearchDense`；`KnowledgeQuery.docIds` 是 `f_llm/src/store/StoreModels.cj` 的公开构造参数（当前仓内只有测试传入，属潜在面）；④同文件/同层已有正确写法：`mySearchSparse` 用 `meet(true, 't.namespace').IN(namespaces)` 全参数绑定（`MemoryDAO.cj:91-95`），PG 的 `searchDense` 同（`f_llm/src/dao/postgres/MemoryDAO.cj:58-63`），说明内联只是 `MYVECTOR_IS_ANN` 过滤器文本无法绑定参数后的退化写法，不是业务必需
- **描述**：`MYVECTOR_IS_ANN(... , (filter))` 的第 5 个参数是「一段子查询文本」，不能放占位符，于是代码改为自行引号拼接；而自研转义不完整，构成 SQL 注入面。触发条件是 namespace/docId 含 `\`（或 `\` + 引号组合）。后果是任意 SQL 拼接（读越权数据 / 触发错误），且 `doc_id` 过滤条件可被整体短路（`OR 1=1`）导致跨文档召回
- **建议**：`annPath`（配置派生）可保留内联；`namespace` / `docId` 两种落点二选一——(a) 白名单校验后再拼（`[A-Za-z0-9_.:@-]{1,32}`，不匹配直接跳过并计数告警），(b) 按 MySQL 规则补全转义（先 `\`→`\\` 再 `'`→`''`，即 `daoEscape` 改成两替换并加注释说明「依赖 `NO_BACKSLASH_ESCAPES` 关闭」）。同时把两处引号列表构造合并到一个 `private func quoteIn(values)`（见 §2 #4），并补用例 `namespaces = ["a\\"]`、`docIds = ["a\\"]` 断言 SQL 仍能正确执行

### [一般][存量] 主键回读用「第二条语句 `SELECT LAST_INSERT_ID()`」，而 `f_orm` 在非事务路径每条语句后归还连接

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:42-44`（`myUpsertMemory`）、`f_llm/src/dao/mysql/MetaDAO.cj:87-93`（`confPut`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 跨语句依赖会话状态）、§12.1（异步语义与跨线程资源）
- **证据**：静态确定 —— ①`f_orm` 的 `execute` 在非事务路径 `finally` 里调 `this.close()`（`f_orm/src/base/SqlExecutor.cj:878-900`）；②`close()` 执行 `_connection_.close()` 并置 `NoneConnection`、从线程 current 表移除（`SqlExecutor.cj:153-171`），下一条语句经 `connection` getter 重新从连接池取连接（`SqlExecutor.cj:409-430`）；③`LAST_INSERT_ID()` 是**会话级**函数。⇒ 第二条 SELECT 与 INSERT 不保证同一物理会话。缺的数据：连接池容量与并发下两条语句是否稳定复用同一连接（`f_llm/src/store/mysql/MySqlMemoryRepository_test.cj:110` 的断言只在单线程下成立）
- **描述**：两段式「INSERT … → 另起 SELECT 取 id」在并发下可能拿到 0 或其他线程刚插入的 id。调用方后果：`MySqlMemoryRepository.upsert` 返回 0 → 随后 `upsertSparse(memoryId=0)` 把词项挂到 `memory_id = 0`（`f_llm/src/store/mysql/MemoryRepository.cj:57-66`），稀疏召回永久丢失该条；`confPut` 返回 0 → 上层索引键与主体不一致
- **建议**：改单语句回读。PG 已用 `INSERT … RETURNING id`（`postgres/MemoryDAO.cj:32-38`）；MySQL 用执行器的 `insert` 属性取 `UpdateResult.lastInsertId`（`SqlExecutor.cj:469-473`）即可，`ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)` 的写法与该属性兼容；或把两段包进显式事务（`tx.isSome()` 时 `close()` 不执行）。补并发用例：8 线程各 upsert 一条，断言返回值非 0、互不相同且能在库中查到

### [一般][存量] `MemoryQuery.kinds` 在 MySQL 检索路径被静默丢弃，与内存实现行为不一致

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:47-48`（`mySearchDense` 签名无 kind）、`:88-89`（`mySearchSparse` 签名无 kind）、`:71-77`（`myInsertToken` 固定 `field = 'm'` 同时不落 kind 维度）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§14（只做了一半的分支）
- **证据**：静态确定 —— ①`MemoryQuery` 明确带 `kinds`（`f_llm/src/store/StoreModels.cj:61-77`），`LoomStoreGateway` 也确实把工具入参 `kinds` 传进 `MemoryQuery` 做 `search`（`f_llm/src/loom/LoomStoreGateway.cj:181-191`）；②内存实现按 kinds 过滤（`f_llm/src/store/InMemoryStores.cj:149-152`）；③MySQL 仓储的 `searchDense` / `searchSparse` 只把 `userId` / `namespaces` / `tokens` / `limit` 下推，DAO 签名里根本没有 kind 形参，`hits()` 也只是映射不加过滤（`f_llm/src/store/mysql/MemoryRepository.cj:52-55, 137-149`）；④`list` 路径反而正确下推（`myListByKind`，`MemoryDAO.cj:148-157`），说明检索路径是漏了而不是有意
- **描述**：同一个 `MemoryQuery` 在内存后端按 kind 过滤、在 MySQL 后端不过滤。表现是「检索结果里混入其它 kind（如 `session` / `note`）」，且与 `list` 的语义不一致；调用方无法感知过滤器被丢弃
- **建议**：给 `mySearchDense` / `mySearchSparse` 增 `kinds: Array<String>` 形参，用 `${meet(kinds.size > 0, 'm.kind').IN(kinds)}` 下推（与 `myListByKind` 同风格）；`mySearchDense` 的 ANN filter 子查询里同样拼 `AND kind IN (...)`（需接着 #1 做白名单/转义）。补 conformance 用例：同一数据集在 `InMemoryStores` 与 MySQL 上 `MemoryQuery(..., kinds: ['fact'])` 结果集必须一致

### [一般][存量] MySQL 记忆 DAO 读写的向量列不在仓内 MySQL 表结构里（`llm_memory.title_vec` 等 4 列）

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:28-33`（写入 `title_vec` / `content_vec`）、`:62`（`myvector_distance(m.title_vec, …)`）、`:79-86`（写 `title_colbert` / `content_colbert`）、`:111-121`（读同两列）
- **来源**：存量（快照模式无基线；`git log -1` 显示 `MemoryDAO.cj` 2026-11-04 仍在改，`tables-mysql.sql` 停在 2026-10-31）
- **判据**：review-checklist §11（与规格冲突）、§13（规格与实现漂移）
- **证据**：待确认（权威侧未定）—— ①`f_llm/tables-mysql.sql:110-122` 的 `llm_memory` 只有 `id/user_id/namespace/title/content/kind/save_time/update_time`，向量另立 `llm_memory_vector`（同文件 `:156-168`）；②`f_llm/doc/content-store.md:25` 与 `f_llm/doc/f_llm.md:274` 同样把向量列写在 `llm_memory_vector`；③PG 侧同名 DAO 已拆表写入（`f_llm/src/dao/postgres/MemoryDAO.cj:29-56`）；④只有测试自建的临时表把 `title_vec` 直接放在 `llm_memory` 上（`f_llm/src/store/it/CrossBackendConformance_test.cj:164-178`、`f_llm/src/store/mysql/MySqlMemoryRepository_test.cj:51`）。缺的信息：生产库实际结构（是否有未入库的 `ALTER`）、哪一侧是权威
- **描述**：若以随仓 DDL 建库，MySQL 记忆后端所有向量写入都会 `Unknown column`，即「后端整体不可用」；同时单测用的是自建表，永远测不出这个偏差。若生产库确实被手工加过列，则随仓 DDL 与文档才是错的（新部署必挂）。两种情况下都必须先对齐一方
- **建议**：二选一并同步另一侧——(a) 按 PG 拆分：`myUpsertMemory` 写 `llm_memory` 取 id 再写 `llm_memory_vector`，`mySearchDense` 改 `JOIN llm_memory_vector`、ANN 路径改 `{db}.llm_memory_vector.title_dense`，colbert 读写改到向量表；(b) 若确要单表，把 4 列补进 `tables-mysql.sql` 并补向量索引。两种都要加一条「按随仓 DDL 建空库 → upsert → dense 召回」的用例

### [一般][存量] MySQL 用 `INSERT IGNORE` 顶替 `ON CONFLICT DO NOTHING`，错误被降级为 warning 后与「0 行 = 已存在」的判定混同

- **位置**：`f_llm/src/dao/mysql/EvolutionLeaseDAO.cj:37-43`（`leaseInsert`）、`f_llm/src/dao/mysql/KindDAO.cj:38-44`（`kindInsert`）、`:52-58`（`kindInsertCustom`）、`f_llm/src/dao/mysql/EvolutionStateDAO.cj:75-81`（`knowledgeInsert`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 静默）、§2（跨方言实现漂移导致语义不等价）
- **证据**：静态确定（语义差异）+ 待确认（是否存在能触发的输入）—— MySQL 的 `IGNORE` 会把「数据过长被截断」「NOT NULL 写入隐式默认」等错误降级为 warning 并继续执行；PG 的 `ON CONFLICT DO NOTHING` 只吞唯一冲突，其它错误照常抛出。调用方把返回值当语义用：`EvolutionLease.ensure` / `acquire` 里 `leaseInsert(...) == 1` 表示「抢到租约」（`f_llm/src/store/mysql/EvolutionLease.cj:46-52, 69-80`）；`kindInsert(kind, …)` 的 `kind` 是用户自定义串（`f_llm/src/store/mysql/KindPersistence.cj:26-34`），列宽 `VARCHAR(32)`（`tables-mysql.sql:125-132`），仓内无长度校验
- **描述**：超长 kind 会被静默截断后写入，之后 `kindHas(原值)` 永远查不到 → 「补种」每次都报成功但库里是另一条记录；`leaseInsert` 若遇可降级错误则返回 0，被解释为「别人已持有租约」，结果是**演进任务永久不启动且无日志**
- **建议**：MySQL 侧改用 `INSERT ... ON DUPLICATE KEY UPDATE lease_id = lease_id`（保留 0 行语义）或 `INSERT ... SELECT ... WHERE NOT EXISTS`，让非唯一冲突的错误照常抛出；`kindInsert` 前后加长度校验（`kind.size > 32` 直接拒绝并告警），并在 DAO 注释里写明「返回值只表示唯一冲突，不表示写入成功」

### [一般][存量] `llm_skill_evolution` 主键由应用侧 `MAX(id)+1` 分配，仓内只有进程内互斥

- **位置**：`f_llm/src/dao/mysql/EvolutionDAO.cj:26-38`（`id BIGINT PRIMARY KEY`，无自增/序列）、`:68-71`（`maxEntryId`）；`f_llm/src/dao/postgres/EvolutionDAO.cj:26-37`、`:76-79`（同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（并发正确性）、§12.1（检查-然后-写入非原子）
- **证据**：静态确定（DB 侧无分配器）+ 待确认（部署是否多实例）—— ①两张表都把 `id` 建成普通 `BIGINT PRIMARY KEY`，没有 `AUTO_INCREMENT` / `GENERATED … AS IDENTITY`；②DAO 只提供 `maxEntryId()`，id 计算在调用方：`MySqlEvolutionStore.save` 用 `nextId = maxIdOf(dao) + 1`，唯一保护是实例字段 `mutex`（`f_llm/src/store/mysql/EvolutionStore.cj:34-57`）；③`insertEntry` 是普通 INSERT，冲突即抛
- **描述**：多进程 / 多实例部署（或滚动发布期间新旧进程并存）时，两个进程各自从 `MAX(id)` 起算，必然出现主键冲突 —— 表现为「演进报告写不进去」或（若上层吞异常）静默丢记录。`llm_evolution_lease` 的 CAS 只串行化「当天由谁跑」，不保护 id 分配
- **建议**：把 id 交回数据库（MySQL `AUTO_INCREMENT`、PG `GENERATED BY DEFAULT AS IDENTITY`），`insertEntry` 后按 #2 的方式单语句回读；若必须保留外部指定 id（导入场景），改成「冲突时重算一次并重试」的显式 CAS 循环，而不是依赖进程内锁。DDL 变更需带 `ALTER TABLE` 迁移脚本

### [轻微][存量] 公开常量拼写错误 `THINGKING_ENABLED` / `THINGKING_DISABLED`

- **位置**：`f_llm/src/constant/ThinkingSwitch.cj:19-20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性 / 命名）；属对外可达 `public`，按硬原则一不判死代码，只作可见性/命名问题
- **证据**：静态确定 —— 正确拼写为 `THINKING`；同文件 `ThinkingSwitch`（`:18`）与 `ThinkingMode`（`:23`）都是正确拼写，只有两个常量错。已有 4 处引用：`f_llm/src/llm/LLMParams.cj:57`、`f_llm/src/llm/openai/ProviderDialects.cj:160, 165, 167`
- **描述**：常量是对外契约（下游会硬编码），错拼会被复制到下游代码；改名属破坏性变更
- **建议**：新增正确名并把旧名做成别名（`public const THINKING_ENABLED = THINGKING_ENABLED`），旧名标 `@Deprecated`，下个大版本删除；同时全仓把 4 处引用切到新名

### [轻微][存量] `TodoStatus` 注释承诺 7 种状态，实现只有 6 个常量，「删除」态全仓不存在

- **位置**：`f_llm/src/constant/TodoStatus.cj:18-26`（注释列出 `⏸️ ◯ 🟡 ✅ ❌ 🔄 🗑️` 七态）、`:28-33`（只有 6 个 `TODO_STATUS_*`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）、§14（承诺但未实现）
- **证据**：静态确定 —— 全仓 `grep "🗑"` 在 `src/`、`README*.md`、`doc/` 零命中；写入侧 `TodoFunction` 直接把模型给的字符串透传（`f_llm/src/tool/TodoFunction.cj:103` `updateStatus(param.task, param.id, param.status)`），无白名单校验；`Todo` 模型默认值用 `TODO_STATUS_PENDING`（`f_llm/src/model/po/Todo.cj:35`）
- **描述**：状态词表是这套工具对外契约（模型按词表填值），但注释多出一态、代码少一个常量、写入端不校验 —— 三处都不一致，调用方无法确定合法取值集合
- **建议**：补 `TODO_STATUS_DELETED = "🗑️"` 并在 `updateStatus` 上按常量白名单校验（非法值拒绝并回错误），或从注释里删掉该态；README 的状态说明按同一份常量表生成

### [轻微][存量] `src/constant/imports.cj` 的两条 `internal import` 在整个 `constant` 包零使用

- **位置**：`f_llm/src/constant/imports.cj:18-20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— `fountain::f_llm.constant` 包共 17 个 `.cj`，全包搜 `convert` / `exception` / `LLMException` 只在 `imports.cj` 自身命中；包内其余文件（`ConstantSize` / `KnowledgeKind` / `LLMAgent` / `Role` / `SkillType` / `SpecKind` / `ModelName(s)` / `ToolType` / `TodoStatus` / `ThinkingSwitch` / `ContextPrunerName` / `SummaryActionKind` / `SpecialAgentId`）既不用 `std.convert` 也不用 `f_llm.exception`；反向也不成环（`f_llm/src/exception/*.cj` 只 import `f_base.BaseException`）
- **描述**：该文件是「包级导入汇总」约定的残留模板：其它包（`src/agents/imports.cj:18-34`、`src/embedding/imports.cj:18-35`）的写法里每条导入都有实际使用，本包这两条没有。留着会让读者以为包内用了 `convert` / 异常类型
- **建议**：删掉这两行（或整文件），需要时再按「用到才加」补回；若确要保留包级导入约定，就在 README 的模块约定里写明「`imports.cj` 允许暂时空置」

### [轻微][存量] 演进表索引管理两方言不对称：MySQL 只在 `CREATE TABLE` 内建 KEY，没有 PG 那种幂等补建入口

- **位置**：`f_llm/src/dao/mysql/EvolutionDAO.cj:28-36`（`KEY idx_evo_skill (skill_title, at_time)` 写在建表语句里）vs `f_llm/src/dao/postgres/EvolutionDAO.cj:40-46`（`ensureSkillIndex()` 用 `CREATE INDEX IF NOT EXISTS` 单独补）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（升级路径缺失）、§14（只做了一半的分支）
- **证据**：静态确定 —— `CREATE TABLE IF NOT EXISTS` 在表已存在时整句跳过，KEY 不会补；MySQL 侧没有任何 `ensureIndex` 入口（`grep ensureSkillIndex` 只在 PG DAO 与其 store 出现），PG 侧有（`f_llm/src/store/postgres/EvolutionStore.cj`）
- **描述**：表先由旧版本建出、索引后加的场景下，MySQL 部署会永久缺 `idx_evo_skill`，`listBySkill` / `listEntries` 退化为全表扫 + filesort；同一份代码在两种方言上「升级后能力不同」
- **建议**：MySQL 侧补 `func ensureSkillIndex()`：`CREATE INDEX idx_evo_skill ON ...` 包在「先查 `information_schema.statistics` 再建」或直接捕 `ER_DUP_KEYNAME`（1061）当成功；与 `ensureTable` 一起在启动期调用

### [轻微][存量] 词法回调用 `LIKE '%term%'` 但 `term` 未转义 `%` / `_`，模式会被放大

- **位置**：`f_llm/src/dao/mysql/KnowledgeDAO.cj:123-131`（`chunkSearch`）、`f_llm/src/dao/postgres/KnowledgeDAO.cj:97-105`（同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约与实现不符）、§6.4（只判存在却全量扫描）
- **证据**：静态确定 —— 模式由调用方拼成 `'%' + terms[0] + '%'`（`f_llm/src/store/mysql/KnowledgeStore.cj:119`），而 `KnowledgeSearch.terms` 只做空格切分与 `trimAscii`，不过滤通配符（`f_llm/src/store/KnowledgeSearch.cj:31-41`）。用户输入 `%` 时模式退化为 `'%%%'`（匹配全表），`_` 则匹配任意单字符
- **描述**：不构成注入（仍是参数绑定），但会让一次检索退化为「全表逐行 + 最多 `maxCandidates` 行」的扫描，并且词法命中先被放大再被 `occurrences` 打分淘汰 —— 结果正确性大致不变，代价是白扫一批页（`pageSize=200`、`maxCandidates=1000`）
- **建议**：`terms()` 里剥掉 / 转义 `%`、`_`（`\%`、`\_`），或对 `chunkSearch` 的 pattern 做同样转义后再绑定；顺手补用例：`KnowledgeQuery('%')` 的返回条数与 `KnowledgeQuery('无此词')` 一致

### [轻微][存量] 重复逻辑：`?Map` 包装模板 9 处、`Any → Int64` 解析 5 套、引号 IN 列表 2 处、`enabled AND weight > 0` 谓词 3 处

- **位置**：
  - ①`executor.setSql(...).firstToMap()` + `if(row.isEmpty()){None}else{Some(row)}`：`mysql/MemoryDAO.cj:115-120`、`:129-133`、`mysql/MetaDAO.cj:31-35`、`:113-117`、`:144-148`、`:157-161`、`mysql/KindDAO.cj:31-35`、`mysql/KnowledgeDAO.cj:31-35`、`:83-87`（PG 侧同样形态，`postgres/KindDAO.cj:36-40`、`postgres/KnowledgeDAO.cj:31-35`）
  - ②`Any → Int64`：`mysql/MemoryDAO.cj:170-176`（`daoIntOf`，只认 Int64/Int32）、`mysql/MetaDAO.cj:89-93`（行内 match `?Any`）、`f_llm/src/store/mysql/MemoryRepository.cj:190-199`（`intOf`，认 Int64/Int32/Int16/Int8/UInt64）、`f_llm/src/store/mysql/EvolutionStore.cj:128-136`（`myEvoIntOf`，另认 Float64/String）、`f_llm/src/store/mysql/KindPersistence.cj`（`kindIntOf`）
  - ③引号 IN 列表：`mysql/MemoryDAO.cj:51-58`（调 `daoEscape`）vs `mysql/KnowledgeDAO.cj:95-102`（行内 `replace`）
  - ④`enabled … weight > 0`：`src/dao/LLMConfDAO.cj:36`（`enabled = true`）、`mysql/MetaDAO.cj:58`（`enabled = 1`）、`:72`（`enabled = 1`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：近似重复 / 字面量复制 / 只改类型名）
- **证据**：静态确定 —— 逐组两两比对函数体「输入-输出-副作用」：①9 处语义完全一致（同一 map 形状、同一 None 语义），抽一个 `func rowOption(row: Map<String, Any>): ?Map<String, Any>` 即可；②5 套分支集合**不等价**：`daoIntOf` 对 `Int16` / `Float64` / `String` 返回 0，`myEvoIntOf` 会解析，`intOf` 认 `Int8` / `UInt64` —— 同一驱动返回值交给不同 helper 结果可能不同（当前列宽下多数走 Int32/Int64，未观察到错误，属潜在漂移）；③两处循环逻辑逐行对齐，只有「是否调用 `daoEscape`」不同（同时是 #1 的成因）；④三处是同一业务谓词的复制，且 `true` / `1` 两种写法并存
- **描述**：这四组都不是「刻意的独立演进」：①③④是纯粹的复制，②已经出现分支集合漂移。风险不在当下行为，而在「改一处忘另一处」——例如补超长 kind 校验时只改 `KindPersistence` 的 helper，或修 #1 时只改 `daoEscape` 一处
- **建议**：①抽到 `f_orm` 的 DAO 基类能力（`RootDAO.rowOption(...)`）或本包 `dao/util.cj`；②统一成一个 `daoIntOf(?Any)`，分支取并集（Int64/Int32/Int16/Int8/UInt64/Float64/String），放 `f_llm/dao` 包内供两个方言共用；③合并成 `quoteIn(values)` 并只保留一处转义（与 #1 同批修）；④把 `llm_conf` 的「启用且有权重」抽成 `const ENABLED_CONF_PREDICATE = 'enabled = true AND weight > 0'` 常量或 `SqlPartial`。合并时必须保留各方言必需差异（`LIMIT a,b` vs `LIMIT ? OFFSET ?`、`CAST(… AS SIGNED)`、`ON DUPLICATE KEY` vs `ON CONFLICT`），这些不算重复

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分没有性能基线（未跑 `cjpm bench -O2` / `cjprof`），下列收益一律为**待验证**，不进 `tasks.md`。

### [CPU] 稠密召回把「该用户全部 id」用 `JSON_ARRAYAGG` 物化成过滤数组

- **现状**：`mySearchDense` 的 ANN 过滤参数是 `SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = ? [AND namespace IN (…)]`（`f_llm/src/dao/mysql/MemoryDAO.cj:49-59`），每次检索都由 MySQL 把该用户**全部**记忆 id 聚合成一个 JSON 数组再交给 `MYVECTOR_IS_ANN`。规模随单用户记忆条数线性增长（`llm_memory` 无上限约束，`tables-mysql.sql:110-122` 无明显淘汰机制）
- **方案**：先把候选集收窄再聚合 —— (a) 在 filter 子查询里加 `namespace` / 时间窗 / `LIMIT`（例如只取最近 N 天或 `ORDER BY save_time DESC LIMIT 20000`）；(b) 若 MyVector 支持多列过滤，把 `kind` 也下推（与 #3 一起做）；(c) 单用户记忆量超阈值时改用两级检索（先稀疏/时间窗取候选 → 再 ANN）
- **预期**：单次检索的聚合行数从「全量」降到「窗口量」，语句耗时与临时内存同比例下降；具体幅度需实测
- **代价**：候选集被截断 → 极旧记忆可能不再被语义召回（需要产品确认可接受性）；filter 文本更长
- **验证**：`cjprof record` / 慢查询日志对比同一账号 1k / 10k / 100k 条记忆下 `KnowledgeStore`/`MemoryRepository.searchDense` 的 P50/P95 与 `Handler_read_*`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 标量查询仍走 `mapList()` / `ArrayList<HashMap>`，每行至少一次 Map 分配

- **现状**：`maxEntryId()`（`mysql/EvolutionDAO.cj:68-71`、`postgres/EvolutionDAO.cj:76-79`）、`knowledgeList()`（`mysql/EvolutionStateDAO.cj:67-73`）都只取单列/单值，却返回 `ArrayList<HashMap<String, Any>>`；`kindHas()`（`mysql/KindDAO.cj:26-36`）只用于 `isSome()` 却构造整行 Map；调用方再手写 `for(row in rows){ return … }` 或 `.isSome()`
- **方案**：这几处改成 `firstToMap()` + 标量 getter（`func maxEntryId(): Int64`、`func kindExists(kind): Bool`、`func knowledgeList(limit): ArrayList<String>`），与 `llm_conf` 的 `findById(): ?LLMConf` 保持同一风格
- **预期**：每轮演进省下 N 个 `HashMap` + N 个 `Any` 装箱（N = 表行数 / 候选文档数），并去掉调用方的 match 兜底；量化需 heap 采样
- **代价**：DAO 签名变更，调用方（`store/{mysql,postgres}/EvolutionStore.cj`、`EvolutionStateStore.cj`、`KindPersistence.cj`）同步改；`knowledgeList` 返回 `ArrayList<String>` 后 call site 少一层取列
- **验证**：`getAllocatedHeapSize()` 在一轮「演进状态读取 + 知识去重」中的分配量对比；RSS 稳态对比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `llm_skill_evolution_knowledge` 按 `processed_at` 排序但该列无索引

- **现状**：`knowledgeList` 是 `ORDER BY processed_at DESC LIMIT n`（`mysql/EvolutionStateDAO.cj:67-73`、`postgres/EvolutionStateDAO.cj:76-82`），而建表只有 `doc_id` 主键（`mysql/EvolutionStateDAO.cj:57-65`、`postgres/EvolutionStateDAO.cj:66-74`），无 `processed_at` 索引 ⇒ 每轮演进都对整表全扫 + filesort，代价随「已消费知识量」单调增长（该表只增不减，注释明确写了「只增不减」）
- **方案**：建表语句补 `KEY idx_evo_knowledge_time (processed_at)` / `CREATE INDEX IF NOT EXISTS`，与 #10 的索引补建入口一并做
- **预期**：`knowledgeList` 从「全表扫」降为「索引倒序取 n 行」；具体耗时需实测
- **代价**：写入侧多维护一个索引（`knowledgeInsert` 频率 = 每轮新知识条数，很低）
- **验证**：`EXPLAIN` 前后对比 + `cjprof` 中 `knowledgeList` 调用点耗时；表行数 10k / 100k 两档
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `JSON_ARRAYAGG` 全量 id 的聚合成单次 ANN 检索的主要开销 | `f_llm/src/dao/mysql/MemoryDAO.cj:49-59` | 语句级耗时占比、聚合行数 | 对同一账号构造 1k/10k/100k 条记忆，开 MySQL 慢查询日志 + `cjprof record` 跑 `searchDense` 100 次，看该语句占比 |
| 2 | `mySearchSparse` 的 `GROUP BY` 含 `content`（LONGTEXT）导致临时表 + filesort | `f_llm/src/dao/mysql/MemoryDAO.cj:98-108`、`f_llm/src/dao/postgres/MemoryDAO.cj:112-125` | `EXPLAIN` 的 `Using temporary; Using filesort`、扫描行数 | `EXPLAIN ANALYZE` 同一 SQL（tokens 10/100/1000 三档），与「先按 id 聚合再 JOIN 正文」的改写版对照 |
| 3 | `knowledgeList` 全表扫成为每轮演进的固定成本 | `f_llm/src/dao/mysql/EvolutionStateDAO.cj:67-73`、`postgres/EvolutionStateDAO.cj:76-82` | 表行数、单次耗时 | 灌 10k/100k 行后计时 + `EXPLAIN`；再做「加索引」前后对照（同机器、`-O2`、取中位数） |
| 4 | `LIKE '%term%'` 分页扫描在 `pageSize=200` / `maxCandidates=1000` 下的实际代价 | `f_llm/src/dao/mysql/KnowledgeDAO.cj:123-131`、`postgres/KnowledgeDAO.cj:97-105` | 每页耗时、命中分布 | 造 1k/10k chunk，跑含 `%` 与不含 `%` 的两组 query，比 `Handler_read_next` 与端到端耗时的中位数 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_llm.part9.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/constant/ThinkingSwitch.cj` | .cj | ✅ | `ThinkingSwitch` 别名 + 2 常量 + `ThinkingMode` 枚举；拼写问题见 #7 |
| 2 | `f_llm/src/constant/TodoStatus.cj` | .cj | ✅ | 6 常量；注释 7 态不一致见 #8 |
| 3 | `f_llm/src/constant/ToolType.cj` | .cj | ✅ | 3 常量，`TOOL_TYPE_FUNCTION` 被 `ChatCompletionsMapper`/`ResponsesMapper` 使用；另两个是对外契约常量，按硬原则一不判死代码 |
| 4 | `f_llm/src/constant/imports.cj` | .cj | ✅ | 两条 `internal import` 包内零使用，见 #9 |
| 5 | `f_llm/src/dao/LLMConfDAO.cj` | .cj | ✅ | 5 个方法均有调用（`service/LLMConfService.cj:46-62`）；`updateById` 的三参数是默认重载的展开（`f_orm/src/base/SqlPartial.cj:46-49`），仅冗余；`enabled/weight` 谓词见 #12④ |
| 6 | `f_llm/src/dao/mysql/EvolutionDAO.cj` | .cj | ✅ | 建表 + 追加写 + `maxEntryId`；id 分配与索引见 #6 / #10 |
| 7 | `f_llm/src/dao/mysql/EvolutionLeaseDAO.cj` | .cj | ✅ | CAS 语义正确（条件 UPDATE）；`INSERT IGNORE` 见 #5 |
| 8 | `f_llm/src/dao/mysql/EvolutionStateDAO.cj` | .cj | ✅ | 状态/水位线/知识三张表；`knowledgeList` 排序无索引（优化方案 3）；`INSERT IGNORE` 见 #5 |
| 9 | `f_llm/src/dao/mysql/KindDAO.cj` | .cj | ✅ | `kindHas` 只取一列却建整行 Map（优化方案 2）；`INSERT IGNORE` 见 #5 |
| 10 | `f_llm/src/dao/mysql/KnowledgeDAO.cj` | .cj | ✅ | 注入面见 #1；LIKE 通配符见 #11；向量列内联（数值字面量）其余正常 |
| 11 | `f_llm/src/dao/mysql/LoomDAO.cj` | .cj | ✅ | upsert / get / list / remove 完整，参数全绑定 |
| 12 | `f_llm/src/dao/mysql/MemoryDAO.cj` | .cj | ✅ | 本部分问题最集中的文件：#1 / #2 / #3 / #4 / #12②③ |
| 13 | `f_llm/src/dao/mysql/MetaDAO.cj` | .cj | ✅ | `confPut` 主键回读见 #2；4 处 Option 包装与 `text()` 见 #12①；谓词复制见 #12④ |
| 14 | `f_llm/src/dao/mysql/TokenUsageDAO.cj` | .cj | ✅ | 单条 INSERT，8 个参数全绑定；无问题 |
| 15 | `f_llm/src/dao/postgres/EvolutionDAO.cj` | .cj | ✅ | 索引单独 `ensureSkillIndex`（#10 的正面对照）；`maxEntryId` 见 #6 |
| 16 | `f_llm/src/dao/postgres/EvolutionLeaseDAO.cj` | .cj | ✅ | `ON CONFLICT DO NOTHING` 语义正确（#5 的对照） |
| 17 | `f_llm/src/dao/postgres/EvolutionStateDAO.cj` | .cj | ✅ | 与 MySQL 同构；`knowledgeList` 无 processed_at 索引（优化方案 3） |
| 18 | `f_llm/src/dao/postgres/KindDAO.cj` | .cj | ✅ | `predefined = false` / `ON CONFLICT (user_id, kind)` 与 DDL 主键一致 |
| 19 | `f_llm/src/dao/postgres/KnowledgeDAO.cj` | .cj | ✅ | `NULLIF(${arg(vector)}, '')::vector` 处理空向量（MySQL 侧拆成两个方法，属方言差异）；LIKE 通配符见 #11 |
| 20 | `f_llm/src/dao/postgres/LoomDAO.cj` | .cj | ✅ | 与 MySQL 版逐句对应，仅 upsert / 分页语法不同 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 安全性 1（#1）、正确性/契约 3（#2 #3 #4）；设计上 DAO 只依赖 `RootDAO.executor`、SQL 全在 DAO、无 `ORM.executor()` 越层，分层合规；语言特性无值/引用语义误用（DAO 无状态，无 `mut` 共享） |
| §1 死代码 | 1 | 逐个核对：3 个 `private` 顶层函数都有调用（`daoIntOf` → `MemoryDAO.cj:44`、`daoEscape` → `:56`、`meta/text` → `MetaDAO.cj:62`）；本部分无 `internal` / `protected` 声明；16 个 DAO 接口的约 70 个方法逐个 grep 调用点（`grep -rn "\.methodName\b"`，排除定义行），全部有 `store/**` 调用者；`public` 顶层类型（3 个 `type` 别名、1 个 `enum`）与 11 个 `public` 常量按硬原则一不判（`TOOL_TYPE_WEB_SEARCH` / `TOOL_TYPE_RETRIEVAL` / 5 个 `TODO_STATUS_*` 仓内零引用，仅记信息）。命中仅 `imports.cj` 的未使用 import（#9）。各文件 `return` 后无同层语句，无恒真恒假分支 |
| §2 重复逻辑 | 4 | 已按「输入-输出-副作用」两两比对：`MemoryDAO` 14 个函数、`MetaDAO` 14 个、`KnowledgeDAO` 11 个、`KindDAO` 6 个、`LoomDAO` 4 个、各 Evolution*DAO 5-6 个；跨文件按相同 SQL 片段/字面量/正则搜 `firstToMap`、`LAST_INSERT_ID`、`COALESCE(MAX(id)`、`enabled … weight > 0`、`ON DUPLICATE KEY`、`ON CONFLICT`、`replace("'", "''")`。命中 4 组（#12 ①②③④）。方言必需差异（`LIMIT a,b` vs `LIMIT ? OFFSET ?`、`CAST(… AS SIGNED)`、`true` vs `1`、`ON DUPLICATE KEY` vs `ON CONFLICT`、`myvector_construct` vs `::vector`）按误报边界不计；`CREATE TABLE` 文本虽在演进表两方言间同字，但索引/upsert 语句不同、且各方言独立演进，按 §2 误报边界保留两份 |
| §3 空实现 | 0 | 20 个文件无空函数体、无 `TODO` / `FIXME`、无 `catch {}`；`case None => ()` 只出现在 store 层（本部分无）；DAO 默认方法体全部执行 SQL |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构、无深度遍历；SQL 拼接都是单层循环（`for(index in 0..docIds.size)`），深度由常量界定 |
| §5 OOM | 0 | 逐个核对结果集物化：`listEntries` / `docIds` / `myList` / `myListByKind` / `chunkSearch` / `knowledgeList` 都由调用方传 `limit`（`pageOf` 默认 20/200）；`knowledgeAmong` 的 `IN` 元素数 = 本次候选数；`maxEntryId` 单行。无按不可信长度预分配、无全局只增容器。唯一的规模随数据增长点是 `JSON_ARRAYAGG`（服务端聚合，进优化方案 1 与假设 1，未定为缺陷） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` / 分段计时数据，任何「热点」结论都不成立；三条性能线索（`JSON_ARRAYAGG`、`GROUP BY LONGTEXT`、无索引排序）已分别落到优化方案与假设表 |
| §6.2 大粒度锁 | 0 | DAO 层无锁、无临界区；`Mutex` 在 store 层（`EvolutionStore` / `EvolutionLease`），且临界区内只有 DAO 调用（DB I/O），属「串行化 DB 写」的必要设计，本部分不判 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池；无批处理配置 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `remove(at: 0)`、无循环内字符串 `+` 拼接（`quoted +=` 是单条拼接构造，元素数 ≤ 候选数，未测到热点，见假设表）；`LIKE '%…%'` 的前导通配符属设计选择，代价见假设 4 |
| §7 降堆内存方案 | 1 | 优化方案「标量查询走 `mapList`」（无基线） |
| §8 降 CPU 方案 | 2 | 优化方案「`JSON_ARRAYAGG` 收窄候选」「补 `processed_at` 索引」（均无基线） |
| §9 local mode 可行性 | 0 | DAO 层不产生函数内大临时对象（最大的是 `ArrayList<HashMap>` 结果集，且必须返回给调用方 ⇒ 逃逸），无 `Split` / 大数组中间结构；改造成本（实验开关 + 需 mode 重载的 std API）与收益不成比例，判定不可行 |
| §11 现有代码的 BUG（存量） | 6 | 本轮读到的 20 个文件、约 60 个函数逐个过了边界/空值/错误处理/资源/并发/契约：#1 注入、#2 跨语句会话状态、#3 过滤器丢弃、#4 列与 DDL 不符、#5 `INSERT IGNORE` 语义、#6 主键分配；其余（空集合入参、`LIMIT` 参数、`firstToMap` 空结果、CAS 条件更新）均已核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | 已列出共享点：`SqlExecutor.getCurrent()` 为**线程级**（`f_orm/src/base/SqlExecutor.cj:113-144`），DAO 接口本身无字段 ⇒ 线程封闭成立，多线程并发调用安全；唯一的跨语句依赖是 `LAST_INSERT_ID()`（#2，判在 §11 的会话状态上）。锁粒度无问题（本层无锁） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；按 `src/` 公开声明对照 DAO 能力：`llm_conf` / 记忆 / 知识 / 种类 / loom / prompt / skill / token 用量 / 演进 9 组表都有对应 DAO 方法且都被 store 调用，无「注册了没接线」的方法；`TODO_STATUS_DELETED` 的缺失已在 #8 记（承诺源在代码注释而非 README，故不计入本行） |
| 文件覆盖（§13 等） | 20/20 | `files/f_llm.part9.txt` 共 20 行、全为 `.cj`，`.md` 为 0，故 §13「文档与代码一致性」在本部分没有独立 `.md` 取证对象；只按 `.cj` 内注释核对了 `ThinkingSwitch.cj:22-26`（与实现一致）、`TodoStatus.cj:18-26`（不一致，见 #8）、`postgres/EvolutionStateDAO.cj:23-28`（`__run__` 保留行，`store/*/EvolutionStateStore.cj:30/36` 确有使用）。20 个文件全部读完，无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

这一部分是「常量 + DAO」两层，结构上是干净的：SQL 全部收在 `@DAO` 接口里、只用 `RootDAO.executor`、参数基本走 `arg()` / `meet().IN()`，DAO 无字段因此天然线程封闭，方言差异（upsert 语法、分页语法、向量类型）也基本收在各自包里，没有出现「业务代码里 `match` 方言」的坏味道。合并后没有发现空实现、递归、无界容器或锁粒度问题。

真正的阻塞项只有一个，但性质最重：MySQL 稠密召回为了给 `MYVECTOR_IS_ANN` 传 filter 子查询，把 `namespace` / `docId` 手工拼进 SQL，而自研转义只处理单引号 —— 反斜杠可越出字面量，且 `namespace` 就来自模型工具入参，属生产可达的注入面（#1）。这一处必须与「两处引号列表合并 + 白名单/补全转义」一起改，不能只改一行。

其次三件「契约与实现不符」需要在合并前定调，因为它们决定 MySQL 后端到底能不能用：#4（`llm_memory` 的向量列在随仓 DDL 里不存在，若 DDL 为准则是后端起不来）、#2（`LAST_INSERT_ID()` 跨语句依赖会话，非事务路径下连接已归还池）、#3（`kinds` 过滤在 MySQL 检索被静默丢弃，与内存后端行为不一致）。三条都不是新代码引入，但都会表现为「线上行为与本地/内存实现不同」，建议优先于其余项排期。#5、#6 属健壮性（`INSERT IGNORE` 吞错误、`MAX(id)+1` 多实例冲突），可排在其后。

6 条轻微项（公开常量拼写、TodoStatus 词表、空置的 `imports.cj`、索引补建不对称、LIKE 通配符、四组重复逻辑）都是低成本、可批量处理的技术债，其中 #12 的重复逻辑建议与 #1 同批做（同一处转义、同一处引号列表）。

存量 12 条（严重 1 / 一般 5 / 轻微 6），是否纳入修复待用户决定；本部分不涉及本次改动引入的回归。

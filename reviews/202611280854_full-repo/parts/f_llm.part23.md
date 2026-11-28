# f_llm 模块审查报告（第 23/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm/src/store/{mysql,postgres,it}`（本部分 20 个源文件）
- **基线**：工作区快照（`git diff` 为空）；本部分代码最后改动为 2026-10-29 / 10-30（`git blame` 可见），早于快照 ⇒ 全部问题来源记「存量」
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全（本部分落在 SQL 存储层：方言实现 + 集成测试）
- **报告版本**：分部分报告（模块第 23/25 部分，只统计本部分）

## 发现

### [严重][存量] `MemoryRepository.remove` 先按 `id` 删子表、后按 `(userId, id)` 删主表，可越权删掉他人记忆的索引

- **位置**：
  - `f_llm/src/store/mysql/MemoryRepository.cj:126-131`（先 `DELETE FROM llm_memory_token WHERE memory_id = ?`，再 `myRemoveMemory(userId, id)`）
  - `f_llm/src/store/postgres/MemoryRepository.cj:122-125`（先 `deleteVectors(id)`，再 `removeMemory(userId, id)`）
  - 同类未限定 `user_id` 的子表删除：`f_llm/src/store/mysql/MemoryRepository.cj:57-66`、`f_llm/src/store/postgres/MemoryRepository.cj:53-62`（`upsertSparse`）
- **来源**：存量（`git blame -L 123,124` → `05ba66d08d` / `cdea037a40`，2026-10-30）
- **判据**：review-checklist §11（越权 / 资源不对称）、§10（安全性：外部输入未校验）、§12.1
- **证据**：静态确定 —— 子表删除语句只带 `memory_id`，主表删除带 `user_id AND id`；两者不是同一条件。`id` 由调用方传入，调用链 `LoomStoreGateway.cj:209-210` 直接把流程参数 `args['id']` 交给 `content.memory.remove(userId, id)`，`userId` 只来自流程上下文，代码里没有任何「先按 `(userId, id)` 校验归属」的前置查询。
- **描述**：传入他人的 `id`（或模型编造的 `id`）时，主表删除影响 0 行、`remove` 返回 `false`，但子表已经被删干净：
  - MySQL：被删 `llm_memory_token` → 受害者该条记忆的稀疏倒排消失，`searchSparse` 再也召不回它（正文仍在，dense 仍可召回）；
  - PostgreSQL：被删 `llm_memory_vector` → `searchDense` 的 `JOIN llm_memory_vector` 直接丢行，该记忆对语义检索**完全不可见**（需 `MemoryIndexRebuilder` 重建才恢复）。
  两个方向都是静默的跨租户数据破坏，且返回值 `false` 会让调用方以为是「id 不存在」。
- **建议**：把归属校验放进同一条语句：MySQL `DELETE FROM llm_memory_token WHERE memory_id = ? AND user_id = ?`（并保留 `myRemoveMemory(userId, id)` 返回行数作为唯一成功判据）；PG 改为 `deleteVectors(id, userId)`，SQL 写成 `DELETE FROM llm_memory_vector WHERE memory_id = ? AND EXISTS (SELECT 1 FROM llm_memory WHERE id = ? AND user_id = ?)`。规范做法是主表 `DELETE ... RETURNING id` 成功后再删子表，或在同一事务内先校验归属。

### [一般][存量] `MemoryRecord.saveTime` 恒为查询时刻，演进水位线因此永远「有新材料」

- **位置**：`f_llm/src/store/mysql/MemoryRepository.cj:176-186`（`recordOf` 第 184 行 `DateTime.now()`）、`f_llm/src/store/postgres/MemoryRepository.cj:150-160`（第 158 行同）
- **来源**：存量（`git blame -L 184,184` → `7d173af446`，2026-10-29）
- **判据**：review-checklist §11（语义与命名不符 / 契约与实现不符）、§10
- **证据**：静态确定 —— `MemoryRecord.saveTime` 是对外字段（`StoreModels.cj:29`，README `f_llm/README.md:264`、`doc/loom.md:396` 都写了「按真实时间比较」），但两处方言 DAO 的 `SELECT` 都不含 `save_time`（`dao/mysql/MemoryDAO.cj:125,139,151`；`dao/postgres/MemoryDAO.cj:143,157,169`），映射时直接填 `DateTime.now()`。
- **描述**：`list/get` 返回的 `saveTime` 是「读的时刻」，不是写入时刻。`LoomStoreGateway.cj:442` 把它序列化给流程侧，`SkillEvolutionJob.cj:295-300` 用它做 `ExperienceItem.at`，`fresh()`（同文件 247-255）以 `at > since` 判定新素材。由于 `at` 恒为当轮查询时间，**每一条经验每轮都被判为「全新」**，同时第 218-238 行把水位线推进到该时刻 ⇒ 每轮重复聚类最多 500 条经验（`load` 的 `limit` 默认 500），白跑 LLM 调用并可能重复提案技能；`doc/loom.md:396` 承诺的「按真实时间比较」实际不成立。
- **建议**：两处方言 DAO 的 `get/list/listByKind` 补 `save_time` 列，`recordOf` 用 `save_time` 解析成 `DateTime`；解析失败再退化为 `now()`（并保留注释说明退化条件）。

### [一般][存量] PostgreSQL `remove` 漏删 `llm_memory_token`，孤儿行只增不减

- **位置**：`f_llm/src/store/postgres/MemoryRepository.cj:122-125`（对比 `f_llm/src/store/mysql/MemoryRepository.cj:126-131` 有删 token）
- **来源**：存量（`git blame -L 123,123` → `05ba66d08d`）
- **判据**：review-checklist §11（资源不对称 / 长期持有）、§5（无界容器）
- **证据**：静态确定 —— PG 的 `remove` 只调 `deleteVectors` + `removeMemory`，全仓没有第二处按 `memory_id` 删 token 的调用（`grep llm_memory_token` 仅命中 `clearTokens`（`dao/postgres/MemoryDAO.cj:78`，无调用者）、`insertToken`、`searchSparse` 与两处 `upsertSparse` 的裸 DELETE）。
- **描述**：`llm_memory` 删掉后 `llm_memory_token` 里对应 `memory_id` 的行永久留存。`searchSparse` 用 `JOIN llm_memory` 过滤，所以结果正确，但表按「每次记忆写入的 token 数」无界增长（bge-m3 词表命中通常几十到上百行/条记忆），且 `llm_memory_token` 没有 TTL/清理任务。
- **建议**：`remove` 内补 `clearTokens(id)`（正好已有该 DAO 方法且当前零引用），顺序与 MySQL 对齐：先删 token → 删 vector → 删主表。

### [一般][存量] MySQL / PostgreSQL 存储层是逐行复制的两套代码，已出现 4 处行为漂移

- **位置**（成对文件，包内同名）：
  - `f_llm/src/store/{mysql,postgres}/ContentStore.cj:23-57`
  - `f_llm/src/store/{mysql,postgres}/KindPersistence.cj:24-86`
  - `f_llm/src/store/{mysql,postgres}/MetaStore.cj:30-203`
  - `f_llm/src/store/{mysql,postgres}/TokenUsageSaver.cj:29-37`
  - `f_llm/src/store/{mysql,postgres}/EvolutionLease.cj:32-109`
  - `f_llm/src/store/{mysql,postgres}/EvolutionStateStore.cj:33-133`
  - `f_llm/src/store/{mysql,postgres}/EvolutionStore.cj:33-113`
  - `f_llm/src/store/{mysql,postgres}/KnowledgeStore.cj:31-237`
  - `f_llm/src/store/{mysql,postgres}/MemoryRepository.cj:37-226`
- **来源**：存量（两套文件同批引入，`git blame` 命中 2026-10-29/30 同两三个提交）
- **判据**：review-checklist §2（只改类型名 / 跨层复制）
- **证据**：静态确定 —— 9 对文件合计 ≈2,627 行，结构逐一对应；`diff`（去掉版权头）只有 ≈417 行不同（≈84% 重复），其中 7 个文件差异 ≤68 行、几乎全是 `DRIVER` 字面量与 DAO 类型名替换（如 `KindPersistence` 16 行、`TokenUsageSaver` 10 行、`ContentStore` 11 行）。
- **描述**：真正的语义差异只有 4 处，且都已出现漂移：
  1. `remove` 删哪张子表不一致（见上两条：MySQL 删 token，PG 删 vector）；
  2. `EvolutionStore.ensure`：PG 额外 `dao.ensureSkillIndex()`（`postgres/EvolutionStore.cj:98-105`），MySQL 只在 DDL 里建（`mysql/EvolutionStore.cj:95-101`，靠 `dao/mysql/EvolutionDAO.cj:34` 的 `KEY idx_evo_skill`）——同名字段行为不同；
  3. `MetaStore` 属性：PG 缓存四个子 store（`postgres/MetaStore.cj:33-36`），MySQL 每次访问 `new`（`mysql/MetaStore.cj:34-45`）；
  4. `KnowledgeStore.upsert`：PG 用 `vectorOf` 单条 SQL 写入 NULL 降级（`postgres/KnowledgeStore.cj:74,188-193`），MySQL 分两条 SQL 二选一（`mysql/KnowledgeStore.cj:71-75`）。
  这四条里任何一条再度演化（例如加「删除时同时清 colbert 标记」）都只能靠人肉同步两份文件，上面的越权删除与漏删就是这么产生的。
- **建议**：抽一层与方言无关的 `SqlContentStoreBase` / `SqlEvolutionStateBase` 等包内抽象（`internal abstract class`），把「读-映射-组装、锁与建表时机、子表清理顺序」放基类，方言只提供 `DRIVER` 常量与 3~5 个 DAO 方法（SQL 本来就已经在 `dao/{mysql,postgres}` 里，属于天然分层落点）；差异点必须显式参数化（如 `func removeChildren(id, userId)`），不允许两边各写一份。合并前先把上面 4 处漂移定成同一语义。

### [一般][存量] 临界区包住全部数据库 I/O，而共享状态只有一个 `ready` 布尔

- **位置**：`f_llm/src/store/mysql/EvolutionStateStore.cj:41-119`（`ensureSchema/get/save/processedKnowledge/markKnowledge/processedAmong` 六个方法都 `synchronized(mutex){ … 全部 SQL … }`）、`f_llm/src/store/postgres/EvolutionStateStore.cj:46-124`；同类：`mysql/EvolutionLease.cj:37-83`、`postgres/EvolutionLease.cj:42-90`、`mysql/EvolutionStore.cj:41-93`、`postgres/EvolutionStore.cj:43-96`
- **来源**：存量
- **判据**：review-checklist §12.2（大粒度锁：锁内 I/O）、§6.2
- **证据**：静态确定 —— 临界区内是 `daoOf().xxx(...)` 一类的行往返（`markKnowledge` 还是 N 次 insert 的循环，`mysql/EvolutionStateStore.cj:99-103`），而 `mutex` 保护的唯一可变状态是 `tableReady`/`ready`（`mysql/EvolutionStateStore.cj:121-128`、`mysql/EvolutionLease.cj:85-90`）。`Mutual` 是实例字段，单例 bean 下所有调用者共享。
- **描述**：这是「一次建表标记」用了「串行化整类」的锁：同一实例上的 `get/save/processedAmong` 全部互相排队，`processedAmong` 的 `IN` 查询与 `markKnowledge` 的 N 次写入也会互斥。演进是低频批处理，所以目前未必形成热点（无测量数据），但锁的范围与它保护的不变量严重不匹配，一旦有并发读（例如网关查水位线）就退化成串行。
- **建议**：把 `ready` 改成一次性的原子初始化（`AtomicBool` 或 `Mutex` 只包住 `ensureReady` 本身），`ensureSchema` 之外的方法调完 `ensureReady()` 立刻出锁再执行 SQL；若确实需要「同一事务语义」，用显式事务而不是实例锁（`postgres/EvolutionStateStore.cj:30-31` 的注释已经承认当前没有事务）。

### [一般][存量] MySQL 稠密召回把「用户全部记忆 id」做成 JSON 数组，空集合时为 NULL

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:49-66`（`filter = 'SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = …'`，再作为 `MYVECTOR_IS_ANN` 第 5 参）
- **来源**：存量（`git blame -L 49,66` 同批 2026-10-29/30）
- **判据**：review-checklist §5（按不可信规模构造中间结构 / DB 侧无界）、§6.4、§11
- **证据**：待确认 —— MySQL 官方语义中 `JSON_ARRAYAGG` 对空结果集返回 `NULL`（不是 `[]`），`MYVECTOR_IS_ANN(..., (NULL))` 的行为取决于 MyVector 组件实现：可能报错，也可能返回空集。缺的是「空 filter 调用 MyVector 的实际返回」，需要一次实测（对一个没有任何记忆的 `user_id` 调 `searchDense`）。
- **描述**：两个问题同源：① 无论 `limit` 多小，过滤条件都要把该用户所有 `id` 聚合一遍，成本随用户记忆总量线性增长（PG 侧用 `WHERE` 子句直接过滤，没有这一步）；② 新用户/空库的首次语义检索可能以 SQL 异常告终，而调用方 `MySqlMemoryRepository.searchDense`（`mysql/MemoryRepository.cj:52-55`）没有捕获，异常会一路抛到检索链路。
- **建议**：空集合走短路（先 `SELECT COUNT(*)` 或让调用方在 `searchDense` 前判断），或用 `COALESCE(JSON_ARRAYAGG(id), JSON_ARRAY())`；过滤条件尽量下推到 `MYVECTOR_IS_ANN` 能接受的列上（`namespace`/`kind`），避免全量 id 数组，并补一条「空用户检索返回空列表」的用例。

### [轻微][存量] 死代码：`minOf`（两处方言）与 `PostgresMetaStore.DRIVER` 无任何引用

- **位置**：`f_llm/src/store/mysql/KnowledgeStore.cj:230-236`、`f_llm/src/store/postgres/KnowledgeStore.cj:219-225`（`private static func minOf`）；`f_llm/src/store/postgres/MetaStore.cj:31`（`private static let DRIVER`，全类 4 处 `dao<PostgresMetaDAO>` 都直接写 `'postgres'`）
- **来源**：存量
- **判据**：review-checklist §1（`private` 符号全仓无调用者）
- **证据**：静态确定 —— `grep -rn "\bminOf\b" f_llm` 只命中定义（`KnowledgeChunker.cj:162` 是另一个同名的 `Int64` 版本），`grep DRIVER f_llm/src/store/postgres/MetaStore.cj` 只命中定义行。两处 `minOf` 是复制 `KnowledgeChunker` 时带过来的残留（真正的 min 逻辑已收进 `RetrievalScoring`）。
- **建议**：删除两处 `minOf`；`PostgresMetaStore.DRIVER` 要么删，要么把 4 处 `'postgres'` 字面量替换成它（与 MySQL 侧保持同一写法）。顺带：`mysql/EvolutionLease.cj:18`、`postgres/EvolutionLease.cj:18` 的 `import std.collection.*` 在本文件未直接命名任何集合类型，可一并清掉（编译器未报错说明 `f_orm.*` 重导出覆盖了推断需求，属可删项，删除时以编译通过为准）。

### [轻微][存量] `ContentStore` 的记忆/知识实现是未同步的惰性初始化

- **位置**：`f_llm/src/store/mysql/ContentStore.cj:30-56`、`f_llm/src/store/postgres/ContentStore.cj:31-57`；同类：`mysql/KnowledgeStore.cj:35,189-204`（`cachedDatabase` 写后无同步）
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化：`if (x == None) { x = ... }` 首次赋值竞态）、§10
- **证据**：静态确定 —— `cachedMemory` / `cachedKnowledge` 是普通 `var`，`get()` 里「读-判 None-写」没有任何锁或原子；`MySqlContentStore` 是 `Stores` 工厂返回的单例，两个请求线程可同时进入。
- **描述**：并发首访问会各构造一个 store，后写者覆盖前者（丢一个实例），并可能出现「线程 A 用无 Embedder 的 store、线程 B 用有 Embedder 的 store」这种同一进程内两种语义并存；`cachedDatabase` 的重复写值相同，属良性。后果有限（不产生脏数据），但确实是共享可变状态无保护。
- **建议**：用 `Mutex` 包住首次构造（与 `EvolutionStore.ensure` 同一写法），或改为构造期一次性解析（`ContentStore` 的实现由 `Stores` 工厂在启动阶段创建，把 `lookupOption<Embedder>()` 挪进 `init()` 即可彻底去掉懒加载）。

### [轻微][存量] MySQL `MetaStore` 每次访问属性都新建子 store，与 PG 的缓存写法不一致

- **位置**：`f_llm/src/store/mysql/MetaStore.cj:34-45`（4 个 `get(){ MySqlXxxStore() }`）对比 `f_llm/src/store/postgres/MetaStore.cj:33-52`（4 个 `private let` 字段 + `get(){ xxxStore }`）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 实现漂移）、§8（减少分配）
- **证据**：静态确定 —— 子 store 无状态，行为等价；差异只是每次 `meta.characters.get(...)` 多一次对象分配，并让两方言的对象身份语义不同（PG 可做 `is` 比较，MySQL 不行）。
- **建议**：与 PG 对齐（字段持有），或干脆把「按需 new」定为规范并同步改 PG；不要一边缓存一边新建。

### [轻微][存量] 演进报告 `id` 依赖进程内 `nextId` 缓存，多写者会撞主键

- **位置**：`f_llm/src/store/mysql/EvolutionStore.cj:41-60`（`nextId` 初始化 `MAX(id)`，之后只 `++`）、`f_llm/src/store/postgres/EvolutionStore.cj:43-62`
- **来源**：存量（类注释 `postgres/EvolutionStore.cj:29-31` 明确写了「单进程写足够」）
- **判据**：review-checklist §11（检查-然后-写入）、§12.1
- **证据**：待确认 —— 缺部署形态信息：`EvolutionLease` 只保证「同一天只有一个进程跑演进」，但 `EvolutionStore.save` 是公开接口，没有租约保护；若同库存在第二个实例（蓝绿发布、多副本），两边各自 `MAX(id)+1` 会算出同一个 `id`，`INSERT` 直接主键冲突。冲突异常在 `SkillEvolutionJob.cj:208-213` 被 `catch` 吞掉，表现为报告静默丢失。
- **建议**：改用自增列/序列（MySQL `AUTO_INCREMENT`、PG `GENERATED BY DEFAULT AS IDENTITY`）由数据库分配 id，或 `INSERT ... ` 冲突时重试一次重算 `MAX(id)`；至少把「单进程」写成 `ensureSchema` 的显式前置条件并在启动日志里提示。

### [轻微][存量] 集成测试污染全局配置与共享库

- **位置**：`f_llm/src/store/it/StoresBootstrap_test.cj:31-49`；`f_llm/src/store/mysql/MySqlMemoryRepository_test.cj:40-71,82-90`；`f_llm/src/store/postgres/PostgresMemoryRepository_test.cj:119-178`
- **来源**：存量
- **判据**：review-checklist §10（可测试性）、§14（用例覆盖）
- **证据**：静态确定 —— `StoresBootstrapTest` 用 `Config.set<String>` 改写全局 `llm_memoryStore` 且不还原（第二个用例留下 `sqlite`），同进程后续任何 `Stores.content()` 都会抛「unknown llm_memoryStore」；`MySqlMemoryRepository_test.prepare()` 每用例 `DROP TABLE llm_memory / llm_memory_token`，与 `store/it/CrossBackendConformance_test.cj:161` 共用同一个 `fllm_test` 库；`PostgresMemoryRepository_test.testConfCandidatesFilterDisabledAndZeroWeight` 直接 `DELETE FROM llm_conf` 清表。
- **描述**：`@Test` 默认并行/乱序执行时，这些用例会互相清表或改全局配置，表现为偶发失败（`available()` 只在连不上库时跳过，断言失败仍会暴露，但「表被别的用例删了」会走成 SKIP 分支，把真失败伪装成跳过）。
- **建议**：用例结束用 `Config.set` 还原或提供 `Stores.resetForTest()`（`Stores.cj:62-65` 已有）；表名按用例加后缀（或每用例独占 `schema`/`database`）；`DELETE FROM llm_conf` 改为只删本用例插入的行。

### [轻微][存量] `processedKnowledge` 多一次数组拷贝、`get` 用 `for` 取单行

- **位置**：`f_llm/src/store/mysql/EvolutionStateStore.cj:82-93`（`ArrayList.add` → `toArray()`）、`f_llm/src/store/postgres/EvolutionStateStore.cj:87-98`；`get` 用 `for(row in …)` 赋值后再 `box.value`：`mysql/EvolutionStateStore.cj:49-60`、`postgres/EvolutionStateStore.cj:54-65`、`mysql/EvolutionLease.cj:92-97`、`postgres/EvolutionLease.cj:99-104`
- **来源**：存量
- **判据**：review-checklist §7（删除中间副本）、§10（可读性）
- **证据**：静态确定 —— 5000 条上限下 `ArrayList<String>` + `toArray()` 即两份引用数组同时存活；`for` 循环取单行（主键查询最多 1 行）没有 `break`，读者需要自己确认「不会覆盖」。
- **建议**：直接用 `Array<String>` 或 `ArrayList<String>`（接口本身若返回 `Array`，用 `list.toArray()` 前先 `ArrayList` 预分配容量）；单行查询改 `firstToMap()` 或 `for` 内 `break`。

## 优化可行性方案

### [CPU] `vectorLiteral` 在循环里做字符串拼接，1024 维是 O(n²)

- **现状**：`f_llm/src/store/mysql/MemoryRepository.cj:215-225`、`f_llm/src/store/postgres/MemoryRepository.cj:188-198`，`text += '${vector[index]}'` 逐元素拼接；每次 `upsert` 调 2 次、每次 `searchDense` 调 1 次，向量维度 1024（`Fixed1024Embedder`、`llm_memory_vector vector(1024)`）⇒ 每次约 1024 次 string realloc，累计复制量约 O(1024²/2) 字符。
- **方案**：`StringBuilder` + `append` 序列化（`StringBuilder.append(Float64)` 仍会转串，但避免每步整体复制）；或两方言共用 `VectorMath.literal`（已存在同功能实现，`f_llm/src/store/VectorMath.cj`）。
- **预期**：单次字面量构造从 O(n²) 降到 O(n)，减少约 1000 次中间串分配；对 `upsert` 端到端的影响取决于嵌入耗时占比（大概率 <5%）。
- **代价**：无语义变化；需回归「浮点格式与 `myvector_construct` / `::vector` 可解析」的用例（现有集成测试已覆盖）。
- **验证**：`cjpm bench` 或用例级分段计时，同 1024 维输入各跑 200 次取中位数；对照 `cjprof record` 中 `vectorLiteral` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `markKnowledge` 在持锁状态下逐条 `INSERT`

- **现状**：`f_llm/src/store/mysql/EvolutionStateStore.cj:95-105`、`f_llm/src/store/postgres/EvolutionStateStore.cj:100-110` —— 对 `docIds` 每个元素一次 `knowledgeInsert`（MySQL `INSERT IGNORE`、PG 见 `dao/postgres/EvolutionStateDAO.cj`），全部在 `synchronized(mutex)` 内；单轮 `usedKnowledge` 量级等于本轮新消费的知识数（`SkillEvolutionJob.cj:203`）。
- **方案**：改成单条多值 `INSERT ... VALUES (...),(...)` 或 JDBC batch；`insert` 前先按 `docId` 去重并在应用侧截断空串（现在每条都判 `isEmpty`）。
- **预期**：N 次网络往返 → 1 次，持锁时间同比缩短；N=50 时约省 49 次往返。
- **代价**：多值 INSERT 的 SQL 长度上限（MySQL `max_allowed_packet`）——按 500 条 × ~80 字节分片，例如每批 200 条。
- **验证**：`cjpm bench`（或 `EvolutionStoreIT_test` 场景）同 N 下中位数对比；同时记录 `synchronized` 临界区耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 分页循环内反复 `dao<>('mysql')` 查找

- **现状**：`f_llm/src/store/mysql/KnowledgeStore.cj:123` 与 `f_llm/src/store/postgres/KnowledgeStore.cj:122` —— `while` 每翻一页都重新 `dao<…DAO>('driver')`（宏生成方法内部再取 `executor`，而 `executor` 走 `ThreadLocal` 查表，见 `f_orm/src/base/SqlExecutor.cj:44-45`）；`upsert` 只取一次（`mysql/KnowledgeStore.cj:66`），说明写法本可以统一。
- **方案**：循环外取一次 DAO 存局部变量（与 `upsert` 一致）。
- **预期**：每页省 1 次注册表 + 1 次 ThreadLocal 查找；页数 = `maxCandidates/pageSize`（默认 ≤5 页），收益很小，属顺手清理。
- **代价**：无。
- **验证**：`cjprof record` 里 `dao<>` / `ORM.executor` 的自耗时占比是否可测；占比低于噪声则不做。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] MySQL 稠密召回的过滤条件是「全量 id 的 JSON 数组」

- **现状**：`f_llm/src/dao/mysql/MemoryDAO.cj:49-59` —— 每次 ANN 检索先 `SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = …` 聚合该用户所有记忆 id；成本随用户记忆总量线性增长，与 `limit`（默认 `topK*2`）无关。
- **方案**：能下推的条件（`namespace`、`kind`）直接写进 `llm_memory` 的 `WHERE`；无法下推时改成「ANN 取 `limit*K` 后在应用侧按 `user_id` 过滤」或依赖 MyVector 支持的标量过滤语法（需实测组件能力）。
- **预期**：过滤集合从 O(用户记忆数) 降到 O(候选数)；用户记忆 10k 时省一次万级聚合。
- **代价**：若改为后置过滤，`limit` 需放大以补偿被过滤掉的行，召回质量需回归（`KnowledgeSearch`/`RetrievalScoring` 用例）。
- **验证**：造 1k / 10k / 100k 条记忆的单用户数据，`cjprof` + 数据库慢日志对比 `mySearchDense` 端到端耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `processedKnowledge` 的双份引用数组

- **现状**：`f_llm/src/store/mysql/EvolutionStateStore.cj:82-93`、`f_llm/src/store/postgres/EvolutionStateStore.cj:87-98` —— 先 `ArrayList<String>` 累积（≤5000 条，约 5000×(24B 头 + 内容)），再 `toArray()` 复制一份引用数组；峰值 = 两份同时存活。接口注释已说明它「只用于运维/调试查看」（`f_llm/src/store/EvolutionStateStore.cj:64`）。
- **方案**：运维路径不需要数组语义时返回 `ArrayList<String>`，或在 `ArrayList` 上 `reserve(KNOWLEDGE_LIMIT)` 后直接返回；`toArray()` 只在测试断言处调用。
- **预期**：省一份 ≤5000 元素的引用数组（≈40KB 量级），并把扩容次数从 log2(5000) 次降到 1 次。
- **代价**：接口返回类型变化（`EvolutionStateStore` 是对外接口，属破坏性变更，需用户确认）。
- **验证**：`getAllocatedHeapSize()` 在循环调用 100 次后对比（口径见 `mem §1.2`），并确认 GC 后回落。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每个方法一个 `*Box` 临时对象（本部分 12 个 box 类）

- **现状**：为了把 `synchronized(mutex){ … }` 里的结果带出来，每个方法都 `let box = XxxBox()` 再 `box.value = …`：`mysql/EvolutionLease.cj:44,57,66`、`postgres/EvolutionLease.cj:49,62,71`、`mysql/EvolutionStateStore.cj:50,83,109`、`postgres/EvolutionStateStore.cj:55,88,114`、`mysql/EvolutionStore.cj:42,63,73`、`postgres/EvolutionStore.cj:44,65,75`；对应 12 个 `class *Box`（`mysql/EvolutionStateStore.cj:152-162`、`postgres/EvolutionStateStore.cj:157-167`、`mysql/EvolutionStore.cj:142-148`、`postgres/EvolutionStore.cj:146-152`、`mysql/EvolutionLease.cj:111-113`、`postgres/EvolutionLease.cj:118-120`、`f_llm/src/store/EvolutionLease.cj:235-237`）。
- **方案**：若 `std.sync.synchronized` 的签名支持返回值（返回值即 lambda 的返回值），整体删掉 box 与「锁外再读 box」的写法；否则保留，但把 `class` 换成 `struct` 降低分配成本。**该 API 语义本轮无法查证**（`~/.autocode/cj/doc` 在本机不存在），必须先查文档再动手。
- **预期**：每方法 1 次小对象分配（≤48B）× 每次演进调用；演进低频，绝对收益很小，主要收益是可读性（去掉 6 个类、17 处样板）。
- **代价**：若 `synchronized` 确实返回值，改动面覆盖 6 个文件；语义不变。
- **验证**：改后跑 `EvolutionStoreIT_test` / `EvolutionStateStore_test` 全绿；分配量用 `getAllocatedHeapSize()` 前后对比（预期差异在噪声内，那就只做可读性改造）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `vectorLiteral` 的 O(n²) 拼接在 `upsert` 端到端里占比很低（嵌入与网络占主导），单独改造收益 <5% | `f_llm/src/store/mysql/MemoryRepository.cj:215`；`postgres/MemoryRepository.cj:188` | 自耗时占比 | `cjprof record` 跑 200 次 `upsert`（1024 维），看 `vectorLiteral` self time 与 `String` 分配的占比 |
| 2 | 6 个演进/租约类的实例 `Mutex` 在真实并发下会成为串行点 | `mysql/EvolutionStateStore.cj:41-119`；`postgres/EvolutionStateStore.cj:46-124` 等 | 锁等待时长、并发线程数 | 多线程压 `get/save/processedAmong`（例如 8 线程 × 1k 次），线程状态看 BLOCKED/WAITING 时长（`cjprof` 的 CPU profile 看不出锁竞争） |
| 3 | MySQL `MYVECTOR_IS_ANN` 的过滤数组规模是召回延迟主因子 | `f_llm/src/dao/mysql/MemoryDAO.cj:49-66` | 用户记忆条数 vs 查询延迟曲线 | 造 1k/10k/100k 条记忆，逐档记录 `searchDense` P50/P95 与慢日志 |
| 4 | 空 `JSON_ARRAYAGG`（NULL filter）会让 MyVector 报错而不是返回空集 | `f_llm/src/dao/mysql/MemoryDAO.cj:49,65` | MyVector 组件对 NULL filter 的实际行为 | 对一个零记忆的 `user_id` 调 `searchDense`，记录返回/异常 |
| 5 | `Box` 写法可以整体消除（取决于 `synchronized` 是否返回值） | 见「优化可行性方案 · 堆内存」 | `std.sync.synchronized` 的签名 | 查 `std.sync` 文档或看 `sdk` 里 `synchronized` 的声明；再决定是删 box 还是换 `struct` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/store/it/StoresBootstrap_test.cj` | .cj | ✅ | 见「轻微 · 集成测试污染全局配置」 |
| 2 | `f_llm/src/store/it/TokenUsageSaver_test.cj` | .cj | ✅ | PK/MySQL 各一条落库用例，断言失败会重新抛出（第 96-99、135-138 行），无问题 |
| 3 | `f_llm/src/store/mysql/ContentStore.cj` | .cj | ✅ | 见「轻微 · 未同步惰性初始化」；与 PG 版逐行对应 |
| 4 | `f_llm/src/store/mysql/EvolutionLease.cj` | .cj | ✅ | CAS 语义正确；锁范围见「一般 · 临界区包住 DB I/O」 |
| 5 | `f_llm/src/store/mysql/EvolutionStateStore.cj` | .cj | ✅ | 锁范围、逐条 insert、`toArray` 拷贝 |
| 6 | `f_llm/src/store/mysql/EvolutionStore.cj` | .cj | ✅ | `nextId` 见「轻微 · 演进报告 id」 |
| 7 | `f_llm/src/store/mysql/KindPersistence.cj` | .cj | ✅ | 与 PG 版仅驱动名不同；`allCustom` 分组正确 |
| 8 | `f_llm/src/store/mysql/KnowledgeStore.cj` | .cj | ✅ | `minOf` 死代码；分页循环内 `dao<>`；`denseK` 有上界 |
| 9 | `f_llm/src/store/mysql/MemoryRepository.cj` | .cj | ✅ | 越权删除（严重）、`saveTime`、`vectorLiteral` |
| 10 | `f_llm/src/store/mysql/MetaStore.cj` | .cj | ✅ | 每次访问新建子 store；`confCandidates` 的 `enabled=true` 与 SQL 过滤一致 |
| 11 | `f_llm/src/store/mysql/MySqlMemoryRepository_test.cj` | .cj | ✅ | `DROP TABLE` 与共享库冲突；`available()` 跳过逻辑有注释说明 |
| 12 | `f_llm/src/store/mysql/TokenUsageSaver.cj` | .cj | ✅ | 单方法直落库，与 PG 版等价 |
| 13 | `f_llm/src/store/postgres/ContentStore.cj` | .cj | ✅ | 同 #3 |
| 14 | `f_llm/src/store/postgres/EvolutionLease.cj` | .cj | ✅ | 同 #4 |
| 15 | `f_llm/src/store/postgres/EvolutionStateStore.cj` | .cj | ✅ | 同 #5 |
| 16 | `f_llm/src/store/postgres/EvolutionStore.cj` | .cj | ✅ | `ensure` 多建 `ensureSkillIndex`（与 MySQL 漂移） |
| 17 | `f_llm/src/store/postgres/KindPersistence.cj` | .cj | ✅ | 同 #7 |
| 18 | `f_llm/src/store/postgres/KnowledgeStore.cj` | .cj | ✅ | `minOf` 死代码；`vectorOf` 的 NULL 降级路径正确 |
| 19 | `f_llm/src/store/postgres/MemoryRepository.cj` | .cj | ✅ | 越权删除（严重）、漏删 token、`saveTime` |
| 20 | `f_llm/src/store/postgres/MetaStore.cj` | .cj | ✅ | `DRIVER` 死代码；子 store 缓存与 MySQL 不一致 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 2（越权删除、`saveTime`）、设计 2（方言重复、锁粒度）、安全性 1（越权删除同条）；语言特性无问题（`match` 解包、`?Any` 映射均正确），可读性并入「轻微」两条 |
| §1 死代码 | 2 | 逐个 `private` 符号全仓搜过：`minOf`×2、`PostgresMetaStore.DRIVER` 无引用（已报）；`myLeaseTextOf`/`pgLeaseTextOf`/`myStateIntOf`/`myStateTextOf`/`myEvoEntriesOf`/`myEvoIntOf`/`myEvoTextOf`/`kindTextOf`/`kindIntOf`/`chunkIntOf`/`chunkFloatOf`/`textOf`/`intOf`/`floatOf`/`boolOf`/`bytesOf`/`recordOf`/`parseDatabase`/`vectorLiteral`/`denseK`/`annPath`/`scoreKey`/`maxOf` 均有调用者；`*Box`/`ChunkScore*` 均为本文件内使用；`public` 且对外可达的 store 类（`MySql*Store`/`Postgres*Store`）按硬原则一不判，`Internal` 类（`MySqlCharacterStore` 等）经 `MetaStore` 属性被使用 |
| §2 重复逻辑 | 1 | 9 对同名文件逐行 `diff`（≈84% 相同）+ 逐文件函数体摘要比对；另比对 3 个 `LeaseBox`、3 个 `*StateBox`、2 个 `*KnowledgeBox`、2 个 `*EvoListBox` 为同形样板（并入 box 优化方案）；`minOf`/`maxOf` 与 `VectorMath` 功能重叠已记在死代码条目 |
| §3 空实现 | 0 | 本部分无 `TODO`/`FIXME`；空 `init()`（`ContentStore`/`EvolutionLease`/`EvolutionStore`/`TokenUsageSaver`/`KindPersistence`）无字段需初始化，非空契约；`case None => ()`（`KnowledgeStore.search` 无 Embedder 时跳过 dense）是文档写明的降级路径，`catch(e: Exception){ println("SKIP…") }` 仅出现在测试且带注释说明「断言失败仍会暴露」 |
| §4 栈溢出 | 0 | 20 个文件内无自递归/间接递归；`KnowledgeSearch.rank`、`KnowledgeChunker.split` 为循环实现（不在本部分，只作调用关系确认） |
| §5 OOM | 1 | MySQL 稠密召回的 `JSON_ARRAYAGG(id)` 随用户记忆总量线性增长（已报，DB 侧）；应用侧容器均已有上界：`KNOWLEDGE_LIMIT=5000`、`maxCandidates`（默认 400/1000）、`denseK` 有 cap、分页 `while (collected < maxCandidates)` 有出口 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`f_llm/doc/perf-baseline.md` 未覆盖 store 层），故不立热点结论；5 条猜测已进「待验证假设」 |
| §6.2 大粒度锁 | 1 | 6 个类的临界区含全部 SQL（已报为「一般 · 锁内 DB I/O」）；`markKnowledge` 的 N 次 insert 同条 + 优化方案 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`；串行点只有实例 `Mutex`（并入 §6.2/§12.2 条目） |
| §6.4 低效算法 | 2 | `vectorLiteral` 循环拼接 O(n²)（优化方案）；`annPath`/DAO 每页重复查找（优化方案）。`wanted()` 的线性 `docIds` 比较规模 ≤ 请求 docIds 数，暂不构成 |
| §7 降堆内存方案 | 2 | `processedKnowledge` 双份引用数组、`*Box` 每方法分配（均无基线） |
| §8 降 CPU 方案 | 4 | `vectorLiteral`、批量 `markKnowledge`、循环内 `dao<>`、ANN 过滤集合收缩 |
| §9 local mode 可行性 | 0 | 无函数内大临时结构：`vectorLiteral` 产出的是要返回/绑定的字符串（逃逸），`merged`/`hits` 要作为返回值逃逸，`processedKnowledge` 结果返回给调用方；local region 无适用对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 6 | 越权删除、`saveTime`、PG 漏删 token、`JSON_ARRAYAGG` 空集、`nextId` 撞主键、测试互相清表；边界/空值另核对了 `parseDatabase`（无 `/` 时返回空串，下游 `annPath` 为空 → dense 跳过，符合「SQL 构造不合法时不发查询」的降级意图）、`chunkFloatOf`/`intOf` 的 `?Any` 分支、`processedAmong` 空数组（DAO 内 `docIds.size == 0` 短路）、`upsertSparse` 空 tokens（`isEmpty` 短路） |
| §12 并发安全与锁粒度 | 4 | 越权删除（跨请求共享库，同条计入）、未同步惰性初始化、实例锁粒度（同条）、`nextId` 非原子（同条）；其余方法状态为栈上局部或 `let` 常量，DAO 走 `ThreadLocal` executor（`f_orm/src/base/SqlExecutor.cj:44-45`），未发现共享可变状态 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；按 `src/` 公开声明对照模块 README 的能力项（记忆/知识/元数据/演进/token 用量）均有实现入口，无「承诺未实现」；`POSTGRES/MYSQL` 两方言能力对齐差异已并入 §2 漂移条目 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 `.md`，§13 无适用对象 |

> 范围外提示（不占统计）：`f_llm/tables-mysql.sql:110-122` 的 `llm_memory` 没有 `title_vec`/`content_vec`/`*_colbert` 列（向量在 `llm_memory_vector`，第 156-168 行），而本部分 `mysql/MemoryRepository.cj:48-49` 与 `dao/mysql/MemoryDAO.cj:30,38,62,82` 直接读写这些列 ⇒ 照仓库自带 DDL 部署 MySQL 会 `Unknown column`。该漂移已在 `docs/fountain实现思想与应用/…第16弹.md:403` 记为已知限制，修复涉及 DDL 与 DAO（均不在本部分），故只记一句。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 4 |

## 总评

本部分（MySQL / PostgreSQL 两套 SQL 存储实现 + 3 个集成测试文件）的代码本身写得规整：SQL 全部下沉到 `dao/{mysql,postgres}`，方言差异集中在 DAO 的 `ON DUPLICATE KEY` / `ON CONFLICT` 与 MyVector/PGVector 表达式上；`?Any` 行映射对 Int64/Int32/Int16/Float32/字符串都做了分支，位图/colbert 的 `Array<Byte>` 也有空值兜底；演进租约用「单行 + 条件更新」实现跨进程互斥，比锁服务轻且语义清楚。**唯一阻塞项是 `MemoryRepository.remove` 的子表删除未带 `user_id`**——它把「删别人的记忆」从不可能变成了副作用，且 PostgreSQL 侧直接丢 dense 向量（需重建索引才恢复）。这条必须在 MySQL/PG 上任何生产使用前修掉；它之所以存在，正是两套实现逐行复制、子表结构又不同（PG 是独立 vector 表 + token 表，MySQL 是宽表 + token 表）的结果，所以「抽一层方言无关基类、把清理顺序写死一处」应作为随后的排期项，而不是可选项。

其余各项按危害排序：`saveTime` 恒为 `now()` 会让技能演进每轮重跑全部经验（白烧 LLM 调用，且 `doc/loom.md` 承诺的「按真实时间比较」不成立），PG 漏删 token 是慢性表膨胀，`JSON_ARRAYAGG` 空集与 `nextId` 撞主键属「需要一次实测/一次部署形态确认」的边界问题，可按上面的验证清单补齐数据后再决定是否修。死代码只有 `minOf`×2 与一个未用的 `DRIVER` 常量，重复逻辑的主要形态就是方言双份代码（≈84% 相同）而非散落的字面量复制；性能侧没有 profile 数据，因此 `vectorLiteral`、批量写入、锁粒度都只写进「优化可行性方案 / 待验证假设」，未计入缺陷。

存量问题共 12 条，是否纳入修复请用户按「严重 1（越权删除）→ 一般 5」的顺序拍板；本报告未改动任何源码，也未运行构建。

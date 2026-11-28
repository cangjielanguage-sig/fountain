# f_llm 模块审查报告

> **模块第 21/25 部分**（分报告）。本部分只覆盖 `f_llm/src/store/` 的 20 个文件
> （`KnowledgeSearch` / `MemoryIndexRebuilder` / `MemoryKinds` / 三个适配器 / `PostgresMemoryStore` /
> `PredefinedCharacters` / `RetrievalScoring` / `StoreContracts` / `StoreModels` / `StoreSettings` 及其 6 个 `_test.cj`）；
> 同模块其余文件见 `parts/f_llm.part1-20/22-25.md`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个源文件，全部 `.cj`，无 `.md`；全模块 368 个 `.cj` + 112 个 `.md`）
- **基线**：工作区快照（`scope.md`：无 diff）。关键文件历史 `git blame`：`MemoryRepositories.cj:28-33` → `ff71f4bb97`/`945d571899`（2026-10-30）、`PostgresMemoryStore.cj:60-68` → `8b70c78ce4`（2026-10-29）/`be0999c476`（2026-11-07）、`MemoryKinds.cj:55-57` → `a94533515d`/`7398ed095a`（2026-10-29/31）；工作区干净，**本部分全部按「存量」计**
- **审查重点**：LLM 客户端契约与配置、存储层契约一致性、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1.1（第 21/25 部分分报告）。v1 完成 20 个文件的全量通读与 #1–#21；v1.1 为同日第二轮独立复核，补 #22–#26（检索排序退化、向量维度/负值、重建可恢复性、排序规模前提、人格双表）、把 `search` 路径的 kind 过滤并入 #1，并修正 v1 中两处表述（`MemoryStoreAdapter` 的转发其实正确；`weightOf` 等价分支是规格要求的显式写法）

## 发现

> 交叉引用编号 #N 按下列标题出现顺序编号（#1–#26；#1–#21 来自首轮通读，#22–#26 来自第二轮独立复核），用于「文件覆盖」与「覆盖自检」中的指代。

### [严重][存量] `MemoryRepositoryAdapter` 未转发 `listByKind`，生产路径的 kind 过滤退化为「先分页后过滤」，静默丢记录

- **位置**：`f_llm/src/store/MemoryRepositories.cj:28-74`（适配器只转发 9 个方法，**无 `listByKind`**）；近似实现 `f_llm/src/store/MemoryRepository.cj:72-82`；上抛链 `f_llm/src/store/PostgresMemoryStore.cj:83-85` → `f_llm/src/store/StoreContracts.cj:54-64`；真实消费方 `f_llm/src/loom/LoomStoreGateway.cj:155-162`
- **来源**：存量（`git blame`：`MemoryRepositories.cj:28-33` = `ff71f4bb97`/`945d571899`，2026-10-30；接口默认实现在 `MemoryRepository.cj` 同批提交）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复：一块少了边界判断，往往同时是缺陷」、§14.1「接线缺失」
- **证据**：静态确定 —— ① `MemoryRepository`/`MemoryStore` 两处接口的默认 `listByKind` 都是 `list(offset, limit)` 取一页再按 `kind` 过滤，注释自认「近似的…否则 `limit` 很小时会漏掉目标记录」（`MemoryRepository.cj:66-82`）；② `PostgresMemoryRepository` 与 `MySqlMemoryRepository` 都已把条件下推 SQL（`f_llm/src/store/postgres/MemoryRepository.cj:112-119`，注释「kind 条件下推到 SQL：先过滤再分页」）；③ `MemoryRepositoryAdapter` 未覆写 `listByKind`，因此在**生产装配路径**（`SqlMemoryStore()` → `MemoryRepositoryAdapter` → `lookupOption<MemoryRepository>()`，见 `PostgresMemoryStore.cj:35-38`）调用落到接口默认实现，精确覆写被绕过
- **描述**：`PostgresContentStore.memory` 就是 `SqlMemoryStore()`（`f_llm/src/store/postgres/ContentStore.cj:31-41`，`SqlMemoryStore()` 在 `:36`），所以 Loom 的 `memory list` + `kind` 过滤（`LoomStoreGateway.cj:155-162`，注释写「交给 Store 过滤：先过滤再分页，**不会出现「本页没有就判空」**」）走的是近似版：先按 `pageOf` 取一页（默认 50 条）再过滤，若这 50 条里恰好没有目标 kind，**返回空数组**，调用方（流程/模型）会认为"该用户没有这条记忆"。数据没坏，但读结果系统性偏少，且随 kind 分布稀疏程度放大
- **同一根因的第二条路径（`search`，不是 `list`）**：`SqlMemoryStore.search` 把 `topK * 2` 交给仓储后，才在内存里按 `query.kinds` 过滤（`PostgresMemoryStore.cj:90-93`、`:109-113`、`:195-206`），而 DAO 的两条召回 SQL 都没有 kind 条件（`f_llm/src/dao/postgres/MemoryDAO.cj:66-74` 与 `:114-124` 的 `WHERE` 只有 `user_id` 与 `namespace IN`）。因此「只要 `kind='experience'`、topK=5」时，若截断窗口里的 10 条大多是 `session`，最终只返回 2 条甚至 0 条——即使库里还有上千条 `experience`（`LoomStoreGateway.cj:86-90,181-191` 会给 experience 工具传默认 kind，不是边缘用法）。`MemoryStoreAdapter.listByKind`（`MemoryStoreAdapter.cj:60-63`）本身转发正确，这里的漏读来自它委托到的 `SqlMemoryStore` → `MemoryRepositoryAdapter` 默认实现，不是适配器少写了一层
- **建议**：`MemoryRepositoryAdapter` 补 `public func listByKind(...) { delegate.listByKind(...) }`（与其余 9 个方法同形）；`SqlMemoryStore` 同样显式转发而不是依赖接口默认实现；把 `kind` 条件也下推进 `searchDense`/`searchSparse` 的 DAO（与 `namespace` 同一写法），或改成有界翻页直到凑满 topK；把接口默认实现改为 `throw UnsupportedException` 或明确标注「仅测试用」，避免"看起来能跑"的近似路径继续被继承；补两条用例：「kind 记录分散在 2 页之后仍能取到 limit 条」「按 kind 检索时截断窗口被其它 kind 占满仍能返回 topK」

### [严重][存量] 启动索引重建根本没接线：`llm_rebuildIndexOnStart` 全链路无运行时调用者，文档承诺的「启动时重建」不成立

- **位置**：`f_llm/src/store/MemoryIndexRebuilder.cj:46-56`（`rebuildIfConfigured` 是唯一读配置的入口，**零调用者**）；配置读取 `f_llm/src/store/MemoryIndexRebuilder.cj:48-52`；承诺源 `f_llm/README.md:305`、`f_llm/README_en.md:303`、`f_llm/README.md:771`、`f_llm/doc/f_llm.md:320-321`、`f_llm/doc/f_llm-memory-design.md:114-115`
- **来源**：存量（`git blame`：类与入口来源 2026-10 批次；工作区无改动）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失：配置项被读取却从未使用」、§3「开关打开后走进空分支（功能未接完）」、§11「与规格 / README 冲突」
- **证据**：静态确定 —— ① 全仓（排除 `.worktrees`）搜 `rebuildIfConfigured` / `MemoryIndexRebuilder.` / `Rebuilder` 只命中定义与 `*_test.cj`，无任何装配点；② 装配类 `f_llm/src/wiring/StoreWiring.cj:60-92` 只注册 Store bean 与 `seedKinds()`，不含重建调用；③ `LLMConfig.isIndexRebuildEnabled()` / `getIndexRebuildUserId()` / `getIndexRebuildNamespace()` 的唯一调用点就是 `rebuildIfConfigured` 自身（`f_llm/src/config/LLMConfig.cj:137-150`），即整条配置链在运行期不可达；④ 承诺写法明确是自动触发：「`KnowledgeIndexRebuilder` / `MemoryIndexRebuilder`：**启动时**按 `llm_rebuildIndexOnStart` 重建索引」（README.md:305）、「两者都不会自动触发，需要显式调用**或开 `llm_rebuildIndexOnStart`**」（doc/f_llm-memory-design.md:115）
- **描述**：使用者按文档置 `llm_rebuildIndexOnStart=true` 后不会发生任何重建：日志无 `memory index rebuilt`，索引照旧缺失，检索长期停在 `degraded` 的 dense-only 状态；同时 `KnowledgeIndexRebuilder` 连配置入口都没有（`f_llm/src/store/KnowledgeIndexRebuilder.cj:33-63` 只有 `rebuild`/`rebuildAll`），文档承诺的两条重建里有一条完全无从触发。这类"配置静默无效"最难排查——配置读到的值与行为无关联，且不会报错
- **建议**：在 `StoreWiring`（启动期、Store 装配之后）调用 `MemoryIndexRebuilder.rebuildIfConfigured(...)`，并把 `KnowledgeIndexRebuilder` 的配置入口补齐（复用同一组 key，或另开 `llm_rebuildKnowledge*`）；若决定不做自动触发，则改文档为"需显式调用"，并删掉 `rebuildIfConfigured` 与三个配置 getter 的死链

### [一般][存量] 稀疏/多头向量为空时无条件覆盖写：重建或重复 `add` 会把已有倒排与 colbert 索引清空，并计入"成功重建"

- **位置**：`f_llm/src/store/MemoryIndexRebuilder.cj:79-86`（`upsertSparse` / `upsertColbert` 不看空值）；`f_llm/src/store/PostgresMemoryStore.cj:52-62`（`add` 同源）；被调契约 `f_llm/src/store/MemoryRepository.cj:50-55`
- **来源**：存量（`git blame`：`PostgresMemoryStore.cj:60-68` = `8b70c78ce4`，2026-10-29）
- **判据**：review-checklist §11「错误处理缺失 / 边界」、§14.1「半成品：只处理部分输入」、§3「静默失效」
- **证据**：静态确定（契约 + 实现两侧）——`upsertSparse` 契约是「先删旧 token，再写新 token」，PG 实现第一步就是无条件 `DELETE FROM llm_memory_token WHERE memory_id = ?`（`f_llm/src/store/postgres/MemoryRepository.cj:53-62`），空 map 等于**清空**；`upsertColbert` 契约「空数组表示没有」，PG 实现直接覆盖列（`MemoryRepository.cj:64-68`），而 `ColbertCodec.encode([])` 产出的是「count=0 的 4 字节 blob」（`f_llm/src/store/ColbertCodec.cj:28-45`），旧向量被这一小段字节顶掉、`decode` 回来就是空数组。而 `HttpEmbedder.tokenize/embedColbert` 直接透传传输层结果，`EmbeddingResponse` 的 `sparse`/`colbert` 默认就是空（`f_llm/src/embedding/HttpEmbedder.cj:28-39`，透传见 `:85-91`），`LlmEmbeddingTransport` 更是只回 dense（`f_llm/src/embedding/LlmEmbeddingTransport.cj:23-26` 注释自认）
- **描述**：触发条件两条：① 换过嵌入端点（BGE-M3 → OpenAI 兼容）后开重建：`rebuild` 逐条 `upsertSparse(空)` / `upsertColbert(空, 空)`，把**旧模型下仍然可用的** sparse/colbert 索引整片删掉，`rebuilt++` 照常计数，日志报"成功重建 N 条"；② 同 `(user, namespace, title)` 覆盖写时嵌入器某一路返回空，同样会清空该记录原有的一路索引。结果不可回滚（旧向量没备份），只能再换回原模型重跑，而重跑又要求三路都非空
- **建议**：重建与 `add` 都加"本路非空才写"的守卫（`if (!tokens.isEmpty())` / `if (!titleVectors.isEmpty() || !contentVectors.isEmpty())`），跳过的记录单独计数并在日志区分 `rebuilt` / `skipped(noVector)`；`upsertSparse` 的空覆盖语义在接口注释里点明"空 map = 删除全部"，让调用方不敢直传

### [一般][存量] `MemoryHit.degraded` 语义不可靠（"查询无命中"被当成"缺一路"），且全仓无消费点

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:95`、`:115`；字段契约 `f_llm/src/store/StoreModels.cj:85-92`；承诺源 `f_llm/doc/f_llm.md:241,309`、`f_llm/doc/f_llm-memory-design.md:81-83,309`
- **来源**：存量（`git blame`：`PostgresMemoryStore.cj:95` 同 `8b70c78ce4` 批次，2026-10-29）
- **判据**：review-checklist §13「文档承诺与实现不符」、§14.1「降级标记未接线」、§11「语义与注释不符」
- **证据**：静态确定 —— `degraded = sparse.isEmpty()`；而 `searchSparse` 在两种完全不同的情况下都返回空：`tokens.isEmpty()`（查询文本切不出 token、或嵌入器只回 dense，见 `f_llm/src/store/postgres/MemoryRepository.cj:71-78`）与"有倒排但无命中"。文档把该字段定义为「某一路向量**缺失**」并明确「调用方据此判断结果可信度」（doc/f_llm.md:309），实现无法区分这两种语义；同时全模块搜 `degraded` 只命中 store 内构造与 `PostgresMemoryStore_test.cj:223` 一处断言，网关的检索响应序列化里没有该字段（`f_llm/src/loom/LoomStoreGateway.cj:194-207` 只有 `id/title/content/kind/score`）
- **描述**：两个后果叠加——① 误报：健康的 sparse 索引遇到"查询词全部未命中文档"时，整批结果被打上 `degraded`，运维据此排障会走向错误方向；② 断链：文档承诺的"可观测降级标记"没有任何仓内消费者，Loom 的 `memory search` 结果不携带它，流程侧拿不到可信度信号，等于承诺的观测点不存在
- **建议**：把"索引缺失"与"本次无命中"分开表达——`MemoryRepository` 增加能力探测（如 `hasSparseIndex(userId): Bool`）或让 `searchSparse` 返回 `(hits, available)`；`degraded` 只在一路**不可用**时置位。若保留现语义，则在字段注释与 doc 里改成"本次检索未产生 sparse 命中"，并在 `LoomStoreGateway` 的 JSON 里输出 `degraded`，否则该字段建议直接删掉

### [一般][存量] `add` 的三段写入非原子：`upsertSparse` 失败会留下"有记录无倒排"的脏数据；colbert 异常被空 catch 吞掉且零日志

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:46-69`（`upsert` → `upsertSparse` → `try/catch` colbert）
- **来源**：存量（`git blame`：`8b70c78ce4` 2026-10-29；`try{...}catch{}` 外壳 `be0999c476` 2026-11-07）
- **判据**：review-checklist §11「资源/状态不对称」、§3「`catch (_: Exception) {}` 静默吞掉异常」、§5「契约：失败拒绝写入」
- **证据**：静态确定 —— 注释声明「任何一次**向量化**失败都拒绝写入（不能存无向量记忆）」，但只有 `embed()` 在 `upsert` 之前执行；`repo.upsert` 已提交主表后，`repo.upsertSparse` 抛异常会直接冒出，**主表行留在库里**，重试又走唯一键覆盖，调用方看到"添加失败"却实际已写入；colbert 段是 `try { ... } catch (_: Exception) { }`，异常体为空，既不记日志也无计数，`MemoryHit.degraded` 也不会因它置位
- **描述**：嵌入服务抖动或 DB 连接中途断开时，写入语义变成"半成功"：主表有行、dense 有向量、sparse 没有 → 该条记忆永久只能被 dense 召回（且每次检索把它算进 `degraded` 的少数派）；colbert 失败则完全静默，排障时没有任何线索（`f_log` 无 warn，无指标）。注释与实现相反，属契约不符
- **建议**：把三步放进同一事务（`f_orm` 的 executor 级事务）或改为"先算全部产物、再一次性落库"；确实无法事务化时，`upsertSparse` 失败要补偿删除主表行或写"待补索引"标记供重建扫描；colbert 的 `catch` 至少 `log.warn('colbert upsert skipped: id=${id}, ${e.message}')` 并计数

### [一般][存量] `MemoryKinds` 用进程级可变静态 `HashMap`/`ArrayList` 做 kind 注册表，写入口无任何同步

- **位置**：`f_llm/src/store/MemoryKinds.cj:55-56`（`static let CUSTOM` / `static var persistence`）、`:63-78`（`attach` 清空并重填）、`:109-127`（`register` 检查-然后-写入）、`:153-173`（`remove` 重建列表）
- **来源**：存量（`git blame`：`MemoryKinds.cj:55` = `a94533515d` 2026-10-29、`:56-57` = `7398ed095a` 2026-10-31）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」「迭代与修改并发」、§11「并发正确性」
- **证据**：静态确定（缺同步）；触发面 待确认 —— ① 共享路径明确：`CUSTOM` 是 `static let` 的 `HashMap<Int64, ArrayList<String>>`，`register` 先 `CUSTOM.get(userId)` 取到内部 `ArrayList` 再 `custom.add(kind)`，`all` 遍历同一个 `ArrayList`；② 容器本身不是并发容器：std 另设 `std.collection.concurrent.ConcurrentHashMap` 并注明「此类用于实现并发场景下线程安全的哈希表」（文档 `1.3.0/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.html`），普通 `HashMap` 无此承诺；③ 同一 `user` 上两个线程各自 `register` 不同 kind 时，`contains` 判重与 `add` 之间有窗口，且 `ArrayList` 扩容与 `all()` 的遍历可并发；④ `attach` 在启动线程 `CUSTOM.clear()` 后逐用户重填，与任何并发读同时发生即为可见性问题
- **描述**：`register` / `remove` 是对外 `public` 写入口（`MemoryKinds` 是 `public class`），一旦接到 HTTP 处理线程（kind 管理接口）就立刻具备两个并发访问者，届时轻则丢一次注册（内存丢了但 DB 已写，`attach` 重启才恢复），重则 `ArrayList` 结构性破坏导致读出错乱；目前仓内 `register`/`remove`/`all`/`validate` 只被 `*_test.cj` 与 `store/it/KindPersistence_test.cj` 调用，所以是**潜伏**而非已触发的竞争——这也是它没有定为严重的原因
- **建议**：`CUSTOM` 换 `ConcurrentHashMap`（或 `HashMap` + 一把 `synchronized`/`ReentrantMutex`，注册是低频写、纯读多，读写锁更合适）；`register` 的"判重 + 插入"整体进临界区，且插入时用**新列表替换**而不是原地 `add`（避免遍历中修改）；`attach` 先构好新 map 再整块替换引用，保持"要么全旧要么全新"

### [一般][存量] `search` 对 `topK` 无校验无上界：`topK*2` 直接下推仓库，请求可拉全表；`topK<=0` 时向 SQL 传负 `limit`

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:87-93`（`let limit = query.topK * 2` → `searchDense` / `searchSparse`）；模型无校验 `f_llm/src/store/StoreModels.cj:70-78`；调用方 `f_llm/src/loom/LoomStoreGateway.cj:182-191`
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度取数 / 无拒绝路径」、§11「缺少边界校验」
- **证据**：静态确定（无上限）＋ 规模 需实测 —— `MemoryQuery` 构造只做赋值，`topK` 无下限也无上限；`LoomStoreGateway` 只兜了 `topK > 0`（否则取 5），**没有上限**，`intOf(args,'topK')` 直接来自请求 payload；`MemoryRepository.searchDense` 把 `limit` 透传给 DAO 的 SQL `LIMIT`（`f_llm/src/store/postgres/MemoryRepository.cj:49-51` → `f_llm/src/dao/postgres/MemoryDAO.cj:54-73`）
- **描述**：一次 `loomStore("memory","search", {topK: 100000000})` 会让仓库返回该用户全部记忆（向量 + 正文），`collect`/`normalize`/选择排序全部按这个规模物化：既无拒绝路径也无分页，单请求即可把 RSS 顶到容器上限；反向的 `topK<=0`（直接构造 `MemoryQuery`，绕过网关）会把 `0`/负数传进 `LIMIT`，SQL 侧行为随驱动不同（报错或全量）
- **建议**：`MemoryQuery` 构造或 `search` 入口统一夹紧：`topK = min(max(topK, 1), MAX_TOPK)`，`MAX_TOPK` 取常量（如 50）并在 README 配置表写明；`limit` 下推前再断言 `> 0`

### [一般][存量] `KnowledgeSearch.terms` 文档称「按空白切词」，实现只按空格 `split(' ')`，换行/制表符分隔的查询召回为 0

- **位置**：`f_llm/src/store/KnowledgeSearch.cj:30-41`（注释在 `:30`，实现 `text.split(' ')` 在 `:33`）；对照契约 `f_llm/src/store/StoreModels.cj:207`（`KnowledgeQuery` 注释「`text` 按空白切词」）
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」、§13「文档承诺与实现不一致」
- **证据**：静态确定 —— `trimAscii()` 只去首尾 ASCII 空白（含 `\t\n\v\f\r`，文档 `core_package_structs.html`「去除原字符串开头结尾以 ASCII 空白字符组成的子字符串」），`split(' ')` 只以空格 0x20 分割，因此 `"记忆\n检索"` 得到的**一个** term 是 `"记忆\n检索"`；knowledge 检索的首词召回与 `occurrences` 都用这个 term，倒排与子串匹配都必然 0 命中
- **描述**：多行文本（模型生成的多行 query、从文件/日志粘贴的段落）作为检索输入时静默返回空结果；调用方无从区分"没有相关文档"与"切词失败"。三个后端（PG/MySQL/内存）共用该函数，所以问题一致，不会互相掩盖
- **建议**：按空白字符集合切分（先 `split('\n')`/`\t` 归一，或用正则/`String.split` 逐分隔符），或先把所有 ASCII 空白替换为空格再 `split(' ')`；补一条 `"记忆\n检索"` 的用例锁定行为

### [一般][存量] MySQL 连通性用例与其注释相反：连不上时 catch 全部异常并 SKIP，CI 无库即永久绿

- **位置**：`f_llm/src/store/MySqlConnectivity_test.cj:25-44`（`available()`）、`:46-52`、`:63-69`
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」、§3「静默吞异常」、§14.1「半成品」
- **证据**：静态确定 —— 类注释写「连不上就让用例失败，而不是静默跳过——否则后面的 MySQL 实现无法验证」（`:25-28`），实现是 `try { ... } catch (e: Exception) { println("SKIP ..."); false }`，两个 `@TestCase` 拿到 `false` 直接 `return`（`:48-50`、`:65-67`），用例名与最终状态都是通过
- **描述**：MySQL 后端（4.3 及 `MySqlMemoryRepository`、`MySqlKnowledgeStore` 等）的验证前提正是这个探测；探测失败只打印一行 SKIP，CI 报告全绿，MySQL 相关回归长期无人发现。注释与实现方向完全相反，读代码的人会以为它在守门
- **建议**：二选一并写进 README：① 需要库的用例走 `@Configure`/环境变量开关，未配置时**跳过整个测试类**并在 CI 汇总里显式列出 skipped（而不是在用例内 `return`）；② 保持"必须有库"，失败即 `@Expect(false, true)` 抛出。同时把 `available()` 里 `ORM.register(..., default: true)` 的全局副作用挪到 `@BeforeAll`，只在真正执行时注册一次

### [一般][存量] kind 校验入口 `MemoryKinds.validate` 全仓仅测试引用，写入路径不校验：任意 kind 字符串都能落库并按 0.8 计权

- **位置**：`f_llm/src/store/MemoryKinds.cj:197-205`（`validate`）、`:178-195`（`weightOf` 的兜底 `0.8`）；写入路径无校验 `f_llm/src/store/PostgresMemoryStore.cj:46-50`；消费方 `f_llm/src/loom/LoomStoreGateway.cj:182-191`
- **来源**：存量
- **判据**：review-checklist §14.1「接线缺失」、§11「缺少边界校验」
- **证据**：静态确定 —— 全模块搜 `MemoryKinds.validate` 只命中 `MemoryKinds_test.cj`（6 处）与 `store/it/KindPersistence_test.cj`（4 处），无生产调用；`add` 只把 `write.kind` 原样透传给 `repo.upsert`；`weightOf` 对未知 kind 落到 `else { 0.8 }`（`:192-194`），与 `doc`/`knowledge` 同权
- **描述**：`loomStore("memory","add")` 的 `kind` 来自流程/模型输出，拼错（`facts`、`Fact`）不会报错，而是以 0.8 权正常入库，直到检索排序才发现"权重不对"；`MemoryKinds.register` 的字符集校验（`:224-236`）也只作用于注册，不管写入。公开的校验能力与真正的写路径脱节
- **建议**：`add` 入口调用 `MemoryKinds.validate(userId, kind)`，失败抛 `IllegalArgumentException`（或在 `StoreSettings` 里加 `llm_allowUnknownKind` 开关，默认关）；若确实要允许未知 kind，则把 `weightOf` 的兜底权重显式化并写进 doc，而不是复用 0.8

### [轻微][存量] 实现名清单以字面量在 4 处各写一遍（`mysql`/`postgres`/`f_store`/`f_hydra`），新增后端要改多处且已出现措辞漂移

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:28-29`（`@BeanMeta` 条件）、`f_llm/src/store/MetaStoreAdapter.cj:38-50`（三分支 + 错误消息）、`f_llm/src/store/MemoryRepositories.cj:80-86`（错误消息 `postgres|mysql`）、`f_llm/src/store/StoreSettings.cj:39-41`（默认值 `f_hydra`/`f_store`）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制：同一张状态码表 / 同一组字段名散落多处」
- **证据**：静态确定 —— 错误消息一处写 `available: f_store, mysql, postgres`（MetaStoreAdapter.cj:49），另一处写 `配置 llm_memoryStore=postgres|mysql`（MemoryRepositories.cj:85），`@BeanMeta` 又是一份 `mysql`/`postgres` 的枚举
- **描述**：加一个后端（如 `sqlite`）需要同时改 bean 条件、适配器分支、错误消息、默认值判断，漏一处即"配了却落到默认路径"或错误提示与实际可选值不符；已有两处提示文案不一致
- **建议**：在 `StoreSettings` 定义 `CONTENT_IMPLS` / `META_IMPLS` 常量数组，`@BeanMeta` 之外的判断与错误消息统一由常量拼装；适配器分支改为查表（`match` 只剩 `f_store` 特例）

### [轻微][存量] 线性 `contains` 助手 4 份；`persistInsert`/`persistDelete` 两个私有函数逐行同构

- **位置**：`f_llm/src/store/KnowledgeSearch.cj:106-113`、`f_llm/src/store/MemoryKinds.cj:238-245`、`f_llm/src/store/PostgresMemoryStore.cj:208-215`、`f_llm/src/store/MemoryKinds_test.cj:164-171`；`f_llm/src/store/MemoryKinds.cj:130-150`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 换控制流」
- **证据**：静态确定 —— 四处实现都是同语义 `for + ==` 早返回（签名 `ArrayList<String>` 与 `Array<String>` 各两处）；`persistInsert` 与 `persistDelete` 除 `store.insertCustom`/`store.deleteCustom` 与告警文案外完全一致
- **描述**：同类判重散落 4 份，后续若要改判定（大小写不敏感、trim 后再比）必须同步 4 处，漏一处即行为分叉；`persist*` 两份的告警文案已不同（`persist failed` vs `delete failed`，这个差异是合理的），但 `match(persistence)` + `try/catch` 外壳重复
- **建议**：模块内抽一个 `util/Collections.cj`（`containsString(Array<String>|ArrayList<String>, String)`）供 store 三处引用；`persist*` 合成 `persist(userId, kind, action: (KindPersistence, Int64, String) -> Unit)`，文案作为参数传入

### [轻微][存量] token 合并逻辑两处实现且语义有漂移（`?? 0.0` 会丢 0 权重 token、非正权重取不到最大值）

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:52-61`（`add` 内联）vs `f_llm/src/store/MemoryIndexRebuilder.cj:92-109`（`tokensOf`）；后者注释自称「与写入路径一致：标题 + 正文合并，同 token 取较大权重」
- **来源**：存量
- **判据**：review-checklist §2「近似重复：一块少了边界判断」
- **证据**：静态确定 —— `add` 用 `tokens.get(token) ?? 0.0f64` 后比大小，缺省值被当成 0：正文侧权重为 0 的 token 不会写入，标题侧已有权重为负时 `weight > 0.0` 恒假、无法取到较大值；`tokensOf` 用 `match` 区分 `Some/None`，`None` 分支无条件写入、`Some` 分支才比大小
- **描述**：同一记录走"写入"与走"重建"得到的 token 集合可能不同（0 权重 token 见/不见），sparse 候选集因此在重建前后不一致；BGE-M3 的权重通常为正值，所以影响面有限，属于行为漂移而非数据损坏
- **建议**：`SqlMemoryStore.add` 直接复用 `MemoryIndexRebuilder.tokensOf`（把它提到 `store` 包内的公共 util 或用 `Embedder` 上的默认方法），保证"写入 = 重建"；顺手把 `?? 0.0` 的缺省比较去掉

### [轻微][存量] `weightOf` 的 `experience` 分支与 `else` 返回同一个 0.8，是等价冗余分支

- **位置**：`f_llm/src/store/MemoryKinds.cj:189-194`
- **来源**：存量
- **判据**：review-checklist §1「恒真恒假分支 / 兼容残留」
- **证据**：静态确定 —— `else if (kind == EXPERIENCE || kind == EXPERIENCE_FAILED) { 0.8 }` 与末尾 `else { 0.8 }` 完全等价，`MemoryKinds_test.cj:157-161` 断言的也正是"两者都是 0.8"
- **描述**：注释说明了意图（"与纳入预定义前一致"），但代码上这支 `if` 不影响任何取值，读者会以为 `experience` 有特殊权重；未来若把兜底权重改成 0.5，这支分支会意外保留 0.8，形成"改了默认值却对某两类不生效"的陷阱
- **建议**：删掉该分支，把注释移到 `else` 上（"未登记 kind 与 experience 同权 0.8"）；若确实需要 experience 独立权重，则改成显式常量 `EXPERIENCE_WEIGHT` 并被测试引用。**注意（v1.1 复核）**：`f_llm/doc/spec/fix-memory-write-consistency/tasks.md:5` 明确要求「`weightOf` 显式返回 0.8」，所以这支分支是有规格依据的有意写法；本条只作「等价冗余」记录，删除前需先改规格，不宜直接当死代码清理

### [轻微][存量] 三处注释与实现漂移：预定义 kind 数量、废弃键数量、"回退 fhydra"

- **位置**：`f_llm/src/store/MemoryKinds.cj:22-25`（称「预定义 7 值」，实际 9 个，见 `:43-53`）；`f_llm/src/store/StoreSettings.cj:27-28`（注释列 3 个废弃键，`DEPRECATED_KEYS` 有 4 个，见 `:45`）；`f_llm/src/store/MemoryRepositories.cj:26`（「没有匹配时回退到 fhydra（尚未实现）」，实现是直接抛 `IllegalStateException`，见 `:82-86`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§13「文档过期」
- **证据**：静态确定 —— `predefined()` 返回 9 项（`note/fact/preference/task/doc/knowledge/session/experience/experience_failed`），`MemoryKinds_test.cj:78-82` 也断言 9；`DEPRECATED_KEYS` 字面量 4 项含 `llm_contentStore`；`defaultRepository()` 唯一语句是 `throw`
- **描述**：三处都是"读注释建立的心智模型与代码不一致"：以为 7 种 kind 时新增 kind 会漏改权重；以为废弃键只有 3 个时漏配 `llm_contentStore` 的迁移提示；以为有 fhydra 兜底时会配默认值然后撞上启动异常
- **建议**：注释改为「预定义 9 值」；废弃键清单改为与常量同源（`DEPRECATED_KEYS.size`），或在注释里逐个列全；`MemoryRepositories` 的类注释改成"无匹配直接抛错并提示可选项"

### [轻微][存量] 测试隔离不足：`StoreSettings_test.clearAll` 漏清 `llm_contentStore`；重建用例只复位 `onStart`，`userId`/`namespace` 残留

- **位置**：`f_llm/src/store/StoreSettings_test.cj:26-34`（clearAll 三项）与 `:77`（断言 `deprecated.size == 3`）；`f_llm/src/store/MemoryIndexRebuilder_test.cj:157-169`（只复位 `llm_rebuildIndexOnStart`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理 / 边界」、§2「测试里的准备代码」误报边界之外的真实缺陷（用例顺序依赖）
- **证据**：静态确定 —— `Config` 是进程级全局（`f_config`），`DEPRECATED_KEYS` 有 4 项而 `clearAll` 只 remove 3 项；重建用例设置了 `llm_rebuildIndexUserId=42` / `llm_rebuildIndexNamespace=global` 后不复位
- **描述**：任何前置用例（或并行用例）一旦设置 `llm_contentStore`，`testOldKeysAreDeprecatedNotApplied` 的 `size == 3` 会变成 4 而失败；反之本用例设置的 `llm_contentStore` 也会污染后续用例。重建用例残留的 userId/namespace 目前无害（其它用例不读），但同样是顺序依赖隐患
- **建议**：`clearAll` 改成遍历 `StoreSettings.DEPRECATED_KEYS` + 四个新键；重建用例用 `try/finally` 或 `@BeforeEach/@AfterEach` 恢复三项配置；顺手把 `DEPRECATED_KEYS` 提升为 `public`（测试需要）或提供 `StoreSettings.deprecatedKeys()` 访问器

### [轻微][存量] 可见性建议：`emptySkills()` 与 `resetForTest()` 是仓内零引用 / 仅测试用的对外 `public`

- **位置**：`f_llm/src/store/StoreModels.cj:162-165`（`public func emptySkills()`，注释「空实现辅助：让接口先能编译」）；`f_llm/src/store/MemoryKinds.cj:219-222`（`public static func resetForTest()`，注释「仅测试用」）
- **来源**：存量
- **判据**：review-checklist §1「仅测试使用 → 可提可见性建议，但不是死代码」；硬原则一（对外可达的 `public` 不判死代码）
- **证据**：静态确定 —— 全仓搜 `emptySkills` 仅定义处命中（含 `f_llm` 以外目录）；`resetForTest` 仅在 `MemoryKinds_test.cj:76-137` 与 `store/it/KindPersistence_test.cj:128,150` 命中
- **描述**：两者对外可见但仓内无使用：`emptySkills` 从名字与注释看是接口落地前的脚手架残留，`resetForTest` 是测试钩子却进了库的公开面。**按硬原则均不计死代码**，仅作为可见性建议记录，删除与否需用户确认下游无依赖
- **建议**：`emptySkills` 直接删（或降为 `internal`）；`resetForTest` 收窄为 `internal`，测试同包可直接访问（`MemoryKinds_test.cj` 与 `store/it` 都在 `fountain::f_llm.store` 包内）

### [轻微][存量] 文件命名与实现漂移：`PostgresMemoryStore.cj` 内是 PG/MySQL 共用的 `SqlMemoryStore`，仓内无同名类

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:23-30`（文件头注释与类声明）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 可维护性」、§11「语义与命名不符」
- **证据**：静态确定 —— 全仓搜 `class PostgresMemoryStore` 零命中；按名查找实现的人会找不到类，`@BeanMeta` 却同时匹配 `mysql` 与 `postgres`（`:28-29`）
- **描述**：文件与测试（`PostgresMemoryStore_test.cj` 内类名却是 `SqlMemoryStoreTest`）都留着重构前的名字，检索与导航成本高
- **建议**：文件重命名为 `SqlMemoryStore.cj`、测试重命名为 `SqlMemoryStore_test.cj`（纯改名，无逻辑变更）

### [轻微][存量] 测试文件硬编码数据库账号口令

- **位置**：`f_llm/src/store/MySqlConnectivity_test.cj:31`（`mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test`）
- **来源**：存量
- **判据**：review-checklist §10「安全性：硬编码凭据」
- **证据**：静态确定 —— URI 明文含用户名与口令，直接在源码中；仅测试用、仅本机库
- **描述**：口令进版本库后无法轮换（改口令要改代码），且会被密扫工具报出；对生产无直接影响，故定轻微
- **建议**：改读环境变量（`LLM_TEST_MYSQL_URL`）并提供 `.env.example`；缺变量时按上一条 SKIP 策略处理

### [轻微][存量] 两条用例断言打在测试替身而非生产实现上（`lastLimit`、`FakeEmbedder.tokenize`）

- **位置**：`f_llm/src/store/PostgresMemoryStore_test.cj:179-186`（断言 `repo.lastLimit == 4`）、`:304-308`（`FakeEmbedder().tokenize('ab cd')`）
- **来源**：存量
- **判据**：review-checklist §2「测试里的准备代码」之外的覆盖度问题、§14.1「半成品 / 只做了一半」
- **证据**：静态确定 —— `lastLimit` 只在 `FakeMemoryRepository.searchDense` 内赋值（`:87-90`），断言验证的是替身收到的参数，不是 `SqlMemoryStore` 的产出；`tokenize` 用例验证的是 `FakeEmbedder` 自己的实现，与生产 `HttpEmbedder`/`DefaultEmbedder` 无关
- **描述**："先取 2 倍候选"这条契约确实被这两条用例间接锁定（参数即契约），但 `tokenize` 一条纯属自测替身，零信息量，给覆盖率虚增
- **建议**：`lastLimit` 用例保留但注明"验证下推参数契约"；`tokenize` 用例删除或改为对真实嵌入器（可注入固定 `EmbeddingTransport`）的用例

### [轻微][存量] 结果排序在并列分时没有确定 tie-break，与"跨后端排序口径一致"的目标不一致

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:159-191`（选择排序，比较只用 `score` / `rerankScores`）；对照 `f_llm/src/store/KnowledgeSearch.cj:95-104`（`before` 明确用 `score → docId → seq` 兜底）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§2「同一件事两种口径」
- **证据**：静态确定（无 tie-break）＋ 后端返回序 待确认 —— 知识侧有三级排序键并注释「保证跨后端一致」；记忆侧 `better = scored[index].score > scored[best].score`，同分保留先出现者，而候选先后来自 `collect(dense, …)` / `collect(sparse, …)` 的仓库返回顺序
- **描述**：同分候选的最终顺序取决于 PG / MySQL / 内存各自的行序，`topK` 截断点落在同分组内时，不同后端返回的集合可能不同；知识侧刻意避免的问题在记忆侧仍存在
- **建议**：比较函数补 `id` 升序兜底（`if (score == other.score) { id < other.id }`），与 `KnowledgeSearch.before` 统一；补一条"全同分时按 id 升序"的用例

### [一般][存量] 开启 rerank 但候选都没有 colbert 向量时，最终 topK 退化为候选插入序，融合分与 kind 权重全部失效

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:121-124`（`rerankScores` 全置 0.0）、`:151-155`（`case None => 0.0`）、`:166-191`（pick 循环只比较 `rerankScores`）
- **来源**：存量（`git log -1 -- f_llm/src/store/PostgresMemoryStore.cj` → `2c8f1bbf8`，2026-11-07；工作区无 diff）
- **判据**：review-checklist §11「逻辑错误：排序不按分数」、§3「用 0 当哨兵吃掉缺失语义」
- **证据**：静态确定 —— pick 循环首次迭代 `best < 0` 必取 `scored[0]`，此后只有 `rerankScores[...] > rerankScores[best]` 才替换；当所有候选的 rerank 分都是 0.0 时没有任何候选能替换 `best`，输出顺序等于 `scored` 的插入顺序（= `ids` 顺序 = `collect(dense, …)` 的仓库返回序 + 仅 sparse 命中的 id，`:100-104`）
- **描述**：`repo.colbert()` 全部返回 `None` 是**常态而非例外**——`LlmEmbeddingTransport` 只回 dense（`f_llm/src/embedding/LlmEmbeddingTransport.cj:23-26` 自认「rerank 失效」），`add` 的 colbert 写入又允许失败（#5），`MemoryIndexRebuilder` 修的正是这个场景。此时把 `rerank` 打开，`topK` 结果按 dense 原始顺序给出：稀疏通路的 `0.3 × sparseScore`、`MemoryKinds.weightOf` 的 kind 权重、以及 #21 讨论的分差都不再影响排名；同一批数据 `rerank=false` 能正确排序，两个开关互相矛盾。`PostgresMemoryStore_test.cj:238-253` 只覆盖「向量存在」的路径，`testRerankOnlyQueriesTopCandidates`（`:258-270`）也没断言顺序
- **建议**：把「缺失」与「真实 0 分」分开（`HashMap<Int64, ?Float64>` 或额外的 `reranked: HashSet<Int64>`），pick 的比较键改成两级：`reranked ? rerankScore : 0.0`，且 `reranked` 为假时回退 `scored[i].score`；补一条「colbert 全缺失 + rerank=true 时结果与 rerank=false 同序」的用例

### [一般][存量] `maxSim` 把负相似度截成 0，`dot` 对维度不一致静默截断，重排分数「错而不报」

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:218-234`（`var best = 0.0f64`）、`:236-247`（`let size = if (left.size < right.size) left.size else right.size`）；维度放宽来源 `f_llm/src/store/ColbertCodec.cj:49-58`
- **来源**：存量（`2c8f1bbf8`）
- **判据**：review-checklist §11「边界 / 契约与实现不符」、§5「不可信输入的维度未校验」
- **证据**：静态确定（初值与截断机制）＋ 待确认（负点积是否真的出现，取决于 BGE-M3 colbert 向量是否归一化/含负分量）
- **描述**：`maxSim` 每行 `best` 从 `0.0` 起、仅 `score > best` 时更新，所有负点积被当成 0：对「query token 与 doc token 全为负相关」的候选，max-sim 被抬到 0，与「完全不相关」不可区分，`total / query.size` 整体偏大。`dot` 取两边较短长度，维度不一致时（换过向量模型、库里残留旧维度——`ColbertCodec.decode` 明确「维度不是 1024 也允许，按剩余字节推断」，`ColbertCodec.cj:49-58`）静默只算前 min(dim) 维，不报错也不记日志，只表现为重排顺序莫名变化
- **建议**：`best` 初始化成第一个 `dot` 结果（或 `-Float64.inf`）；`dot` 在 `left.size != right.size` 时抛 `IllegalArgumentException`（或返回 `None` 让 `maxSim` 跳过并 `warn` 一次）；`upsertColbert` 写入前校验维度与模型一致

### [轻微][存量] `rebuild` 单条失败即中断整批、无进度与失败计数；offset 分页窗口在并发写入下会漏记录

- **位置**：`f_llm/src/store/MemoryIndexRebuilder.cj:72-89`；分页实现 `f_llm/src/dao/postgres/MemoryDAO.cj:156-161`（`ORDER BY save_time DESC LIMIT/OFFSET`）
- **来源**：存量（`git log -1` → `112790669`，2026-10-31）
- **判据**：review-checklist §11「错误处理、进度可观测」、§5「分页稳定性」
- **证据**：静态确定（中断与分页机制）＋ 待确认（重建是否与在线写入并发，取决于部署窗口）
- **描述**：页内任一 `embedColbert`/`upsertSparse` 抛错（向量服务超时最常见）会让整个重建抛出：已重建的部分保留、`rebuilt` 计数丢失，日志里只有成功时的一条 `info`（`:54`），失败时没有「处理到第几条」的痕迹，重启只能从 `offset=0` 重来（幂等但成本翻倍）。分页按 `save_time DESC` 偏移：重建期间若有新记忆写入（`save_time` 更新、排在最前），offset 窗口整体后移会跳过一批旧记录；`save_time` 相同的记录之间没有二级排序键，跨页边界可能重复或遗漏
- **建议**：页内改逐条 `try/catch` 累计 `failed`，结束时 `warn('... rebuilt=${rebuilt}, failed=${failed}')`；分页改用 `id > lastId ORDER BY id` 的游标（仓储补一个 `listAfter`），最小改动是 `ORDER BY save_time DESC, id DESC` 消除同时间戳歧义

### [轻微][存量] `KnowledgeSearch.rank` 选择插入排序的依据写着「候选通常 ≤ 200」，调用方实际上限是 1000（合并后可达 2000）

- **位置**：`f_llm/src/store/KnowledgeSearch.cj:70-93`（注释在 `:74`）；规模来源 `f_llm/src/store/postgres/KnowledgeStore.cj:34-58`（`maxCandidates` 默认 1000、`pageSize` 200）、`:170-178`（`denseK` 与 lexical 两路合并）
- **来源**：存量（`git log -1` → `16ee79ddb`，2026-10-31）
- **判据**：review-checklist §6.4「低效算法：O(n²) 的规模前提不成立」、§13「注释与调用方不一致」
- **证据**：静态确定（复杂度与上限）；实际耗时未测，只在「待验证假设」给测量方案，不当热点
- **描述**：`hits` 来自 dense 与 lexical 的并集，两路上限各 1000，最坏约 2000 条；插入排序 `O(n²)` 约 2×10⁶ 次 `before()` 比较，仍在毫秒级，所以不改也不算缺陷——但注释给出的「≤ 200」与实际差一个数量级，会让后续维护者误判成本，也会误导「候选会被截到 200」的判断（`§6.4` 自检、`§5` 的规模估算都引用过这个数字）
- **建议**：注释改成真实上限（n ≤ 2 × `maxCandidates`）；若要消平方项，改成「一次 `sort`（`score desc, docId asc, seq asc`）+ 取前 limit」，等价性用 `KnowledgeChunker_test.cj:100-115` 的排序断言覆盖

### [轻微][存量] `PredefinedCharacters` 的 key 名单与正文 `match` 是两份需手工同步的字面量

- **位置**：`f_llm/src/store/PredefinedCharacters.cj:54-83`（12 个 `case` + `_ => ''`）与 `:85-91`（13 个 key，含 `default`）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制：同一张表的两个副本」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `keyList()` 第 1 个 `'default'`（正文约定为空）与其余 12 个 key 和 `bodyOf` 的 12 个 `case` 一一对应；`keys()` / `isKnown()` / `bodyOf()` 分别遍历/匹配这两份列表
- **描述**：当前 13/12 是一致的，不是缺陷；风险在演进：新增人格只加 `keyList` 不加 `case` 时，`isKnown()` 返回 `true`（能写入）而 `bodyOf()` 返回空串，按 `:50-52` 的约定静默回落成「没有系统提示词」，不报错；只加 `case` 不加 `keyList` 则无法写入。现有用例（`FStoreMetaStore_test.cj:84-85`）只查数量与 `isKnown()`，穷举不到这个空档。另外 `keys()` 目前只有测试引用（`FStoreMetaStore_test.cj:84-85`），属测试驱动的公开入口，不算死代码
- **建议**：把正文表做成常量 `HashMap<String, String>`，`keys()`/`isKnown()`/`bodyOf()` 查同一张表（`default` 显式映射空串）；或保留双列表并加用例 `for (key in keys()) { if (key != 'default') @Expect(bodyOf(key).isEmpty(), false) }`

## 优化可行性方案

> 本部分**没有** bench / profile / 分配量基线数据（`scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`，不含本模块实测），因此按取证要求不列具体方案与收益，候选全部落到「待验证假设」。堆内存 / CPU 方案数记 0 / 0。
> v1.1 复核又识别出两个候选（`search` 的两轮选择排序合并、重建的批量大小取舍），同样无改前基线，写入假设 6 / 7，不在此处列收益（容器合并的候选已由假设 1 覆盖）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单次 `search` 的临时容器（`denseScores`/`sparseScores`/`records`/`ids`/`rerankScores`/`used` 共 6 个 Map/List）在 `topK=5`、候选 10~20 时占自耗时与分配量可观比例 | `f_llm/src/store/PostgresMemoryStore.cj:97-164` | 每次检索的分配字节数、GC 次数占比 | `cjprof heap` 跑 10k 次同参数检索；对照"复用外部传入 buffer"版本 |
| 2 | `MemoryKinds.predefined()` 每次调用新建 9 元素 `ArrayList`，被 `validate`/`all` 在写路径调用时放大 | `f_llm/src/store/MemoryKinds.cj:80-92`、`:95-106`、`:197-205` | 调用频次与单次分配 | 埋点统计 `validate` 每秒调用数；`cjprof` 看 `ArrayList` 分配栈 |
| 3 | `add` 每条记忆 4 次远程向量化（title/content 各一次 embed + 各一次 embedColbert），HTTP 场景下写延迟主要由这 4 次往返决定 | `f_llm/src/store/PostgresMemoryStore.cj:47-49`、`:64-65` | 端到端写延迟分布、4 次调用各自耗时 | 分段计时打点，跑 1k 次写入，取 P50/P95；对照批量接口（一次传 title+content） |
| 4 | 重建为逐条 upsert（每条 2 次向量化 + 2 次 DB 写），百万级记忆的全量扫描耗时与 DB 压力构成运维风险 | `f_llm/src/store/MemoryIndexRebuilder.cj:74-89` | 每页耗时、总时长、连接占用 | 在 10 万条数据集上跑 `rebuild(batchSize=100)`，记录每页耗时中位数与 DB 侧 QPS |
| 5 | `KnowledgeSearch.occurrences` 对每个 term 做一次 `indexOf` 扫描，长文档 × 多 term 时是知识检索的 CPU 主项 | `f_llm/src/store/KnowledgeSearch.cj:43-68` | 单文档长度分布、每查询扫描字节数、自耗时占比 | `cjprof record` 跑 1k 次 `knowledge.search`，输入 20 篇 × 4KB；对照"单趟多词匹配"实现 |
| 6 | `SqlMemoryStore.search` 的两轮选择排序（rerank 取前 bound + 最终取 topK）在 topK=50/100 时约 `O(topK²)` 次比较，可能成为单次检索的 CPU 主项 | `f_llm/src/store/PostgresMemoryStore.cj:134-191` | `topK` 分布、自耗时占比、与 DB 往返的比值 | `cjprof record` 跑 1k 次 `search`（候选 2×topK，topK=5/20/100 三档），对比「一次 sort + 截断」实现，`-O2` 中位数与 P95 |
| 7 | `rebuild` 的 `batchSize=100` 与「每条 2 次 `embedColbert` + 2 次 DB 写」的串行模式决定全量重建耗时，分批大小可能有最优区间 | `f_llm/src/store/MemoryIndexRebuilder.cj:74-89` | 每页耗时中位数、向量服务 QPS 上限、峰值 RSS | 对 1 万条记忆跑 `batchSize` = 50/100/500 三组，记录总耗时、每页耗时分布、进程峰值 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/store/KnowledgeSearch.cj` | .cj | ✅ | 见 #8（切词）、#12（contains 重复）、#21（tie-break 对照）、#25（排序规模前提） |
| 2 | `f_llm/src/store/MemoryIndexRebuilder.cj` | .cj | ✅ | 见 #2（未接线）、#3（空索引覆盖）、#13（token 合并漂移）、#24（失败中断/分页窗口） |
| 3 | `f_llm/src/store/MemoryIndexRebuilder_test.cj` | .cj | ✅ | 见 #16（配置未复位）；其余断言与实现一致 |
| 4 | `f_llm/src/store/MemoryKinds.cj` | .cj | ✅ | 见 #6（并发）、#10（validate 未接线）、#12/#14/#15/#17 |
| 5 | `f_llm/src/store/MemoryKinds_test.cj` | .cj | ✅ | 与实现一致（9 种 kind、权重 0.8 均对上） |
| 6 | `f_llm/src/store/MemoryRepositories.cj` | .cj | ✅ | 见 #1（缺 listByKind 转发）、#11、#15 |
| 7 | `f_llm/src/store/MemoryRepository.cj` | .cj | ✅ | 接口与默认实现；见 #1、#3 |
| 8 | `f_llm/src/store/MemoryStoreAdapter.cj` | .cj | ✅ | 转发齐全（含 `listByKind`）；漏读根因在 #1 的上游 |
| 9 | `f_llm/src/store/MetaStoreAdapter.cj` | .cj | ✅ | 分支显式、不静默降级；见 #11（字面量） |
| 10 | `f_llm/src/store/MySqlConnectivity_test.cj` | .cj | ✅ | 见 #9（SKIP 与注释相反）、#19（硬编码凭据） |
| 11 | `f_llm/src/store/PostgresMemoryStore.cj` | .cj | ✅ | 见 #1（search 的 kind 后过滤）、#3/#4/#5/#7/#13/#21、#22（rerank 退化）、#23（maxSim/dot）、#18（文件名） |
| 12 | `f_llm/src/store/PostgresMemoryStore_test.cj` | .cj | ✅ | 覆盖较全；见 #20（替身断言）、#22（缺 colbert 全缺失用例） |
| 13 | `f_llm/src/store/PredefinedCharacters.cj` | .cj | ✅ | 13 key / 12 正文当前一致；见 #26（双表维护风险） |
| 14 | `f_llm/src/store/RetrievalScoring.cj` | .cj | ✅ | 常量与 `StoreContracts.cj:74-80` 文档口径一致；无重复实现残留 |
| 15 | `f_llm/src/store/RetrievalScoring_test.cj` | .cj | ✅ | 锁定常量，无问题 |
| 16 | `f_llm/src/store/StoreConformance_test.cj` | .cj | ✅ | 只覆盖内存实现，与类名"Conformance"不符（未单列，轻微观察） |
| 17 | `f_llm/src/store/StoreContracts.cj` | .cj | ✅ | 见 #1（默认 `listByKind`） |
| 18 | `f_llm/src/store/StoreModels.cj` | .cj | ✅ | 见 #4（degraded 契约）、#7（无 topK 校验）、#8（按空白切词契约）、#17（emptySkills） |
| 19 | `f_llm/src/store/StoreSettings.cj` | .cj | ✅ | 见 #11（默认值字面量）、#15（废弃键注释）、#16 |
| 20 | `f_llm/src/store/StoreSettings_test.cj` | .cj | ✅ | 见 #16（clearAll 漏键） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单无 `.md`，`README*` 与 `doc/**` 仅在别部分审查，本报告只把它们当承诺源引用）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1/#3/#4/#5/#7/#10/#22/#23；设计 #1（默认实现被继承）、#5（三段写入无事务）；语言特性 #4（`degraded` 用单 bool 表达两态）、`String.size` 按字节用法已核（`core_package_structs.html`「UTF-8 编码后的字节长度」），`MemoryKinds.check` 的字节遍历与 `occurrences` 的字节偏移均正确；可读性 #15/#18/#25/#26；安全性 #19 |
| §1 死代码 | 1 | 逐个 private 符号（`KnowledgeSearch.before/contains`、`MemoryKinds.check/contains/persistInsert/persistDelete`、`MemoryIndexRebuilder.tokensOf`、`PostgresMemoryStore.permitted/containsName/maxSim/dot/collect/normalize`、`MemoryRepositories.defaultRepository`、`PredefinedCharacters.keyList`、`MetaStoreAdapter` 成员）全仓搜均有调用者；`protected` 本部分 0 个；`public` 全部对外可达（顶层 `public class` / `public func`），按硬原则一不判，但 #17/#26 记了 3 个无引用/仅测试的可见性建议（`emptySkills`、`resetForTest`、`PredefinedCharacters.keys`）；`internal` 0 个；无 `return/throw` 后死语句、无未用 import。唯一计入的是 #14（等价冗余分支，且已注明规格依据） |
| §2 重复逻辑 | 4 | #11（实现名字面量 4 处）、#12（contains 4 份 + persist* 同构）、#13（token 合并 2 处且已漂移）、#26（人格 key 与正文双表）；另核对 `MemoryStore.listByKind` 与 `MemoryRepository.listByKind` 两份默认实现逐行相同（已并入 #1，不重复计数）；`PostgresMemoryStore` 的两处选择排序（rerank 取前 bound、最终取 topK）语义不同（键不同、目标不同），不判重复；`normalize`/权重常量已收口成 `RetrievalScoring` 单份（`grep "func normalize"` 仅一处） |
| §3 空实现 | 1 | #5（`catch (_: Exception) {}` 完全静默）；`StoreModels.emptySkills` 是返回空列表的脚手架，计入 #17（可见性建议）；无 `TODO`/`FIXME`/`UnsupportedException`（13 个生产文件搜零命中；`MemoryIndexRebuilder_test.cj:81-83` 的 `UnsupportedException` 是测试替身里"不该被调用"的守卫，属正常写法）；`case None => ()` 出现在可选分支（`attach`/`register`/`all`）语义正确 |
| §4 栈溢出 | 0 | 本部分 0 个递归函数（`contains`/`maxSim`/`dot`/`normalize`/选择排序全为循环）；无自引用结构遍历；`PredefinedCharacters.bodyOf` 是平铺 `match` |
| §5 OOM | 1 | #7（用户可控 `topK` 无上界 → 全量候选物化，无拒绝路径）；`rebuild` 分页取数、`search` 候选有 2×topK 关系，均无"按报文头预分配"；`KnowledgeSearch.rank` 复制一份候选，上限是 `maxCandidates`（规模前提见 #25） |
| §6.1 热点瓶颈 | 0 | 无本模块 profile / bench 数据；所有性能猜测进「待验证假设」表的 7 条，未作为发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁（0 个 `synchronized`/`Mutex`/原子类型），并发问题只有 #6 的"无锁" |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池；`add` 的 4 次串行远程调用是延迟问题，进假设 3 |
| §6.4 低效算法 | 1 | #25（`rank` 插入排序的规模前提写着 ≤200，实际可达 2000——按复杂度与上限判为「注释依据不成立」，耗时仍未测）；`PostgresMemoryStore` 选择排序（n ≤ 2×topK）与 `occurrences` 的 `indexOf` 扫描有规模上界或属于假设 5/6，无占比数据不定为低效 |
| §7 降堆内存方案 | 0 | 无 `getAllocatedHeapSize`/RSS 基线，按取证要求不列方案（候选见假设 1） |
| §8 降 CPU 方案 | 0 | 无 `cjpm bench -O2` 对照，不列方案（候选见假设 1/2/5/6） |
| §9 local mode 可行性 | 0 | 本部分函数内无"函数内创建、函数内用完"的大临时对象：`terms`/`rank`/`normalize` 的产物都作为返回值逃逸，`maxSim`/`dot` 只做标量累加；`search` 的 `records`/`scores` 也跨方法返回（`ArrayList<MemoryHit>`）——无逃逸候选即无收益可证 |
| §11 现有代码的 BUG（存量） | 11 | #1、#3、#4、#5、#7、#8、#9、#10、#22、#23、#24 均为本轮读到的既有逻辑/边界/契约缺陷；`StoreSettings.load()` 的 `??` 默认值、`MetaStoreAdapter` 三分支、`PredefinedCharacters` 空串回落、`RetrievalScoring` 数学、`normalize` 除零保护、`rank` 边界（`limit<=0` → 空）逐条核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | #6（静态可变注册表无同步）；`SqlMemoryStore` 成员全为 `let`（线程安全前提取决于 repo/embedder）、适配器无状态、`StoreSettings` 不可变、重建工具纯静态无共享写；锁粒度无对象可评（0 锁） |
| §13 文档一致性 | 2 | 本部分 0 个 `.md`；以模块 README/doc 作承诺源核对出 #2（启动重建）与 #4（degraded 语义）；另 #15 是代码注释漂移、#25 是注释里的规模前提错误。`RetrievalScoring` 常量与 `StoreContracts.cj:74-80`、`doc/f_llm.md:309` 三处口径一致；`PredefinedCharacters` 当前 13 key 与 12 正文一致（双表风险记 #26） |
| §14 功能完备性与 README 覆盖 | 2 | #2（重建未接线）、#10（kind 校验未接线）；`StoreSettings` 四个新键与默认值均在 README 配置表中可查（README.md:760-772） |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个 `.cj` 全部逐行读完，无未读文件；本部分无 `.md` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 14 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 统计口径：#1–#26（v1.1 合并后连续编号），其中 #1 含 `list`/`search` 两条同源路径，按一条计。

## 总评

本部分是两个"装配层"文件的组合：`store/` 的契约与模型（`StoreContracts` / `StoreModels` / `RetrievalScoring` / `PredefinedCharacters`）质量不错——打分公式收口成唯一来源且有测试锁定，接口注释把"谁负责打分、谁负责过滤"写得很清楚；问题集中在**装配是否把契约落实**这一层，且都是存量：

- 两个阻塞项都属"承诺了但没接线"：#1 适配器漏转发 `listByKind`，让 `kind` 过滤在生产路径退化成近似实现（静默少读）；#2 启动重建入口零调用者，`llm_rebuildIndexOnStart` 是彻底无效配置。两者都不会报错，只表现为"结果不对/功能没生效"，排查成本高，建议优先修。
- 次一级是写入侧的一致性：#3（空索引覆盖）与 #5（三段写入非原子 + 静默 catch）会留下"有记录无索引"的永久脏数据；#4 的 `degraded` 既是误报源又没有消费点，观测价值接近于零。
- 检索结果的可解释性是第二组风险：#22（rerank 全缺失时退化成插入序）与 #23（`maxSim` 负值截断 / 维度静默截断）都会让"同一批数据、同一份配置"给出难以复现的顺序差异，且都不抛错；配合 #1 的 kind 后过滤与 #21 的并列分无 tie-break，"检索质量"目前无法从代码或日志上自证。
- 并发面很窄：整部分只有 `MemoryKinds` 一个进程级可变注册表（#6），当前无生产并发调用者，属潜伏问题；`SqlMemoryStore` 无状态、适配器与重建工具纯静态，不存在锁粒度问题。
- 14 条轻微项主要是字面量复制（实现名、`contains`、token 合并、人格双表）与注释/命名漂移，可排期清理；`weightOf` 的等价分支（有规格依据）、`emptySkills`/`resetForTest`/`keys()` 的可见性建议适合顺手处理；#24 指出了重建工具的「不可断点续跑 + offset 窗口漂移」，运维前建议先补日志再跑大库。
- 性能面本轮**没有任何测量数据**，7 条候选全部只在「待验证假设」里，未写成结论、也不应进 `tasks.md`。

存量缺陷共 26 条（严重 2 / 一般 10 / 轻微 14），是否纳入修复待用户决定。

# R6: 性能与内存（热路径 / 无界增长 / 复杂度）

审查时间：2026-11-06 11:57

### 审查范围

- `src/store/PostgresMemoryStore.cj`、`src/store/InMemoryStores.cj`、`src/store/postgres/KnowledgeStore.cj`、`src/store/hydra/ContentStore.cj`、`src/store/KnowledgeSearch.cj`
- `src/loom/SkillCatalog.cj`、`src/loom/LoomRunner.cj`、`src/loom/LoomContextLog.cj`、`src/loom/LoomStoreGateway.cj`、`src/loom/LoomMemoryPolicy.cj`、`src/loom/LoomHostApi.cj`、`src/loom/LoomWiring.cj`、`src/loom/StoreFunctions.cj`、`src/loom/EvolutionStores.cj`、`src/loom/Supervisor.cj`
- `src/store/Stores.cj`、`src/store/StoreSettings.cj`、`src/store/EvolutionStore.cj`、`src/channel/ChannelMediator.cj`、`src/wiring/StoreWiring.cj`
- 规模假设：单流程 5~50 步；技能 30~80 条（正文 1~3KB）；记忆/知识块数 1e3~1e5；并发流程 1~数十。

### 发现

#### [严重] `loomStore(...)` 每次调用都重建整条存储链路（开本地库 / 新建传输）

- **位置**：`src/loom/LoomWiring.cj:72-74` → `src/loom/LoomStoreGateway.cj:60-65` → `src/store/hydra/ContentStore.cj:34-38` / `src/loom/EvolutionStores.cj:41-43` / `src/store/EvolutionStore.cj:175-177` / `src/store/Stores.cj:68-97` / `src/store/StoreSettings.cj:63-78`
- **描述**：`installStore` 的闭包是 `LoomStoreGateway().call(...)`，即**每个 `loomStore` 调用新建一个网关**。网关默认构造做四件事：
  1. `Stores.content()` → `StoreSettings.load()`（1 次配置读 + ArrayList + 4 个废弃键查找 + 可能 `log.warn`）→ 工厂 `{ => HydraContentStore() }` → **`InProcessTransport(FStoreVectorStore('./data/f_hydra'))` 打开一次本地向量库** + `requireEmbedder()` bean 查找；
  2. `Stores.meta()` → **第 2 次 `StoreSettings.load()`** + `FStoreMetaStore(DeployPaths.resolve(...))` 新建/开库；
  3. `EvolutionStores.current()` → **第 3 次 `StoreSettings.load()`** + `Store(path)` 打开一个 KV；
  4. 再叠加 `.knowledge` / `.memory` 惰性构造：新 `HydraKnowledgeStore` / `SqlMemoryStore`（`lookup<Embedder>()`、`MemoryRepositoryAdapter()`），**上一个实例的缓存全部作废**。
  `MemoryCallFunction.target()`（`src/loom/StoreFunctions.cj:74-79`）、`KnowledgeIngestFunction.target()`（`:130-135`）同样是每次调用构造网关。
- **量化**：一次 store 操作 = 3 次配置读 + 2~3 次打开本地库/传输 + 3~5 个对象构造；10 步流程里 5 个 store 步骤 → 15 次配置读 + ~12 次开库；并发 N 流程 → O(N·steps) 次开库，连接/索引完全无法复用（fhydra 走 HTTP 时是每次新建 `HttpTransport()`）。**真实热点，且随并发线性恶化**。
- **建议**：在 `LoomWiring.wire()` 里构造一次网关并让闭包捕获（`{ k, o, p => gateway.call(k, o, p) }`）；`StoreSettings.load()` 结果按文档承诺「配置只读一次」缓存到启动期（当前每次重读并重复 warn）。

#### [一般] `HydraKnowledgeStore.search` 每个候选一次 `transport.get`（N+1），再 O(n²) 排序

- **位置**：`src/store/hydra/ContentStore.cj:158-191`（循环 `:174-189`）、`src/store/KnowledgeSearch.cj:71-93`
- **描述**：dense 200 + sparse 200 候选合并后，对**每个 id 单独 `transport.get(KB, id)` 取正文**，并 `id.split('#')`；随后 `KnowledgeSearch.rank` 用插入排序。
- **量化**：单次 `knowledge.search` ≈ 最多 400 次 KV 点查 + 400 次 split；rank 为 O(n²) = 1.6e5 次比较（含 `docId` 字符串比较）。对比 PG 实现一次 SQL 拿全量，这是**真实热点**（长尾最重的一处）。
- **建议**：候选先按分数截断到 `limit*2~3` 再取正文（懒加载）；或让 transport 提供批量 `getMany(ids)`。

#### [一般] `PostgresKnowledgeStore.search` 词面召回最多 5 页 ×200 行，候选与正文全量驻留内存

- **位置**：`src/store/postgres/KnowledgeStore.cj:123-153`、`:200-202`、`:155-161`、`:175-179`
- **描述**：`maxCandidates=1000`、`pageSize=200` → 最多 5 次 DB roundtrip；每行 `textOf(content)` 全量取回（≈0.5KB）存进 `ChunkScore`；`scoreKey` 每行新建一个 `docId#seq` 字符串；dense 侧 `denseK=limit*20`（上限 1000）。最后 `rank` 对 ≤1000 条插入排序。
- **量化**：一次搜索 ≈ 5 次 SQL + ~0.5MB 临时内存 + 1000 次字符串分配 + 5e5 次比较。**中等热点**（毫秒~十毫秒级），在 `loomStore("knowledge","search")` 每步调用时会累积。
- **建议**：`maxCandidates` 默认降到 `pageSize`（200）量级，或把排序/截断下推到 SQL；`scoreKey` 可改为 `(docId, seq)` 复合键或复用已持有对象，避免字符串拼接。

#### [一般] `LoomHostApi.render` 每次模板替换都全表扫描 `values`，且在全局锁内做字符串拷贝（O(steps²)）

- **位置**：`src/loom/LoomHostApi.cj:69-87`，调用点 `src/loom/LoomCompiler.cj:108,117`、`src/loom/CodeGen.cj:114,118`
- **描述**：第 i 步渲染时 `values` 已有 i-1 条，逐条 `text.replace('{id.output}', value)`；每个 replace 都要扫一遍整串并新建两个字符串（needle 也是现拼的）。整个过程在 `mutex` 内完成。
- **量化**：n 步累计 Σ(i-1) ≈ n²/2 次替换；n=50、模板 1KB → ~1225 次 replace ≈ 数 MB 临时分配 + 数万次字符扫描。`AsyncFlow` 并发分支会被这个锁串行化（渲染期间 `callTool/callStore/callLlm` 全部阻塞）。**步骤数 ≥20 时是真实热点**。
- **建议**：改为**单遍扫描模板占位符**（遇 `{` 找 `}` 后查 map），复杂度 O(len) 与步骤数无关；`values` 抽快照出锁后再渲染。

#### [一般] `SkillCatalog.search`：每次重列技能全集、关键词路径 O(runes×len×skills)、并发重复 embed、失败不熔断

- **位置**：`src/loom/SkillCatalog.cj:148`（`skillsOf()` `:188-199`）、`:262-303`（关键词）、`:306-324`（`runeScore`）、`:231-246`（向量缓存）、`:165`（失败仅计数）
- **描述与量化**：
  - `skillsOf()` 每次 search 都 `make().list()` → `Stores.meta()` → `StoreSettings.load()` + `FStoreMetaStore(...)`，**连关键词路径也要开一次元数据 KV**（与 R6-1 同源）。
  - 关键词路径：每技能一次 `'${title} ${details}'.toAsciiLower()`（1~3KB 拷贝），`needle.split(' ')` 写在技能循环内（`:271`，应外提），`runeScore` 对每个唯一字符调 `haystack.contains(rune.toString())`（`:316`，每字符一次 1~3KB 扫描）→ 50 技能 × 2KB × 20 唯一字 ≈ **2e6 次字符比较/次搜索**。属于「装了 embedder 但编码失败」时的降级路径，**真实热点但概率中等**。
  - 向量路径：缓存粒度 `标题#版本`（`:233`）合理、命中即返回；但 `readVector` 与 `tryEncode` 不在同一临界区（`:234-243`），并发流程会对同一技能重复 embed；`tryEncode` 失败后**每次都重试**（`:165`，无负缓存/熔断），若 embedder 超时为 5s，单次 search 会被 50 个技能打满 → 上百秒。**这条按「真实风险」计**。
- **建议**：`split` / `toAsciiLower` 提到循环外；`runeScore` 用 `HashSet<Rune>` 或一次性 `count` 取代逐字 `contains`；embed 失败加短期负缓存（如 30s）+ 单飞锁（同一 key 只允许一个线程 embed）。

#### [一般] `LoomContextLog.turns` 单次执行内无条数上限，且每轮冗余存 `fullSystem`

- **位置**：`src/loom/LoomContextLog.cj:66-72`（只 `add`，无上限）、`:51-53`（进程级静态 ArrayList）、`src/loom/LoomHostApi.cj:138`（每轮存 `fullSystem`）、`src/loom/LoomMemoryPolicy.cj:172-191`（`maxTurns` 只在提炼阶段生效）
- **描述**：`record()` 无 `policy.maxTurns` 约束；`fullSystem` 已含 persona + 技能块（可 3~10KB），同一流程里每轮几乎相同却完整复制一份。
- **量化**：常规流程 3~20 次交互 × ~5KB = 15~100KB，**可接受**；失控长流程（JIT loop / 上百步）100 turn × 10KB = 1MB 常驻，且 `mode=enabled` 时直到流程结束才 `clear()`。**定「一般」：有界但边界由流程长度决定，缺少硬上限**。
- **建议**：`record` 时用环形缓冲（保留最近 `maxTurns` 条）或只存 `system` 的引用/散列；`snapshot()+clear()`（`LoomRunner.cj:221-222`）合并为一个原子 `takeSnapshot()`，避免两次加锁之间的并发窗口。

#### [一般] `SqlMemoryStore.search` 的 rerank 分支：每候选一次 `repo.colbert()`

- **位置**：`src/store/PostgresMemoryStore.cj:123-133`（`:126`）、`:135-167`、`:194-210`
- **描述**：`rerank=true` 时对 `scored` 中每个候选单独查一次 colbert 多头向量（N+1），再逐个 `maxSim`；选择排序内层在 rerank 模式下每次比较做 2 次 HashMap 查找（`:152-153`）。
- **量化**：候选 ≤ 4·topK（topK=10 → 40）→ **40 次额外 IO**；`maxSim` 32×32×128 ≈ 1.3e5 乘加/命中 × 40 ≈ 5e6，毫秒级。选择排序本身 400 次迭代，可忽略。**真实但可接受**，成本主要在 N+1 IO。
- **建议**：`repo.colbert` 提供批量 `colbert(ids)`；rerank 前先把 `scored` 截到 `topK*2`。

#### [一般] loom 执行期的进程级静态态（`values` / `turns` / `persona` / `skills`）在并发流程间互相串台

- **位置**：`src/loom/LoomHostApi.cj:43-45,50-55,57-62,147-188`、`src/loom/LoomContextLog.cj:58-63`
- **描述**：`bind()` / `begin()` 会**清空对方的 `values` / `turns`**；`setPersona/setSkills` 同理。类注释（`LoomHostApi.cj:29-30`）已声明「单线程使用」，但 `LoomRunner.runAsync`、`BackgroundTasks`、Supervisor 派发与直接 `run()` 是不同入口，没有互斥保护。
- **量化**：并发 2 流程时模板替换会取到错误/空值（功能失效），并造成 `values`/`turns` 反复重建（内存抖动）。属于「静态态无界/共享」类问题，成本不体现在 CPU 而在正确性与分配抖动。
- **建议**：把 `values`/`turns`/`persona`/`skills` 收进「一次执行的上下文对象」，随 `runCompiled` 传递（或 `ThreadLocal` 语义），静态入口只保留对当前上下文的引用。

#### [轻微] `runCompiled` 每次重复计算拓扑序/后继/入度，Kahn 用 `remove(at: 0)`

- **位置**：`src/loom/LoomRunner.cj:125` 与 `:138`（`run` 算过的 `order` 在 `runCompiled` 又算一遍）、`:139-155`（每次执行重建 `successorsOf/indegreesOf/bodies/producing`）、`:508-546`（`:528` `ready.remove(at: 0)` → 每次 O(n) 位移）
- **量化**：V+E 数十~上百 → O(V²) ≈ 1e4 次位移/次执行，微秒级；`runCompiled` 已复用编译好的 step 闭包（`LoomAgent.cj:130`），编译不是热点。**可忽略**，但 plan 不可变，`successors/indegree/bodies` 本可缓存到 `LoomAgent`。

#### [轻微] JSON 手工 `+=` 拼接（循环内字符串累积）

- **位置**：`src/loom/LoomStoreGateway.cj:101-111,139-148,165-180,201-210,373-388,401-412`；`src/loom/LoomRunner.cj:462`；`src/loom/LoomMemoryPolicy.cj:173-190`；`src/loom/Supervisor.cj:243-245`
- **描述**：仓颉 String 不可变，循环内 `text += ...` 为 O(n²) 字节拷贝。
- **量化**：`memory.search`/`knowledge.search` 默认 limit=5 → 单次 ≤ 几 KB，**可忽略**；但 `memory.list`、`knowledge.docIds`、`skill.list`、`evolution.list` 若调用方传 limit=200~1000，则退化为 0.1~1MB 级重复拷贝，此时不应忽略。`digestOf`/`routerPrompt` 的 n 受 `maxTurns`(20)/流程数(数十) 约束，可忽略。
- **建议**：统一用 `StringBuilder`（或先 collect 元素再一次性 join），至少给 `list/docIds/evolution.list` 这类开放 limit 的出口加长度上限。

#### [轻微] 静态缓存/表的增长边界

- **位置**：`src/loom/SkillCatalog.cj:51`（`vectors` 仅 `install/reset` 清空，`:65,73`）、`src/loom/LoomMemoryPolicy.cj:140-151` + `:126-131`（`seq` 递增生成 `loom:<flow>:<seq>` docId）、`src/channel/ChannelMediator.cj:37,104-131`、`src/loom/Supervisor.cj:79,343-353`
- **描述与量化**：
  - `SkillCatalog.vectors`：key 为 `标题#版本`，版本不断 bump 时旧向量永不淘汰（每条约 dim×8B ≈ 8KB）→ 百个废弃版本 ≈ 0.8MB，**轻微**，建议加 LRU/条数上限。
  - `writeKnowledge=true` 时每次流程新增一篇知识文档、无保留策略 → 知识库随运行次数**线性增长**（真实增长点，属数据而非内存）。建议按 flow 名覆盖写或加 TTL。
  - `ChannelMediator.instances` / providers 受 `llm_channels` 配置约束；`platforms()/accounts()` 内 `result.contains` 线性去重 O(n²)，账号数十 → **可忽略**。
  - `Supervisor.table` 受流程数约束；`routable()` 每次派发整表复制、`register` 线性查重、`unregister` `remove(at:)` O(n)：数十流程 → **可忽略**。

#### [轻微] `InMemoryStores` 全表扫描（仅测试用）

- **位置**：`src/store/InMemoryStores.cj:130-155`（先收集全部 `hits` 再截断，多一次拷贝）、`:212-252`（全体 chunk 扫描 + `rank` 插入排序）、`:254-276`（`docIds` 每次全量 + 插入排序 O(D²)，分页循环调用时为 O(D²·页数)）
- **描述**：内存实现定位是「单测与本地演示」，不参与生产；但 `docIds` 若在测试里做分页遍历，D=1000 时 5e5~1e6 次比较仍可见。**可忽略（测试域）**，若要留在测试链路，`docIds` 可一次性排序缓存。

#### 已验证为「可忽略」的项（不需改）

- `PostgresMemoryStore.search` 两路归一化各一次、无重复 normalize/embedding（`:91,95,100-101`）；选择排序 O(topK×4·topK) 在 topK≤10 时 400 次迭代。
- `JoinBarrier.release`（`LoomRunner.cj:78-96`）为 HashMap 查找 + 计数，每步 O(1)。
- `MemoryKinds.weightOf`（`MemoryKinds.cj:176-188`）为纯比较，每候选一次不构成热点。
- `LoomHostApi.callLlm` 的 persona/skills 前缀拼接（`:123-133`）每次新建 1~2 个字符串，与 LLM 网络耗时相比可忽略（但可缓存前缀）。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 4 |

### 总评

本轮热路径的整体设计是**清醒的**：记忆融合的两路归一化没有重复计算、技能向量有 `标题#版本` 缓存、loom 执行复用已编译闭包（`runCompiled`）、`JoinBarrier`/`indegree` 都是 O(1)/O(V+E)。真正的问题集中在一个反模式上——**`LoomStoreGateway()` 被当作廉价值对象在每次 store 调用处新建**，而它的构造函数会读 3 次配置、打开本地向量库与 KV、并作废子 store 的缓存；这一条把「零配置装配」的便利变成了每步开库的固定开销，是本轮唯一需要优先修的严重项（改法很小：闭包持有单例）。其次是三处 N+1/全量候选：`HydraKnowledgeStore.search` 的逐候选 `get`、`SqlMemoryStore` rerank 的逐候选 `colbert`、`PostgresKnowledgeStore` 的 1000 候选翻页，以及 `LoomHostApi.render` 的 O(steps²) 全表替换（且在全局锁内）。无界增长方面没有发现真正的泄漏：`turns`/`values` 每次执行重置，静态表受配置/流程数约束，仅 `SkillCatalog.vectors` 缺淘汰、`writeKnowledge` 缺保留策略属温和的长期增长。手工 JSON `+=` 拼接在默认 limit 下可忽略，但出口 limit 开放，建议统一改 `StringBuilder` 并加长度上限。

REVIEW_WRITTEN:R6
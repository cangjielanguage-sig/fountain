# f_llm 模块审查报告

> **模块第 20/25 部分**（本报告只覆盖 `files/f_llm.part20.txt` 列出的 20 个文件：`service/StoreMetaConfSource*` 与 `store/` 下的 `ColbertCodec` / `DeployPaths` / `Evolution*` / `FStoreMetaStore` / `InMemoryStores` / `KnowledgeChunker*` / `KnowledgeIndexRebuilder*`。其余 348 个 `.cj` 与 112 个 `.md` 由其他子轮产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个 `.cj`：10 个实现 + 10 个测试；本部分无 `.md`）
- **基线**：工作区快照（`sts/1.3.x` 工作区，无 diff 可比 ⇒ 全部问题记「存量（快照模式无基线）」）
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 20/25 部分）

## 发现

### [严重][存量] #1 同一个 `llm_metaStorePath` 被 4 个 store 类各自 `Store(path)` 打开，而 f_store 每次构造都会删掉目录下全部 WAL —— 未 flush 的写入静默丢失

- **位置**：
  - `f_llm/src/store/FStoreMetaStore.cj:41`、`:51`（`Store(path)`）
  - `f_llm/src/store/EvolutionStateStore.cj:193`、`:198`
  - `f_llm/src/store/EvolutionStore.cj:171`、`:176`
  - `f_llm/src/store/EvolutionLease.cj:180`、`:185`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称 / 数据丢失」、§12.1「跨线程资源」「共享可变状态无保护」
- **证据**：静态确定 —— 三处事实叠加：
  1. 四个类的两个 `init` 都执行 `Store(DeployPaths.resolve(StoreSettings.load().metaStorePath))`（或同路径的 `Store(path)`），即**同一个目录被 4 个独立 Store 实例打开**；`f_store` 的 `Store` 没有任何按路径的单例注册（`f_store/src/Store.cj:36-94` 全是实例字段，无 `static`）。
  2. `Store.init` 在恢复完 MemTable 后调用 `cleanupOldWALFiles(walDir)`（`f_store/src/Store.cj:76-77`），该函数把目录下**所有** `.wal` 文件 `remove` 掉（`f_store/src/store_func.cj:216-229`，`catch (_: Exception) {}` 连失败都吞掉）。于是**每构造一个 Store，就把同目录里其他存活实例正在写的 WAL 文件删掉**；被删实例的后续 `add` 只落在自己的 MemTable 与已 unlink 的文件里。
  3. 构造频率不是"一次"：`Stores.meta(name)` / `Stores.content(name)` 每次都 `factory()`（`f_llm/src/store/Stores.cj:76`、`:92`，无缓存），而 `LoomWiring.cj:128` 把它包成 `{=> Stores.meta().skills}` 交给 `SkillCatalog.install`，`SkillCatalog` 每次检索都 `make().list()`（`f_llm/src/loom/SkillCatalog.cj:188-199`）；`EvolutionStores.current()` / `EvolutionLeases.current()` / `EvolutionStateStores.current()`（`EvolutionStores.cj:41-43`）同样是"每次新建"。
- **描述**：持有路径（长期强引用 → 目标对象）：`BeanFactory` 单例（`@Bean` 默认 `BeanScope.singleton`，见 `f_bean/src/BeanMeta.cj:26`）→ `LoomStoreGateway.meta`（`LoomStoreGateway.cj:70-71`）→ `FStoreMetaStore` → `Store` → `Compactor` 的 `spawn` 线程（`f_store/src/Compaction.cj:42`）+ WAL/SSTable 文件句柄。这些 `FStore*` 类都没有实现 `Resource`/`close()`，即使 `Store` 本身是 `Resource`（`f_store/src/Store.cj:23`）。
  后果分两层：①**数据丢失**——A 实例写 prompt/skill/character（走 `LoomStoreGateway` 的工具调用），期间任意一次 `SkillCatalog` 检索构造出 B 实例，B 构造时删掉 A 的 WAL；A 之后写入的记录只在 A 的 MemTable 里，A 一重启就消失。②**资源泄漏**——每次构造新增一个 compactor 线程 + 一个 `atExit` 钩子 + 1~2 个 WAL 文件，`SkillCatalog` 在主链路上按请求创建，线程与句柄随请求数线性增长。
- **建议**：`llm_metaStorePath` 只允许一个 `Store` 实例：在 `f_llm` 内加"路径 → Store"的引用计数缓存（例如 `FStoreHandle`：`static` map + `Mutex` + 引用计数，全模块共用），四个 `FStore*` 改为注入该共享实例；或者把 `FStoreMetaStore` / `EvolutionStore` / `EvolutionStateStore` / `EvolutionLease` 统一挂在同一个 `FStoreFamily` 门面下（一次 `Store(path)`，四个子 store 共用）。同时把 `Stores.meta()` / `Stores.content()` 的工厂改成长缓存（构造一次），并在 `FStore*` 上实现 `Resource.close()`。f_store 侧建议把 `cleanupOldWALFiles` 改成"只清理已成功回放的 WAL 且加目录锁"，避免多实例互相删文件。

### [严重][存量] #2 `InMemoryMemoryStore` 是 `@Bean` 单例，`HashMap` + `seq` 完全无同步

- **位置**：`f_llm/src/store/InMemoryStores.cj:83-95`（`@Bean` 与字段：`86-87`；`add` 的 `seq++` 与 `records[record.id] = record`：`90-93`）、`109-120`（`remove` 的检查-然后-删除）、`122-169`（`list` / `search` 遍历 `records`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」「迭代与修改并发」
- **证据**：静态确定 —— 该类带 `@Bean` + `@BeanMeta[condition: ConfCond.Value('llm_memoryStore', StringCond.Exactly('inMemory'))]`（`83-84`），`f_bean` 默认 `scope = BeanScope.singleton`（`f_bean/src/BeanMeta.cj:26`），即**全进程一个实例**；`MemoryStoreAdapter` 在匹配到该 bean 时直接把它当 `MemoryStore` 用（`f_llm/src/store/MemoryStoreAdapter.cj:33-40`），HTTP / 工具调用是多线程并发。类内没有任何 `Mutex` / `synchronized` / 原子量：`seq++` 是非原子的读-改-写，`records` 是非线程安全 `HashMap`，`list` / `search` 一边 `for ((_, record) in records)` 遍历，另一线程可以 `records[...] = ...` / `records.remove(id)`。
- **描述**：在 `llm_memoryStore=inMemory` 下（`StoreWiring.cj:60` 注册了 `inMemory` 内容族；bean 路径由 `MemoryStoreAdapter` 直接取本类，非 bean 路径下 `InMemoryContentStore.memory` 也是本类，见 `InMemoryStores.cj:29-35`），两个并发 `add` 可能拿到同一个 `seq` → 后者覆盖前者（丢一条记忆）；并发 `add` 与 `list` 可能让遍历看到半更新的 map（仓颉 `HashMap` 无并发保证）。类注释（`23-27`）只声明"只用于单测与本地演示"，没有声明"非线程安全"，而它确实被注册成了可选后端。
- **建议**：与同模块 `InMemoryEvolutionStore` / `InMemoryEvolutionStateStore` 的写法对齐（`private let mutex = Mutex()` + 用 `Box` 把返回值带出 `synchronized`，见 `EvolutionStore.cj:74-116`）；`search` 里先 `synchronized` 拷出快照再算分，避免锁内做 `contains`。若确定只做单线程演示，则从 `StoreWiring` 摘掉 `inMemory` 或在类注释与 README 明写"非线程安全、仅供单线程演示"。

### [严重][存量] #3 `ColbertCodec.decode` 用数据里的 `count` 决定循环次数与分配，无上限 —— 损坏/恶意 blob 可让进程 OOM

- **位置**：`f_llm/src/store/ColbertCodec.cj:47-71`（`count` 取自前 4 字节：`51`；本应做校验的分支是空块：`52-54`；`dims` 由除法反推：`55`；循环：`58-69`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」「无界容器」、§11「错误处理缺失 / 边界」
- **证据**：静态确定 —— `count = Int64(readInt32(bytes, 0))` 是 `Int32` 范围（最大 2 147 483 647），`dims = (bytes.size - 4) / count / 4`。当 blob 只有几字节而 `count` 很大时 `dims == 0`，于是 `for (_ in 0..count)` 执行 2^31 次，每次 `Array<Float64>(0)` + `vectors.add(...)`：`ArrayList` 至少要存 2^31 个引用（约 17 GB），必然 `OutOfMemoryError` 或长时间占满一个线程；字节数够大时则按 `count × dims` 真实分配，同样没有上限。`encode` 侧也没有校验"所有向量等长"，`bytes` 按 `vectors[0].size` 开（`30-31`），ragged 输入在写入时越界抛 `IndexOutOfBoundsException`，错误信息不指向真实原因。
- **描述**：`decode` 的唯一输入是 `MemoryRepository` 从库里读出的 `title/content` 向量列（`f_llm/src/store/postgres/MemoryRepository.cj:91`、`mysql/MemoryRepository.cj:95`）。只要这条路径上出现一个被截断或被改写的 blob（迁移、手工修数、别的写入方），读库请求就变成进程级 OOM/挂死，而不是一条可定位的解析错误。`52-54` 的空 `if` 说明作者本来打算做维度校验，但分支体是空的（见 #14）。
- **建议**：解码前做三段校验，失败抛明确异常（或在契约里返回 `?`）：`count in 0..MAX_CHUNKS`、`bytes.size >= 4 + count * 4`、`(bytes.size - 4) % (count * 4) == 0` 且 `dims in 1..MAX_DIM`（维度上限用常量，例如 4096）；`encode` 校验所有向量等长并给带下标的错误消息。上限常量写进类注释与 README，避免"到 OOM 才知道"。

### [一般][存量] #4 租约的时间戳被截断到 65.5 s 粒度，每天前 66 秒内"当天已领取"可能判成"昨天"

- **位置**：`f_llm/src/store/EvolutionLease.cj:65-72`（`high48` 与 `millis = high48 << 16`）、`:88-95`（`dayOf`）、`:152-164` 与 `:211-225`（两处 `acquire` 用 `dayOf(...) == now / 86400` 判同日）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 语义与注释不符」
- **证据**：静态确定 —— `TimeUuid.create()` 走 `UUID.unixTimeBased()`（`f_util/src/uuid.cj:392-409`），该函数把毫秒时间戳写成 `UInt8((millis >> (7 - i) * 8) & 0xff)`（`i = 0..5`），即写入的是 `millis >> 16` 的 48 位；`timestampOf` 的 `high48 << 16` 正好补回，**低 16 位（65 536 ms）永久丢失**。于是解码值 = `floor(millis / 65536) × 65536`，最多比真实时间早 65.535 s。`86400000 % 65536 = 23552`，即每天零点相对 65536 ms 网格的整体偏移量；UTC 零点后的前 ~66 s 内，"真实属于今天"的租约值有约一半概率解成**昨天**（取决于截断余数与当天偏移）：`dayOf(value) != now / 86400` → `acquire` 认为"今天还没人领"，再写一个新值并返回 → 当天第二轮演进被放行。
- **描述**：类注释（`99-106`）承诺"多进程环境下保证同一天只有一个进程真正跑演进任务"，`69-70` 更明确写"≤66s 误差——对「按天判重」足够，取整后不会跨天漂移"，但取整恰好发生在天界，**在 0:00:00–0:01:06 UTC 这个窗口内互斥失效**：多进程（或同一进程的两次 `acquire`）都会拿到租约，`SkillEvolutionJob.schedule` 的 `allowed` 分支（`f_llm/src/loom/SkillEvolutionJob.cj:391-400`）就会各跑一遍。同一 `dayOf` 还被 `store/hydra`、`postgres`、`mysql` 三个租约实现共用（`f_llm/src/store/hydra/EvolutionLease.cj:84`、`it/EvolutionStoreIT_test.cj:103`），影响面不限于 f_store。
- **建议**：租约值不要依赖"截断精度刚好够用"，改为把"天序号"直接编码进值（例如 `value = '${now / 86400}:${uuid}'`，读侧只比第一个字段），或改用 `UUID.timestampNanos` 之外的整秒编码（`now.toString() + ':' + uuid`）。若坚持复用 UUID，至少把 `dayOf` 改成"用 `timestampOf` 的半天边界做 ±120 s 容差后取整"，并补用例覆盖"跨天前后 66 s"这个窗口。

### [一般][存量] #5 `EvolutionLease` 契约写"按旧值 CAS 覆盖"，实现只有进程内 `Mutex` + 无条件覆盖写

- **位置**：接口与注释 `f_llm/src/store/EvolutionLease.cj:98-123`（`:101` "读当前值 → …按旧值做 CAS 覆盖"、`:99` "多进程环境下保证"）；实现 `:211-225`（`FStoreEvolutionLease.acquire`）、`:152-164`（`InMemoryEvolutionLease.acquire`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「检查-然后-写入」
- **证据**：静态确定 —— `acquire` 的实现是 `synchronized(mutex) { let previous = read(); if (同日) { () } else { store.add(KEY, created) } }`：`Mutex` 是**实例字段**（`:177`），只串行化同一实例内的线程；写入是 `store.add`（覆盖写，`f_store/src/Store.cj:97-107`），没有 compare-and-set，也没有任何跨进程锁（`f_store` 本身没有 CAS 原语）。同一文件的注释 `167-172` 自己也承认"单进程场景……跨进程共用一个 f_store 目录的情况不在支持范围内"，与接口 `99` 行"多进程环境下保证"直接矛盾。
- **描述**：`SkillEvolutionJob` 只拿到 `?EvolutionLease` 并调 `acquire(now)`（`SkillEvolutionJob.cj:391-394`），调用方无法从类型上看出"跨进程不互斥"。容器多副本部署（两个进程挂同一 `llm_metaStorePath`）时，两边都会抢到租约、各跑一轮演进，与注释承诺相反；而 #1 说明这个目录本来就可能被多个实例打开。
- **建议**：二选一并写进文档：①真做跨进程（f_store 增加 `addIfAbsent` / `replaceIfEquals` 语义，`acquire` 用它实现 CAS，失败即返回空串）；②把接口注释改成"仅进程内互斥，跨进程需外部锁"，并把 `acquire` 的返回值语义（空串 = 未领到）写进 README。不要在 `99` 行保留"多进程保证"这种无法兑现的措辞。

### [一般][存量] #6 `FStoreMetaStore` 家族完全无同步，而实例被 `LoomStoreGateway` 跨线程共享：`prompts.remove` 的 latest 重算、`conf.put` 的 `nextId` 都是检查-然后-写入

- **位置**：`f_llm/src/store/FStoreMetaStore.cj:92-99`（`put`：`nextId()` + 两次 `store.add`）、`:163-170`（`nextId`：读 `SEQ` → +1 → 写回）、`:327-351`（`remove`：删主体后扫前缀重算 `latest`）、`:246-251`（`upsert`：主体 + title 索引两次写）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「检查-然后-写入」「共享可变状态无保护」
- **证据**：静态确定 —— 这四个类（`FStoreLLMConfStore` / `FStoreCharacterStore` / `FStoreSkillStore` / `FStorePromptStore`）没有任何 `Mutex`/`synchronized`，而同模块 `FStoreEvolutionStore`（`EvolutionStore.cj:167`）、`FStoreEvolutionStateStore`（`EvolutionStateStore.cj:190`）、`FStoreEvolutionLease`（`EvolutionLease.cj:177`）都加了锁 —— 同一份存储三种同步策略。共享路径明确：`LoomStoreGateway` 在构造时把 `meta` 存成字段（`f_llm/src/loom/LoomStoreGateway.cj:70-71`），随后 `skills.upsert` / `prompts.put` / `prompts.remove` / `characters.set` 都在工具调用里执行（`LoomStoreGateway.cj:216`、`:308`、`:317`、`:330`、`:334`），工具调用来自并发的对话请求。
- **描述**：`prompts.remove` 是典型检查-然后-写入：先删版本键，再 `prefix` 扫剩余版本重算 `latest` 指针；两个并发 `remove`（或 `remove` 与 `put`）交错时，`latest` 可能指向已被删除的版本，或把刚 `put` 的新版本指针覆盖回旧值 → `latest(name)` 返回 `None`／旧版本。`conf.put` 的 `nextId` 并发时两边读到同一个 `SEQ` → 同一个 id → 后写覆盖前写（配置丢失）。虽然 `confs.put` 目前没有生产调用点（只有 `FStoreMetaStore_test.cj:147`），`prompts` / `skills` / `characters` 的写路径是活的。
- **建议**：给 `FStoreMetaStore` 加一把实例级 `Mutex`（与 Evolution 系列一致），把 `nextId`、`latest` 重算、`upsert` 的双写包进同一个临界区；更好的做法是把"id 分配"下沉到 `f_store` 的原子自增（`Store` 已有 `AtomicInt64 sequence`）而不是读-改-写一个普通键。`prompts.remove` 建议改成"先算新 latest、再删主体"（与接口注释 `StoreContracts.cj:106` 的说法一致），把两次写放在同一临界区。

### [一般][存量] #7 `LLMConfStore.put` 契约写"新增/覆盖"，两个实现都只追加 —— 重复 `put` 同一条配置会产出重复候选

- **位置**：接口 `f_llm/src/store/StoreContracts.cj:115-116`（"新增/覆盖一条配置"）；实现 `FStoreMetaStore.cj:92-99`（`nextId()` 永远 +1，不查已有 provider/llmName）、`InMemoryStores.cj:415-418`（`views.add(view); Int64(views.size)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复导致的行为漂移」（两个实现同错）
- **证据**：静态确定 —— `put` 的 id 来源分别是"`SEQ` 键 + 1"和"`views.size`"，两者都不做"按 (provider, llmName, actualLlmName) 查找既有记录并覆盖"。`candidates(llmName)` 只按 `BYNAME` 前缀返回（`FStoreMetaStore.cj:121-140`），不做去重；`names()` 用 `has()` 去重（`112`），所以表现是"名字只出现一次、候选却有多条"。
- **描述**：`StoreMetaConfSource.load()`（`service/StoreMetaConfSource.cj:42-63`）按 `names()` × `candidates()` 展开，重复 `put` 会让同一模型出现多行 `LLMConf`（id 递增、weight 相同），权重选择/熔断会把同一个端点当成多条候选。运营侧"改一条配置的权重"这种最自然的操作在当前实现下只能新增一条，旧记录永远留在候选池里。
- **建议**：`put` 改为按 (provider, llmName, actualLlmName) 唯一：先扫 `BYNAME{llmName}:` 找到同名记录，命中则用同一 id 覆盖主体（并清掉改名后的旧索引），未命中才 `nextId()`；`candidates` 里按 id 去重。若"覆盖"不是本意，就把接口注释改成"新增（同一条重复 put 会产生多个候选）"，并把这条写进 README。

### [一般][存量] #8 `InMemoryEvolutionStore.bySkill` 只扫最新 1000 条，老记录静默查不到（与 FStore 实现语义不一致）

- **位置**：`f_llm/src/store/EvolutionStore.cj:118-129`（`for (entry in list(0, 1000))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 静默丢数据」、§2「两实现语义漂移」
- **证据**：静态确定 —— `list(0, 1000)` 先按 `at` 倒序取前 1000 条，再在其中按 `skillTitle` 过滤并截断到 `limit`。条目总数 > 1000 时，某技能的历史记录只要不在最新 1000 条内就完全不出现；而 `FStoreEvolutionStore.bySkill`（`:223-238`）走 `IDX` 前缀索引，扫的是该技能的全部记录，语义是"这个技能最近的 N 条"。
- **描述**：`1000` 是硬编码且未写进注释。`SkillEvolutionLedger.history(store, skillTitle, ...)`（`f_llm/src/loom/SkillEvolutionLedger.cj:57`）在内存后端下对"老技能"会返回空或残缺，测试（`EvolutionStore_test.cj:48`，只有 3 条）覆盖不到。
- **建议**：内存实现也维护 `HashMap<String, ArrayList<EvolutionEntry>>` 的按技能索引（或至少在 `bySkill` 里遍历全部 `entries` 而不是 `list(0,1000)`）；若确实要上限，把常量提成参数并在接口注释写明"只回看最近 N 条"。

### [一般][存量] #9 持久化字段用 `Int64.parse` / `Float64.parse` 直读，一条脏记录就会让整表读取抛异常

- **位置**：`f_llm/src/store/FStoreMetaStore.cj:180`（`Float64.parse(parts[7])`）、`:182`（`Int64.parse(parts[3])`）、`:271`（`Int64.parse(segments[3])`）、`:293`（`Int64.parse(parts[3])`）、`:321`（`Int64.parse` 读 latest 指针）、`:340`（`Int64.parse(segments[4])`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 失败路径当成功」、§3「静默吞异常」的反面（这里是从"静默"跳到"整表不可用"）
- **证据**：静态确定（不一致性）—— 同一模块的 `FStoreEvolutionStateStore.readState` / `readRun`（`EvolutionStateStore.cj:282`、`:290`）对同类文本用 `Int64.tryParse(...) ?? 0` 兜底，而 `FStoreLLMConfStore.parse` / `FStoreSkillStore.list` / `FStorePromptStore.latest` 全部用会失败的 `parse`。`parse` 对非法文本的确切失败语义（抛 `IllegalArgumentException` 还是别的）未在仓内文档核对，属 `待确认`；但无论哪种，它与同文件另一处的兜底策略不一致这一点是确定的。
- **描述**：`parse` 的调用者是 `names()` / `candidates()` / `list()` / `latest()` 的循环体 —— 一条 `weight` 或 `version` 字段损坏的记录会让**整次** `names()`/`list()` 中断，`LLMConfs.createHolder` 的 `try { StoreMetaConfSource(...) } catch { 走旧来源 }`（`f_llm/src/llm/LLMConfs.cj:52-57`）会把整个模型配置降级到旧来源，现场表现是"配置明明在库里，服务却用了另一套"。
- **建议**：统一改成 `tryParse` + 默认值 + `LoggerFactory.getLogger<...>().warn('skip corrupt record ${key}')`；对可确定是结构损坏的记录（段数不足）沿用现在的"返回默认视图"不如直接跳过并告警。补一条用例：写入一条 `weight` 非数字的记录，断言 `candidates` 跳过它而不是抛异常。

### [一般][存量] #10 `DeployPaths.root()` 依赖 `getCommand()` 的 argv[0]：裸命令名启动时退化成 CWD，`canonicalize` 失败也没有兜底

- **位置**：`f_llm/src/store/DeployPaths.cj:30-42`（`canonicalize(Path(getCommand()).parent)`、`path.fileName == 'bin'`）、`:45-60`（`resolve`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「惰性初始化」（`cached` 无同步，见覆盖自检）
- **证据**：静态确定 + 待确认 —— 静态：`root()` 只有一条推导路径，没有失败分支；`canonicalize` 对不存在/不可规范化的路径抛 `FSException`（同仓 `docs/review/2026-11-28/f_cmd.md:31-38` 已就同一 API 记录过这一点），`root()` 不捕获，异常直接冒到 `resolve()` 的调用者（`FStoreMetaStore.cj:50`、`FStoreEvolutionStateStore.cj:198` 等构造期）。待确认：`env.getCommand()` 在"以裸命令名（经 PATH 解析）启动"时返回绝对路径还是 argv[0] 原样；若返回 `argv[0]`，`Path('app').parent` 是 `'.'`，`canonicalize('.')` 就是**进程 CWD**，与类注释 `24-25` "存储路径一律相对部署目录，而不是进程 CWD"相反。
- **描述**：该类的全部价值就是这个推导；一旦落到"argv[0] 是裸名"或"二进制不在 `bin/` 下"，`llm_metaStorePath = './data/f_llm-meta'`（`StoreSettings.cj:41` 默认值）就会写到 CWD 下，systemd/容器里通常是 `/` 或只读目录，表现为启动时 f_store 建目录失败或数据写到意外位置 —— 正是注释里说要避免的场景。`resolve` 另外只识别 `'/'` 前缀，Windows 盘符路径（`C:\...`）会被当相对路径拼接。
- **建议**：优先用 `env.getCommandLine()[0]`（`f_config/README.md:49` 明确这是"程序自身路径"）并做一次 `canonicalize`；失败时回退到 `Path(getCommand()).parent` 的绝对化结果，再失败才退回 CWD，并把回退原因 `warn` 出来。`resolve` 增加 `Path.isAbsolute()` 判定而不是只比 `'/'`。

### [一般][存量] #11 `InMemoryKnowledgeStore` 删除/覆盖文档时不清 `vectors` —— 块向量永久残留

- **位置**：`f_llm/src/store/InMemoryStores.cj:197-210`（`upsert` 只写 `vectors[chunkKey(docId, seq)]`）、`:216-224`（`remove` 只删 `chunks` / `docs`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称」、§7「缩短生命周期 / 注册表不注销」
- **证据**：静态确定 —— `vectors` 的键是 `'${docId}#${seq}'`（`:291-293`），`remove(docId)` 没有任何 `vectors` 相关语句；`upsert` 在块数变少时也不会删掉 `seq >= 新块数` 的旧键。而 `KnowledgeStore.remove` 的契约是"删除正文与全部块"（`StoreContracts.cj:73`）。
- **描述**：装了 `Embedder` 时每条块向量是 `Array<Float64>`（1024 维 ≈ 8 KB + 头），`remove` 后这些向量仍被 `vectors` 强引用 → 泄漏；`upsert` 缩短文档时同样留下"孤儿向量"。因为 `search` 只遍历 `chunks` 里的块，孤儿向量不会被读到，所以表现为"删了文档但内存不降"，而非错误结果 —— 这正是 `mem §1` 那类"GC 后 RSS 不回落"的现场。
- **建议**：`remove` 里按 `chunks.get(docId)` 的块数逐个 `vectors.remove(chunkKey(docId, i))`；`upsert` 覆盖前先清该 docId 的旧向量（或改为 `HashMap<String, ArrayList<Array<Float64>>>` 与 `chunks` 同生命周期）。类注释里补一句"向量与块同生共死"。

### [一般][存量] #12 `InMemoryCharacterStore.set` 不校验 `characterKey`，与 `FStoreCharacterStore.set` 行为相反

- **位置**：`f_llm/src/store/InMemoryStores.cj:303-305`（直接写 map）对照 `f_llm/src/store/FStoreMetaStore.cj:219-225`（`PredefinedCharacters.isKnown` 不通过就抛 `IllegalArgumentException`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「近似重复 / 行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `CharacterStore.set` 的接口注释（`StoreContracts.cj:85-90`）没有写"校验预定义 key"，但两个实现对同一输入给出不同结果：FStore 抛异常、内存实现接受任意串。测试也只覆盖了 FStore 侧（`FStoreMetaStore_test.cj:91-100`）。
- **描述**：内存后端（`InMemoryMetaStore`，单测与本地演示用）会接受 `characterKey = 'not-exist'`，随后 `LoomRunner` 取 `PredefinedCharacters.bodyOf(key)` 拿不到人格体，落到默认分支（`f_llm/src/loom/LoomRunner.cj:410-415`）—— 表现是"人格静默不生效"，而在生产后端同样输入会直接报错。跨后端一致性测试（`store/it/MetaConformance_test.cj`）没有覆盖这条分支。
- **建议**：把校验上移到 `CharacterStore` 的公共入口（或 `Character` 的构造/`set` 前置检查），两个实现共用；内存实现也抛 `IllegalArgumentException`，并给 `MetaConformance_test` 补一条"未知 key 在两个后端都拒绝"的用例。

### [轻微][存量] #13 §2 重复逻辑：两处手写插入排序、三处线性 `contains`、四处 4 字节小端拼装

- **位置**：
  - 插入排序：`f_llm/src/store/EvolutionStore.cj:98-106`（按 `at`/`id` 倒序）与 `f_llm/src/store/InMemoryStores.cj:273-281`（按 `docId` 字典序）
  - 线性包含：`f_llm/src/store/FStoreMetaStore.cj:186-193`（`has`）、`f_llm/src/store/InMemoryStores.cj:420-427`（`InMemoryLLMConfStore.contains`）、`f_llm/src/store/InMemoryStores.cj:430-437`（`containsText`）
  - 4 字节小端：`f_llm/src/store/ColbertCodec.cj:36-40`（写 float 内联）、`:61-64`（读 float 内联）、`:73-79`（`writeInt32`）、`:81-87`（`readInt32`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定 —— 三组代码逐行对齐，差异只有元素类型与比较函数。
- **描述**：插入排序那份还同时是低效算法与锁内长临界区：`InMemoryEvolutionStore.list` 在 `synchronized(mutex)` 内对**全量**条目做 O(n²) 排序（`EvolutionStore.cj:92-114`），条目上千后每次 `list` 都持锁做平方级工作，`bySkill`（`:120`）还会再调一次。三份 `contains` 语义完全相同（线性查找字符串），任何一处改成 `HashSet` 都不会同步到另两处。`ColbertCodec` 的四个 4 字节小端片段里，`encode`/`decode` 的向量循环没有复用 `writeInt32`/`readInt32`，字节序一旦要改（例如加 magic 或改成大端）必须改四处。
- **建议**：排序抽成模块内 `internal func sortBy<T>(items: ArrayList<T>, less: (T, T) -> Bool)`（或直接用 `std.sort`），并让 `InMemoryEvolutionStore` 在锁内只做"拷贝 + 粗排索引"，排序移到锁外；三份 `contains` 合并为 `InMemoryStores.cj:430` 的 `containsText(Array<String>, String)` 一个实现（`ArrayList<String>` 传 `toArray()` 的代价大于收益时，改成泛型 `Iterable<String>`）；`ColbertCodec` 加 `writeFloat32`/`readFloat32` 两个私有函数，让 encode/decode 循环只调它们。

### [轻微][存量] #14 §1 死代码：`ColbertCodec.decode` 的空 `if` 分支（无语句、无副作用）

- **位置**：`f_llm/src/store/ColbertCodec.cj:52-54`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒真恒假分支 / 无作用语句」
- **证据**：静态确定 —— 分支体只有注释（"维度不是 1024 也允许，按剩余字节推断"），没有任何语句；条件表达式本身也没有赋值或调用，整个 `if` 可删而对行为零影响。
- **描述**：它标记的是"本该在这里做维度/长度校验"的位置（见 #3），留着会让人以为校验已经存在。
- **建议**：按 #3 的建议把校验补上；若决定不做校验，直接删掉这个 `if` 并把"维度由字节数反推"写进函数注释。

### [轻微][存量] #15 §1 未使用的 `import`（5 处）

- **位置**：`f_llm/src/store/EvolutionLease.cj:19`（`import std.convert.*`）、`f_llm/src/store/FStoreMetaStore.cj:21-22`（`import fountain::f_bean.*` + `fountain::f_bean.macros.*`）、`f_llm/src/store/EvolutionLease_test.cj:18`、`EvolutionStateStore_test.cj:18`、`EvolutionStore_test.cj:18`（三处 `import std.collection.*`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `EvolutionLease.cj` 全文无 `parse` / `tryParse` / 任何 `std.convert` 符号（`String.fromUtf8` 属核心库，同仓 `f_llm/src/loom/Plan.cj` 未 import `std.convert` 也在用）；`FStoreMetaStore.cj` 无 `@Bean` / `lookupOption` / `ConfCond`；三个测试文件里没有 `ArrayList` / `HashMap` / `StringBuilder` 等集合类型（`Array` 是核心类型）。
- **描述**：`std.convert` 在多处是"顺手带上"，容易掩盖真正的依赖；`FStoreMetaStore` 的 `f_bean` 依赖更会误导读者以为该类是通过 bean 容器装配的（实际由 `StoreWiring` / `MetaStoreAdapter` 直接 `new`）。
- **建议**：删除这 5 行 import（仓颉编译器对未使用 import 的告警在 `cjpm` 默认配置下不阻断，所以一直没被清理）。

### [轻微][存量] #16 注释与实现不符（3 处，均会误导维护者）

- **位置**：
  - `f_llm/src/store/EvolutionLease.cj:34`（"生成时间型 UUID（f_util 的 v6：重排后的 v1）"）→ 实际是 **v7**（`f_util/src/uuid.cj:378-409`，version nibble 写 `7 << 4`）
  - `f_llm/src/store/EvolutionLease.cj:42-43`（"v7 的高 48 位就是毫秒时间戳，直接按十六进制解析前 12 个字符"）与 `:69-70`（"右移了 16 位……解码时补回来"）**互相矛盾**，实现取的是后者
  - `f_llm/src/store/InMemoryStores.cj:24`（"不注册进 `Stores`（§5.3）"）→ `StoreWiring.cj:60` 明确 `ensure('inMemory', { => InMemoryContentStore() })`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 规格与实现漂移」（本条针对 `.cj` 内的契约性注释）
- **证据**：静态确定 —— 上述三处均可用"注释描述的版本号/位移/注册关系"与对应代码行直接对照。
- **描述**：第一条和第二条共同掩盖了 #4 的精度问题（读者会以为"直接解析毫秒"所以很准）；第三条会让人误判内存后端在生产不可达（进而低估 #2 的影响）。
- **建议**：把 `create()` 的注释改成 "v7（RFC 9562 时间型 UUID）"，删掉 `42-43` 的"直接解析"表述、统一到 `69-70` 的位移说明并补上"低 16 位被截断 ⇒ 精度 65.5 s"；`InMemoryStores` 的头注释改成"只用于单测与本地演示；`inMemory` 内容族已在 `StoreWiring` 注册，非线程安全"。

### [轻微][存量] #17 `FStoreEvolutionStore` 的显式 id 路径：`nextId` 不与库内最大 id 对齐，后续自增 id 可能覆盖既有记录

- **位置**：`f_llm/src/store/EvolutionStore.cj:179-202`（`if (id <= 0) { if (nextId <= 0) nextId = maxId(); … } else if (id > nextId) { nextId = id }`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 数据覆盖」
- **证据**：静态确定 —— 新实例 `nextId == 0`；若第一次 `save` 带显式正 id（例如 `id = 3`），走 `else if (id > nextId)` 分支只把 `nextId` 置为 3，**不会**调用 `maxId()`；随后自增写入得到 `id = 4`，而库里可能已经存在 id 4（上一次进程写入），`store.add(DATA4, …)` 直接覆盖（同时新增一条指向同一 data key 的索引）。仓内所有调用点都传 `id = 0`（`SkillEvolutionLedger.cj:70`、各测试），所以这条路径目前无人走。
- **描述**：接口注释（`StoreContracts` 之外的 `EvolutionStore.cj:59`）写"`entry.id <= 0` 时自动分配"，隐含"显式 id 由调用方保证唯一"，但没有校验，也没有测例覆盖混用场景。
- **建议**：`save` 开头统一 `if (nextId <= 0) { nextId = maxId() }`（不看 `id` 正负），并且显式 id 大于零时也用它参与 `nextId` 推进；补一条用例"显式 id 3 之后自增得到 4"。

### [轻微][存量] #18 本部分测试的隔离性：固定 `/tmp` 目录 + 非原子全局计数 + 秒级路径

- **位置**：`f_llm/src/store/FStoreMetaStore_test.cj:25`（`private var confDirSeq`）、`:27`（`META_PATH = '/tmp/fllm-meta-test'`）、`:35-42`（`metaPath()` 每次先 `remove(..., recursive: true)`）、`:123`/`:132`（用"当前秒"做目录名）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「并发正确性（测试自身）」
- **证据**：静态确定 —— `metaPath()` 在**每个用例**开头删同一个固定目录：`testCharacterSurvivesRestart`、`testResetRemovesCharacter`、`testPredefinedKeysAccepted`、`testUnknownKeyRejected`、`testCustomPromptsPreserved` 共用 `/tmp/fllm-meta-test`，并行执行时互相清库；`confDirSeq++`（`:112`、`:142`）是无锁全局自增；`testSkillVersionAndList` / `testPromptLatestAndMissing` 用 `DateTime.now().toUnixTimeStamp().toSeconds()` 命名，同一秒内重跑会读到上轮残留（`list().size` 断言随之波动）。
- **描述**：这些用例本身在注释里承认"跨运行、跨 worktree 都不自动清理"，说明已经被残留坑过一次；改用固定目录+前置删除只能解决串行场景。若 `cjpm test` 默认并行跑用例（仓颉 `unittest` 支持并行执行），这套测试会出现随机失败。
- **建议**：所有用例统一用 `UUID.random().toHexString()` 生成独立临时目录（同文件里 `EvolutionLease_test.cj:33-35` 已经是这种写法），并删掉 `metaPath()` 的"先删固定目录"逻辑；需要"同路径重开"语义的用例自己建目录再传同一个路径。

### [轻微][存量] #19 键编码不转义：`':'` / `'|'` / `'\n'` 作分隔符，名字里出现分隔符时静默丢配置或错解析

- **位置**：`f_llm/src/store/FStoreMetaStore.cj:97`（`byname:{llmName}:{id}`）、`:104-108` 与 `:125-129`（按 `split(':')` 的第 6 段取 id）、`:248`（skill 主体 `title|details|functions|version`）、`:289-293`、`:307-308`（prompt `{name}:{version}`）、`:336-340`（`split(':')[4]`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 语义与注释不符」
- **证据**：静态确定（触发条件待确认）—— 解析侧一律按 `:`（或 `|`）切分并按下标取值，写入侧不校验、不转义。`llmName = 'openai:gpt-4o'` 时键变成 `…:byname:openai:gpt-4o:7`，`segments.size == 7`，`id = segments[5] == 'gpt-4o'` → `store.get('…:conf:gpt-4o')` 为 `None` → 该模型**静默不出现在候选里**。`FStoreEvolutionStore` 的索引键已经采用"标题长度 + 标题"的防污染方案（`EvolutionStore.cj:154-160`），说明作者知道这个坑。
- **描述**：待确认的是"仓内是否会出现含 `:` 的 llmName / prompt 名 / skill 标题"。`f_llm/doc/f_llm.md:255-256` 只写了键格式，没写字符约束；`PromptEntry.name` 现有取值是 `memory.extract` 这类点分名，暂未踩到。
- **建议**：与 `EvolutionStore` 统一，把不定长字段改成"长度前缀"（`${name.size}:${name}`）或对 `:`/`|`/`\n` 做百分号转义；至少在 `LLMConfView` / `PromptEntry` / `Skill` 的字段注释里写明"不得包含分隔符"，并在 `put`/`upsert` 入口校验后抛 `IllegalArgumentException`。

### [一般][存量] #20 `StoreMetaConfSource.load()` 丢掉 `LLMConf.conf` 扩展项，provider 方言路径 / tokenizer / thinking 全部退回默认

- **位置**：`f_llm/src/service/StoreMetaConfSource.cj:48-59`（只逐字段搬 9 个属性，没有 `conf.setConf`）；`f_llm/src/store/StoreModels.cj:168-192`（`LLMConfView` 无 `conf` 字段）；`f_llm/src/model/po/LLMConf.cj:70-77`（`confJson` 默认 `'{}'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「能力未接入 / 只做了一半的分支」、§13「契约与实现不符」
- **证据**：静态确定 —— `LLMConfView` 的字段只有 provider/llmName/actualLlmName/weight/enabled/llmUrl/auth/temperature/alwaysThinking，`load()` 逐个赋值后返回；`LLMConf.conf` 读的是 `confJson`，未 `setConf` 时为空表。而 `conf.option(...)` 承载了大量行为：`openai/ProviderDialect.cj:61-62` 的 `chatPath`/`responsesPath`、`embedding/Embedding.cj:123` 的 `embeddingPath`、`llm/ModelCapabilities.cj:32` 的 `thinking`、`llm/TokenCounter.cj:62` 的 `tokenizerUrl`、`balance/BalanceQueriers.cj:248-249` 的 `accessKeyId`/`secretKey`。
- **描述**：`llm_metaStore=f_store|postgres|mysql` 时 `LLMConfs.createHolder()` 优先走 `StoreMetaConfSource`（`f_llm/src/llm/LLMConfs.cj:51-53`），凡是从 store 读到的配置都不带扩展项：非默认端点的 provider 会打到 `/chat/completions` 默认路径、`thinking=toggle` 的模型不再按需开启思考、余额查询拿不到 AK/SK，且没有任何日志提示。与 JSON / 数据库来源的行为不一致，属于"配置看着生效、实际参数被悄悄丢弃"。
- **建议**：`LLMConfView` 增加 `conf: HashMap<String, String>`（或 `confJson: String`），`FStoreLLMConfStore.put/parse` 用 `SEP` 追加第 10 段并向后兼容旧 9 段格式，`load()` 里 `conf.setConf(view.conf)`；若短期不打算支持，则在 `LLMConfSource` 接口注释与 README 明写「store 来源不支持 conf 扩展项」。

### [一般][存量] #21 配置 id 由遍历序号生成，配置增删后熔断状态与 `usage.llmId` 会串到别的模型

- **位置**：`f_llm/src/service/StoreMetaConfSource.cj:44`（`var seq: Int64 = 0`）、`:49`（`conf.id = seq`）；消费侧 `f_llm/src/llm/LLMConfsHolder.cj:242`（`byId[conf.id] = conf`）、`:257`（`breaker.cleanup(HashSet(byId.keys()))`）、`f_llm/src/llm/LLM.cj:169`（`result.usage.llmId = conf.id`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」
- **证据**：静态确定 —— id 是 `names()` × `candidates()` 的遍历序号（1..n），与 `FStoreLLMConfStore` 里真实的 `f_llm:meta:conf:{id}` 无关；`LLMConfsHolder.refresh` 以 `conf.id` 建 `byId` 并只清理"本次不存在的 id"，即熔断器按 id 长期持有状态。
- **描述**：插入一条排在扫描序前面的配置、或改掉某个 llmName 后，同一 id 会指向另一个模型：对 A 打开的熔断会继续拦 B，B 的成功又会重置 A 的失败计数；`usage.llmId` 统计同样错位。因为序号每次 `load()` 重新生成，这不是一次性错位，而是每次配置变更整体平移。
- **建议**：`LLMConfView` 带上真实 id（`LLMConf` 已有 `id` 字段）并用它，而不是遍历序号；在改动前，至少把熔断键从 `conf.id` 换成 `provider + llmName + url`，并在类注释写明「id 仅在单次快照内有效」。

### [一般][存量] #22 inMemory 模式存在两份 `MemoryStore`，且 `Stores.content()` 每次调用新建实例 —— 两个入口互相看不到对方写入的记忆

- **位置**：`f_llm/src/store/InMemoryStores.cj:29`（`private let memoryStore = InMemoryMemoryStore()`）、`:83-85`（另一个 `@Bean` 单例）、`f_llm/src/store/Stores.cj:74-81`（`content()` 每次 `factory()`）、`f_llm/src/store/MemoryStoreAdapter.cj:38-41`、`f_llm/src/loom/LoomStoreGateway.cj:70`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「接线缺失 / 只做了一半的分支」、§11「契约与实现不符」
- **证据**：静态确定 —— `Stores.content()` 每次 `factory()` 新建，因此每次拿到新的 `InMemoryContentStore`，其内部 `memoryStore` 字段也是新对象；`MemoryStoreAdapter` 走的是 `lookupOption<MemoryStore>()` 的 bean 单例。两条路径指向两个不同实例（`f_llm/README.md:135` 把 `Stores.content().memory` 写成读写记忆的标准入口，`Memory.cj:134` 走适配器）。
- **描述**：`llm_memoryStore=inMemory` 下，`Memory.remember` 写入的记忆落在 bean 实例；`LoomStoreGateway` 持有 `Stores.content()` 写入/检索的是另一个实例，loom 侧永远搜不到这些摘要，反向亦然。表现为"刚记住的事下一轮就忘了"，且只在内存后端出现，SQL 后端因为落同一张表而看不到这个问题。
- **建议**：`InMemoryContentStore` 复用 `lookupOption<MemoryStore>()` 的 bean（测试场景保留注入构造），或让 `Stores` 对 `inMemory` 返回单例；同时修正 `InMemoryStores.cj:24`「不注册进 `Stores`」的注释（实际 `StoreWiring.cj:60` 已注册）。

## 优化可行性方案

### [CPU] 把 `FStoreLLMConfStore.repair()` 从构造函数里移出去

- **现状**：两个 `init`（`FStoreMetaStore.cj:40-46`、`:49-56`）都会 `repair()`（`:89`），而 `repair` 是"`store.prefix('f_llm:meta:conf:')` 全量扫 + 每条一次 `store.get(indexKey)` + 缺失时 `store.add"（`:143-161`）。构造点不唯一：`MetaStoreAdapter.cj:39`、`StoreWiring.cj:67`，以及 `Stores.meta()` 每次工厂调用（`Stores.cj:92`）——`SkillCatalog` 每次检索就新建一个（`SkillCatalog.cj:193`）。
- **方案**：`repair` 改为显式的一次性维护入口（`MetaStores.bootstrap()`），构造只做"打开 + 读配置"；若必须兜底，改成"只在 `SEQ` 键缺失时扫一次"。
- **预期**：把每次构造的 O(配置数) 次 IO 降为 0；构造次数按 `SkillCatalog` 调用频次线性下降。定量收益需要 profile。
- **代价**：启动流程多一个"必须显式调用"的约定（需要在 `StoreWiring.wire()` 里接上，`doc/known-limitations.md` 补一句）。
- **验证**：`cjprof record` 跑"N 次 `SkillCatalog` 检索 + M 次工具调用"，对比 `repair` 的 self time 与 `store.prefix` 调用次数；同时用 `strace -c` 看 `get` 系统调用数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `InMemoryEvolutionStore.list` 的锁内 O(n²) 排序

- **现状**：每次 `list` 全量拷贝 + 手写插入排序（`EvolutionStore.cj:94-106`），全程持 `mutex`；`bySkill` 还会再触发一次（`:120`）；条目数 N 增长后单次调用是 O(N²)，且阻塞同实例的其他读写。
- **方案**：`save` 时维护按 `(at, id)` 的有序结构（或在 `list` 里用 `std.sort` 的 O(N log N)），锁内只做"取窗口 + 拷贝"，排序在锁外。
- **预期**：单次 `list` 从 O(N²) 降到 O(N log N)，锁持有时间同阶下降。N=10⁴ 时理论差两个数量级，但缺实测。
- **代价**：`save` 多一次有序插入（O(N) 或 O(log N)），只影响内存实现。
- **验证**：`cjpm bench -O2` 对 `list` / `bySkill` 各跑 N = 10²/10³/10⁴ 三档，给中位数与 P95；同进程 `Mutex` 等待时间用分段计时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `KnowledgeChunker.split` 的全量 rune 展开

- **现状**：`splitImpl` 先 `countRunes` 再 `ArrayList<Rune>(total)` 逐 rune 展开（`KnowledgeChunker.cj:72-85`），峰值 ≈ `4 × 内容字节数`（`ArrayList<Rune>` 元素 4 字节 + 扩容余量），**与内容长度线性、无上限**；local 档只在 `content.size <= 2 MiB` 时生效（`:25-31`），更大文档全走堆。调用方 `InMemoryKnowledgeStore.upsert`（`InMemoryStores.cj:201`）与各 SQL 仓储都不限制正文长度。
- **方案**：不预展开全文 —— 用 `content.runes()` 的迭代器 + 环形窗口（`overlap` 个 rune）逐块产出，峰值降到 `O(maxChars)`；需要保留 local 档时把环形缓冲放进 local region。
- **预期**：峰值从 `4 × size` 降到 `4 × (maxChars + overlap)`（默认 1 800 B）；对 100 MiB 文档是 400 MB → 常数级。缺实测。
- **代价**：`runes()` 迭代器只能顺序走，切块逻辑要从"按下标取"改成"滑动缓冲"，`appendChunksLocal`/`appendChunksHeap` 两档都要改；`-O0` 下 local region 的临时对象行为已在注释 `89-99` 里踩过坑，需重新验证。
- **验证**：`getAllocatedHeapSize()` 前后差 + `getUsedHeapSize()` 峰值，输入 1/10/100 MiB 各 20 轮取中位数；与现实现同输入比对块内容逐字节相等。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] evolution 表的 f_store 索引键没有保留策略

- **现状**：每条 `EvolutionEntry` 写 3 个键（`DATA` / `IDX` / `TIME`，`EvolutionStore.cj:192-198`），永不删除；`pad(at, 20) + pad(id, 20)` 让键长约 60+ 字节。一天一条/技能的写入速率下增长很慢，但 `list` / `bySkill` 每次都要 `store.prefix` 扫全量键再逐个 `get`（`:205-238`），读放大随历史线性增长。
- **方案**：加保留策略（按 `TIME` 键滚动删除超过 N 天/ N 条的记录，三个键同步删），或把 `list` 改成"从最大键往前取 limit 个"的有界反向游标（`prefix` 迭代器是否支持反向需先查 API）。
- **预期**：读放大从 O(全表) 降到 O(limit)。
- **代价**：删除逻辑要保证 `DATA` / `IDX` / `TIME` 三键一致（当前没有事务），需要"先删索引再删主体"的顺序约定 + 崩溃恢复思路。
- **验证**：写入 10⁵ 条后测 `list(0,20)` / `bySkill(x,20)` 的耗时与 `prefix` 扫描条数（加计数埋点）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 构造期 `repair()` 是模型配置读取路径的主要固定开销 | `FStoreMetaStore.cj:89,143` | 单次 `repair` 自耗时、配置条数 | `cjprof record` 跑 1000 次 `LLMConfs.holder()` + 1000 次 `SkillCatalog` 检索，看 `prefix`/`get` 占比 |
| 2 | 每次 `Stores.meta()` 新建 `Store` 导致线程数随请求增长 | `FStoreMetaStore.cj:41,51`；`Stores.cj:92` | 进程线程数随请求数的曲线 | 压测 10 分钟（QPS 固定），每 30 s 采 `/proc/self/status` 的 `Threads` 与 `lsof` 句柄数 |
| 3 | `InMemoryEvolutionStore.list` 的排序成为内存后端瓶颈 | `EvolutionStore.cj:90-116` | N = 10²/10³/10⁴ 的单次耗时与锁等待 | `cjpm bench -O2` 三档 + 分段计时（锁内/锁外） |
| 4 | `KnowledgeChunker` 峰值内存 ≈ 4×内容字节 | `KnowledgeChunker.cj:72-85` | `getUsedHeapSize()` 峰值 vs 内容大小 | 1/10/100 MiB 各 20 轮，`getAllocatedHeapSize()` 差 + `VmHWM`（可复用 `KnowledgeChunkerLocalModeBench_test.cj:67-80` 的 `peakRssKb`） |
| 5 | `FStoreEvolutionStore` 三键写入使读路径放大到全表扫描 | `EvolutionStore.cj:205-238` | 写入条数 vs `list` 耗时/扫描条数 | 写入 10³/10⁴/10⁵ 条后测 `list(0,20)`，并在 `prefix` 循环里加计数 |
| 6 | 锁内 `store.prefix`（`FStoreEvolutionStateStore.processedKnowledge`）在天量知识下成为串行段 | `EvolutionStateStore.cj:231-244` | 临界区持有时长、调用频次 | 线程状态采样（BLOCKED/WAITING）+ 分段计时；CPU profile 看不到锁等待 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/service/StoreMetaConfSource.cj` | .cj | ✅ | 64 行；按 `names()`×`candidates()` 展开，过滤依赖 `LLMConfStore` 契约（#7 的放大点）；字段只搬 `LLMConfView` 的 9 项，`LLMConf.conf` 扩展项丢失（#20）；`seq` 自增 id 与真实配置 id 无关（#21） |
| 2 | `f_llm/src/service/StoreMetaConfSource_test.cj` | .cj | ✅ | 2 条用例覆盖"完整字段"与"过滤 disabled/weight=0"；未覆盖重复 `put`（#7） |
| 3 | `f_llm/src/store/ColbertCodec.cj` | .cj | ✅ | 见 #3（`count` 无上限）、#13（4 处字节拼装）、#14（空 `if`） |
| 4 | `f_llm/src/store/ColbertCodec_test.cj` | .cj | ✅ | 3 条往返用例；缺"count 非法/截断 blob/dims 非 1024"负例（#3 的测试缺口） |
| 5 | `f_llm/src/store/DeployPaths.cj` | .cj | ✅ | 见 #10（`getCommand` 退化 CWD、`canonicalize` 无兜底）；`cached` 无同步但幂等（覆盖自检 §12 已说明） |
| 6 | `f_llm/src/store/EvolutionLease.cj` | .cj | ✅ | 见 #4（65.5 s 截断）、#5（无 CAS）、#15（未用 import）、#16（v6/v7 注释）；`LeaseBox` 仅用于 `synchronized` 带出返回值 |
| 7 | `f_llm/src/store/EvolutionLease_test.cj` | .cj | ✅ | 覆盖"同日只放行一次/隔天可领/重开实例持久化"；未覆盖跨天前后 66 s 窗口（#4） |
| 8 | `f_llm/src/store/EvolutionStateStore.cj` | .cj | ✅ | `processedAmong` 覆盖成按主键点查（与接口默认实现语义一致）；`processedKnowledge` 在锁内 `prefix` 全扫（待验证假设 6）；见 #1（`:193/:198`） |
| 9 | `f_llm/src/store/EvolutionStateStore_test.cj` | .cj | ✅ | 3 条用例覆盖内存/持久化/幂等；见 #15（未用 import） |
| 10 | `f_llm/src/store/EvolutionStore.cj` | .cj | ✅ | 见 #8（`bySkill` 1000 条上限）、#13（锁内插入排序）、#17（显式 id）、#1（`:171/:176`）；索引键"长度前缀"是正确做法（#19 的对照） |
| 11 | `f_llm/src/store/EvolutionStore_test.cj` | .cj | ✅ | 覆盖倒序/条件索引/重开不复用 id；见 #15 |
| 12 | `f_llm/src/store/FStoreMetaStore.cj` | .cj | ✅ | 见 #6（无同步）、#7（put 只追加）、#9（`parse` 直读）、#19（键不转义）、#15（未用 import）；`repair` 的"先写主体再补索引"与注释一致 |
| 13 | `f_llm/src/store/FStoreMetaStore_test.cj` | .cj | ✅ | 见 #18（固定 `/tmp` 目录、全局 `confDirSeq`）；`testRepairRebuildsMissingIndex` 是唯一覆盖 `repair` 的用例 |
| 14 | `f_llm/src/store/InMemoryStores.cj` | .cj | ✅ | 见 #2（内存记忆库无同步）、#11（`vectors` 不清理）、#12（不校验 characterKey）、#13（两份重复）、#16（头注释）；`knowledge` 懒建（`:36-52`）同为无同步赋值，并入 #2 的共享路径说明 |
| 15 | `f_llm/src/store/KnowledgeChunker.cj` | .cj | ✅ | 参数校验完整（`maxChars>0`、`0<=overlap<maxChars`）；local/堆两档循环体逐行相同但注释 `89-99` 给了 `-O0` local region 的理由，**不计为重复逻辑**；峰值内存见优化方案 3 |
| 16 | `f_llm/src/store/KnowledgeChunkerLocalModeBench_test.cj` | .cj | ✅ | 参考基准（非门禁），只断言"能切出块"；`getAllocatedHeapSize` 不含 local region，但同处打印 `VmHWM` 作对照，口径正确 |
| 17 | `f_llm/src/store/KnowledgeChunkerLocalMode_test.cj` | .cj | ✅ | 门限常量与字节边界（2 097 152 / 2 097 153）核对正确；local/堆逐元素等价覆盖 ASCII/中文/emoji/混合/矩阵 |
| 18 | `f_llm/src/store/KnowledgeChunker_test.cj` | .cj | ✅ | 覆盖滑窗、中文按字符、空串、非法参数；同时测了 `KnowledgeSearch`（范围外，顺带） |
| 19 | `f_llm/src/store/KnowledgeIndexRebuilder.cj` | .cj | ✅ | 分页重建逻辑正确（`page.size < batchSize` 提前结束、`batchSize<=0` 抛错）；单篇失败会中断整轮（未捕获），属运维工具的合理取舍 |
| 20 | `f_llm/src/store/KnowledgeIndexRebuilder_test.cj` | .cj | ✅ | `CountingEmbedder` 的 `calls++` 无同步（仅测试内单线程使用，不计）；3 条用例覆盖全量/定向/非法 batch |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 正确性 #1 / #4 / #7 / #8 / #9 / #11 / #12 / #17 / #20 / #21；设计 #1（Store 生命周期）、#6（同族三种同步策略）、#22（同一后端的两个实例）；可读性 #16 / #19。语言特性：`synchronized` 不能带返回值 → 全模块用 `XxxBox` 带出（`LeaseBox` / `StateBox` / `IdBox` …，用法一致无缺陷）；`Option` 均被 `match` 消费，无静默丢弃。安全性：本部分无 SQL 拼接、无 HTML、无凭据进日志（`auth` 只做字段搬运 `StoreMetaConfSource.cj:54`），未命中；`ColbertCodec` 的长度信任问题已归 #3（§5） |
| §1 死代码 | 2 | 逐个 `private` / `internal` 符号全仓搜引用：`writeInt32` / `readInt32`（#13 同址，有调用者）、`knowledgeChunkerUsesLocalBytes`（测试 + `knowledgeChunkerUsesLocal`）、`splitImpl`（`split` + 2 个测试）、`countRunes` / `minOf` / `hexDigitOf` / `indexPrefix` / `indexKey` / `pad` / `readState` / `readRun` / `maxId` / `readByKey` / `read` / `before` / `has` / `contains` 均有调用者；`LeaseBox` / `StateBox` / `StampBox` / `KnowledgeBox` / `KnowledgeSetBox` / `IdBox` / `EntryListBox` 均为"`synchronized` 带出返回值"的载体，全部在用（属非公共顶级声明里的 `public var`，但全项目有使用 ⇒ 不是死代码）。命中：`ColbertCodec.cj:52-54` 空 `if`（#14）、5 处未用 import（#15）。对外可达的 `public`（`ColbertCodec` / `DeployPaths` / `EvolutionLease` / `InMemory*` / `KnowledgeChunker` / `KnowledgeIndexRebuilder` / `StoreMetaConfSource`）不判；`public open` 类不存在 ⇒ `protected` 豁免无适用对象。`private init()`（`TimeUuid`、`KnowledgeChunker`、`KnowledgeIndexRebuilder`）是"禁止实例化"的有意声明，不判（`DeployPaths` 无 `init`，全静态） |
| §2 重复逻辑 | 3 | 同文件两两比对 40+ 个函数体 + 跨文件搜相同字面量/分隔符：命中的三组见 #13（插入排序 ×2、线性 `contains` ×3、4 字节小端 ×4）。**判为"不重复"**：`appendChunksLocal` / `appendChunksHeap`（循环体逐行相同，但注释 `KnowledgeChunker.cj:89-99` 给出 `-O0` 下 local region 会为大文档消耗数百 MB 的实测理由，合并会引入 OOM 面）；`FStoreMetaStore` 的两个 `init`（仓颉无构造函数委托）；`ColbertCodec.writeInt32` 与 `Int32` 的 count 字段（语义不同：一个是定长字段、一个是向量元素）；三份 `ensureSchema` 默认空实现（接口扩展点，语义各自独立） |
| §3 空实现 | 0 | 逐条核对：`EvolutionLease.ensureSchema` / `EvolutionStateStore.ensureSchema` / `EvolutionStore.ensureSchema` 的默认 `()` 都有注释说明"f_store 与内存实现无需建表"（Null Object，且四个后端实现里 mysql/postgres 均已覆盖，`mysql/EvolutionStateStore.cj:41` 等）；`processedKnowledge` / `markKnowledge` 默认实现有"运维/调试用"的注释；`case None => ()` 出现在 `markKnowledge` 跳过空串（`EvolutionStateStore.cj:267`）、索引读失效（`EvolutionStore.cj:215`、`:233`、`:299`）等**有明确语义**的位置，不是吞异常。真正的"承诺有行为却空实现"只有 #14 的空分支，已按 §1 计 |
| §4 栈溢出 | 0 | 本部分无递归：`TimeUuid.timestampOf` 是单层循环，`KnowledgeChunker` 的滑窗是 `while (start < total)`，`KnowledgeIndexRebuilder.rebuildAll` 是 `while(true)` + 分页退出，`ColbertCodec` 双层定长循环。`EvolutionStateStore.processedAmong` 默认实现无自引用 |
| §5 OOM | 2 | #3（`decode` 按数据里的 `count` 循环与分配）；`KnowledgeChunker` 的全量 rune 展开（4×内容字节，无内容长度上限）量化后作为优化方案 3 + 待验证假设 4（无实测，不定为缺陷）。另核对：`InMemoryEvolutionStateStore.knowledge` / `InMemoryKnowledgeStore.docs` 只增不减，但规模由业务实体数决定（非"每次请求新增键"），未计；`FStoreEvolutionStore` 三键/条属磁盘增长，列入优化方案 4 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，本部分所有"看起来贵"的位置（构造期 `repair`、锁内排序、`prefix` 全扫）一律降为优化方案 1-2 与待验证假设 1-6，不作缺陷 |
| §6.2 大粒度锁 | 1 | `InMemoryEvolutionStore.list` 在 `synchronized` 内做全量拷贝 + O(n²) 排序（`EvolutionStore.cj:92-114`），临界区含纯 CPU 的排序逻辑；已并入 #13 的描述（内存实现、影响面小，定级轻微）。`FStoreEvolutionStateStore.processedKnowledge` 在锁内做 `store.prefix` 磁盘扫描（`EvolutionStateStore.cj:233-242`）列入待验证假设 6（是否成热点缺数据）。其余 `synchronized` 块只包裹单次 map/Store 操作 |
| §6.3 并发串行 | 0 | 本部分没有 `spawn`，也没有"提交后立刻 `get()`"；唯一的并行面是 `Store` 内部 compactor 线程（`f_store`，范围外） |
| §6.4 低效算法 | 1 | 手写插入排序代替 `std.sort`（`EvolutionStore.cj:98-106`、`InMemoryStores.cj:273-281`），另 `names()` 的 `has()` 去重是 O(n²)（`FStoreMetaStore.cj:112`，n = 配置条数，量级小）。`FStoreEvolutionStore.list` 的 `keys[index]` 反向遍历本身是 O(limit)，但前置 `prefix` 全扫属读放大（优化方案 4）。`KnowledgeChunker` 的 `countRunes` 为精确容量服务，属"多走一遍 O(n) 换掉扩容"，有意取舍 |
| §7 降堆内存方案 | 2 | 优化方案 3（`KnowledgeChunker` 全量 rune）、优化方案 4（evolution 索引键无保留策略）；另 #11 是"泄漏"（缺陷）而非"可省"，不重复计 |
| §8 降 CPU 方案 | 2 | 优化方案 1（构造期 `repair`）、优化方案 2（锁内 O(n²) 排序）；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分唯一的 local mode 改造已经在 `KnowledgeChunker` 落地（`@ local!` + `exclave` + 8 MiB 预算 + 门限单测），并有 `perf-baseline.md` 口径的参考 bench；其余候选（`ColbertCodec.decode` 的向量数组、`EvolutionLease.timestampOf` 的 nibble 缓冲、`FStore*` 的 `ArrayList`) 要么作为返回值逃逸（违反 `@ ~local` 约束），要么量级只有几十字节（收益无法用峰值内存证明），不满足"峰值内存前后对照"的取证要求 |
| §11 现有代码的 BUG（存量） | 22 | 本部分是工作区快照，**全部 22 条发现都是存量**；其中按 §11 形态判定的：#1（数据丢失）、#4（边界 / 注释不符）、#5 / #7 / #12（契约与实现不符）、#8（静默丢数据）、#9（错误处理）、#10（契约不符）、#11（资源不对称）、#17（数据覆盖）、#18（检查-然后-写入）、#19（边界未校验）、#21（语义与契约不符）；#2 / #3 / #6 / #13-#16 / #20 / #22 分别按并发、OOM、重复、死代码、功能完备性维度归类，不重复计数。逐函数核对过边界与空值：`ColbertCodec.decode` 的空 blob（`bytes.size < 4` 返回 `[]`）、`count == 0`、`TimeUuid.timestampOf` 的空串/非十六进制（返回 0）、`DeployPaths.resolve` 的空配置/纯 `./`、`KnowledgeChunker.split` 的空内容与 `overlap >= maxChars`、`FStoreLLMConfStore.parse` 的段数不足（返回默认视图）、`FStoreCharacterStore.get` 的"无换行"分支、`FStoreEvolutionStore.read` 的 detail 含分隔符（第 4 段起拼回）、`KnowledgeIndexRebuilder.rebuildAll` 的分页退出，均已核对，无额外缺陷 |
| §12 并发安全与锁粒度 | 4 | #1（多 Store 实例共用目录 + WAL 被删）、#2（`InMemoryMemoryStore` / `KnowledgeStore` / `cachedKnowledge` 无同步）、#6（`FStoreMetaStore` 家族无同步的检查-然后-写入）、#5（租约的跨进程互斥缺失）。已明确线程封闭/无害的：`DeployPaths.cached`（幂等，重复计算同值，仅可能多做一次 `canonicalize`）、`TimeUuid.hexDigitOf`（纯函数）、`ColbertCodec` / `KnowledgeChunker`（无状态静态方法）、`CountingEmbedder`（仅测试单线程用）。锁粒度：Evolution 三个 f_store 实现都用"实例级 `Mutex` + `Box` 带出"，临界区内是单次 Store 读写，无嵌套取锁，无死锁路径；`InMemoryKnowledgeStore` 走的是"完全无锁"而不是"锁太大" |
| §14 功能完备性与 README 覆盖 | 3 | 本部分 0 个 `.md`（`f_llm/README.md` 与 `doc/**` 由其他子轮覆盖），无法做完整 README 对照；能做的代码内契约核对已做：#5（接口承诺 CAS）、#7（`put` 承诺覆盖）、#12（`CharacterStore` 两实现不一致）、#21（id 语义）均以"承诺源（接口/类注释 `文件:行号`）+ 缺失证据"的形式给出；#20（`LLMConf.conf` 扩展项未接线）、#22（inMemory 双实例 + `Stores.content()` 每次新建导致记忆不可见）是按 §14.1「能力未接入 / 接线缺失」判定的功能缺口 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`files/f_llm.part20.txt` 的 20 行逐行对应上表。§13 文档一致性：本部分无 `.md`，只核了 `.cj` 内的契约性注释（#16） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 12 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分是 `f_llm` 的存储底座：`store/` 下的 f_store 元数据族、演进状态/报告表/租约、内存实现、切块与索引重建。功能实现完整、注释密度高（键布局、精度取舍、local mode 的 `-O0` 坑都写清了），单测覆盖也算扎实；**风险不在单个函数，而在"同一个路径 / 同一个实例被多处独立构造"这条主线**：

- 阻塞项一（**#1**）：`llm_metaStorePath` 被 4 个类各自 `Store(path)`，而 f_store 的 `Store` 构造会删掉目录下全部 WAL（`store_func.cj:216`）。配上 `Stores.meta()` 每次新建实例、`SkillCatalog` 每次检索新建实例的现实，这是"改动/重启后 skill、prompt、character 写入消失"的直接解释，也是线程与句柄随请求增长的来源。修法应落在"一个路径一个 Store + 工厂缓存"，而不是逐个类打补丁。
- 阻塞项二（**#2**、**#6**）：两个 `@Bean`/共享实例（`InMemoryMemoryStore`、`LoomStoreGateway.meta`）都假设单线程：一个连 `Mutex` 都没有，一个的 `prompts.remove` 是检查-然后-写入。同一模块里 Evolution 系列已经给出了正确范式（`Mutex` + `Box` 带出 + 布尔标志），照抄即可。
- 边界上的静默错误（**#4**、**#7**、**#8**、**#9**、**#11**）：租约在每天前 66 秒可能失效（注释还写着"不会跨天漂移"）、`put` 承诺覆盖却只追加、内存版 `bySkill` 只看最新 1000 条、一条脏记录能让整表读取抛异常、删文档不删向量。这些都不会报错，只会让"配置/历史/内存"慢慢对不上，靠日志很难定位。
- 配置来源的静默降级（**#20**、**#21**、**#22**）：`StoreMetaConfSource` 只搬 9 个字段，`LLMConf.conf` 里的 `chatPath`/`thinking`/`tokenizerUrl`/余额凭据全部丢失，同一份配置走 store 来源与走 JSON 来源行为不同；配置 id 用遍历序号，配置一变熔断状态就串到别的模型；inMemory 模式还存在两份 `MemoryStore`，经 `Memory` 写入的记忆在 loom 网关侧不可见。这一类是"功能看着齐全、实际少一半"的形态，建议与 #7 的 `put` 语义一起收口。
- 工程化欠账（**#3**、**#17**、**#18**、**#19**）：`decode` 信任 blob 里的长度（OOM 面）、显式 id 路径无人走也没对齐 `maxId`、测试用固定 `/tmp` 目录 + 全局自增计数、键编码不转义。都是低成本可修的项，建议与 1.3.x 的存储收口一起做。
- 性能与内存：本部分没有任何改前/改后数据，四条优化与六条假设**不进修复清单**；其中"构造期 `repair` + 每次新建 Store"与 #1 同源，修 #1 时顺带就能缓解，值得下一轮补 `cjprof` 与前后的线程/句柄曲线。
- 已确认**没有**的问题：栈溢出（无递归）、死锁（无嵌套取锁、无锁内回调）、`Option` 被静默丢弃（全部 `match` 消费）、local mode 误用（`KnowledgeChunker` 的分档有注释与单测支撑）、接口默认空实现被漏覆盖（mysql/postgres 全部覆盖）。

存量缺陷共 22 条（严重 3 / 一般 12 / 轻微 7），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

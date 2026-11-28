# f_llm 模块审查报告（第 22/25 部分：store 层 hydra/it）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm/src/store/`（本部分 10 个 `.cj` 源文件 + 10 个测试 `.cj`，共 20 个文件，3143 行）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 所有问题来源均为「存量」
- **审查重点**：客户端契约与配置、流式/错误处理（本部分集中在 RPC 错误路径）、资源与超时、死代码、重复逻辑、并发安全
- **报告版本**：part22（模块全量审查的第 22 个子轮，供主 Agent 合并）

## 发现

### [严重][存量] `HydraMemoryRepository.nextId()` 读-改-写无同步，并发写入会拿到重复 id

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:254-263`（`nextId`），调用点 `:63`（`upsert` 第一行）
- **来源**：存量（快照模式无基线；整文件为 2026-10 后的 hydra 方案）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态无保护）、§6.2（复合操作不原子）
- **证据**：静态确定 —— `nextId` 是「`transport.get(MAP,'seq')` → `current + 1` → `transport.upsert(...)`」三步复合操作，全程没有锁、没有 CAS；`HydraTransport` 接口（`Transport.cj:31-43`）也没有条件写/自增原语。`HydraMemoryRepository` 由 `HydraContentStore.memory`（`ContentStore.cj:50`）构造，而 `SqlMemoryStore`（`PostgresMemoryStore.cj:50`）直接在 `add()` 里调用 `repo.upsert`，无上游同步。
- **描述**：两个请求并发写记忆时都读到 `seq=N`，都写 `N+1`，返回同一个 id。后写者的 `VectorRecord` 覆盖前者的 payload/向量，`map:{id}` 也指向同一 collection —— 前一条记忆静默丢失。因为记忆 id 是全局自增（`MAP` 为全局集合），该冲突跨用户、跨 namespace 发生，不是单用户局部问题。
- **建议**：给 id 分配加一条进程内互斥（`Mutex`，与 `HydraEvolutionLease` 的写法一致），并注明「单进程保证」；跨进程（`fhydra` 远程部署）必须由服务端提供 `hydra.nextId` 之类的原子自增，或在 `upsert` 里带 `expectedSeq` 做 CAS。短期至少要把「并发写不安全」写进 `MemoryRepository` 的契约注释，避免被当成幂等。

### [严重][存量] `HttpTransport.upsert` 只投影部分字段：`filters`（kind）与 `colbert` 在远程部署下静默丢失

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:82-86`（param 拼装）、`:94-118`（`get` 不回填 `filters`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§3（开关打开后走进空分支）、§14.1（能力未接线）
- **证据**：静态确定 —— 写入 param 只有 `collection/id/payload/denseB64/saveTime/titleDense/contentDense/tokenIds/weights`，`record.filters` 与 `record.colbert` 从未出现；对照 `fhydra/src/HydraParams.cj:25-47`，`UpsertParam` 有 `kind/saveDay/tags` 三个过滤字段，但**没有** `colbert` 字段，`recordOf()` 也不会带。`fhydra/src/HydraRpc.cj:143-151` 的 `ids` 在有 `filters` 时走 `store.idsFiltered`（倒排），而写入侧从未写 `kind` ⇒ 倒排里没有该维度条目。
- **描述**：`llm_memoryStore=fhydra` 时：① `MemoryRepository.listByKind`（`MemoryRepository.cj:174-187`）下推的 `filters['kind']` 服务端永远查不到 → 返回空列表，`memory` 工具的 kind 过滤在远程部署下失效（`doc/f_llm.md:341` 只承诺了 `f_hydra` 本机部署下推，但 `doc/content-store.md:10` 把 `fhydra` 与 `f_hydra` 并列在同一实现矩阵里，等于承诺同语义）；② `upsertColbert`（`MemoryRepository.cj:117-128`）经 `rewrite` → `transport.upsert` 后 colbert 向量未被持久化，`colbert()` 永远拿不到 → `rerank=true` 的检索在远程部署下静默退化为按融合分排序，且没有任何日志。
- **建议**：`HttpTransport.upsert` 增加 `"kind":"${esc(record.filters.get('kind') ?? '')}"`；`get` 回填 `filters`（远端 `RecordDto` 需要新增 kind 字段）。colbert 需要在 `fhydra` 的 `UpsertParam`/`RecordDto` 两侧一起补，补齐前应在 `HttpTransport.upsert` 里对非空 `record.colbert` 显式 `warn` 或抛错，不能静默丢弃。

### [一般][存量] `HydraMemoryRepository.upsert` 不按 `(user_id, namespace, title)` 覆盖写，违背 `MemoryRepository` 契约

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:61-80`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 接口注释 `f_llm/src/store/MemoryRepository.cj:36` 写「唯一键是 `(user_id, namespace, title)`：同键写入覆盖，返回既有 id」，`doc/content-store.md` §2 也写「同一 `(user_id, namespace, title)` 覆盖写，返回既有 id」；实现是 `nextId()` + 无条件 `transport.upsert`，没有任何按 title 查旧记录的步骤，`PostgresMemoryRepository`/`MySqlMemoryRepository` 靠 DB 唯一键达到该语义，hydra 侧缺这一层。
- **描述**：同一用户重复写同标题记忆（`loom` 的会话摘要、`kind=session` 覆盖很常见）时，hydra/fhydra 部署会不断新增记录而不是覆盖：`list` 出现重复项、`memory.search` 召回同一内容多份、`MemoryKinds.weightOf` 重复计分。与 `[严重] nextId` 叠加时还会放大重复 id 概率。
- **建议**：`upsert` 前按 `collection + title` 查一次（`transport.idsFiltered` 已支持 filters，可把 `title` 也写进 filters），命中则复用既有 id 做覆盖写；或在文档中明确「hydra 族不支持同标题覆盖」并把接口注释改成后端相关。

### [一般][存量] `colbert()` 的 title 分支恒为空数组，重排少一路信号且与 SQL 实现不一致

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:137-141`
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支 / 读了不用）、§11（语义与注释不符）
- **证据**：静态确定 —— `case Some(vector) => Array<Array<Float64>>()` 与 `case None => Array<Array<Float64>>()` 完全一致，`record.vectors.get('title')` 的取值被丢弃；对比 `postgres/MemoryRepository.cj:91`、`mysql/MemoryRepository.cj:95` 都是 `ColbertVectors(ColbertCodec.decode(title), ColbertCodec.decode(content))`。
- **描述**：`SqlMemoryStore` 的重排（`PostgresMemoryStore.cj:151-153`）用 `maxSim(query, vectors.title)` 与 `maxSim(query, vectors.content)` 合并；hydra 后端 `title` 恒空 ⇒ `maxSim` 短路返回 0（`PostgresMemoryStore.cj:218-221`），标题相似度这一路在所有 hydra 部署（含默认配置）下都不参与排序。`upsertColbert` 把标题向量和正文向量合并进同一条 `record.colbert`（`:117-128`），语义上已不可分，因此当前写法是「知道分不开，于是把 title 留空」，但用了一个恒等 `match` 掩盖，读者无法判断是刻意还是漏写。
- **建议**：两分支合一，直接 `let title = Array<Array<Float64>>()`，并把「colbert 在 hydra 族只保留合并序列，title 恒空、重排只用 content」写进注释；若要恢复两路信号，需要在 `VectorRecord` 上拆 `titleColbert`/`contentColbert` 两个字段（涉及 f_hydra 存储布局，属设计变更）。

### [一般][存量] `decode()` 丢弃 payload 中的 `saveTime`，记忆时间退化为读取时刻

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:281-288`（`decode`），写入侧 `:276-279`（`encode`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死写）、§11（数据错误）
- **证据**：静态确定 —— `encode` 按 `title␁content␁kind␁saveTime␁namespace` 写 5 段，`decode` 只取 `parts[0..2]` 与 `parts[4]`，`parts[3]`（epoch 秒）从未被解析，第 7 个构造参数写死为 `DateTime.now()`。
- **描述**：任何 `repo.get`/`list`/`listByKind`/`search*` 返回的 `MemoryRecord.saveTime` 都是「读的这一刻」，而不是写入时刻。该字段经 `LoomStoreGateway.cj:442` 输出到 `memory.search` 的 JSON，调用方按时间排序/判新旧会全部错乱；payload 里那一段成为永不被读取的冗余数据。另有次要问题：`parts.size < 5` 时返回一条 `content=''` 的空记录而不是 `None`（`:284-286`），调用方看到的是「存在但内容为空」的记忆。
- **建议**：`decode` 解析 `parts[3]` 并构造 `DateTime`（`std.time` 有从 epoch 秒构造的 API，实现前用 `cangjie-doc-lookup` 核对签名），解析失败回落 `DateTime.now()` 并打一次 warn；`parts.size < 5` 返回 `None`，由调用方按「记录损坏」处理。

### [一般][存量] RPC 错误判定依赖 `text.contains('"error"')`，payload 里出现 `"error"` 会被误判为失败

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:212-216`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失/误判）、§3（错误路径）
- **证据**：静态确定 —— 响应体里的业务字段 `payload` 由 `esc()` 转义，正文中的 `"error"` 会变成 `\"error\"`，其字节序列中仍然包含子串 `"error"`（反斜杠 + 引号 + error + 引号），`contains` 命中后走 `parse<ErrorEnvelope>`；此时真实响应没有 `error` 键，`DataAssist` 会给出默认 `ErrorDto(code=0, message='')`，于是抛出 `hydra rpc error 0: `（空消息）。
- **描述**：只要被存/被读的记忆正文或标题里出现带引号的 `error` 字样（「日志里写了 `"error"` 字段」这类内容很常见），该记录的 `get`/`list` 就永久抛异常，且异常信息只有 code 0 与空消息，排障成本极高。`list`/`search` 里的 `case None => ()` 不会兜住异常，整页读取直接失败。
- **建议**：按 JSON 结构判断而不是子串判断——顶层解出 `ObjectData` 后检查是否存在 `error` 键（`DataObject` 的缺失字段语义），或解析成含可选 `error` 的 envelope（`?ErrorDto`）再判 `isSome()`；异常消息附上 `method` 与 `id`，不要附响应体。

### [一般][存量] 惰性初始化与注册表读写无同步：`HydraContentStore` 缓存与 `Stores` 静态表

- **位置**：`f_llm/src/store/hydra/ContentStore.cj:31-32`（`cachedMemory`/`cachedKnowledge`）、`:47-53`、`:59-65`；`f_llm/src/store/Stores.cj:34-35`（两张静态 `HashMap`）、`:47-59`（写入）、`:74-97`（读取）
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化 / 发布逸出 / 共享可变状态无保护）
- **证据**：静态确定 —— ①`memory`/`knowledge` 是「`match` 判 `None` → 新建 → 赋值」的检查-然后-写入，两个线程同时首次访问会各建一份 `SqlMemoryStore`/`HydraKnowledgeStore`，`private var` 也没有内存屏障；②`Stores.contentFactories`/`metaFactories` 在 `registerContent`（`:51`）/`registerMeta`（`:58`）里写，在 `content(name)`（`:75`）/`meta(name)`（`:91`）里读，两侧都没有锁；写入方不只在模块加载期——`StoreWiring.wire()`（`wiring/StoreWiring.cj:52-70`）在 `Memory.remember`（`memory/Memory.cj:124`）里被**每次调用**触发，而 `LoomStoreGateway()`（`loom/LoomStoreGateway.cj:70-71`）会在别的线程读这两个表。
- **描述**：进程首次并发使用时存在「一次 `HashMap` 读与一次 `put` 并发」的窗口，可能读到半初始化状态（`contains` 返回 false 后抛 `unknown llm_memoryStore`），也可能产生两份 store 实例（各自持有一份 `FStoreVectorStore` 句柄，见下一条）。启动后稳态不再写入，因此影响集中在首请求窗口，但后果是「首次请求随机失败」这类难复现问题。
- **建议**：`Stores` 的两张表加一把 `Mutex`（注册与读取都进临界区，读取只做 `get` 引用，代价可接受），或在 `StoreWiring.wire()` 之外禁止注册并要求启动期单线程完成后再对外服务；`HydraContentStore` 的两个缓存改为 `private let` + 构造时初始化，或沿用 `Mutex` + 双重检查（不得只加 `if`）。

### [一般][存量] `Stores.content()` / `meta()` 每次都走工厂 `new`，同进程会出现多个 `FStoreVectorStore` 指向同一目录

- **位置**：`f_llm/src/store/Stores.cj:68-81`（`content()`/`content(name)`，`Some(factory) => factory()`）、`:84-97`
- **来源**：存量
- **判据**：review-checklist §5（长期持有 / 句柄增长）、§12.1（跨线程资源）、§11（契约与实现不符）
- **证据**：静态确定 —— 工厂返回的是**新实例**，没有任何实例缓存；调用点：`loom/LoomStoreGateway.cj:70-71`（每个网关一次）、`store/MemoryStoreAdapter.cj:40`（每个适配器一次，`Memory.remember` 的回退路径每次新建适配器）、`loom/LoomWiring.cj:213`（定时任务每次触发 `Stores.meta()`）。`HydraContentStore.init`（`ContentStore.cj:34-38`）会 `FStoreVectorStore(DeployPaths.resolve(...))`，即每次 `new` 一个 `f_store` 句柄。
- **描述**：①`HydraContentStore` 内部的 `cachedMemory`/`cachedKnowledge` 缓存只对「同一个实例」有效，跨调用完全失效，`requireEmbedder()`（`ContentStore.cj:69-75`）也每次重新 `lookupOption`；②同一进程内可能有 N 个 `Store` 句柄指向同一目录，f_hydra 的「两阶段写 + ready 标记」是否跨实例互斥、是否会因多句柄并发写损坏数据，需要读 `f_store` 实现确认（本部分未展开，见待验证假设 #5）。风险随 `Memory.remember` 调用次数线性增长。
- **建议**：`Stores` 内按名字缓存单例（`HashMap<String, ContentStore>`，与上一条的锁一并加），或把「一个进程一个 ContentStore」写成硬约定并在 `bootstrap()` 里实例化一次；`Stores.resetForTest()` 同时清实例缓存。

### [一般][存量] `HttpTransport` 全局关闭 TLS 证书校验（`CertificateVerifyMode.TrustAll`）

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:202-204`
- **来源**：存量
- **判据**：review-checklist §10（安全性：敏感数据、外部输入未校验）、§11（契约与实现不符：`llm_hydraSecret` 走明文信任链）
- **证据**：静态确定 —— `let tls = TlsClientConfig(); tls.verifyMode = CertificateVerifyMode.TrustAll`，无条件生效，没有配置开关；`client.header('X-Hydra-Key', secret)`（`:201`）把共享密钥放在这条连接上，请求体里是整个记忆库的 payload 与向量。
- **描述**：`https://` 的 `llm_hydraUrl` 部署下，任何能中间人的攻击者都可以冒充 fhydra 读取全部记忆内容与 `llm_hydraSecret`，或篡改检索结果（`searchDense` 命中集）。同一写法在 `llm/LLMTransport.cj:48`、`llm/LLMStreamTransport.cj:50`、`embedding/BgeM3Transport.cj:92`、`balance/BalanceQueriers.cj:43`、`search/DeepSeekSearchProvider.cj:45` 重复出现，属模块级约定，因此不是本文件独有缺陷，但本文件承担的是持久化数据面。
- **建议**：`TrustAll` 改为按配置项开启（如 `llm_hydraInsecureTls`，默认 false），默认走标准信任链；需要自签证书的内网部署应支持指定 CA 文件而不是关闭校验。跨传输统一收口到一个 `httpOptions()` 帮助函数，避免 6 处各写一遍。

### [一般][存量] 自定义分隔符（`0x01`）与 `#` 拼接无转义，正文/`docId` 含分隔符时静默串段

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:43`（`SEP`）、`:276-288`（`encode`/`decode`）；`f_llm/src/store/hydra/ContentStore.cj:104`（`SEP`）、`:116-118`（`doc:` payload）、`:135-139`（`get` 拆分）、`:124` 与 `:210-214`（`'${docId}#${seq}'` 与 `id.split('#')`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 语义与注释不符）、§13 相邻（编码格式未在注释中声明约束）
- **证据**：静态确定 —— 两处都用不可见控制字符做字段分隔，且都不做转义或长度前缀。记忆 payload：正文若含 `0x01`（二进制/多模态摘录、从其它系统搬运的文本都可能带），`split(SEP)` 的段数 >5，`parts[0..2]`/`parts[4]` 全部错位 → `title`/`content`/`kind`/`namespace` 被错误还原（`decode` 只判 `<5`，不判 `>5`）。知识库：`docId` 含 `#` 时 `id.split('#')` 得到的 `docId` 被截断（`:210-214`），`wanted()` 的 `docIds` 过滤随之失效、`KnowledgeHit.docId` 指向不存在的文档；`doc:` 记录的 `title+SEP+content` 同理会被切错（`:135-139`）。
- **描述**：错误不抛异常、不记日志，表现为「某条记忆的正文丢失一半」「按 docId 过滤查不到但不过滤能查到」。`0x01` 与 `#` 都是外部输入可携带的字符，不是理论边角。
- **建议**：`doc:` 记录与 chunk id 改成两段定长编码（`docId` 用长度前缀，或 `doc:` 记录里单独存 `titleLen`），记忆 payload 改为 `saveTime` 等定长字段前置 + 仅 `content` 放末段（只 `split` 前 4 段），或直接改用 `JsonValue`/`DataObject` 编解码；最少要在 `encode` 处对 `SEP` 做替换或断言。

### [一般][存量] `HydraKnowledgeStore.upsert` 先 purge 后写，非原子：并发或中断会留下缺块文档

- **位置**：`f_llm/src/store/hydra/ContentStore.cj:114-130`（`upsert` → `purgeChunks` `:230-239`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 复合操作不原子）、§11（资源对称性、崩溃路径）
- **证据**：静态确定 —— `upsert` 第一步 `purgeChunks` 按 `DOCS` 里记录的旧块数逐条删除，再逐块写入新块，最后才写 `DOCS` 计数；全程无锁、无版本号、无事务。`upsert` 与 `remove`（`:144-148`）同为「多次独立 RPC」，`f_hydra` 侧每条都是独立两阶段写。
- **描述**：①同一文档并发 upsert：A purge 后 B purge（此时 `DOCS` 仍是旧值）→ A 写块 → B 写块覆盖，最终 `DOCS=seq_B`，但块是交错的，可能出现 0..max(seq) 空洞或残留旧块；②写块过程中进程退出/网络中断：`doc:` 记录已更新而块只写了一半，`DOCS` 未更新 → 该文档检索永久缺块，且下次 upsert 会按**旧** `DOCS` 计数清理，漏删的块长期残留。远程部署下这个窗口是「N 次 HTTP 往返」的量级。
- **建议**：改为「写新块到带版本后缀的 key → 写 `DOCS{version,count}` → 异步删旧版本」，让 `search` 只读当前版本，做到「先写后切」；或至少把 `DOCS` 计数先清零再写块（宁可短期查不到，也不要留残块），并在 purge 失败时抛出而不是继续。

### [一般][存量] kind 过滤对每个候选做两次 `transport.get`（结构重复读取 + 两次读之间的状态不一致）

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:203-212`（`collect` 第 208 行 `transport.get`）与 `:215-230`（`kindWanted` 第 219 行 `transport.get`）
- **来源**：存量
- **判据**：review-checklist §2（同语义重复执行）、§6.4（同一输入重复解析/重复取数），并发面见 §12.1
- **证据**：静态确定 —— `collect` 先调 `kindWanted(query, collection, hit.id)`，后者内部 `transport.get(collection, id)` 并 `decode` 出 `kind`；返回后 `collect` 立刻对**同一个 key** 再 `get` 一次并 `decode` 一次。两次调用之间没有任何写操作，结果必然相同（除非另一线程刚好删除）。远程传输下每次 `get` 是一次 HTTP JSON-RPC（`HttpTransport.cj:94-118`）。
- **描述**：`searchDense`/`searchSparse` 的每个候选（`namespaces × limit` 条，默认可达数十条）都要 2 次往返 + 2 次 payload 解码，检索延迟随候选数翻倍；同时 `kindWanted` 用 `decode(0, record)`（`:221`）构造一条 `userId=0` 的临时 `MemoryRecord` 只为读一个 `kind` 字段。未提供 profile 数据，按铁律不写成性能缺陷，只报「确定存在的重复读取」。
- **建议**：`kindWanted` 改为接收已取到的 `record`（或直接返回 `?MemoryRecord`），`collect` 只 `get` 一次；顺带把 `decode` 拆成 `kindOf(record)` 之类的轻量读取，避免为取一个字段构造整条记录。

### [轻微][存量] `ensure(now)` 的 `now` 未使用，且写后不做校验（与 `acquire` 不一致）

- **位置**：`f_llm/src/store/hydra/EvolutionLease.cj:57-70`（`ensure`），对照 `:80-94`（`acquire` 有写后读校验）
- **来源**：存量
- **判据**：review-checklist §1（读了不用）、§12.1（发布未校验）
- **证据**：静态确定 —— `ensure(now)` 方法体没有引用 `now`；`read()` 为空时直接 `write(created)` 并把自己写的值返回，没有 `acquire` 里的 `if(read() == created)` 校验。
- **描述**：两个节点同时启动时各自写入、各自返回不同的租约值；返回值只用于 `EvolutionLeases.bootstrap()` 的返回与日志（`loom/EvolutionLeases.cj:64`），实际互斥仍由 `acquire` 的写后读校验承担，因此不构成双跑，但「bootstrap 报告的租约值与库里的值不一致」会误导排障，`now` 这个未用参数也让人误以为 `ensure` 与日期有关。
- **建议**：删掉参数或真正用它判日；`ensure` 也加一次写后读校验（写输的一方返回 `read()` 的结果），与 `acquire` 口径统一。

### [轻微][存量] `llm_hydraPath` 的读取与默认值在三个文件各写一遍，且绕过 `StoreSettings`

- **位置**：`f_llm/src/store/hydra/ContentStore.cj:35`、`f_llm/src/store/hydra/MemoryRepository.cj:49`、`f_llm/src/store/hydra/EvolutionLease.cj:41`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换算复制）
- **证据**：静态确定 —— 三处都是 `DeployPaths.resolve(getVariable('llm_hydraPath') ?? './data/f_hydra')`，逐字符相同；模块其余配置项统一走 `StoreSettings.load()`（`store/StoreSettings.cj:72-74`），只有 hydra 这三处直读环境变量。
- **描述**：改默认目录或加新的解析规则时要同步改三处，漏一处就出现「记忆写在一个目录、租约写在另一个目录」；也让 `StoreSettings` 不再是配置的唯一入口。
- **建议**：在 `StoreSettings` 里加 `hydraPath` 字段（默认值单点定义），三处改为读它；或至少在 `hydra` 包内提供一个 `defaultLocation()` 帮助函数。

### [轻微][存量] 若干同语义实现可合并（数字串、稀疏 CSV、id 列表拷贝、名字列表、分页过滤、自写 `sqrt`）

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:229-238`（`numbers`）vs `f_llm/src/store/VectorMath.cj:29-38`（`literal`）；`HttpTransport.cj:72-81` vs `:135-144`（tokenIds/weights CSV）；`HttpTransport.cj:153-157` vs `:175-179`（id 列表拷贝）；`f_llm/src/store/Stores.cj:118-132`（`contentNames`/`metaNames`）；`f_llm/src/store/hydra/MemoryRepository.cj:157-168` vs `:174-187`（`list`/`listByKind`）；`f_llm/src/store/VectorMath.cj:62-72`（自写 `sqrt`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 换控制流 / 字面量复制）
- **证据**：静态确定 —— ①`numbers` 与 `literal` 对 `Array<Float64>` 都输出 `[a,b,c]`，逐行对齐，唯一差异是 `literal` 为 `public` 供 SQL 侧复用；②`upsert` 与 `searchSparse` 各写一遍「首元素不加逗号」的 CSV 拼接（`:74-81`、`:137-144`）；③`ids`/`idsFiltered` 尾部都是 `for(id in response.result.ids){ result.add(id) }`（`ArrayList` → `ArrayList` 的纯拷贝）；④`contentNames`/`metaNames` 只差遍历哪张表；⑤`list`/`listByKind` 只差 id 来源；⑥`VectorMath.sqrt` 是 30 次牛顿迭代，而 `std.math.sqrt` 在 `f_chart`（`BlandAltmanChart.cj:242`）等模块已在用。
- **描述**：以上均未发现行为差异（错误文案、边界、日志级别、可空性已逐项核对），但让「改一处忘另一处」成为常态，尤其 ②③ 属序列化格式：稀疏向量的 CSV 规则一旦要改（如支持负权重编码），漏改一处就是静默错数据。
- **建议**：②③ 合并为 `HttpTransport` 内两个私有帮助函数（`sparseCsv`、`toList`）；①让 `HttpTransport.numbers` 直接调 `VectorMath.literal`（同模块，无分层问题）；④⑤ 抽成带参数的单一实现；⑥删除自写 `sqrt`，用 `std.math.sqrt`。

### [轻微][存量] `parse<T>` 的异常消息把整个响应体拼进去，敏感内容会进日志

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:221-227`
- **来源**：存量
- **判据**：review-checklist §10（安全性：敏感数据进日志/异常）、§11（错误处理）
- **证据**：静态确定 —— `throw IllegalStateException('hydra rpc response is not a valid ${text}')`，`text` 是完整响应体（含 `payload`：记忆标题与正文）。
- **描述**：一次协议不匹配就能把整条记忆（可能是隐私数据）写进日志，且消息长度无上限；排障真正需要的只是「哪个 method、响应前 N 字节」。
- **建议**：消息改为 `'hydra rpc response is not a valid ${method} response'`，需要时附 `text.size` 与前 128 字节的截断预览（截断处加 `…`），`method` 由 `call` 传入 `parse`。

### [轻微][存量] `CrossBackendConformance_test` 重复 import 同一批包

- **位置**：`f_llm/src/store/it/CrossBackendConformance_test.cj:19-20` 与 `:29-30`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import / 冗余声明）
- **证据**：静态确定 —— `import fountain::f_llm.store.postgres.*` 与 `import fountain::f_llm.store.mysql.*` 在文件内出现两次，内容完全一致。
- **描述**：可能触发重复 import 告警，也让读者以为两段 import 有区别。
- **建议**：删除第二处两行。

### [轻微][存量] `Stores.DEFAULT_CONTENT` / `DEFAULT_META` 与 `StoreSettings` 的同名常量值冲突

- **位置**：`f_llm/src/store/Stores.cj:29-32`（`'postgres'`/`'postgres'`）vs `f_llm/src/store/StoreSettings.cj:39-40`（`'f_hydra'`/`'f_store'`）
- **来源**：存量
- **判据**：review-checklist §11（与规格/文档冲突：默认值两处定义不一致）
- **证据**：静态确定 —— 这两个常量全仓零引用（`StoreSettings.cj:72-74` 与 `doc/f_llm.md`、`README.md:768` 用的是 `StoreSettings` 那一组）；`Stores` 是 `public class`，成员对外可达，**不判死代码**。
- **描述**：下游若照 `Stores.DEFAULT_CONTENT` 写死默认值，会得到与 README 相反的结果（`postgres` 需要真库，无库部署直接启动失败）。与文档部分（part1 对 `README.md:764-765` 的核对）同源，合并时请去重保留一条。
- **建议**：删除这两个常量，或改成 `public static const DEFAULT_CONTENT = StoreSettings.DEFAULT_CONTENT`，让默认值只有一处定义。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下全部**无改前基线**，因此只作方案登记，不进修复清单。

### [堆内存] `HttpTransport.esc()` 的三次字符串/字节复制

- **现状**：每次拼 param 都对每个字符串做 `text.toArray()`（1 份 `Array<Byte>`）→ `ArrayList<Byte>`（扩容多次）→ `out.toArray()`（再 1 份）→ `String.fromUtf8`（再 1 份）；一条记忆的 payload 含标题+正文+时间+namespace，`upsert` 里还会对 `collection`/`id` 各做一次，单次写请求产生 4 份以上等价字节。
- **方案**：改用 `StringBuilder` 逐字符/逐字节追加（`std` 的 `StringBuilder` 语义先用 `cangjie-doc-lookup` 核对），只对 `<0x20` 与 `"`/`\` 分支处理，避免 `toArray()`。
- **预期**：单次请求的临时字节对象从 3~4 份降到 1 份；峰值内存收益与 payload 长度成正比。
- **代价**：需逐字节比较 UTF-8 序列，代码比现在长；正确性风险集中在多字节字符边界（现有注释已说明这个坑）。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10k 次 upsert（payload 1KB/10KB 两档）+ RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 复用 `HttpClient` 而不是每次 RPC 新建

- **现状**：`call()`（`HttpTransport.cj:193-219`）每次调用 `HttpClient(url)` + 三个 `header` + `tlsConfig`，用完 `resource(client)` 关闭；`upsert`/`get`/`search*`/`ids*` 每个都是一次 `call`，检索路径是 N+1 次 `call`。
- **方案**：把 client 提升为 `HttpTransport` 的 `private let`（构造期建一次，随 transport 生命周期），或按 URL 做进程级缓存；`HttpTransport` 已是长生命周期对象（`HydraContentStore` 持有）。
- **预期**：省掉每次 RPC 的建连/TLS 握手与对象构造；对 20 次往返的检索收益明显。
- **代价**：`HttpClient` 是否线程安全、是否能跨请求复用需先查 `f_httpclient` 文档；单例 client 需要处理连接失效重连。
- **验证**：`cjprof record` 对 `hydra.search` 场景（候选 20、10k 次循环）取 self time 占比，改前/改后同机同输入。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `HydraKnowledgeStore.search` 的选择排序与逐候选 `get`

- **现状**：`ContentStore.cj:176-195` 对 `ranked`（dense 200 + sparse 200，去重后 ≤400）做完整选择排序 O(n²)（160k 次 `HashMap.get`），只为取前 `limit*4`；`:204-226` 再对候选逐条 `transport.get` 取正文。
- **方案**：改为「一次遍历维护大小为 `bound` 的最小堆」；正文读取按 `bound` 批量（若 fhydra 提供 `hydra.getBatch` 则一次往返，否则至少把 `bound` 收紧到 `limit*2` 并记录命中率）。
- **预期**：排序比较次数从 ~160k 降到 ~400·log(20)；远程往返从 `limit*4` 降到可配。
- **代价**：堆实现代码量增加，需要等价性用例（分数相同时候选顺序、`docIds` 过滤后的填充率）。
- **验证**：`cjpm bench` 同输入（400 候选、limit=5），中位数 + P95 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `nextId()` 的双 RPC → 本地区间缓存

- **现状**：每次 `upsert` 至少 3 次 `transport` 调用：`get(seq)` + `upsert(seq)` + 记录写 + `map` 写（远程 4 次往返）。id 只是单调计数，业务不要求连续。
- **方案**：一次 `get` 后本地预取 `[N+1, N+K]`（把 `seq+K` 写回），进程内用 `Atomic` 分配区间；`K` 可配（默认 64），进程重启浪费至多 K 个 id。
- **预期**：写路径远程往返从 4 次降到 3 次（摊薄后接近 2 次）。
- **代价**：id 不连续、进程崩溃浪费区间；跨进程仍不唯一（不能替代上文的互斥/CAS 修复）。
- **验证**：写路径分段计时（`seq` 读取 / 记录写 / map 写 三段），1k 次 upsert。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次 RPC 新建 `HttpClient` 的建连开销是远程检索的主要成本 | `f_llm/src/store/hydra/HttpTransport.cj:198` | 建连+握手在单次调用中的耗时占比 | 分段计时（client 构造 / post / readEntire），`hydra.search` 20 候选，跑 1000 次取中位数 |
| 2 | `HydraKnowledgeStore.search` 的选择排序 + 逐候选 `get` 占检索自耗时较高比例 | `f_llm/src/store/hydra/ContentStore.cj:176-226` | self time 占比、候选实际分布 | `cjprof record` 跑 400 候选 / limit=5 场景 |
| 3 | `nextId()` 的两次往返在写路径中占比可观 | `f_llm/src/store/hydra/MemoryRepository.cj:254-263` | 两段耗时占比 | 写路径分段计时，1k 次 upsert（远程 transport） |
| 4 | `esc()`/`numbers()` 的拼接分配是长 payload 写路径的主要分配来源 | `f_llm/src/store/hydra/HttpTransport.cj:229-275` | 单次写分配字节数、GC 次数 | `getAllocatedHeapSize()` + GC 计数，payload 1KB/10KB 对照 |
| 5 | 同进程多个 `FStoreVectorStore` 指向同一目录是否安全（是否加锁/是否会写坏） | `f_llm/src/store/Stores.cj:68-97` → `ContentStore.cj:35` | `f_store.Store` 的并发/多实例语义 | 读 `f_store` 的 `Store.open` 实现 + 多线程压测同一目录（20 线程 × 100 写）后校验 `recover()` 结果 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/store/Stores.cj` | .cj | ✅ | 注册表/工厂，见「一般」#7、#8；`DEFAULT_CONTENT` 冲突见轻微 #18 |
| 2 | `f_llm/src/store/Stores_test.cj` | .cj | ✅ | 4 个用例覆盖未知值报错与配置选择；测试替身抛异常属刻意 |
| 3 | `f_llm/src/store/VectorMath.cj` | .cj | ✅ | `literal`/`cosine` 正确；`sqrt` 与 `std.math` 重复见轻微 #15 |
| 4 | `f_llm/src/store/hydra/ContentStore.cj` | .cj | ✅ | 见「严重」#2、「一般」#7、#10、#11 |
| 5 | `f_llm/src/store/hydra/EvolutionLease.cj` | .cj | ✅ | `ensure` 的 `now` 未用/写后不校验，见轻微 #13 |
| 6 | `f_llm/src/store/hydra/HttpTransport.cj` | .cj | ✅ | 见「严重」#2、「一般」#6、#9、「轻微」#16 |
| 7 | `f_llm/src/store/hydra/HydraRemote_test.cj` | .cj | ✅ | 远程一致性用例，无显式配置即 SKIP；未覆盖 `listByKind`/colbert（与 #2 相关） |
| 8 | `f_llm/src/store/hydra/MemoryRepository.cj` | .cj | ✅ | 见「严重」#1、「一般」#3、#4、#5、#10、#12 |
| 9 | `f_llm/src/store/hydra/MemoryRepository_test.cj` | .cj | ✅ | 覆盖 upsert/get/list/listByKind/search/colbert/remove；`testColbertRoundtrip` 只断言 content |
| 10 | `f_llm/src/store/hydra/Transport.cj` | .cj | ✅ | 接口与进程内实现，纯转发，无逻辑 |
| 11 | `f_llm/src/store/it/BeanCondition_test.cj` | .cj | ✅ | `ConfCond` 过滤与 `lookupOption` 优先级，逻辑自洽 |
| 12 | `f_llm/src/store/it/ContentStoreAdapter_test.cj` | .cj | ✅ | 只断言类型，不清理 `Config` |
| 13 | `f_llm/src/store/it/CrossBackendConformance_test.cj` | .cj | ✅ | 重复 import 见轻微 #17；PG/MySQL 不可达时 SKIP |
| 14 | `f_llm/src/store/it/EvolutionStoreIT_test.cj` | .cj | ✅ | 覆盖 PG/MySQL 租约与状态表；未覆盖 `HydraEvolutionLease`（覆盖缺口，见总评） |
| 15 | `f_llm/src/store/it/KindPersistence_test.cj` | .cj | ✅ | 补种幂等 + 自定义 kind 重载；`MemoryKinds.resetForTest()` 留在全局状态 |
| 16 | `f_llm/src/store/it/KnowledgeConformance_test.cj` | .cj | ✅ | 三实现共用断言；`FixedEmbedder` 用于验证向量通道 |
| 17 | `f_llm/src/store/it/LoomStore_test.cj` | .cj | ✅ | 只把「连不上」当 SKIP，断言失败会暴露（写法正确） |
| 18 | `f_llm/src/store/it/MetaConformance_test.cj` | .cj | ✅ | f_store/PG/MySQL 三路；PG 侧只 DELETE 依赖既有表 |
| 19 | `f_llm/src/store/it/MetaStoreAdapter_test.cj` | .cj | ✅ | 分支可用 + 未知值抛错，两例均清理配置 |
| 20 | `f_llm/src/store/it/StoreWiring_test.cj` | .cj | ✅ | 注册表重建/未知值失败；部分用例不回滚 `llm_memoryStore` |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分不含 `.md` 文件）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 18 | 全部 18 条发现都落在这五个维度内：正确性/契约 8 条（#1–#6、#10、#11）、设计 2 条（#7、#8）、安全性 2 条（#9、#16）、可读性/可维护性 6 条（#12–#15、#17、#18）；语言特性方面核对了 `Option` 的 `match` 穷尽性、`var`/`let` 语义、`Mutex`+`synchronized` 用法、`ArrayList` 与 `Array` 的拷贝语义 |
| §1 死代码 | 3 | 逐符号搜过：`private` 成员 25 个（`Stores` 3、`VectorMath` 2 含 `private init`、`ContentStore` 3、`MemoryRepository` 9、`HttpTransport` 6、`EvolutionLease` 2）全有调用者；`protected` 0 个；非 public 顶层类型（`HydraTransport`/`InProcessTransport`/`HydraKnowledgeStore`/`VectorCodecLike`/`HydraLeaseBox`/DTO 10 个/`SeqBox`/`FixedEmbedder`）的 `public` 成员均为包内使用或接口实现，无死代码；`return` 后无同层语句；命中 3 条弱形态：`colbert()` 恒等 `match`（#4）、`decode` 不读 `parts[3]`（#5）、`ensure(now)` 的 `now` 未使用（#13） |
| §2 重复逻辑 | 7 | 函数体两两比对后命中：`HttpTransport.numbers` ≡ `VectorMath.literal`、`upsert` 与 `searchSparse` 的 tokenIds/weights CSV 拼接、`ids`/`idsFiltered` 尾部列表拷贝、`Stores.contentNames` ≡ `metaNames`、`list` ≡ `listByKind`、自定义 `sqrt` ≡ `std.math.sqrt`（均见 #15），以及 `kindWanted`+`collect` 对同一记录两次 `get`（#12） |
| §3 空实现 | 1 | 无 `TODO`/空函数体/`throw UnsupportedException`；`catch {}` 仅出现在测试替身（`FakeContentStore` 等按契约抛错，非空实现）；远程 `colbert`/`filters` 的静默丢弃计入 #2（契约承诺但实现为空） |
| §4 栈溢出 | 0 | 全部函数无递归（`VectorMath.sqrt` 是定长 30 次循环）；`KnowledgeChunker`/`FlowPlan` 等递归候选不在本部分 |
| §5 OOM | 1 | 搜索候选被 200+200 上限约束，无全局无界容器；命中一条：`Stores` 无实例缓存导致同目录句柄随调用增长（#8），并在待验证假设 #5 记 f_store 多实例风险 |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据；`esc`/选择排序/`nextId` 三项只进「优化方案」与「待验证假设」 |
| §6.2 大粒度锁 | 0 | `HydraEvolutionLease` 的 `Mutex` 内只有 1 次 `get` + 条件 `upsert`（远程下是 I/O，`EvolutionLease.cj:59-68`、`:82-92`），已单独记为「锁内 I/O」候选 → 见 §12 行说明；本部分其余路径无锁 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`；`EvolutionLease` 是单值串行更新，无批处理语义 |
| §6.4 低效算法 | 1 | `HydraKnowledgeStore.search` 选择排序 O(n²) + 逐候选 `get`（候选 ≤400，未测占比 → 只进优化方案）；`rank` 的插入排序有界（≤ namespaces×limit）不计 |
| §7 降堆内存方案 | 1 | `esc` 三次复制（无基线）；local mode 收益无法用峰值内存证明，未展开 |
| §8 降 CPU 方案 | 3 | client 复用、选择排序→堆、`nextId` 区间缓存（全部无基线） |
| §9 local mode 可行性 | 0 | 本部分唯一候选是 `esc` 的临时 `ArrayList<Byte>`（函数内创建、不逃逸），但它是逐请求短生命周期小对象且缺少峰值内存对照；按 §9 约束只能记「待验证假设」（#4），不成方案 |
| §11 现有代码的 BUG（存量） | 11 | 本轮读到的 20 个文件全部按边界/空值/错误处理/资源/并发/契约过了一遍，命中 #1–#6、#10–#13、#18；测试侧另记 `StoreWiring_test` 用例不回滚 `llm_memoryStore`、`KindPersistence_test` 遗留 `MemoryKinds.resetForTest()` 的全局状态（只记录，不单列） |
| §12 并发安全与锁粒度 | 5 | 共享路径：`Stores` 静态表（#7）、`HydraContentStore` 缓存（#7）、`nextId` 复合写（#1）、`HydraKnowledgeStore.upsert` 非原子（#11）、`kindWanted` 双读（#12）；`HydraEvolutionLease` 的单实例 `Mutex` 内包含远程 I/O（`acquire` 3 次往返），因 `EvolutionLeases.byName` 每次新建实例、互斥只对单实例有效，跨实例靠写后读校验（已能收敛，不判缺陷），故本行不计入命中 |
| §14 功能完备性与 README 覆盖 | 1 | `doc/content-store.md:9-10` 把 `fhydra` 与 `f_hydra` 并列承诺同一套 `MemoryStore`/`KnowledgeStore` 语义，但远程实现丢 `filters`/`colbert` → 计入 #2；本部分无 `.md`，README 覆盖核对留给文档部分 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.cj` 全部读完；本部分无 `.md`，故 §13 文档一致性不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

## 总评

本部分（`store` 层 hydra 客户端 + 集成测试）的主要风险集中在**远程/并发两条路径**：

1. **阻塞项**：`nextId()` 的读-改-写没有互斥（#1），并发写入会重复 id 并静默覆盖已存记忆 —— 这是数据正确性问题，默认配置（`f_hydra`）就命中，应先修。`HttpTransport.upsert` 的字段投影缺失（#2）让 `fhydra` 远程部署下的 `listByKind` 恒空、colbert 重排静默失效，属于「文档承诺了、实现丢了」的契约缺口，同样建议在本次门禁内处理（fhydra 侧 `UpsertParam` 缺 colbert 字段，需两侧一起改）。
2. **可排期**：`upsert` 不按唯一键覆盖（#3）、`saveTime` 丢读（#5）、`"error"` 子串误判（#6）、TLS `TrustAll`（#9）、分隔符无转义（#10）、知识库 upsert 非原子（#11）都是确定性缺陷但触发条件较窄（特定配置、特定输入字符、特定部署形态）；`colbert()` 恒空 title（#4）只影响重排精度。
3. **测试质量**：集成用例的「只把连不上当 SKIP」写法（`LoomStore_test.cj:49-52` 的注释与实现）是正确的，值得在其余 IT 中推广；但 `HydraEvolutionLease` 完全没有 IT 覆盖（`EvolutionStoreIT_test.cj` 只跑 PG/MySQL 两个实现），`HydraRemote_test` 也没覆盖 `listByKind` 与 colbert —— 正好是 #2 这类缺陷的盲区，补两个用例的成本很低。
4. 代码整体风格统一（注册表 + 工厂 + 接口 + 契约注释齐全，注释里写明「为什么」的比例高于模块平均），重复逻辑不多且都是可合并的小块（#15），死代码只有 3 条弱形态。

**存量 18 条（严重 2 / 一般 10 / 轻微 6），是否纳入修复待用户决定；本次未改动任何源码。**

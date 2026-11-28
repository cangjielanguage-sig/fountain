# f_hydra 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_hydra`（9 个 `.cj` + 5 个 `.md`，共 14 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，`git status --porcelain f_hydra` 为空，无 diff 可比 → 所有问题来源记「存量」）
- **审查重点**：契约完整性、空实现、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] `upsert` 覆盖写不清理旧命名 dense 与 `vf:` 名单，`get` / `searchDenseField` 返回上一版本向量

- **位置**：`f_hydra/src/FStoreVectorStore.cj:57`（upsert 清理段 61–63、命名向量写入段 68–79）、`f_hydra/src/FStoreVectorStore.cj:111`（get 回读）、`f_hydra/src/FStoreVectorStore.cj:192`（searchDenseField → bruteForceField 读 `v:f:` 前缀）
- **来源**：存量（`git blame -L 57,64` 指向 `f97cebe50b 2026-10-31` / `b5cea9fd82 2026-10-31`；工作区无改动）
- **判据**：review-checklist §11（契约与实现不符：`upsert` 声明按 id 幂等覆盖）+ §14.1（承诺了但没实现）
- **证据**：静态确定 —— `upsert` 只清 `deletePostings` / `deleteColbertParts` / `deleteFilterEntries` 三类（61–63），**没有** `deleteFieldVectors`；`fieldMetaKey` 仅在 `names` 非空时写入（77–79），旧 `vf:{id}` 因此保留；`get` 先读 `vf:{id}` 名单再逐个读 `v:f:{name}:{id}`（111–123），旧向量仍存在 → 原样返回。`remove`（142）与 `purgeRecord`（848）都调了 `deleteFieldVectors`，证明这是 upsert 漏掉的一步。
- **描述**：同一 id 先写 `vectors = {title: v1}`，再写 `vectors = {}`（或只保留 `content`）后：`get` 仍返回 `title: v1`；`searchDenseField(q, 'title')` 仍把该 id 召回并给出旧分数。旧 `v:f:title:{id}` 键永久残留（磁盘与扫描成本双增）。触发条件是"业务侧改了记录，去掉了某个命名向量"，属正常写入序列。
- **建议**：`upsert` 在 `deleteColbertParts` 之后补 `deleteFieldVectors(collection, record.id)`（放在写新 `vectors` 之前）；或把 61–63 的三次删除合并成一个 `deleteDerived(collection, id)`，保证新增派生键不会再次漏清。补一条用例：upsert 带 `title` → upsert 不带 → `get().vectors` 为空且 `searchDenseField(...,'title')` 不再命中。

### [严重][存量] 同一 id 并发 `upsert` 无互斥、跨 8+ 键写非原子，可残留 posting 并读到混合版本

- **位置**：`f_hydra/src/FStoreVectorStore.cj:57`（upsert 全流程）、`f_hydra/src/FStoreVectorStore.cj:96`（get 逐键读）；共享实例路径：`fhydra/src/HydraRpc.cj:35`（`private static let store`，JSON-RPC 处理器并发调用）、`f_llm/src/store/hydra/Transport.cj:47`（`InProcessTransport.store`）
- **来源**：存量（快照无基线；upsert 主体 blame 至 2026-10-31/11-04）
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入、发布逸出）
- **证据**：静态确定 —— `upsert` 是「读旧状态（`deletePostings` 读 `sparseKey`）→ 删 → 写 8 类键 → 写 ready」的复合序列，全模块没有任何锁 / CAS / 按 id 分片；`f_store.Store` 只保证**单键**操作并发安全（`f_store/src/Store.cj:18-21` 注释"关键路径无锁设计"），不提供跨键事务。两个线程写同一 id 时的确定交错：A 删旧 posting → B 删旧 posting（依据仍是旧 `sparseKey`）→ A 写新 posting + 新 `sparseKey` → B 写新 posting + 新 `sparseKey`；最终 `sparseKey` 只剩一方，另一方的 posting 成为永久孤儿（`deletePostings` 只按当前 `sparseKey` 反查，见 1002–1011），检索会对已不存在的 token 命中该 id。
- **描述**：`get`/`searchDenseField` 并发于 `upsert` 时同样可能读到「新 payload + 旧 dense」这类混合版本（逐键读取、无快照）；`ready` 标记无法区分版本，因为覆盖写时它从不清除。同一内存记录被两个请求重复写入是 f_llm 的正常并发形态，不是理论场景。
- **建议**：按 id 加互斥（分片锁 `lockOf(id.hashCode() % N)` 或单写者队列），把「删旧 + 写新 + 写 ready」收进临界区；`ready` 改为写入前先删、最后一步再置位；长临界区内的 `ivf().record`（会做 k 次 `store.get`）移到锁外。另需一条多线程用例：同 id 两线程各写 100 次不同 sparse，结束后 `searchSparse` 对任一 token 的命中集合必须是 0 或 1 条，且与 `get().sparse` 一致。

### [一般][存量] `ids` / `idsFiltered` 每次调用重扫全量并重排，分页与重建退化为 O(n²)/页

- **位置**：`f_hydra/src/FStoreVectorStore.cj:353`（ids：全量收集 358–366、插入排序 368–376、分页 377–382）、`f_hydra/src/FStoreVectorStore.cj:389`（idsFiltered 同构 424–437）、`f_hydra/src/FStoreVectorStore.cj:628`（rebuildFilterEntries 每批调 ids:633）、`f_hydra/src/FStoreVectorStore.cj:441`（exportTo 每批调 ids:446）、`f_hydra/src/FStoreVectorStore.cj:872`（earlier 每次比较 2 次 `store.get`）
- **来源**：存量
- **判据**：review-checklist §6.4（低效算法）+ §11（与文档口径不符）
- **证据**：静态确定（复杂度推导）—— `ids` 先物化全部 id（O(n) 次 `isReady` 点查 → n 次 `store.contains`），再用插入排序（O(n²) 次比较），每次比较经 `earlier`→`saveTimeOf` 触发 **2 次 `store.get`**；排序完成后才应用 `offset`。`rebuildFilterEntries` / `exportTo` 以 `offset += 100` 逐页调用 `ids`，每页重做一遍全量收集与全量排序 ⇒ 全量重建为 O(n³/100) 次比较、约 O(n²) 次点查。绝对耗时待实测，但复杂度上界与 README 的「重建是 O(记录数) 的全量扫描」（`f_hydra/README.md:96`）不一致。
- **描述**：集合到万级时，`ids`/`idsFiltered` 单次分页就会主导请求耗时；`applyFilterFields` 触发的启动重建在十万级数据上基本不可完成，且期间持续占读带宽。
- **建议**：把排序键前置——一次 prefix 扫描产出 `(id, saveTime)` 数组（`saveTime` 来自同一次扫描或一次批量读），排序后只保留 id；分页与重建改为"一次排序 + 游标"，`rebuildFilterEntries` 直接遍历 prefix 而不是调 `ids`。

### [一般][存量] 检索命中全量插入排序后截断，取 top-k 用了 O(n²)

- **位置**：`f_hydra/src/FStoreVectorStore.cj:239`（finalize）、`f_hydra/src/FStoreVectorStore.cj:1068`（sortDesc）、`f_hydra/src/FStoreVectorStore.cj:274`（searchSparse 自行截断）
- **来源**：存量
- **判据**：review-checklist §6.4（每请求排序只为取 top-k）+ §2（274–282 与 finalize 重复）
- **证据**：静态确定 —— `finalize` 先对**全部**命中做插入排序（`hits` 数量 = 集合记录数，暴力扫描路径即 n），再按 `limit` 截断；`searchSparse` 复制了同一段截断逻辑。
- **描述**：n=10k 时约 5×10⁷ 次比较；`limit` 通常只有 10~200，排序的绝大部分工作被丢弃。
- **建议**：维护大小为 `limit` 的最小堆（或部分选择），并在 score 相等时用 id 兜底保证顺序稳定；`searchSparse` 复用同一个 helper。

### [一般][存量] 两阶段写顺序与文档相反：过滤倒排与 IVF 挂桶写在 ready 之后

- **位置**：`f_hydra/src/FStoreVectorStore.cj:89`（写 ready）、`:90`（writeFilterEntries）、`:92`（ivf.record）；文档承诺：`f_hydra/src/FStoreVectorStore.cj:39`、`:42`、`f_hydra/README.md:69`
- **来源**：存量
- **判据**：review-checklist §11（注释/文档承诺 A，实现做 B）+ §13
- **证据**：静态确定 —— 三处文档都写「readiness 是最后一步 / 写序 … 倒排 → ready」，代码在 `ready` 之后才写过滤倒排与 IVF 桶；`recover`（320–334）只按「payload 是否存在 + ready 是否存在」判定，不会补倒排。
- **描述**：崩溃或并发查询落在 90–92 之间时，记录已"就绪"但过滤查询查不到它（`idsFiltered`/`searchDenseField(filters)` 静默漏条），IVF 桶也缺条目；`recover` 判它完整，问题长期留存。README 的"两阶段写"因此只是名义上的。
- **建议**：把 `writeFilterEntries` 与 `ivf().record` 移到 `ready` 之前；或把 ready 改成版本号（`ready:{id}` = 本次写入的 seq），读路径校验版本一致，`recover` 清理版本不匹配的记录。二选一后同步改三处文档。

### [一般][存量] `encodeColbert` 不校验各行维度：行长不一致时越界写或错位编码

- **位置**：`f_hydra/src/VectorCodec.cj:92`（`dim = vectors[0].size` 决定缓冲 95 行，写入循环 98–103 不校验）、调用方 `f_hydra/src/FStoreVectorStore.cj:82`
- **来源**：存量
- **判据**：review-checklist §11（边界/越界）+ §5（按不可信长度预分配）
- **证据**：静态确定 —— 缓冲长度按第 0 行算 `4 + count * dim * 4`；若第 k 行更长，`offset` 会越过缓冲（`bytes[offset] = …` 抛 IndexOutOfBounds）；若更短，后续行整体前移，解码端按 `(size-4)/count/4` 反推 dim 得到错位向量。`VectorRecord.colbert` 是调用方直接构造的（`VectorModels.cj:32`），没有维度约束。
- **描述**：一次 ragged colbert 写入要么让请求抛异常，要么静默写入一份"能解码但数值错位"的 colbert，重排分数全错；`VectorCodec_test` 只覆盖等长行（`VectorCodec_test.cj:58`）。
- **建议**：`encodeColbert` 遍历一次校验 `row.size == dim`，不满足直接抛 `IllegalArgumentException`（比静默错分好）；`encodeColbertParts` 的 `rowBytes` 也应基于校验后的 dim。

### [一般][存量] `idsFiltered` 接口默认实现与 FStore 覆盖实现语义分叉（整值相等 vs 逗号 OR）

- **位置**：`f_hydra/src/VectorStore.cj:74`（默认实现，比较在 91–99）、`f_hydra/src/FStoreVectorStore.cj:755`（覆盖实现按 `,` 拆 OR + trim）、`f_hydra/README.md:72`（只描述 OR 语义）
- **来源**：存量
- **判据**：review-checklist §2（近似重复导致行为漂移）+ §11（契约与实现不符）
- **证据**：静态确定 —— 默认实现对 `record.filters.get(field)` 做整串相等比较，`filters = {tags: "a,b"}` 只匹配值恰为 `a,b` 的记录；覆盖实现把查询值按 `,` 拆成多值 OR 并 `trimAscii`。同一份接口文档（72–75 行"有索引的实现应覆盖成 O(命中数)"）没有说两者语义不同。
- **描述**：任何第三方 `VectorStore` 实现（`f_llm.store.hydra.HttpTransport` 走的是远端同实现，暂无影响）继承默认实现后，同一查询会得到不同结果集；调用方无法从接口判断。
- **建议**：把"逗号即 OR"写进接口注释并让默认实现复用同一套拆分逻辑（抽 `filterMatch(record.filters, filters)` 由两边共用），或把默认实现降级为 `throw UnsupportedException` 迫使实现方显式选择。

### [一般][存量] `sqrt` 用固定 30 次牛顿迭代，极小范数下严重欠收敛导致 cosine 静默失真

- **位置**：`f_hydra/src/VectorMath.cj:42`（迭代 46–50，入口 `guess = value`）、`f_hydra/src/VectorMath.cj:36`（`normA/normB <= 0` 之外无下限保护）
- **来源**：存量
- **判据**：review-checklist §11（数值正确性，语义与命名不符："余弦相似度，范围 [-1,1]"）
- **证据**：静态确定（数学推导）—— 牛顿迭代 `x ← (x + a/x)/2` 从 `x0 = a` 起步，当 `a ≪ 1` 时第一步即落到 ≈0.5，之后每步近似减半，30 步后约 `0.5/2²⁹ ≈ 9.3e-10`。对 `a = 1e-24`（真实 √a = 1e-12）返回 ≈9.3e-10，误差 3 个数量级；`cosine` 的分母被放大 ≈10⁶，结果从 1.0 掉到 ≈1e-6。影响面取决于实际向量量级（归一化 embedding 通常 ≫1e-6，故定为一般而非严重）。
- **描述**：小范数向量（缩放后的 embedding、padding 行、稀疏 fields 的短向量）会得到静默偏低的相似度，排序结果错但无异常、无日志。
- **建议**：改用标准库开方（需先确认当前 SDK 的 `std.math` 提供 `sqrt`，本机文档缺位无法核对）；若坚持自实现，至少改为"收敛判定 + 上限迭代"并给极小值兜底（`a < 1e-300` 直接返回 0），同时补 `a = 1e-24` 的等价用例。

### [一般][存量] `build()` 全量物化全部 dense 向量，无分批/上限；`purgeExpired` / `clear` 全量收集 key

- **位置**：`f_hydra/src/IvfIndex.cj:81`（`loadVectors()` 一次读全库）、`f_hydra/src/IvfIndex.cj:209`（每个向量 `decodeDense` 新建数组）、`f_hydra/src/IvfIndex.cj:100`（每轮再分配 k×dim 的 sums）、`f_hydra/src/FStoreVectorStore.cj:466`（purgeExpired 收集全部 key）、`f_hydra/src/IvfIndex.cj:234`（clear 收集全部 key）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 按不可信长度预分配）
- **证据**：静态确定（结构）+ 量化估算 —— 峰值约 `n × dim × 8 B`（外加每项 24 B 对象头）：10 万 × 1024 维 ≈ 819 MB，100 万 × 1024 维 ≈ 8.2 GB，且 k-means 十轮期间必须全程持有；无分批、无记录数上限、无拒绝路径。`purgeExpired` 对 100 万条记录会把约 100 万个 key 字符串（≈60 MB）同时放进 `ArrayList<String>`。
- **描述**：`buildIndex` 是 RPC 暴露的管理操作（60s 超时），在中等规模集合上就会把进程打到 OOM，而 OOM 前没有任何提示；崩溃后半建的索引靠 cfg 键是否写成来决定回退（写 cfg 在 125 行，簇心随后）。
- **建议**：`build` 改为分块（每次 `prefix` 读 batch 行，`decodeDenseInto` 复用一块缓冲，单趟累加 sum/count 做 mini-batch k-means），或对 `n > 阈值` 直接拒绝并要求显式 `clusters`；`purgeExpired`/`clear` 改成分批删除（边遍历边删不超过 N 个 key 先落盘一次）。

### [一般][存量] IVF 维度不符的记录静默不挂桶，索引下可能永不召回

- **位置**：`f_hydra/src/IvfIndex.cj:141`（`record` 维度不符直接 `return`，无返回值/日志）、`f_hydra/src/IvfIndex.cj:130`（build 里同一跳过）、`f_hydra/src/FStoreVectorStore.cj:168`（"IVF 是优化，不牺牲召回"的注释与 164–166 的早退矛盾）
- **来源**：存量
- **判据**：review-checklist §3（静默失效）+ §11（语义与注释不符）
- **证据**：静态确定 —— `record()` 在 `cfg.dim != vector.size` 时 `return`（无信号），该 id 从此不在任何桶；`searchDenseField` 只要 IVF 候选数 `>= limit` 就早退（164–166），不再走暴力扫描，于是维度不符的记录在"候选充足"时永远不会出现在结果里。README 只写了"候选不足 limit 时回退"（`README.md:73`），没有说维度不符会被永久排除。
- **描述**：换 embedding 模型（768 → 1024）后，旧记录与索引维度不符：新旧混存时，旧记录在 IVF 路径下静默消失，且无任何计数可观测；注释"不牺牲召回"会误导下一位维护者。
- **建议**：`record` 返回 `Bool`/枚举并在 `upsert` 计入 `skippedByDim` 计数器（或至少 `f_log` 一条限流日志）；修正 168 行注释为"IVF 为近似召回，候选充足时不回退"；`build` 对维度不符比例超阈值时拒绝建索引。

### [一般][存量] `loadCentroids` 返回"存在的簇心"紧凑数组，与桶的位置索引错位

- **位置**：`f_hydra/src/IvfIndex.cj:223`（只 append 命中的簇心）、使用处 `:147`（按紧凑下标算 cluster）、`:180`（candidates 同样用紧凑下标读 bucket）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误：数组下标被当作簇 id）
- **证据**：静态确定（索引语义）—— `build` 用 `centroidKey(cluster)` 写满 0..k-1，`loadCentroids` 遇到缺失键就跳过，导致 `centroids[i]` 对应的是"第 i 个存在的簇"，而非簇 `i`；`nearest` 返回的下标随即被当成桶号写/读。
- **描述**：任一簇心键缺失（cfg 写成后、簇心未写完就崩溃；或手工/compaction 丢键）后，增量挂桶与候选读取都指向错误桶：召回错乱但 `ready` 校验仍通过，表现为"某些记录查不到"，无异常。触发条件需要簇心缺失（待确认生产是否有该状态）。
- **建议**：`loadCentroids` 返回 `ArrayList<?(dim,centroid)>` 或保留占位（`None` 站位），`nearest` 跳过 `None` 且返回真实簇号；或在 `config()` 里校验簇心数量与 `cfg.clusters` 一致，不一致直接判定索引失效（返回 0 簇，走暴力扫描）。

### [一般][存量] 损坏数据的解码路径抛异常，异常逸出前缀迭代时不关闭 `PrefixIterator`

- **位置**：`f_hydra/src/FStoreVectorStore.cj:1038`（`Int64.parse` / `Float64.parse`）、`:263`（`Float64.parse`，位于 `store.prefix` 循环内 260–266）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 资源不对称）
- **证据**：静态确定 —— `decodeSparse` 用 `parse` 而非 `tryParse`，单条 value 格式损坏（截断写、手工改库、旧版本格式）即抛 `IllegalArgumentException`；该异常从 `for ((key, value) in store.prefix(...))` 内部逸出，循环体内没有 `try (iter = store.prefix(...))`，`PrefixIterator`（`<: Resource`，持有各 SSTable 独立 File 句柄，见 `f_store/src/PrefixIterator.cj:23`、`f_store/src/Store.cj:199`）不会被 `close()`，句柄泄漏到下次 GC/进程结束。
- **描述**：一条坏记录就能让整次 `searchSparse`/`get` 失败（RPC 500），并在反复重试时持续泄漏文件句柄；`pair.size != 2` 的坏值则被静默丢弃（1037），两种处理不一致。
- **建议**：改用 `tryParse` 并计数/日志跳过坏条目；`store.prefix` 的全部遍历点改成 `try (iter = store.prefix(...)) { … }`（或用 while + `defer` 关闭），保证异常路径也释放。

### [一般][存量] 公共 API 入参未校验：`offset < 0` 触发越界，`clusters < 0` 静默按自动处理

- **位置**：`f_hydra/src/FStoreVectorStore.cj:377`（`var index = offset` → `all[offset]`）、`:433`（idsFiltered 同构）、`f_hydra/src/VectorStore.cj:112`（接口默认实现同构）、`f_hydra/src/FStoreVectorStore.cj:177`（`buildIndex(collection)` 传 0）、`f_hydra/src/IvfIndex.cj:87`（`requested > 0` 之外负数走自动）
- **来源**：存量
- **判据**：review-checklist §11（边界/空值）+ §10（外部输入未校验）
- **证据**：静态确定（可达路径）—— `fhydra/src/HydraRpc.cj:138-147` 把 `param.offset` 原样传给 `ids`/`idsFiltered`，未做下界校验；`all[-1]` 抛 IndexOutOfBounds。`limit <= 0` 有短路（355、392），`offset` 没有。
- **描述**：负 offset 从 RPC 传进来即抛异常（请求级失败）；`buildIndex(clusters: -5)` 被当作"自动估算"而不报错，与"0 表示自动"的隐含约定不一致，调用方无法发现参数写错。
- **建议**：`offset < 0` 归一为 0 或抛 `IllegalArgumentException`（并在 `VectorStore` 注释写明）；`clusters < 0` 明确拒绝；`HydraRpc` 侧补 `offset >= 0` 的 BAD_PARAMS 校验。

### [一般][存量] TTL 契约自相矛盾（`<= 0` 立即过期 与 `< 0` 取消），实现取后者

- **位置**：`f_hydra/src/VectorStore.cj:57`、`f_hydra/README.md:35`、`f_hydra/README_en.md:35`；实现 `f_hydra/src/FStoreVectorStore.cj:336`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致 / 关键段落写错）
- **证据**：静态确定 —— 文档同一句里既说"`seconds <= 0` 表示立即过期"又说"`< 0` 表示取消 TTL"，两者对负数给出相反语义；实现是 `seconds < 0` → 删除 ttl 键（取消）、`seconds == 0` → 立即过期。
- **描述**：按"<=0 立即过期"调用的调用方传 -1 会得到"取消 TTL"，已过期数据重新可见（数据保留期被静默延长），属于安全相关语义陷阱；`README_en.md` 同样句式，两版同步错。
- **建议**：文档改成"`0` 立即过期，`< 0` 取消 TTL"，并在 `VectorStore.setTtl` 注释里写明负值含义；考虑把"立即过期"独立成 `expireNow()` 避免 0/-1 靠记忆区分。

### [一般][存量] README 公开 API 覆盖有缺口

- **位置**：`f_hydra/README.md:117`（"其他公开 API"清单）、`:121`（模块级清单）
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化 / 索引未登记）
- **证据**：静态确定 —— 以下 public 声明在 `README.md` / `README_en.md` 全文检索不到：`FStoreVectorStore.filterFields`（`FStoreVectorStore.cj:506`）、`IvfConfig`（`IvfIndex.cj:24`，模块级清单 121 行也漏了它）、`VectorCodec.DEFAULT_PART_BYTES`（`VectorCodec.cj:40`）、`FStoreVectorStore.buildIndex(collection)` 单参重载（`:177`）；`VectorStore.idsFiltered` 只出现在"FStoreVectorStore"分组（122 行），接口成员本身未列。
- **描述**：`filterFields()` 是读取当前白名单的唯一手段、`DEFAULT_PART_BYTES` 是分片阈值、`IvfConfig` 是唯一"索引元数据"类型，使用者只能读源码；`buildIndex` 两个重载在 API 代码块里只展示带 `clusters!` 的一个。
- **建议**：在 121–126 的清单里补齐上述符号（`IvfConfig` 若确认只供内部使用，先按下面"可见性建议"收窄，再决定是否写文档）。

### [轻微][存量] 手写插入排序与 limit 截断在 5 处复制

- **位置**：`f_hydra/src/FStoreVectorStore.cj:368`、`:424`、`:974`（readColbert 按 part 号排）、`:1068`（sortDesc）、`f_hydra/src/IvfIndex.cj:323`（sortClusters）；截断：`:239`（finalize）与 `:274`
- **来源**：存量
- **判据**：review-checklist §2（只改比较器的复制）
- **证据**：静态确定 —— 五段插入排序骨架逐行一致，只有比较表达式不同；finalize 与 searchSparse 的"排序 + 取前 limit"也是两份。
- **描述**：`readColbert`/`sortClusters` 的规模有界（分片数、簇数），保留内联不算问题；但前四处一旦要换成堆/稳定排序，需要同步改 4 份，容易漂移（例如 tie-break 只在其中一份加了 id 比较）。
- **建议**：抽一个 `internal func insertionSortBy<T>(items: ArrayList<T>, less: (T, T) -> Bool)` 与 `topK`，`ids`/`idsFiltered`/`sortDesc` 共用；有界的小数组可继续内联并注明"规模有界"。

### [轻微][存量] `sqrt` 在两处完全相同的私有实现

- **位置**：`f_hydra/src/VectorMath.cj:42`、`f_hydra/src/IvfIndex.cj:312`
- **来源**：存量
- **判据**：review-checklist §2（函数体逐行对齐，仅可见性不同）
- **证据**：静态确定 —— 两段实现 10 行逐字相同（`value <= 0` 返回 0、`guess = value`、30 轮牛顿迭代）；`IvfIndex` 无法调 `VectorMath.sqrt`（private），于是复制。
- **描述**：上面"欠收敛"缺陷要修时两处必须同时改，漏一处会让 `buildIndex` 的 k 估算与检索相似度使用不同精度。
- **建议**：`VectorMath.sqrt` 改为 `internal static`，`IvfIndex` 直接调用；或抽取到包内 `HydraMath`。（另注：`f_llm/src/store/VectorMath.cj:62` 还有第三份相同实现，属范围外，见"范围外提示"。）

### [轻微][存量] doc 注释错位：`rebuildFilterEntries` 的说明挂到了 `applyFilterFields` 上

- **位置**：`f_hydra/src/FStoreVectorStore.cj:537`（第一段注释 537–541 描述 rebuildFilterEntries）、`:547`（applyFilterFields 的实际注释 542–546）、`:628`（rebuildFilterEntries 无任何注释）
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 必要注释）
- **证据**：静态确定 —— 537–541 与 542–546 是两个连续 `/** */` 块，编译器只把最后一块绑定到 `applyFilterFields`；`rebuildFilterEntries` 这个 public 方法（被 `fhydra` 与 README 引用）反而没有文档。
- **建议**：把 537–541 移到 `rebuildFilterEntries` 定义（628 行）上方。

### [轻微][存量] `purgeExpired` 不清理集合登记 `hc:`，`collections()` 会一直返回已删除集合

- **位置**：`f_hydra/src/FStoreVectorStore.cj:470`（按 `h:{collection}:` 前缀删除）、`:796`（登记键 `hc:{collection}`）、`:578`（collections 枚举）
- **来源**：存量
- **判据**：review-checklist §11（状态不对称 / 清理不完整）
- **证据**：静态确定 —— `hc:` 前缀不在 `h:{collection}:` 之下，purge 后登记残留；此后 `applyFilterFields` 变更白名单会对已清空的集合再跑一遍 `rebuildFilterEntries`（空转），`collections()` 也不再反映真实集合。
- **建议**：`purgeExpired` 末尾 `store.remove(collectionKey(collection))`；补一条"purge 后 collections() 不含该集合"的用例。

### [轻微][存量] 测试里 `pathSeq++` 绕过互斥锁，与并行用例竞争

- **位置**：`f_hydra/src/FStoreVectorStore_test.cj:443`、`:455`、`:620`（直接 `pathSeq++`）；对照 `:29`（`pathSeqMutex`）与 `:35`（`newPath` 在锁内自增）、`:28` 注释"用例并行执行：计数器必须加锁"
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）
- **证据**：静态确定 —— 三处绕过锁自增 `Long` 全局变量，与其它用例的 `newPath()` 并发执行；注释自己就说明了不加锁会拿到同一目录。
- **描述**：并行执行时可能生成重复目录（`/tmp/fhydra-partial-${pathSeq}`），导致用例互相污染或偶发失败；测试失败会被误读为被测代码问题。
- **建议**：抽 `private func nextSeq(): Int64`（锁内自增）供测试使用，删掉三处裸自增。

### [轻微][存量] README 测试数量过期（写 37/37，实际 50 个用例）

- **位置**：`f_hydra/README.md:12`、`f_hydra/README_en.md:12`
- **来源**：存量
- **判据**：review-checklist §13（文档过期）
- **证据**：静态确定 —— `@TestCase` 计数：`FStoreVectorStore_test.cj` 38 + `VectorCodecReuse_test.cj` 7 + `VectorCodec_test.cj` 5 = 50（其中 1 个 bench 用例默认跳过，仍计为用例）。
- **建议**：改为"50/50（含 1 个 `F_HYDRA_BENCH=1` 才跑的分配基准）"，或删掉具体数字避免再过期。

### [轻微][存量] `doc/spec` 的基准口径与落地实现不一致

- **位置**：`f_hydra/doc/spec/reuse-f-hydra-dense-decode/tasks.md:16`（"768 维 × 256 候选 × 200 轮"）、`design.md:41`（D4 同口径、"断言 ≤ 旧路径 1/8"）、实现 `f_hydra/src/VectorCodecReuse_test.cj:97`（dim 768、rounds 2000、无候选循环、只断言"差值 ≥ 一半"）
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移；该目录非归档，任务已 [x]）
- **证据**：静态确定 —— 轮数 200 vs 2000、有无"256 候选"维度、断言阈值 1/8 vs 1/2 三处不一致；`design.md:53` 的实测记录（2000 次）对应的是实现口径，不是 D4 写的口径。
- **建议**：按实现回写 D4 与任务 3.1（或补一个真正的 256 候选循环基准），避免下一轮按错口径复测。

### [轻微][存量] 可见性建议：`IvfConfig` 对外不可达

- **位置**：`f_hydra/src/IvfIndex.cj:24`（`public class IvfConfig`）、唯一产出者 `f_hydra/src/IvfIndex.cj:60`（`class IvfIndex` 为包内可见）
- **来源**：存量
- **判据**：review-checklist §1 硬原则一备注（对外可达的 public 不算死代码，但可提可见性建议）
- **证据**：静态确定 —— 全仓无 `IvfConfig` 引用（除自身定义与 `IvfIndex.config()`）；外部只能自行 `IvfConfig(dim, clusters)` 构造一个拿不到来源的对象。**不算死代码**，仅建议收窄。
- **建议**：改为 `internal class IvfConfig`（或并入 `IvfIndex` 的私有字段），确认无下游依赖后再动；若打算对外暴露索引元数据，则应在 `VectorStore` 增加 `indexConfig()` 并写进 README。

## 优化可行性方案

> 下列均非缺陷；性能/内存收益一律需要改前基线 + 改后对照，当前一律 `无基线（待验证）`。

### [CPU] 用 top-k 选择替代全量插入排序

- **现状**：`finalize`（`FStoreVectorStore.cj:239`）对全部命中（= 集合记录数）做插入排序，比较次数 O(n²)，随后只保留 `limit` 条；`searchSparse:274` 同样。`limit` 通常 10–200。
- **方案**：维护大小 `limit` 的最小堆（score 相等时按 id 升序兜底），扫描完一次输出；`ids`/`idsFiltered` 的排序改为"一次收集 `(id, saveTime)` + 一次标准排序"，不再每次比较回读 store。
- **预期**：排序比较次数从 O(n²) 降到 O(n log k)；`ids` 的 `store.get` 次数从 O(n²) 降到 O(n)。端到端收益取决于排序在请求耗时中的占比（未测）。
- **代价**：排序稳定性/并列顺序需要固定 tie-break；`ids` 需要额外一份 `(id, Int64)` 数组（n × 16 B）。
- **验证**：`cjpm bench -O2`，集合 1k/10k/100k，`limit=10/100`，记录 p50/p95 与结果集是否逐条一致（顺序按 (score desc, id asc) 固定）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 相似度计算去掉 2×30 次牛顿迭代

- **现状**：`VectorMath.cosine` 每次调用 2 次 `sqrt`，每次 `sqrt` 固定 30 轮除法（`VectorMath.cj:46-50`）；暴力检索 n 条 → 60n 次除法，colbert 重排 `|q|×|doc|` 次 cosine（32×96 候选即约 18 万次除法/候选）。
- **方案**：改用标准库开方（先核对 SDK 是否提供）；退路是"收敛判定 + 最多 6 轮"，并对 `a < 1e-300` 直接返回 0。
- **预期**：单次 cosine 的除法从 60 次降到 1–6 次；实际收益取决于 cosine 自耗时占比（未测）。
- **代价**：精度行为变化（见"欠收敛"缺陷）；若标准库不可用则引入新依赖判断。
- **验证**：`cjprof record` 看 `VectorMath.cosine`/`sqrt` 自耗时占比；`cjpm bench -O2` 同输入对照；等价性用 `|Δscore| < 1e-9` 断言（对既有测试集）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 减少全量扫描中的点查次数

- **现状**：`bruteForceField`（196–207）对每条 dense 记录额外做 1 次 `isReady`（`store.contains`）+ 1 次 `payloadOf`（`store.get`）= 每条 3 次点查；`ids`/`count` 除 prefix 扫描外每条 1 次 `contains`；`get` 一次调用 8 次以上点查（payload/dense/sparse/vf/字段/time/colbert×p/fl）。
- **方案**：暴力扫描改为只遍历 payload 前缀（`h:{c}:d:`）作为"记录存在"的判据，把 `ready` 校验合并进同一次前缀比对（或在 payload 前缀上携带就绪位），`payload` 直接用迭代器返回的 value，省掉 `payloadOf` 点查；`get` 的 `vf`/`time`/`fl` 可合并成一条 meta value。
- **预期**：检索每记录点查 3 → 1；`get` 点查 8 → 3 左右。端到端收益需 profile 确认。
- **代价**：改写入格式（新增 meta 合并键）需要迁移或双写；`ready` 语义从独立键变为 payload 前缀的一部分，`recover` 判定要同步改。
- **验证**：`cjprof record` 统计 `LevelManager.get`/`MemTable.get` 调用次数与自耗时；`cjpm bench -O2` 跑 10k 条检索对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `build()` 分块训练，避免全库向量常驻

- **现状**：`IvfIndex.loadVectors`（209–221）把所有 dense 解码成 `Array<Float64>` 后全量持有，峰值 ≈ n×dim×8 B（10 万×1024 ≈ 819 MB），十轮 k-means 期间不释放；另每轮分配 k×dim 的 `sums`。
- **方案**：mini-batch / 单趟累加：每次 `prefix` 读 batch（如 4096 行），用一块 `decodeDenseInto` 缓冲，直接累加到 `sums[nearest]`，不保留全量数组；第二轮再把 `(id → cluster)` 边算边写桶。
- **预期**：峰值从 O(n×dim×8) 降到 O(batch×dim×8 + k×dim×8)，1M×1024 维场景从 ≈8 GB 降到几十 MB 量级（未实测）。
- **代价**：k-means 需要两遍扫描（I/O 增加，训练变慢）；mini-batch 版簇心与全量版不完全一致（需接受或增加轮数）。
- **验证**：`F_HYDRA_BENCH` 之外新增 RSS/heapUsed 采样脚本：N=10k/100k 记录 build 期间每 100ms 采样 `getUsedHeapSize()` + RSS，对照峰值；同时校验 `indexClusters` 与检索命中率不退化。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `purgeExpired` / `clear` 分批删除

- **现状**：`purgeExpired`（466–480）与 `IvfIndex.clear`（234–249）把整棵前缀的 key 先收集成 `ArrayList<String>` 再逐条删；100 万条记录约 100 万字符串（≈60 MB）一次性常驻。
- **方案**：按批（如 1000 个 key）收集-删除-清空缓冲，循环直到前缀为空；或改为"删除登记键 + 交给后台 compaction"，但需 `f_store` 支持前缀批量删除。
- **预期**：purge 的额外堆峰值从 O(集合大小) 降到 O(batch)。
- **代价**：删除期间前缀持续变化，需要处理"边删边遍历"的快照语义（每批重新 `prefix`）。
- **验证**：100 万条集合 purge 时 `getUsedHeapSize()` 峰值与 RSS 对照；确认删除条数与 `count()` 归零一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无测试数据，仅作下一轮取证清单，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `VectorMath.cosine`（含手写 `sqrt`）是暴力检索的主要自耗时 | `f_hydra/src/FStoreVectorStore.cj:206`、`VectorMath.cj:24` | 自耗时占比、单次耗时 | `cjprof record` 跑 10k 条 × 768 维检索 100 次，看 `cosine`/`sqrt` self time 占比 |
| 2 | 全量扫描的每条 3 次点查（contains/get/payload）主导检索延迟 | `f_hydra/src/FStoreVectorStore.cj:199`、`:232` | 点查次数与单次耗时 | 在 `isReady`/`payloadOf` 埋计数 + 分段计时，对照 SSTable 命中率 |
| 3 | `ids` 插入排序 + 每次比较 2 次 `store.get` 让 1 万分页进入秒级 | `f_hydra/src/FStoreVectorStore.cj:368`、`:872` | p50/p95 端到端耗时、`store.get` 次数 | `cjpm bench -O2`：1k/10k/100k 记录各 200 次 `ids(0,10)`，记录耗时与调用计数 |
| 4 | `buildIndex` 在 10 万 × 1024 维时峰值内存超容器 limit | `f_hydra/src/IvfIndex.cj:81`、`:209` | 峰值 RSS / heapUsed | 100k 记录 build 期间每 100ms 采样 RSS + `getUsedHeapSize()`，同时记录 GC 次数 |
| 5 | `store.prefix` 多路归并（PriorityQueue + 每源解码）在 10 万 key 上是扫描成本主项 | `f_hydra/src/FStoreVectorStore.cj:196`、`:260` | 单次前缀遍历耗时、每 key 平均成本 | 对 `prefix` 循环加分段计时，对比 memtable-only 与含 SSTable 两种状态 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_hydra/README.md` | .md | ✅ | 与实现基本一致；见 #5（写序）、#14（TTL 措辞）、#15（API 缺口）、#21（测试数）、发现 #1 的承诺源（`:54`） |
| 2 | `f_hydra/README_en.md` | .md | ✅ | 与 `README.md` 逐节对应，无缺节；同样含 #14/#21 的问题 |
| 3 | `f_hydra/doc/spec/reuse-f-hydra-dense-decode/design.md` | .md | ✅ | D1–D3 与实现一致（`decodeDenseInto` 契约、缓冲复用、测试项）；D4 基准口径与实现不一致 → #22 |
| 4 | `f_hydra/doc/spec/reuse-f-hydra-dense-decode/proposal.md` | .md | ✅ | 动机与分配量估算自洽；"明确不做 local mode"与 `docs/LocalMode-O2-Plan.md:123` 结论一致 |
| 5 | `f_hydra/doc/spec/reuse-f-hydra-dense-decode/tasks.md` | .md | ✅ | 任务全部 `[x]`；3.1 基准口径与落盘实现不符 → #22 |
| 6 | `f_hydra/src/FStoreVectorStore.cj` | .cj | ✅ | 1079 行全读；发现 #1/#2/#3/#4/#5/#7/#12/#13/#18/#19 |
| 7 | `f_hydra/src/FStoreVectorStore_test.cj` | .cj | ✅ | 38 个 `@TestCase`；`pathSeq++` 竞态 → #20；覆盖缺口：命名向量覆盖写、ragged colbert、坏 sparse、负 offset、并发写均无用例 |
| 8 | `f_hydra/src/IvfIndex.cj` | .cj | ✅ | 发现 #9/#10/#11；`sqrt` 复制 → #17 |
| 9 | `f_hydra/src/VectorCodec.cj` | .cj | ✅ | 发现 #6；`decodeDense` 预校验与 `decodeDenseInto` 重复（有"分配前校验长度"的理由，未计入重复逻辑） |
| 10 | `f_hydra/src/VectorCodecReuse_test.cj` | .cj | ✅ | 7 个用例；bench 用例受 `F_HYDRA_BENCH` 控制，口径与 spec 不一致 → #22 |
| 11 | `f_hydra/src/VectorCodec_test.cj` | .cj | ✅ | 5 个用例，覆盖 golden bytes / f32 精度 / 分片；无 ragged 行用例（发现 #6） |
| 12 | `f_hydra/src/VectorMath.cj` | .cj | ✅ | 发现 #8；`sqrt` 私有实现 → #17 |
| 13 | `f_hydra/src/VectorModels.cj` | .cj | ✅ | 纯数据类，字段注释与 `upsert` 布局一致；`vectors` 注释"各自独立建索引"与发现 #1 的覆盖写缺陷相关 |
| 14 | `f_hydra/src/VectorStore.cj` | .cj | ✅ | 接口契约；发现 #7（默认实现分叉）、#13（负 offset）、#14（TTL 措辞） |

合计：`.cj` 9 个 / `.md` 5 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性归入 §11/§12 单列；本行计 4：#13 边界、#14 契约歧义、#18 注释错位、#23 可见性。设计上无分层违规（库模块，无 Controller/Service/DAO）；语言特性上值/引用语义使用正确（`Array` 复用、`let` 字段）；安全性 0：无 SQL/命令拼接、无凭据、无外部输入插值（仅有 `/tmp` 测试路径） |
| §1 死代码 | 0 | 逐个核对：`private` 符号（`minOf`、`copyOf`、`partOf`、`sameFields`、`persistFilterFields`、`filterable`、`permitted`、`intersection`、`earlier`、`saveTimeOf`、`payloadOf`、`collectIds`、`purgeRecord`、`deleteFieldVectors`、`deletePostings`、`deleteColbertParts`、`readColbert`、`readFilters`、`writeFilterEntries`、`deleteFilterEntries`、`allowedIds`、`idsWith`、`isReady`、`expired`、`finalize`、`bruteForceField`、`scoreIds`、`ivf`、`sqrt`×2、`sortDesc`、`maxSim`、`encodeSparse`/`decodeSparse`、`writeInt32`/`readUInt32`/`writeFloat32`/`readFloat32`、各 `*Key`/`*Prefix`）全仓搜均有调用者；`internal decodeDenseInto` 有 3 处调用；包内类 `IvfIndex`/`IndexedVector`/`ClusterScore` 的 `public` 成员全部被 `FStoreVectorStore` 或自身引用；`protected` 声明 0 条；`return`/`throw`/`break`/`continue` 后无同层语句；`import` 逐文件核对全部使用。对外可达 public 不判（`buildIndex` 单参重载仓内 0 引用，仅记信息）。`IvfConfig` 单独记为可见性建议 #23 |
| §2 重复逻辑 | 2 | 同文件/跨文件两两比对后命中 2 条：#16（插入排序×5 + limit 截断×2）、#17（`sqrt`×2）；另记 `idsFiltered` 两套实现语义分叉 → #7。`decodeDense` 与 `decodeDenseInto` 的重复边界校验保留（分配前必须校验长度，属有意）；key 前缀拼接/剥离虽重复但只有 2 行，按"可读性刻意展开"不计 |
| §3 空实现 | 0 | 全模块无空函数体、无 `TODO/FIXME`、无 `throw UnsupportedException`、无 `catch {}` 静默吞异常（`FStoreVectorStore_test.cj:143` 的 catch 仅用于断言抛错）；`case None => ()` 均为"可选键缺失"的合法分支。静默失效类问题（IVF 维度不符）归 §11 → #10 |
| §4 栈溢出 | 0 | 逐个函数核对：无自调用、无间接递归（`sqrt`/`maxSim`/`colbert` 解码均为循环迭代），递归深度恒为 0；`PrefixIterator` 的归并也只有堆循环 |
| §5 OOM | 1 | #9（build 全量物化 n×dim×8 + purge/clear 全量 key）。未计入：`decodeDense` 按 `count*4` 预分配但已用 `bytes.size` 上限约束（`VectorCodec.cj:66`），不构成不可信长度分配 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据（`scope.md` 只提供 `docs/LocalMode*.md`，其中 `f_hydra` 标注"已完成复用/待采样"，无本模块耗时）。全部候选写入「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | 生产代码无任何锁（`Mutex` 只出现在测试的目录计数器），不存在"锁内做 I/O"；无锁带来的正确性问题归 §12.1 → #2 |
| §6.3 并发串行 | 0 | 全模块无 `spawn`/`Future`/线程池，无串行段可判 |
| §6.4 低效算法 | 2 | #3（分页每次重扫全量 + 插入排序 + 每次比较 2 次点查）、#4（全量排序取 top-k）。`sameFields`（610）与 `setFilterFields` 的 `contains` 去重是 O(k²)，但 k = 白名单字段数（≤ 个位数），不计 |
| §7 降堆内存方案 | 2 | 「build 分块训练」「purge/clear 分批删除」两条方案（均 `无基线（待验证）`）；`bruteForceField`/`scoreIds` 已复用解码缓冲（上一轮优化），暂无进一步复用空间 |
| §8 降 CPU 方案 | 3 | top-k 选择、cosine 去 30 轮迭代、减少全量扫描点查（均 `无基线（待验证）`） |
| §9 local mode 可行性 | 0 | `decodeDenseInto` 的缓冲是"跨候选复用的一块数组"，必须活到查询结束并作为 `cosine` 入参，局部 region 无法更早释放；`build` 的向量数组会存进 `IndexedVector`/`ArrayList`（逃逸）。与 `docs/LocalMode-O2-Plan.md:123`（f_hydra"已完成复用，无需 local"）结论一致，无新增可行性 |
| §11 现有代码的 BUG（存量） | 10 | #1、#5、#6、#7、#8、#10、#11、#12、#13、#19；全部为存量（快照无基线，blame 至 2026-10-31/11-04），已逐条核对函数边界、空集合（`a.isEmpty()`/`bytes.size < 4`/空 `filters`）、`Option` 取值（`?? 0`、`getOrThrow` 仅在测试）、错误处理与资源释放 |
| §12 并发安全与锁粒度 | 2 | #2（同 id 并发 upsert 跨键非原子、无互斥；共享路径 `fhydra` 静态 store + `InProcessTransport`）、#20（测试 `pathSeq` 竞态）。锁粒度 0：模块无锁，无"锁太大"问题；`indexedFields` 是唯一的进程内可变状态（`setFilterFields` 写、`filterable` 读），当前只在启动装配期写，按"配置只在启动读一次"（`fountain-baseline.md` §5）判定为可接受，若将来支持运行期改白名单需补同步 |
| §14 功能完备性与 README 覆盖 | 1 | #15（`filterFields`、`IvfConfig`、`DEFAULT_PART_BYTES`、`buildIndex` 重载未进 README）；README 承诺的 setFilterFields / rebuildFilterEntries / applyFilterFields / hc: 登记均已接线（`fhydra/src/HydraRpc.cj:48`），无"承诺但未实现" |
| 文件覆盖（§13 等） | 14/14 | 无缺文件；`cjpm.toml` 不在清单内但已读（version 1.3.2021，依赖 `f_base/f_config/f_data/f_log/f_store`，与本模块实现一致） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 13 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量 23 条（全部），是否纳入修复待用户决定；本轮不改源码。

## 总评

模块的骨架是清楚的：`VectorStore` 接口 + `f_store` 落盘 + 显式 key 布局 + 两阶段写 + TTL/过滤/IVF，文档（README 中英两版）写得比多数模块完整，测试 50 个用例覆盖了稀疏、colbert、IVF、TTL、过滤、导出等主路径，`f_store` 单键操作本身并发安全。**阻塞项有两个：**

1. **覆盖写不清理命名 dense（#1）**——这是会直接返回上一版本向量的数据错误，改动只有一行（补 `deleteFieldVectors`），但需要补用例，否则下游（f_llm 的 `title`/`content` 双路检索）会长期拿到过期向量。
2. **同 id 并发写（#2）**——模块对外是一个共享实例（fhydra 的 `static let store`），复合写在 `f_store` 之上没有任何互斥，唯一后果是"posting 孤儿 + 混合版本读"，属于难复现、难定位的静默数据污染，建议按 id 分片加锁，代价很小。

排期建议：上面两条先修；随后是规模相关的三件事——`ids`/`idsFiltered` 的分页重扫（#3）、top-k 排序（#4）、`build` 全量物化（#9），它们决定了模块在十万级集合上是否可用，但都需要补 bench 数据后再定改动幅度（本报告只给方案，不给收益数字）。#5（ready 写序）与 #10/#11（IVF 召回与簇心错位）是有文档承诺、实现不成立的"静默漏条"类问题，建议与 #1 同批处理；#6（ragged colbert）加一次入参校验即可。

文档侧的 #14（TTL 语义自相矛盾）与 #15（公开 API 缺口）成本低、收益明确，可随手修；#21/#22 属于过期数字，改一次即可。

**范围外提示**（不计入统计）：`f_llm/src/store/VectorMath.cj:24-71` 与 `f_hydra/src/VectorMath.cj` 的 `cosine` + `sqrt` 逐字相同（第三份复制），跨模块合并需要先决定依赖方向；`fhydra/src/HydraRpc.cj:182` 的 `export` 把同一个 store 实例同时作为源与目标，`targetCollection` 等于 `collection` 时会边写边分页（潜在自增循环），属 `fhydra` 模块范围。

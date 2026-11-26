# 内容族存储（记忆 / 经验 / 知识 / 文档）

> 数据语义见 `doc/f_llm-memory-design.md` §2、§3；选型与启动接线见 `doc/f_llm.md` §4；实现 `f_llm/src/store/`。

## 0. 实现矩阵

| `llm_memoryStore` | `ContentStore` | `MemoryStore` | `KnowledgeStore` | 位置 |
|---|---|---|---|---|
| `f_hydra`（默认） | `HydraContentStore` | `SqlMemoryStore` + `HydraMemoryRepository` | `HydraKnowledgeStore` | `llm_hydraPath` |
| `fhydra` | `FhydraContentStore` | `SqlMemoryStore` + 远程仓储 | `HydraKnowledgeStore`（远程 transport） | `llm_hydraUrl` |
| `postgres` | `PostgresContentStore` | `SqlMemoryStore` + `PostgresMemoryRepository` | `PostgresKnowledgeStore` | PG 库 |
| `mysql` | `MySqlContentStore` | `SqlMemoryStore` + `MySqlMemoryRepository` | `MySqlKnowledgeStore` | MySQL 库（需 MyVector） |
| `inMemory` | `InMemoryContentStore` | `InMemoryMemoryStore` | `InMemoryKnowledgeStore` | 进程内 |

`SqlMemoryStore` 是**共享的门面**：真正读写由 ORM 注册的 `MemoryRepository` 完成，所以 SQL / hydra 部署下 `lookupOption<MemoryRepository>()` 是否可用取决于内容族实现（见 `known-limitations.md` §6）。

经验不单独存：`kind=experience` / `experience_failed` 的记录仍在 `llm_memory` 里。

## 1. 记忆表（SQL 部署）

| 表 | 作用 | 关键列 |
|---|---|---|
| `llm_memory` | 记忆主表 | `id` PK、`(user_id, namespace, title)` 唯一、`kind`、`content`、`save_time` |
| `llm_memory_kind` | 种类注册表 | `(user_id, kind)` 主键、`predefined`、`weight` |
| `llm_memory_vector` | 标题/正文向量 | `title_dense` / `content_dense`（HNSW）、`title_colbert` / `content_colbert`（bytea）、`has_sparse` / `has_colbert` |
| `llm_memory_token` | 稀疏倒排 | `(memory_id, field, token)` 主键、`weight` |

索引：`idx_memory_ns_time (user_id, namespace, save_time DESC)` 用于列举分页；向量列各自建 ANN 索引。

`namespace` 是调用方定义的隔离维度（loom 默认 `loom`，业务常用 `work` 等），与 `user_id` 共同构成边界。

## 2. 写入流程

```
add(write)
 ├─ embedder.embed(title) / embed(content)        → 两份 dense 向量
 ├─ repo.upsert(...)                              → llm_memory + llm_memory_vector（同键覆盖）
 ├─ embedder.tokenize(title/content) → 合并 token → repo.upsertSparse(...)
 └─ embedder.embedColbert(title/content) → codec → repo.upsertColbert(...)
```

| 失败点 | 行为 |
|---|---|
| dense 编码失败 | 整体拒绝写入（不存无向量的记忆） |
| 写入主表/向量失败 | 抛出，调用方感知 |
| sparse 编码失败 | 抛出（倒排是召回的一路，缺了不该静默） |
| colbert 编码失败 | `try/catch` 吞掉，只丢重排能力 |

同一 `(user_id, namespace, title)` 覆盖写，返回既有 id。

## 3. 检索流程

```
search(query)
 ├─ dense  = repo.searchDense(qv, topK×2)          // 1 - cosine
 ├─ sparse = repo.searchSparse(tokens, topK×2)     // token 权重求和
 ├─ 两路 min-max 归一化 → 0.7×dense + 0.3×sparse（按 id 去重）
 ├─ × MemoryKinds.weightOf(kind)                   // 见 §4
 ├─ [rerank] colbert max-sim 重排（只改顺序，不改候选集、不改 score）
 └─ 截断 topK
```

| 情形 | 行为 |
|---|---|
| `sparse` 为空 | 整次标 `degraded=true`，只用 dense |
| `query.rerank=false`（默认） | 完全不读 colbert 列 |
| 仓库返回越界行 | store 层按 `user_id` / `namespace` / `kind` 再挡一次 |

## 4. 权重（固定值，不可配）

| kind | weight |
|---|---|
| `fact` / `preference` | 1.0 |
| `note` | 0.9 |
| `doc` / `knowledge` | 0.8 |
| `task` | 0.6 |
| `session` | 0.3 |
| 自定义 | 0.8 |

权重在融合**之后**乘，不进 ANN 索引——否则换权重就要重建向量索引。

## 5. 知识表

| 表 | 作用 | 关键列 |
|---|---|---|
| `llm_document` | 文档 | `doc_id` PK、`title`、`content`、`update_time` |
| `llm_document_chunk` | 检索单元 | `id` PK、`doc_id`、`seq`、`content`、`content_vec vector(1024)` |

- 切块：`KnowledgeChunker.split(content, maxChars: 400, overlap: 50)`；
- 索引：`idx_llm_document_chunk_doc (doc_id)` + HNSW（`vector_cosine_ops`）；MySQL 侧是 `MYVECTOR_IS_ANN`，写入后需 `CALL myvector_index_build(...)`；
- 检索返回块级 `KnowledgeHit`（`docId` / `seq` / `content` / `score`），同文档可能命中多块。

## 6. colbert 存储格式

```
count(Int32 LE) + count × dim × Float32 LE
```

- 编解码：`src/store/ColbertCodec.cj`；
- PG 列类型 `BYTEA`，绑定用 `SqlExecutor.add(Array<Byte>)`，读回由 `mapList` 映射为 `Array<Byte>`；
- 不用 JSON：同体积约 3 倍，且每次读写多一轮解析。

## 7. 建表与升级

| 场景 | 做法 |
|---|---|
| 首次部署 | 执行 `tables-pg.sql` / `tables-mysql.sql` |
| 已有库加列 | 必须 `ALTER TABLE`——`CREATE TABLE IF NOT EXISTS` 不会给已存在的表补列 |
| 换 embedding 模型 | 改向量列宽并重建 ANN 索引，再用重建工具重算存量向量 |
| 预定义种类 | 启动时幂等补种；手工删掉会在下次启动恢复（预定义行 API 层不允许删除） |
| 删除记忆 | 先删 `llm_memory_vector` / `llm_memory_token`，再删 `llm_memory` |

## 8. 测试

| 用例 | 覆盖 |
|---|---|
| `PostgresMemoryRepository_test.testAddGetListRemove` | 写入、读回、分页、删除 |
| `PostgresMemoryRepository_test.testDenseSearchReturnsAddedRecord` | dense + sparse 融合检索 |
| `PostgresMemoryRepository_test.testColbertRoundTrip` | colbert 写入 → 读回 → 解码 |
| `CrossBackendConformance_test` | 同一套断言跑 PG / MySQL，验证两后端行为一致 |
| `EvolutionStoreIT_test` | 演进报告、状态、租约、知识去重（真库） |
| `StoreConformance_test` | 契约层（内存实现） |

真库用例**靠探测判断可用性**：`postgresReady()` / `mySqlReady()` 连不上时打印 `SKIP …` 并 `return`，不使用环境变量开关。
不要用整段 `try { run() } catch { println("SKIP") }` 包住断言——那会把 `@Expect` 失败一起吞掉（详见 `doc/dev-env.md`）。

# 内容族存储（记忆 / 经验 / 知识 / 文档）

> 对应设计与代码：`f_llm-memory-design.md` §5.3、§6；实现 `f_llm/src/store/`。
> 状态：PostgreSQL 已实现并通过集成测试；MySQL 与 f_hydra / fhydra 待接。

## 1. 表

| 表 | 作用 | 关键列 |
|---|---|---|
| `llm_memory` | 记忆主表（经验用 `kind=task/knowledge` 表达） | `(user_id, namespace, title)` 唯一；`kind`、`save_time` |
| `llm_memory_kind` | 种类注册表 | `(user_id, kind)` 主键；`predefined`、`weight` |
| `llm_memory_vector` | 标题/正文三路向量 | `title_dense` / `content_dense`（HNSW）、`title_colbert` / `content_colbert`（bytea）、`has_sparse` / `has_colbert` |
| `llm_memory_token` | 稀疏倒排 | `(memory_id, field, token)` 主键；`weight` |

`namespace` 取 `global` 或 `ws-{workspaceId}`，与用户维度共同构成隔离边界。

## 2. 写入流程

```
add(write)
 ├─ embedder.embed(title) / embed(content)        → 两份 dense 向量
 ├─ repo.upsert(...)                              → llm_memory + llm_memory_vector（同键覆盖）
 ├─ embedder.tokenize(title/content) → 合并 token → repo.upsertSparse(...)
 └─ embedder.embedColbert(title/content) → codec → repo.upsertColbert(...)
```

要点：

- 同 `(user_id, namespace, title)` 覆盖写，返回既有 id；
- dense 向量化失败 → 整体拒绝写入（不存无向量记忆）；
- sparse 失败 → 抛错；colbert 失败 → 只丢重排能力（`try/catch`，不影响主流程）。

## 3. 检索流程

```
search(query)
 ├─ dense  = repo.searchDense(qv, topK×2)     // HNSW，1 - cosine
 ├─ sparse = repo.searchSparse(tokens, topK×2) // token 权重 SUM
 ├─ 两路 min-max 归一化 → 0.7×dense + 0.3×sparse（按 id 去重）
 ├─ × MemoryKinds.weightOf(kind)               // session 0.3 … fact 1.0
 ├─ [rerank] colbert max-sim 重排（只改顺序，不改候选集、不改 score）
 └─ 截断 topK
```

- `sparse` 为空 → 整次标 `degraded=true`，只用 dense；
- `rerank=false`（默认）→ 完全不读 colbert 列；
- 隔离在 store 层再挡一次：`user_id` / `namespaces` / `kinds` 三重过滤。

## 4. 权重（固定值，不可配）

| kind | weight |
|---|---|
| `fact` / `preference` | 1.0 |
| `note` | 0.9 |
| `doc` / `knowledge` | 0.8 |
| `task` | 0.6 |
| `session` | 0.3 |
| 自定义 | 0.8 |

权重不进 ANN：向量索引只算相似度，权重在融合后乘——否则换权重就要重建索引。

## 5. colbert 存储格式

```
count(Int32 LE) + count × dim × Float32 LE
```

- 编码/解码：`f_llm/src/store/ColbertCodec.cj`；
- PG 列类型 `BYTEA`，绑定用 `SqlExecutor.add(Array<Byte>)`，读回由 `mapList` 映射为 `Array<Byte>`；
- 不用 JSON：同体积约 3 倍，且每次读写多一轮解析。

## 6. 迁移注意

1. **已有库加列必须 `ALTER TABLE`**：`CREATE TABLE IF NOT EXISTS` 不会给已存在的表补列（本轮 colbert 列就踩过）；
2. 向量列宽与模型绑定：换 embedding 模型要改列宽并重建 HNSW 索引；
3. `llm_memory_kind` 的预定义行由启动时幂等补种，手工删掉会在下次启动恢复；
4. 删除顺序：先删 `llm_memory_vector` / `llm_memory_token`，再删 `llm_memory`。

## 7. 测试

| 用例 | 覆盖 |
|---|---|
| `PostgresMemoryRepositoryTest.testAddGetListRemove` | 写入、读回、分页、删除 |
| `...testDenseSearchReturnsAddedRecord` | dense + sparse 融合检索 |
| `...testColbertRoundTrip` | colbert 写入 → 读回 → 解码 |
| `StoreConformanceTest` | 接口层 conformance（内存实现） |

无 PG 环境时集成用例打印 `SKIP PostgresMemoryRepositoryTest: <原因>` 并跳过，不静默通过。

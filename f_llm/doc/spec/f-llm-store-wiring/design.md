# 设计：存储接线与数据访问分层

> 变更：`f-llm-store-wiring`（2026-10-30）
> 前置：`f-llm-memory-storage`（已归档，27/27）

## 1. 背景与目标

上一变更交付了契约与三套实现，但：

- `PostgresMemoryRepository` / `MySqlMemoryRepository` 直接把 SQL 写在 repository 里，构造时注入 `SqlExecutor`；
- `Stores` 没有生产实现注册，业务层（`Memory` / `LLMConfs`）也没切过来；
- 没有生产 `Embedder` 与 PG/MySQL 的 `KnowledgeStore`。

本变更把「谁持有连接、SQL 放哪、启动时怎么接线」这三件事定下来。

## 2. 决策

### D1 三层：DAO / Repository / Service

| 层 | 职责 | 例子 |
|---|---|---|
| **DAO** | 只放 SQL 与行映射，接口即实现（`@DAO` 默认方法体） | `LLMConfDAO`、`PostgresMemoryDAO`、`MySqlMemoryDAO` |
| **Repository** | 组装业务语义（upsert + 三路写入的先后、过滤条件拼装），不直接写 SQL | `PostgresMemoryRepository` |
| **Service/Store** | 融合、权重、截断、rerank，仍只依赖 `MemoryRepository` 接口 | `SqlMemoryStore`、`MySqlMemoryStore` |

```cangjie
@DAO
public interface PostgresMemoryDAO <: RootDAO {
    func upsert(write: MemoryWrite, titleVector: String, contentVector: String): Int64 {
        executor.setSql('''INSERT … ON CONFLICT … RETURNING id''')
            .add(write.userId) … .firstToMap() … // SQL 细节全在 DAO
    }
    func searchDense(userId: Int64, namespaces: Array<String>, vector: String, limit: Int64): ArrayList<HashMap<String, Any>> { … }
    func insertToken(memoryId: Int64, userId: Int64, ns: String, token: Int64, weight: Float64): Unit { … }
    …
}
```

**理由**：SQL 与方言差异集中在一处，Repository 只表达「先写主表再写倒排」这类顺序；换方言只改 DAO。

### D2 Repository 实现 `RootService`，不再持有 `SqlExecutor`

```cangjie
public class PostgresMemoryRepository <: MemoryRepository & RootService {
    public func upsert(write: MemoryWrite, titleVector: Array<Float64>, contentVector: Array<Float64>): Int64 {
        let dao = dao<PostgresMemoryDAO>('postgres')   // RootService.dao<T>(driver)
        dao.upsert(write, vectorLiteral(titleVector), vectorLiteral(contentVector))
    }
}
```

- 删除 `private let executor` 与构造参数；
- 驱动名固定为 `postgres` / `mysql`（与实现绑定），不开放给调用方；
- `RootService.dao<T>(driver)` 内部把 `SqlExecutor` 适配成 DAO 接口（`@DAO` 已让接口具备执行器能力），失败抛 `ORMException`；
- 测试从「传 executor」改为「先注册 ORM，再 `PostgresMemoryRepository()`」。

### D3 驱动名与库名

| 项 | 来源 | 说明 |
|---|---|---|
| 驱动名 | 实现类常量（`postgres` / `mysql`） | 不由配置传入，避免同一实现连错驱动 |
| 库名（MyVector 路径用） | `StoreSettings.contentStoreUrl` 解析，其次 `llm_contentStoreDatabase` | `MYVECTOR_IS_ANN('{db}.llm_memory.title_vec', …)` 需要库名 |
| URL | `llm_contentStoreUrl` | 不在实现类里硬编码 |

URL 解析规则：取 `//…/` 后、`?` 前的最后一段；解析失败抛 `IllegalArgumentException`（启动期失败优于运行期空指针）。

### D4 DAO 方法清单

| 方法 | PG | MySQL |
|---|---|---|
| `upsert` | `ON CONFLICT … RETURNING id` | `ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)` + `CAST(… AS SIGNED)` |
| `searchDense` | `1 - (title_dense <=> ?::vector)` | `myvector_distance` + `MYVECTOR_IS_ANN` 第五参数 |
| `searchSparse` | `SUM(weight)` | 同构 |
| `deleteTokens` / `insertToken` | 同构 | 同构 |
| `updateColbert` / `selectColbert` | `BYTEA` | `LONGBLOB` |
| `get` / `list` / `delete` | 同构 | `LIMIT ?, ?` |

DAO 返回 `ArrayList<HashMap<String, Any>>` 或基础类型，Repository 负责转 `MemoryRecord` / `MemoryHit`。

### D5 MySQL ANN 的两个硬约束（沿用 4.x 实测）

1. **隔离条件放第五参数**：`MYVECTOR_IS_ANN(…, k, (SELECT JSON_ARRAYAGG(id) FROM … WHERE user_id=? AND namespace IN (…)))`；
   写在 `WHERE` 会先取 k 条再过滤，结果可能少于 k。
2. **不能走预处理占位符**：`myvector_construct(?)`、`k=?` 都会被改写报 1064，DAO 里用字面量拼接；
   向量只含数字，namespace 做 `''` 转义，`user_id` 为 `Int64`，无注入面。

### D6 生产 Embedder

```cangjie
public interface Embedder {
    func embed(text: String): Array<Float64>
    func embedColbert(text: String): Array<Array<Float64>>
    func tokenize(text: String): HashMap<Int64, Float64>
}
```

`HttpEmbedder` 设计：

- 端点 `/v1/embeddings`，一次请求返回 dense + sparse + colbert（BGE-M3 服务约定）；
- 批量 `llm_embeddingBatch`（默认 32），单请求超时 `llm_embeddingTimeoutMs`（默认 3000）；
- 失败重试 2 次（指数退避 100ms/300ms），仍失败抛 `IllegalStateException`；
- 维度校验：返回维度 ≠ 1024 → 抛错（不静默截断）；
- 检索侧：sparse/colbert 缺失时降级并标 `degraded`，dense 失败则整次检索失败。

### D7 KnowledgeStore

```sql
create table llm_document (
    doc_id      varchar(128) not null,
    user_id     bigint       not null,
    namespace   varchar(32)  not null,
    title       varchar(256) not null,
    content     text         not null,
    update_time datetime     not null,
    primary key (doc_id)
);
create table llm_document_chunk (
    doc_id      varchar(128) not null,
    chunk_no    int          not null,
    content     text         not null,
    vector      <vector列>   not null,   -- PG: vector(1024)；MySQL: MYVECTOR
    primary key (doc_id, chunk_no)
);
```

- `upsert`：同 `doc_id` 覆盖，先删旧 chunk 再写新 chunk；
- `remove`：先删 chunk，再删 document（与 3.1 的删除顺序一致）；
- f_store 不实现 `KnowledgeStore`（内容族没有 f_store 选项），配置校验时拒绝。

### D8 实现包与 bootstrap

```
f_llm/src/store/postgres/Register.cj   package fountain::f_llm.store.postgres
f_llm/src/store/mysql/Register.cj      package fountain::f_llm.store.mysql
```

- 各自 `import` 对应驱动与 DAO；
- 各自 `public func register(): Unit` 调 `Stores.registerContent/registerMeta`；
- `f_llm/cjpm.toml` 把 `postgres_driver`、`mysql_driver` 从 `test-dependencies` 提升到 `dependencies`（实现包需要），
  并保留 target 的 `bin-dependencies.path-option`；
- `Stores.bootstrap()` 只做分发：读 `StoreSettings`，按名字调用 `register()`，**不 import 具体实现类**；
- 未注册/未知值 → 启动失败，消息含可选列表。

### D9 测试与迁移

| 变更 | 影响 |
|---|---|
| Repository 构造签名 | `PostgresMemoryRepository(executor)` → `PostgresMemoryRepository()`；测试先 `ORM.register` |
| MySQL 库名 | 测试从 URL 解析 `fllm_test`，或显式传 `llm_contentStoreDatabase` |
| 删除 `executor` 字段 | 所有 DAO 调用改 `dao<T>('postgres')`，编译期即可发现遗漏 |
| 回归基线 | 现有 231 条必须全绿；新增 DAO 层单测（PG/MySQL 各 1 条） |

## 3. 风险

| 风险 | 缓解 |
|---|---|
| `@DAO` 接口默认方法无法访问 `executor`（宏展开差异） | 先写一个最小 DAO（`SELECT 1`）验证，再批量迁移 |
| MySQL DAO 里字面量拼接误引入注入 | 只有三段来自变量：向量（数字校验）、namespace（`''` 转义）、user_id（Int64）；DAO 内部注释标注 |
| `RootService.dao<T>` 在未注册驱动时抛错信息不清晰 | 包一层 `requireExecutor()`，消息带驱动名与 `orm_drivers` 提示 |
| 驱动提升到 dependencies 后构建环境要求变化 | README 记录 `CANGJIE_STDX_PATH` 与 `.so` 位置；CI 固定脚本 |

## 4. 落地顺序

```
0.x DAO 分层（本变更新增）
  ↓
1.x 配置模型扩展 → 2.x Embedder → 3.x KnowledgeStore
  ↓
4.x 实现包与 bootstrap
  ↓
5.x Memory / LLMConfs 切换 + 全量回归
  ↓
6.x 文档与归档
```

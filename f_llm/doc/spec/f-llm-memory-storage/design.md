# Design

## Context

参见 `proposal.md` 的 Why。当前实现里：

- `f_llm/src/memory/FaithfulMemory.cj` 直接持有 `f_store.Store`，按 key 前缀写 JSON；
- `f_llm/src/memory/Memory.cj` 只做对话摘要，无持久化抽象；
- 人格/技能/提示词/模型配置分散在 `model/po` 与 `LLMConfs`，来源只有数据库或环境变量；
- `f_llm/tables-pg.sql` / `tables-mysql.sql` 已有 `llm_memory` 等表的 DDL，但代码里没有对应 DAO。

`f_store` 只提供字节 KV（`add/get/remove/prefix/ttl`），`f_orm` 提供 `@DAO` + `RootDAO`，`f_config` 提供 `Config.getString`。这些是本次实现的全部底座。

## Goals / Non-Goals

**Goals:**

- 落地内容族 / 元数据族两个接口与工厂，配置驱动、未知值启动失败。
- 内容族：PostgreSQL 与 MySQL 两个实现，覆盖记忆 CRUD、kind 注册表、**dense + sparse + colbert 三路检索**、标题/正文两路索引。
- 元数据族：PostgreSQL、MySQL、f_store 三个人格与配置读写实现；技能/提示词接口 + f_store 实现。
- 验证「仅 f_store」可完整启动并持久化元数据。
- 在 WSL Ubuntu 24.04 安装 MySQL 9.2+，跑通 MySQL 侧全部用例。
- 保持 `Memory` / `FaithfulMemory` 既有公开方法不变。

**Non-Goals:**

- `f_hydra` / `fhydra` 内容族实现（两者共用存储与索引，仅调用方式不同；由后续变更落地）。
- loom、通道 MCP、邮件、工具发现、技能自演进、人格按工作空间/任务/流程绑定（各自独立变更）。
- 人格注入与上下文裁剪行为变更。
- MySQL 9.2 以下版本的向量索引能力（只做降级，不追求等价性能）。

## Decisions

### D1 两族而不是一套 `Store`

记忆/知识量大且要向量检索，元数据量小且要能冷启动；合成一套会把「单机 f_store」绑死成「必须装向量库」。两族各自三选一，允许交叉组合。

### D2 接口形状：族接口 + 子接口属性

```cangjie
public interface ContentStore <: Resource {
    prop memory: MemoryStore
    prop knowledge: KnowledgeStore
}
public interface MetaStore <: Resource {
    prop characters: CharacterStore
    prop skills: SkillStore
    prop prompts: PromptStore
    prop confs: LLMConfStore
}
```

替代方案：一个 `Store` 暴露全部方法（30+ 方法，实现类被迫空实现）；或每个实体一个独立工厂（配置项爆炸）。族接口让实现者只挑一族，mock 也简单。

### D3 工厂与注册表

`Stores.content()` / `Stores.meta()` 读 `llm_contentStore` / `llm_metaStore`，在注册表中查找；未命中抛 `IllegalStateException("unknown llm_contentStore: X, available: [postgres, mysql, fhydra]")`。注册表用 `ConcurrentHashMap`，`registerContent/registerMeta` 同名覆盖视为启动期错误。

### D4 f_store 元数据布局与两阶段写

`f_llm:meta:{entity}:{id}` 为主体，`byname/title/latest` 为索引。写主体后写索引；删除先删索引再删主体；启动扫主体补索引。单进程内按 entity 互斥，不做跨进程并发承诺。

### D5 kind 注册表归属

预定义 7 值固化在 `MemoryKinds`；自定义行 `(user_id, kind)` 落 `llm_memory_kind`；启动 `INSERT ... ON CONFLICT DO NOTHING` 补种 `user_id=0` 行。删除预定义在 API 层拒绝；跨用户删除返回 `false`。

### D6 三路检索：dense 走索引、sparse 走倒排、colbert 只重排

| 路径 | 存储 | 检索 |
|---|---|---|
| dense | `vector(1024)` / `VECTOR(1024)` | HNSW（PG）/ `VECTOR INDEX`（MySQL 9.2+），`ORDER BY … <=> q LIMIT topK×2` |
| sparse | `llm_memory_token` 倒排 | 按 query token 取 posting，权重累加，取 topK×2 |
| colbert | `bytea` / `LONGBLOB` | **不进索引**，只对候选 top-20 做 max-sim |

融合：`normalize(dense)×0.7 + normalize(sparse)×0.3`，去重后乘 kind 权重再截断 topK；`rerank=true` 时用 colbert 重排候选。
与设计文档 §3 一致：colbert 单条 307KB，建索引会把 compaction 打满，所以只重排。

### D7 权重固定、超取再截断

`session=0.3`、`task=0.6`、`doc/knowledge=0.8`、`note=0.9`、`fact/preference=1.0`、自定义 0.8。先取 `topK × 2` 再乘权重，避免低权重记忆被提前挤掉；不提供请求级/集合级覆盖。

### D8 MySQL 实现与验证

- 与 PG 同一套 DAO 形状，方言差异（`AUTO_INCREMENT` / `LONGBLOB` / `VECTOR`）收敛在 DDL 与 SQL；
- MySQL 9.2+ 用 `VECTOR INDEX ... USING HNSW`；检测不到索引能力时降级为应用层暴力计算并 `warn`；
- **验证顺序按用户要求**：内存 → PG → f_store → 安装 MySQL → MySQL 用例。安装用官方 APT 源（WSL Ubuntu 24.04），装完校验 `VECTOR` 与 `VECTOR INDEX` 可用。

### D9 测试策略

接口层写一套 conformance 用例，由内存替身、PostgreSQL、MySQL、f_store 分别跑；内存替身不注册进工厂。DB 用例用临时库/临时 schema，测试后清理；无对应数据库时跳过并显式打印原因，不静默通过。

### D10 兼容与迁移

- `Memory.add/summarise`、`FaithfulMemory` 签名不变，内部改走 `Stores.content().memory`；
- `LLMConfs.holder()` 数据源改为 `Stores.meta().confs`，`setHolder` 仍可用于测试；
- 旧配置键 `llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath` 启动 `warn` 并忽略；
- 新增表为纯增量，不删旧表；旧 `f_store` 记忆数据不自动迁移（`FaithfulMemory` 的 key 继续可读）。

### D11 驱动隔离：两个实现包 + 适配器注册（2026-10-29 追加）

- `postgres` 与 `mysql` 各自独立包：`f_llm/src/store/postgres/`、`f_llm/src/store/mysql/`，包内**各自导入驱动**（`postgres_driver` / `mariadb`），并各自实现 `ContentStore` / `MetaStore`；
- 业务代码只 `import fountain::f_llm.store.*`，**看不到实现类型**；实现包在初始化时调用 `Stores.registerContent('postgres', …)` / `registerMeta`；
- `Stores` 是适配器：只认注册名，不 import 任何实现包；`llm_contentStore` / `llm_metaStore` 选中哪个就实例化哪个；
- 驱动以 `output-type = "dynamic"` 加入 `f_llm/cjpm.toml`，**运行时只需驱动在 `LD_LIBRARY_PATH`**，不把驱动源码打进 f_llm；
- 好处：换驱动/换数据库不动业务层；驱动缺失时启动报「适配器未注册」，而不是链接期失败。

**待确认**：MySQL 侧中心仓包名是 `mysql_driver`（仓库内 e2e 用这个名字）还是 `mariadb`；两者驱动名与 URL scheme 不同，必须与用户确认后再写依赖。

## Risks / Trade-offs

- `f_store` 无事务 → 两阶段写可能留下孤儿索引；缓解：启动补索引、删除顺序反转、单进程互斥。
- pgvector 需按库 `CREATE EXTENSION` → 启动检测失败并给出明确 SQL；不自动建扩展。
- MySQL 9.2 在 WSL 的安装体积与初始化耗时 → 先完成 PG/f_store 全部用例，再安装；安装失败时记录原因并暂停 MySQL 相关任务，不伪造通过。
- 三路检索的 sparse token 依赖 BGE-M3 服务返回 `lexical_weights`；服务未就绪时降级 dense-only，标 `degraded`。
- 接口先落地、实现分批 → 中间态存在「接口可用但 fhydra 缺失」；用启动失败信息明确暴露。

## Migration Plan

1. 先合 DDL（增量表），不影响现有功能；
2. 发布时默认 `llm_contentStore=postgres`、`llm_metaStore=postgres`（与现状等价），f_store 需显式开启；
3. 回滚：把两个配置键切回 postgres 即可；新增表可保留；
4. 旧 `FaithfulMemory` 数据不动，读路径继续可用；
5. MySQL 安装属于环境变更，不随回滚撤销，但代码降级路径保证低版本可运行。

## Open Questions

无。

### D12 MySQL 实测结论（2026-10-29，**已被 D13 取代**）

WSL Ubuntu 24.04 从官方 APT 源（`mysql-innovation` 组件）安装到 **MySQL 26.10.0**（年度版本号，晚于 9.2）。
实测结果：

| 能力 | 结果 |
|---|---|
| `VECTOR(1024)` 列 | ✅ 可建表、可写入（`STRING_TO_VECTOR('[1,2,3]')`） |
| `CREATE VECTOR INDEX … USING HNSW` | ❌ 语法不支持（`ALTER TABLE … ADD VECTOR INDEX`、`CREATE INDEX … USING HNSW` 同样失败） |
| `VECTOR_DISTANCE` / `DISTANCE` / `COSINE_DISTANCE` | ❌ 函数不存在 |

结论：该构建只有 VECTOR 类型，没有 ANN 索引与距离函数。MySQL 实现按设计降级：

1. 向量列用 `BLOB` 存 `f32` 小端（不依赖 `VECTOR` 类型，兼容 MySQL 8.x/MariaDB）；
2. `searchDense` 取候选后在应用层算 cosine，并 `warn` 一次「降级为暴力检索」；
3. 若后续换到真正支持 `VECTOR INDEX` 的 9.2+ 构建，只改 DDL 与一条 SQL，不动接口。
### D13 MySQL Community + MyVector：真 ANN 可用（2026-10-29 追加）

MySQL Community 本身没有 `VECTOR INDEX` / `VECTOR_DISTANCE`（D12 的结论仍然成立），
但 **MyVector 组件**（`askdba/myvector`，commit `98c8269`）可以在 Community 上提供 HNSW：

| 项 | 实测 |
|---|---|
| MySQL | 9.7.4 LTS（官方 tarball，`/opt/mysql97`，socket `/tmp/mysql97.sock`，port 3306） |
| MyVector | 组件构建（`libmyvector_component.so` → `component_myvector.so`），`INSTALL COMPONENT 'file://myvector'` |
| 列类型 | `MYVECTOR(type=HNSW,dim=1024,size=…,dist=L2,m=16,ef=100)`（组件改写 DDL，不是 MySQL `VECTOR`） |
| 建索引 | `CALL mysql.myvector_index_build('db.table.col','pk')` |
| ANN 查询 | `WHERE MYVECTOR_IS_ANN('db.table.col','pk', myvector_construct('[…]'), k)` |
| 写入 | `INSERT … VALUES (myvector_construct('[…]'))` |
| 状态 | `CALL mysql.myvector_index_status('db.table.col')` |

冒烟结果（3 行数据）：建索引 `SUCCESS rows: 3`；`MYVECTOR_IS_ANN` 返回 `wordid=1,2`。

**运行前提**：

1. 数据目录放 `myvector.cnf`（`myvector_user_id` / `myvector_user_password` / `myvector_socket`），文件 `chown mysql` + `chmod 600`；
2. 该账号需要 `SELECT, LOCK TABLES, REPLICATION CLIENT, REPLICATION SLAVE`（缺 `LOCK TABLES` 会在建索引时报 `Access denied`）；
3. 索引随 binlog 增量更新，文件落在 `myvector_index_dir`；重启后 `CALL …_index_load` 恢复。

**对 f_llm 的影响**：MySQL 内容族不再需要「BLOB + 应用层 cosine」的降级实现，
改为 `MYVECTOR` 列 + `MYVECTOR_IS_ANN` 查询；隔离过滤（user/namespace）仍由 SQL 的 `WHERE` 条件完成，
需确认 MyVector 的 ANN 结果能否与普通 `WHERE` 条件组合（若不行，则先 ANN 取大候选再在外层过滤）。

**待验证**：`MYVECTOR_IS_ANN` 与 `WHERE user_id=? AND namespace=?` 的组合语义、1024 维下的建索引耗时。
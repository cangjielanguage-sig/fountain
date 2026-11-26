## Why

`f-llm-memory-storage` 已交付内容族/元数据族的契约与 PG/MySQL/f_store 实现，但**业务层还没真正走接口**：

- `Memory` / `FaithfulMemory` 仍直接依赖 `f_store`；
- `LLMConfs.holder()` 仍用旧的 `LLMConfSource`；
- `Stores` 只有注册表，没有生产实现注册（PG/MySQL 工厂无人注册）；
- 没有生产 `Embedder`，也没有 PG/MySQL 的 `KnowledgeStore`。

这四条不补，「配置驱动存储」只是纸面能力：切到 `postgres`/`mysql` 时启动即失败。

## What Changes

1. **扩配置模型**：`LLMConfStore` 返回完整配置（`llm_url`、`auth`、`temperature`、`always_thinking`、`conf`），PG/MySQL/f_store 三实现同步；
2. **生产 `Embedder`**：BGE-M3 HTTP 客户端（批量、超时、失败重试、维度校验）；
3. **PG/MySQL `KnowledgeStore`**：文档与块的最小实现（upsert/get/remove），复用 `llm_memory` 之外的独立表或文档表；
4. **实现包与 bootstrap**：`store/postgres`、`store/mysql` 各自 import 驱动、自注册工厂；`Stores.bootstrap()` 按配置调用对应 `register()`；
5. **业务层切换**：`Memory`/`FaithfulMemory` 走 `Stores.content().memory`，`LLMConfs.holder()` 走 `Stores.meta().confs`，保留 `setHolder` 测试注入；
6. **回归**：切换前后 `Memory` 摘要与写入路径行为一致；既有 231 条用例全绿；
7. **数据访问分层**：MySQL / PostgreSQL 的 `MemoryRepository` 把 SQL 拆到 `@DAO` 接口（参考 `LLMConfDAO`），
   实现类删除 `SqlExecutor` 成员与构造参数，改为实现 `fountain::f_orm.RootService`，通过 `executor()` / `dao<T>()` 取执行器。

## Capabilities

### New Capabilities

- `llm-store-wiring`：存储选型的运行时接线（bootstrap、驱动注册、生产 Embedder、KnowledgeStore）。

### Modified Capabilities

- `llm-content-store`：新增 `KnowledgeStore` 的 PG/MySQL 实现要求；
- `llm-meta-store`：`LLMConfStore` 增加完整配置字段。

## Impact

- 代码：`f_llm/src/store/{postgres,mysql}/`、`Stores.bootstrap()`、`memory/`、`llm/LLMConfs*.cj`；
- 依赖：`f_llm/cjpm.toml` 需把 `postgres_driver` / `mysql_driver` 从 test-dependencies 提升到 dependencies（实现包 import 驱动）；
- 配置：新增 `llm_embeddingUrl` 已在用，需确认超时/批大小键；
- 测试：MySQL 需 9.7 + MyVector；PG 需 pgvector；无环境时显式跳过并打印原因。

## Out of Scope

- 通道 MCP（微信/飞书/钉钉/QQ/邮件）与人格绑定；
- loom 编排与技能自演进；
- fhydra/f_hydra 的 HTTP 内容族实现。

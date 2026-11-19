# llm-store-wiring Specification

## Purpose
TBD - created by archiving change f-llm-store-wiring. Update Purpose after archive.

## Requirements

### Requirement: 数据访问分层

MySQL / PostgreSQL 的 `MemoryRepository` 实现 SHALL 把 SQL 收敛到 `@DAO` 接口（参考 `LLMConfDAO`），
实现类 MUST NOT 持有 `SqlExecutor` 字段或构造参数，并 SHALL 实现 `fountain::f_orm.RootService`，
通过 `executor()` / `dao<T>(driver)` 获取执行器。

#### Scenario: 构造 Repository 不需要执行器

- **WHEN** 已注册 `postgres` 驱动后执行 `PostgresMemoryRepository()`
- **THEN** 构造成功，`add` / `search` 能通过 DAO 访问数据库

#### Scenario: SQL 只出现在 DAO 层

- **WHEN** 检查 `PostgresMemoryRepository` / `MySqlMemoryRepository` 源码
- **THEN** 其中不出现 `SELECT` / `INSERT` / `UPDATE` / `DELETE` 字面量，SQL 全部位于对应 DAO 接口

#### Scenario: 未注册驱动时报错可定位

- **WHEN** 未注册 `mysql` 驱动就调用 `MySqlMemoryRepository().add(...)`
- **THEN** 抛出异常，消息包含驱动名 `mysql` 与注册提示，而不是空指针

### Requirement: 启动时按配置接线

系统 SHALL 在启动时读取 `llm_contentStore` / `llm_metaStore`，调用对应实现包的注册函数，使 `Stores.content()` / `Stores.meta()` 返回已配置的后端；未知值 MUST 启动失败并列出可选实现。

#### Scenario: 配置 postgres 后可直接取用

- **WHEN** `llm_contentStore=postgres` 且 `llm_metaStore=postgres`
- **THEN** `Stores.content().memory` 与 `Stores.meta().confs` 可用，且不需要业务代码 import 具体实现类

#### Scenario: 未注册的配置值启动失败

- **WHEN** `llm_contentStore=sqlite`
- **THEN** 启动抛出异常，消息包含 `sqlite` 与当前已注册的实现名

### Requirement: 生产 Embedder

系统 SHALL 提供 BGE-M3 的生产 `Embedder` 实现（HTTP），支持 dense / sparse / colbert 三路；向量服务不可用时 MUST 拒绝写入，检索结果 MUST 标记 `degraded=true`。

#### Scenario: 向量服务失败拒绝写入

- **WHEN** `/v1/embeddings` 返回非 200 或维度不符
- **THEN** `MemoryStore.add` 抛错，`repo.upsert` 未被调用

#### Scenario: 检索降级

- **WHEN** sparse 或 colbert 一路不可用
- **THEN** 检索仍返回 dense 结果，并标记 `degraded=true`

### Requirement: 业务层只依赖接口

`Memory` / `FaithfulMemory` / `LLMConfs` SHALL 只通过 `Stores.content()` / `Stores.meta()` 访问存储，MUST NOT 直接 import 具体实现类或驱动。

#### Scenario: 同一业务代码切换后端

- **WHEN** 把 `llm_contentStore` 从 `postgres` 改为 `mysql` 并重启
- **THEN** 业务层代码无需修改，读写与检索行为保持一致

### Requirement: 知识存储实现

PG 与 MySQL SHALL 提供 `KnowledgeStore` 实现，支持文档 upsert / get / remove，同 `docId` 覆盖写。

#### Scenario: 同文档覆盖

- **WHEN** 对同一 `docId` 连续 upsert 两次
- **THEN** `get(docId)` 返回第二次内容，且记录数不增加

# Proposal

## Why

`f_llm` 目前没有统一的持久化抽象：记忆（`memory/`）直接用 `f_store` 落 JSON，知识/文档缺少存储接口，人格（`llm_character`）与技能/提示词/模型配置也没有独立后端，导致「只装 PostgreSQL」和「完全不用数据库」两种部署都做不到。

《f_llm-memory-design.md》§5 已定稿：存储拆成**内容族**（记忆/经验/知识/文档）与**元数据族**（人格/技能/提示词/模型配置），各自三选一、可交叉组合。本变更落地这个底座，后续 loom、通道、技能演进才有稳定的存取契约。

## What Changes

- 新增 **内容族** `ContentStore`：记忆/经验/知识/文档，三个实现 `PostgresContentStore` / `MySqlContentStore` / `FhydraContentStore`，由 `llm_contentStore` 选择。
  - 本变更交付接口、内存测试替身、**PostgreSQL 与 MySQL 两个实现**；fhydra 内容族仍按引用方后续变更实现（HTTP 契约已在 `fhydra-design.md`）。
  - 记忆检索**一次做全三路**：dense（pgvector/MySQL VECTOR）+ sparse（倒排表）+ colbert（多头重排），并按 kind 固定权重打分。
- 新增 **元数据族** `MetaStore`：人格/技能/提示词/模型配置，三个实现 `PostgresMetaStore` / `MySqlMetaStore` / `FStoreMetaStore`，由 `llm_metaStore` 选择。
- 新增 `Stores` 工厂与 `registerContent` / `registerMeta` 扩展点；未知配置值**启动失败**，不静默回退。
- 新增 `MemoryKinds`：7 个预定义 kind（note/fact/preference/task/doc/knowledge/session）、自定义 kind 归属用户、预定义不可删、启动幂等补种。
- 新增 `CharacterStore` 与默认人格（13 个预定义 + custom）的存取；人格注入与裁剪保护仍走现有链路，本变更不改裁剪行为。
- DDL 收敛：`llm_memory` / `llm_memory_kind` / `llm_memory_vector` / `llm_memory_token` / `llm_character` 落进 `f_llm/tables-pg.sql` / `tables-mysql.sql`。
- 在 WSL Ubuntu 24.04 安装 MySQL 最新版并启用向量索引，跑通 MySQL 侧全部用例。
- **BREAKING**：`llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath` 三个配置键被 `llm_contentStore` / `llm_metaStore` / `llm_metaStorePath` 取代（旧键在启动时 `warn` 并忽略）。

## Capabilities

### New Capabilities

- `llm-content-store`: 记忆/经验/知识/文档的统一存取契约、用户与命名空间隔离、kind 注册表、三路检索、可替换后端。
- `llm-meta-store`: 人格/技能/提示词/模型配置的统一存取契约、f_store 无数据库运行、可替换后端。

### Modified Capabilities

<!-- 无：人格注入与上下文裁剪的行为不变，本次只新增存储层 -->

## Impact

- 代码：`f_llm/src/store/`（新增）、`f_llm/src/memory/`、`f_llm/src/config/LLMConfig.cj`、`f_llm/src/model/po/`、`f_llm/src/dao/`。
- 依赖：`fountain::f_orm`、`fountain::f_store`（均已有 path 依赖）；不引入第三方依赖。
- 数据库：新增/调整 5 张表；PostgreSQL 用 pgvector 0.8.2，MySQL 需 **9.2+**（`VECTOR` + `VECTOR INDEX`）；WSL 现场安装并验证。
- 配置：新增 `llm_contentStore` / `llm_metaStore` / `llm_metaStorePath` / `llm_contentStoreUrl`，废弃 3 个旧键。
- 文档：`f_llm/README.md`、`README_en.md` 增补存储选型与接口说明；`doc/spec/f-llm-memory-storage/` 落盘四件套。
- 兼容性：`Memory` / `FaithfulMemory` 的公开静态方法保持不变，内部改走 `ContentStore`；`LLMConfs` 快照来源改为 `MetaStore.confs`。
- 环境：WSL Ubuntu 24.04 新增 MySQL 9.2+ 服务（随变更一起安装并写测试）。

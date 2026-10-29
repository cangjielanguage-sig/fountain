# Tasks

> 每个任务按 TDD 推进：先写失败用例并确认失败原因正确（Red）→ 最小实现（Green）→ 重构；跑绿才勾选。
> 顺序按评审意见：内存 → PostgreSQL → f_store → 安装 MySQL → MySQL 实现与测试。

## 1. 契约与工厂

- [x] 1.1 为 `Stores.content()/meta()` 写失败用例：未知配置抛错并列出可选值，合法值返回对应实现；跑出 Red 后实现注册表与工厂，用例转绿
- [x] 1.2 定义 `ContentStore` / `MetaStore` 及六个子接口（`MemoryStore` / `KnowledgeStore` / `CharacterStore` / `SkillStore` / `PromptStore` / `LLMConfStore`），配 `InMemory*` 测试替身；conformance 用例在内存实现上跑绿
- [x] 1.3 新增配置键 `llm_contentStore` / `llm_metaStore` / `llm_metaStorePath` / `llm_contentStoreUrl`，旧键 `llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath` 启动 `warn` 并忽略；用例断言告警与默认值
- [x] 1.4 在 `f_llm/README.md` / `README_en.md` 增补存储选型与扩展点说明；核对示例命令与接口名一致

## 2. 内容族：PostgreSQL（三路检索一次做完）

- [x] 2.1 在 `tables-pg.sql` 落 `llm_memory` / `llm_memory_kind` / `llm_memory_vector` / `llm_memory_token`（含 HNSW 索引），真实 PG 执行两遍验证幂等；`tables-mysql.sql` 同步列定义
- [x] 2.2 写 `MemoryKinds` 用例：预定义 7 值、自定义归属用户、删除预定义抛 `IllegalArgumentException`、启动补种幂等；实现后转绿
- [x] 2.3 写记忆写入用例：标题/正文分别向量化、同 `(user_id,namespace,title)` 覆盖、向量服务失败拒绝写入；实现 `PostgresMemoryStore.add` 后转绿
- [x] 2.4 写 dense 检索用例：相似度排序、`topK×2` 超取后截断、kind 权重乘算、`topK` 上限；实现后转绿
- [x] 2.5 写 sparse 检索用例：query token 命中倒排、权重累加、与 dense 融合（0.7/0.3）、无 sparse 时 `degraded=true`；实现倒排读写与融合后转绿
- [x] 2.6 写 colbert 重排用例：`rerank=true` 改变排序但不改候选集、`rerank=false` 不读 colbert 列；实现 max-sim 重排后转绿
- [x] 2.7 写隔离用例：跨用户不可见、`global` 跨工作空间可见、`ws-*` 互不可见；实现查询条件后转绿
- [x] 2.8 把 1.2 的 conformance 用例接 PostgreSQL 实现跑绿；无 PG 环境时跳过并打印原因
- [x] 2.9 在 `f_llm/doc/` 增补「内容族存储」说明（表、三路检索流程、权重），与设计文档 §5/§6 对齐

## 3. 元数据族：PostgreSQL 与 f_store

- [ ] 3.1 写 `FStoreMetaStore` 用例：写入后重建实例仍可读、主体存在而索引缺失时启动补索引、删除先删索引；实现后转绿
- [x] 3.2 写 `CharacterStore` 用例：一人一条覆盖、13 个预定义 key 可解析、`custom` 原样保存、未知 key 拒绝、`reset` 回落 `default`；在 f_store 与 PG 上分别跑绿
- [ ] 3.3 写 `LLMConfStore` 用例：`enabled=false` 与 `weight<=0` 不进候选、按 `llmName` 查询、`setHolder` 兼容；实现 PG 与 f_store 后转绿
- [ ] 3.4 写 `SkillStore` / `PromptStore` 契约用例：技能 `version` 默认 1、提示词按 `(name, version)` 存取、未知记录返回空值；实现 f_store 后转绿
- [ ] 3.5 把 1.2 的 conformance 用例接 PG / f_store 跑绿
- [ ] 3.6 在 `f_llm/README.md` / `README_en.md` 补「仅 f_store 运行」示例（配置 + 启动 + 冒烟命令），核对可照抄执行

## 4. MySQL：安装、实现与验证

- [ ] 4.1 在 WSL Ubuntu 24.04 安装 MySQL 9.2+（官方 APT 源），记录版本、端口与 root 认证方式；`mysql --version` 与 `SELECT VERSION()` 均为 9.2+
- [ ] 4.2 验证 MySQL 向量能力：`VECTOR(1024)` 建表、`CREATE VECTOR INDEX ... USING HNSW`、`VECTOR_DISTANCE` 查询三步可用；不可用时记录降级结论
- [ ] 4.3 实现 `MySqlMemoryStore`：写与 PG 同构的 DAO（记忆/kind/向量/倒排），先写用例（复用 conformance）跑出 Red，再实现转绿
- [ ] 4.4 实现 `MySqlMetaStore`：人格/配置/技能/提示词，复用 3.x 用例在 MySQL 上跑绿
- [ ] 4.5 跑 MySQL 侧完整 conformance：topK 与 PG 一致（浮点容差）、无向量索引时降级 `warn`、迁移 DDL 幂等
- [ ] 4.6 在 `f_llm/README.md` / `README_en.md` 增补 MySQL 版本要求与降级说明；记录实测版本

## 5. 集成与回归

- [ ] 5.1 将 `Memory` / `FaithfulMemory` 内部改走 `Stores.content().memory`，公开签名不变；补回归用例证明摘要与写入路径行为一致
- [ ] 5.2 将 `LLMConfs.holder()` 数据源切到 `Stores.meta().confs`，保留 `setHolder` 测试注入；既有 167 条用例全绿
- [ ] 5.3 跑 `fboot build` + `cjpm test` 全量，确认无新增 warning；失败项逐条修复后再勾选
- [ ] 5.4 把 propose 产物同步到 `f_llm/doc/spec/f-llm-memory-storage/`（proposal/specs/design/tasks 全量）

## Workflow follow-up

- 执行 `opsx:verify`，CRITICAL 清零后再进入归档。
- 归档前提交代码与文档，保留变更目录直至确认无需返工。
- `opsx:archive` 后用最终版覆盖 `f_llm/doc/spec/f-llm-memory-storage/`。

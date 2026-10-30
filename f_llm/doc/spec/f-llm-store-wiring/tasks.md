## 0. 数据访问分层（DAO + RootService）

- [x] 0.1 写 `PostgresMemoryDAO` / `MySqlMemoryDAO` 的 `@DAO` 接口（SQL 全部下沉，方法体默认实现）
- [x] 0.2 `PostgresMemoryRepository` / `MySqlMemoryRepository` 删除 `SqlExecutor` 字段与构造参数，改 `<: MemoryRepository & RootService`
- [x] 0.3 驱动名与库名解析：从 `StoreSettings` 取 driver 与 database（MyVector 路径），不再由调用方传 executor
- [x] 0.4 迁移现有测试：先注册 ORM，再 `PostgresMemoryRepository()` / `MySqlMemoryRepository()`，全绿

## 1. 配置模型扩展

- [x] 1.1 写 `LLMConfStore` 完整配置用例（url/auth/temperature/always_thinking/conf 往返）
- [x] 1.2 扩 `LLMConfView` 与三实现（PG/MySQL/f_store）并转绿
- [ ] 1.3 `LLMConfSource` 适配器：以 `Stores.meta().confs` 为数据源，保留旧来源回退

## 2. 生产 Embedder

- [ ] 2.1 写 BGE-M3 客户端用例（批量、超时、非 200、维度不符）
- [ ] 2.2 实现 `HttpEmbedder`（`/v1/embeddings`，dense/sparse/colbert 三路）
- [ ] 2.3 失败重试与降级：向量化失败拒绝写入，检索标记 `degraded`

## 3. KnowledgeStore

- [ ] 3.1 写文档/块 conformance 用例（upsert/get/remove、同 docId 覆盖）
- [ ] 3.2 PG 实现（`llm_document` / `llm_document_chunk` 或复用现有表）
- [ ] 3.3 MySQL 实现（同构）
- [ ] 3.4 f_store 实现或明确不支持（元数据族 vs 内容族的边界）

## 4. 实现包与 bootstrap

- [ ] 4.1 `f_llm/cjpm.toml`：驱动提升到 dependencies，补 target bin-dependencies
- [ ] 4.2 `store/postgres`：`register()` 注册 content/meta 工厂（executor + embedder）
- [ ] 4.3 `store/mysql`：同上
- [ ] 4.4 `Stores.bootstrap()`：按 `StoreSettings` 调用对应 `register()`；未知值启动失败
- [ ] 4.5 用例：注册后可 `Stores.content()/meta()`；未注册时错误信息含可选值

## 5. 业务层切换

- [ ] 5.1 `Memory` / `FaithfulMemory` 走 `Stores.content().memory`，公开签名不变
- [ ] 5.2 回归用例：摘要与写入路径行为一致（对比切换前后）
- [ ] 5.3 `LLMConfs.holder()` 走 `Stores.meta().confs`，保留 `setHolder`
- [ ] 5.4 全量回归（目标：现有 231 条 + 新增用例全绿）

## 6. 文档与归档

- [ ] 6.1 README 补 bootstrap 与实现包说明
- [ ] 6.2 `doc/spec` 同步 proposal/specs/design/tasks
- [ ] 6.3 归档并更新主 specs

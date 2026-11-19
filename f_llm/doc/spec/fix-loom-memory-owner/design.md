# Design

## Decisions

### D1. 归属写进 docId，而不是新增列

`loom:<userId>:<namespace>:<flow>:<stamp>-<seq>`：一次字符串拼接同时解决两件事——跨重启不撞号、演进侧可按前缀过滤。

**替代**：给知识文档加 owner 字段。否决——`KnowledgeDoc` 是对外契约，加字段要动两套 SQL 表与三个后端。

### D2. 策略加锁用「箱体」模式

`effective()` 需要返回值，`synchronized` 块是 Unit 语义，用 `PolicyBox` 带出（与 `DocSeqBox` 一致的既有写法）。

### D3. 演进归属默认值改为空串，用「空=未给」判定

`evolutionNamespace` 默认从 `'loom'` 改为 `''`；`evolutionOwner` 里空串回落策略的 namespace。默认值等价（策略默认也是 `loom`），但能区分「调用方真的想要 loom」与「没给」。

### D4. 旧格式知识不消费

`ownedBy` 只认新前缀。旧数据作者不明，宁可少取也不串味——这是安全方向的取舍，写进文档。

### D5. 提炼观测用 warn，不引入新指标

`LoggerFactory.warn` 是既有能力；零写入与异常各一条，文案固定便于 grep。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 旧 docId 的知识不再进演进 | 一次性重建知识（重新 writeKnowledge）即可；已在 `known-limitations` 语义内 |
| docId 变长（含 userId/namespace） | 字段是 `VARCHAR(128)`，实测格式 ≈ 60 字符，安全 |
| 策略加锁带来细微开销 | 每次执行读一次，可忽略 |

## 未覆盖（留给后续变更）

演进素材 `limit=500` 与水位线无条件推进：需要把 `state.markRun(now)` 改成「推进到已处理的最大 at」，并配分页取数，属独立设计。

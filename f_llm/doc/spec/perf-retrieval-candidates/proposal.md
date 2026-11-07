# Proposal

## Why

R6 剩下的热点集中在「按候选数放大远程调用」：

- `HydraKnowledgeStore.search` 对**每个**候选 `transport.get` 一次正文（N+1），候选上限 400 → 最多 400 次远程往返；
- `PostgresKnowledgeStore` / `MySqlKnowledgeStore` 词面召回默认 `maxCandidates=1000`（5 页 × 200 行），
  候选与正文全量驻留内存；
- `SqlMemoryStore.search` 的重排对**每个**候选 `repo.colbert()` 一次 DB 往返，候选上千时为 1000 次。

## What Changes

- Hydra：候选先按融合分排序，只取前 `max(limit*4, 20)` 个拉正文；不够再放宽到全量（正确性优先）。
- PG / MySQL 知识：词面候选上限 1000 → **400**（2 页），默认值下调并保留可调参数。
- 记忆重排：只对融合分最高的前 `max(topK*4, 20)` 个候选查 colbert，其余按 0 分排在后面。
- 测试：1 条（100 个候选时 colbert 只查 20 次）。

## 未做（本轮明确不做）

**`SkillCatalog.search` 的技能列表缓存**：`skill.upsert` 之后必须立即可检索，缓存会引入陈旧窗口；
现有向量缓存已按 `标题#版本` 命中，重复的只有一次本地 `skills.list()` 读取——收益低于「新技能立刻生效」的正确性。
如确实需要，应做成「带版本的失效缓存」而不是 TTL，另开变更。

## Capabilities

### Modified Capabilities
- `loom-flow`：检索的远程调用次数与候选上限有明确上界。

## Impact

- 代码：`store/hydra/ContentStore.cj`、`store/postgres/KnowledgeStore.cj`、`store/mysql/KnowledgeStore.cj`、`store/PostgresMemoryStore.cj`。
- 行为：召回**总数**可能略降（知识候选 1000→400、重排只看前 N），`limit` 内的结果不变。

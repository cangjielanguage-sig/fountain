# Proposal

## Why

R1 指出「检索融合逻辑与权重常量在 memory/knowledge × 各后端各写一遍」。核对后是 4 处同构：

| 位置 | 现状 |
|---|---|
| `store/postgres/KnowledgeStore.cj:34-35,158` | `LEXICAL_WEIGHT=0.1` / `LEXICAL_CAP=5.0` / `dense + w*min(lexical,cap)` |
| `store/mysql/KnowledgeStore.cj:34-35,160` | 同上，逐字重复 |
| `store/InMemoryStores.cj:247-248` | 内联 `5.0f64` 与 `0.1f64`，注释都没有 |
| `store/PostgresMemoryStore.cj:117,128-129` | `0.7*dense + 0.3*sparse`、`0.4*title + 0.6*content`（裸数字） |

后果：调权重要改 4 个文件；`InMemoryStores` 与 SQL 后端的打分口径可能悄悄漂移；数字没有名字，读代码不知道 0.7/0.3 是什么。

## What Changes

- 新增 `store/RetrievalScoring.cj`：集中常量（记忆融合 0.7/0.3、colbert 重排 0.4/0.6、知识词面 0.1/上限 5.0）与三个函数
  （`fuseMemory` / `fuseKnowledge` / `rerank`）。
- 上述 4 处改为调用它；`InMemoryStores` 与两个 SQL `KnowledgeStore` 的打分口径从此只有一个定义。
- 补 5 条用例钉住常量与函数语义（含 lexical 上限截断）。

## Capabilities

### Modified Capabilities
- `loom-flow`：检索融合同一口径（行为不变，只收口实现）。

## Impact

- 代码：新增 1 文件，改 4 个文件；**打分数值完全不变**，属纯重构。
- 测试：新增 5 条；全量基线 645。

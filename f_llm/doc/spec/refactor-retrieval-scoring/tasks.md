# Tasks

## 1. 集中定义

- [x] 1.1 新增 `store/RetrievalScoring.cj`（6 个常量 + 3 个函数）；验证：`RetrievalScoring_test` 5 条（记忆融合、重排、知识融合、cap 截断、常量值）。
- [x] 1.2 `store/postgres/KnowledgeStore.cj` 改用 `fuseKnowledge`，删掉私有常量。
- [x] 1.3 `store/mysql/KnowledgeStore.cj` 同上。
- [x] 1.4 `store/InMemoryStores.cj` 改用 `fuseKnowledge`，去掉内联的 0.1/5.0。
- [x] 1.5 `store/PostgresMemoryStore.cj` 改用 `fuseMemory` / `rerank`。

## 2. 集成

- [x] 2.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 645），打分数值不变。
- [x] 2.2 `doc/f_llm-memory-design.md` 补一句「检索打分的唯一来源是 `RetrievalScoring`」。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/refactor-retrieval-scoring/`。

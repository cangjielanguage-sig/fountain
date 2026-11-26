# Spec Delta

## ADDED Requirements

### Requirement: 检索的远程调用次数有上界

检索实现 MUST 对「按候选逐个远程取数」设上界：只有融合分最高的前 N 个候选才发远程调用
（N = `max(limit*4, 20)` 或 `max(topK*4, 20)`），其余按 0 分处理或不再拉取；结果不足时 MAY 放宽到全量。

#### Scenario: 记忆重排的候选上界

- **WHEN** 100 个候选、`topK=5`、`rerank=true`
- **THEN** `repo.colbert()` 只被调用 20 次，结果仍返回 5 条

#### Scenario: 知识候选上限

- **WHEN** 使用 PG / MySQL 知识库的默认参数
- **THEN** 词面召回最多 400 条候选（2 页 × 200），不再是 1000

#### Scenario: Hydra 只拉需要的正文

- **WHEN** 稠密/稀疏召回返回 400 个候选、`limit=5`
- **THEN** 只对分数最高的前 20 个候选做正文拉取；不足 5 条时再放宽

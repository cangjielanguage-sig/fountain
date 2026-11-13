# Spec Delta

## ADDED Requirements

### Requirement: 检索打分的单一定义

记忆与知识的混合打分 MUST 由 `RetrievalScoring` 统一定义与计算；各后端 MUST NOT 各自内联权重常量。

- 记忆：`score = 0.7 * dense + 0.3 * sparse`，再乘 kind 权重；
- 记忆重排：`0.4 * titleSim + 0.6 * contentSim`，只改顺序不改分数；
- 知识：`score = dense + 0.1 * min(lexical, 5.0)`。

#### Scenario: 知识打分的词面上限

- **WHEN** 某块词面命中数 `lexical = 12`
- **THEN** 计入打分的词面部分为 `0.1 * 5.0 = 0.5`，不会随命中数无限增长

#### Scenario: 三个后端同一口径

- **WHEN** 同一 `dense` 与 `lexical` 输入分别交给内存、PostgreSQL、MySQL 后端
- **THEN** 得到相同的分数（差异只来自候选集，不来自公式）

#### Scenario: 记忆融合

- **WHEN** `dense=1.0, sparse=0.0`
- **THEN** 融合分为 `0.7`，与既有行为一致

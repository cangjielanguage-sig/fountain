# Tasks

## 1. 记忆重排

- [x] 1.1 只对融合分最高的前 `max(topK*4,20)` 个候选查 colbert，其余预置 0；验证：100 候选 → `colbertCalls == 20`、结果 5 条。

## 2. 知识候选

- [x] 2.1 PG / MySQL 的 `maxCandidates` 默认 1000 → 400；验证：全量回归不退化。

## 3. Hydra

- [x] 3.1 候选按分数排序后只拉前 `max(limit*4,20)` 个正文，不足再放宽；验证：全量回归不退化（hydra 用例走远程桩）。

## 4. 明确不做

- [x] 4.1 `SkillCatalog` 技能列表缓存：`skill.upsert` 后必须立即可检索，缓存引入陈旧窗口，收益低于正确性（理由见 proposal）。

## 5. 集成

- [x] 5.1 全量回归 `cd f_llm && cjpm test` 全绿：654 → **655**。

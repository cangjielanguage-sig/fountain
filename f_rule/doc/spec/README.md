# 规格存档

`openspec/` 目录整体在仓库 `.gitignore` 中（过程产物），本目录是它的**入库存档**，供代码评审与后续变更参考。

## 结构

| 路径 | 内容 |
|---|---|
| `specs/<capability>/spec.md` | **主规范**：7 个 capability 的当前有效要求（46 条 Requirement） |
| `archive/<日期>-<变更名>/` | 已归档变更的完整产物（proposal / design / specs / tasks） |

## 当前状态

`implement-f-rule-m0-m7` 已于 2026-11-01 归档，7 份 delta spec 全部为 ADDED，因此主规范由它一次性生成：

| Capability | 覆盖 |
|---|---|
| `f-rule-engine-core` | 门面与生命周期、错误模型（27 个错误码）、初始化 |
| `f-rule-fact-model` | 事实模型、`FactSpace`、`(space, session)` 隔离 |
| `f-rule-condition` | 15 算子、三值逻辑、条件树与展开、`f_jit` 表达式、求值失败语义 |
| `f-rule-rete` | alpha/beta 网络、索引、节点共享、分片、索引覆盖率 |
| `f-rule-agenda` | 激活、冲突消解、`activationGroup`、`FireMode`、循环检测、动作 |
| `f-rule-flow` | `RuleEnvelope`、`ResolveTask`、`JoinTask`、可达性、版本切换 |
| `f-rule-decision-table` | 表模型、7 种 `HitPolicy`、CSV/XLSX、两条执行路径 |

## 与实现的关系

主规范是**行为契约**，实现细节在 `f_rule/doc/01~11`。两者冲突时以主规范为准；受平台限制无法照做的条款在 spec 里以「实施修订 / 实施取舍」引用块标注，并写明理由（例如 `In` 算子未展开为三个 `Eq` 节点）。

后续变更走 `openspec` 流程：`propose` → `apply` → `verify` → `archive`，归档后同步到本目录。

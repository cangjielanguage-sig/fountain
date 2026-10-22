# 复审范围（fmq / f_mq 修复后全量审计）

## 目标

在 `fix-fmq-full-audit` 全部落地并合入 `sts/1.3.x` 后，复审 `f_mq` 与 `fmq` 的全部文档与代码，回答：

1. **文档-实现一致性**：README、`doc/详细设计.md`、`doc/开发计划.md`、`openspec/specs/**` 与 `doc/spec/fix-fmq-full-audit/**` 的每条承诺，是否都能在代码中找到对应实现；文档中的签名、字段、默认值、路径、行为是否与代码一致。
2. **测试覆盖**：规格中的每个 Requirement/Scenario 是否有直接或等价用例；关键失败路径、边界、并发/恢复场景是否覆盖；是否存在「勾选但无用例」。
3. **空函数/空测试**：空 `@TestCase`、无断言、仅 `@Assert(true)`、只打印、被禁用/注释的用例；空函数体、仅 `return`、`throw NotImplemented`、占位桩。
4. **死代码**：无调用方的私有/内部函数、常量、字段、类型；仅测试使用但生产无入口的代码；不可达分支；被注释掉的代码块；未使用的 import；`@Deprecated` 但无迁移路径的 API。

## 审查模式

- **全树复审**，不是 diff：对象为 HEAD `22c13ec4`（已以 `789f1349` 合入 `sts/1.3.x`）。
- 跳过 Code Review Harness 的 squash 分支准备：无待合并差异。
- 源分支（信息性）：`fix/fmq-full-audit`；目标分支（信息性）：`sts/1.3.x`。
- 项目根目录：`/storage/Users/currentUser/Documents/cangjie/projects/fountain/.worktrees/mq`

## 范围

- 代码：`f_mq/src/**`、`fmq/src/**`（含 45 个 `*_test.cj`）。
- 文档：`f_mq/README*`、`f_mq/doc/**`、`fmq/README*`、`fmq/doc/**`、`openspec/specs/**`、`f_mq/doc/spec/fix-fmq-full-audit/**`、`fmq/doc/spec/fix-fmq-full-audit/**`。
- 脚本：`scripts/mq_e2e.sh`、`scripts/mq_e2e_client/**`（只作为覆盖证据）。

## 轮次

| 轮次 | 范围 | 重点 |
|---|---|---|
| R1 | `f_mq/src/base/**`、`f_mq/src/client/**`、`f_mq/src/exception/**`、`f_mq/src/f_mq.cj` + 协议/客户端规格与详细设计 | 文档-实现一致性、协议/客户端用例覆盖、空测试/空函数、模块内死代码 |
| R2 | `fmq/src/meta/**`、`fmq/src/cluster/**` + metadata-cluster 规格与详细设计 | 元数据/集群行为与文档一致、恢复/冲突/墓碑用例、死代码 |
| R3 | `fmq/src/queue/**` + queue-storage/consume-semantics 规格与详细设计 | 存储/游标/ack/死信/延迟的文档与实现、边界用例、死代码 |
| R4 | `fmq/src/server/**`、`manager/**`、`metrics/**`、`config/**`、`main.cj`、`MQUsage.cj` + server-runtime/manager-cli/metrics/docs 规格与 README | 服务端生命周期/CLI/指标/配置的文档一致性与用例、死代码 |
| R5 | 全部 `*_test.cj` + 全部文档/规格（含 `doc/spec/fix-fmq-full-audit`） | 全局空测试/空函数扫描；Requirement→实现→用例矩阵；全局死代码（未使用符号/import/不可达分支/注释代码） |

## 判定

- **严重**：文档承诺的功能缺失或行为相反；数据正确性/持久化/一致性缺陷；空实现冒充完成；无用例导致关键缺陷不可见；整块死代码仍被当作生产入口。
- **一般**：边界/错误路径缺失；文档签名/字段/默认值与实现不符；覆盖明显不全；局部死代码或未使用符号。
- **建议**：命名、结构、可读性、重复、可观测性等。
- 每条必须给出 `文件:行号`、现象、影响；reviewer 只读，不得修改文件。

## 输出

- `review_v1.md` … `review_v5.md`
- `todo.md`：汇总「严重 + 一般」，按 R1–R5 分组。

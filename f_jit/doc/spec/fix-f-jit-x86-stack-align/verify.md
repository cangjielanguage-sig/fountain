# 校验报告（fix-f-jit-x86-stack-align）

- 变更：`fix-f-jit-x86-stack-align`（x86_64 栈深度 CFG 化）
- 校验时间：2026-10-22
- 校验方式：本 worktree 未安装 `opsx:verify` 工作流（`openspec update` 报 `No configured tools found`），
  按 `references/openspec-workflow.md` 第 6 节**回退口径**执行：`openspec validate --strict` + 人工三对齐。

## Completeness

`tasks.md` 全部勾选（1.1–1.3、2.1–2.2、3.1–3.3、4.1–4.3、5.1–5.2）。两处**实现方式调整**已在任务内注明：
① 字节级对齐断言 → `X86Depth` 机制单测；② 手写栈效应表 → 探针遍采集增量（同源、不漂移）。

## Correctness（需求 → 落点）

| 需求 | 落点 | 证据 |
|---|---|---|
| 深度由控制流推导 | `X86Depth.analyze` + `X86Lower.lower` 三遍 | `X86Depth_test` 5/5 |
| 调用点 16 字节对齐由推导深度决定 | `alignBeforeCall`（公式不变，输入改为 CFG 深度） | 3 个原崩溃用例 + 2 个同型用例全绿 |
| 汇合不一致 / 未识别 ⇒ 退回解释器 | `analyze` 返回 `None` ⇒ `ok=false` | `X86Depth_test` 的拒绝用例 + 全量 0 ERROR |
| 两架构结果一致 | aarch64 未改动；差分随全量绿 | `test.diff` 11/11 |

## Coherence

遵循 `design.md`（方案 A）与既有模式：失败即退回解释器（§13.3 同纪律）、不新增公开 API、
不改 `.fbc`/opcode/error 码；`A64Lower` 零改动。

## 回归与已知问题

- 全量：**1098 例 / 1094 过 / 0 ERROR / 4 FAILED**（修前 1091 / 1084 过 / 3 ERROR / 4 FAILED）
- **4 个 FAILED 为修复前既有**（非本变更引入，已用修前基线比对确认）：
  `p0_6_deadlineInterruptsLoop`、`defaultIsStrict`、`strictDivisionByZeroFails`、`strictFpIsPartOfCacheKey`
  ⇒ 属 `strictFp` / 期限面，建议另立变更（`strictFp` 缺省改 true 的 x86 落地面）
- 差分 11 例、性能 1 例、x86 后端 92 例：全绿

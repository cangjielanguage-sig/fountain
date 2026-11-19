# Tasks

## 1. 红：固化复现与同型用例

- [x] 1.1 复核 3 个崩溃用例在 x86_64 上仍以 SIGSEGV 失败，并登记「RED 证据」（`CastOr_test` 注释 +
      `verify.md`）：修复前全量 **1091 例 / 1084 过 / 3 ERROR**；验证：`cjpm test --filter CastOr_test` 复现崩溃
- [x] 1.2 新增同型用例（表达式 `if` 的 else 分支内含 `argc ≥ 1` helper：`ifElseBranchHelperKeepsAlignment`；
      `while` 回边后调用 helper：`loopBodyHelperKeepsAlignment`）；验证：修复前 4 例 ERROR（含 2 个新例），
      修复后 0 ERROR（RED 以临时回退 `X86Lower.cj` 取得，见 verify.md）
- [x] 1.3 **（实现方式调整）** 原计划的字节级对齐断言改为 `X86Depth` 的 5 个单测
      （直链 / 条件汇合一致 / 汇合不一致 / 跳转越界 / 缺增量）——直接钉住"深度由控制流推导"这一机制，
      比字节模式匹配更稳定；行为面由 1.1/1.2 的崩溃用例覆盖。验证：`cjpm test --filter X86Depth_test` 全绿

## 2. 深度分析器（`X86Depth`）

- [x] 2.1 **（实现方式调整）** 不维护手写栈效应表：改由 `X86Lower` 的**探针遍**采集逐指令净栈增量
      （`delta[off]`，与降低代码同源、不会漂移）；`X86Depth.analyze` 以它为数据流输入。
      验证：`X86Depth_test` 的直链/汇合用例通过（增量与真实降低一致）
- [x] 2.2 实现 `analyze(code, codeOff, codeLen, delta)`（工作列表数据流；`JMP/LOOP_BACK` 仅目标、
      `JZ/JNZ` 目标 + 顺序后继、终止类不传播、`target == end` 视为合法出口、汇合不一致/越界/缺增量 ⇒ `None`）；
      验证：`X86Depth_test` 五形态全绿

## 3. 接入 `X86Lower`

- [x] 3.1 `lower()` 改为三遍（探针 → 数据流 → 发射）：探针遍抑制发射（`put/add/bind/rel32` 统一收口）、
      发射遍逐指令以 `depthAt[off]` 设定 `this.depth`；**不可达区域沿用线性深度**（等价修复前行为）；
      数据流失败 ⇒ `ok = false`（整单元退回解释器）。验证：`X86Lower_test`/`X86Frame_test` 全绿
- [x] 3.2 3 个崩溃用例 + 2 个同型用例转绿；验证：`cjpm test --filter CastOr_test` **14/14 通过、0 ERROR**
- [x] 3.3 深度分析单测转绿（对应 1.3 的调整）；验证：`cjpm test --filter X86Depth_test` **5/5 通过**

## 4. 回归与差分

- [x] 4.1 全量 `cjpm test`：**1098 例 / 1094 过 / 0 ERROR / 4 FAILED**（修前 1091 / 1084 过 / 3 ERROR / 4 FAILED）；
      **0 ERROR 达成**；4 个 FAILED 经比对为**修复前既有**（`p0_6_deadlineInterruptsLoop`、`defaultIsStrict`、
      `strictDivisionByZeroFails`、`strictFpIsPartOfCacheKey`，属 `strictFp`/期限面），已记入 `verify.md` 并另立后续变更
- [x] 4.2 三引擎差分（`fountain::f_jit.test.diff` 11 例）随全量执行全绿（结果 / 错误码 / site / 报告逐位一致）
- [x] 4.3 性能抽查：`PerfCompare_test` 通过（1/1），真机数字 native=5,807,847ns / **jit=3,435,226ns** / interp=6,896,156,912ns（JIT ≈ native 的 59%）——预扫为 O(n) 一次性开销，未观察到退化

## 5. 文档同步

- [x] 5.1 `jit-bytecode-m1.md` §12.3 增「操作数栈深度与对齐（v0.18.37）」条（深度由控制流推导、
      对齐补丁由该深度决定、推导失败退回解释器、aarch64 无此约束），规格版本 → v0.18.37；`plan-m1.md` 依据版本同步
- [x] 5.2 `f_jit/doc/spec/f-jit-m1/verify.md` 追加「2026-10-22 真机回归（x86_64 栈对齐修复）」：
      缺陷、修复、修前/修后数字、RED 证据、4 个既有 FAILED 的归属

## Workflow follow-up

- 用户评审本 `design.md` / `tasks.md` 后再进入 apply。（已完成：2026-10-22 用户确认）
- 全部任务完成后执行 `opsx:verify`（CRITICAL 清零），再 `opsx:archive`。
- 提交与推送按仓库既有规范（一次提交只含本修复 + 用例 + 文档）。

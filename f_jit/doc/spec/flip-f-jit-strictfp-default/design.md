# Design

## Context

`strictFp` 是产物级开关（见 `close-f-jit-out-of-checklist-findings` 的 D2）：`true` 时 `Float64` 的 `/` 发射 `FDIV_CHK`，`false` 时发射 `FDIV`。本次只改**缺省值**与随之而来的口径。

## 决策

### D1 三层默认统一为 `true`

`CompileOptions.strictFp`、`SourceCompiler(strictFp!)`、`Lowerer(strictFp!)` 三处缺省同时改为 `true`。

- **为什么要动内部两层**：只改公开层会留下「同一个表达式经 `Compiler` 编译是严格、经 `SourceCompiler` 直连是宽松」的分叉。上一轮刚把「两套默认值」列为反模式，不能在这里重犯。
- **代价**：内部直连的测试若断言 IEEE，必须显式 `strictFp: false`——这正是期望的：口径由用例自己声明。

### D2 IEEE 用例显式选择宽松

`T2/nan`、`T8/nan`、`T8/inf`、`T8/neg-inf`、`T8/nan-str`、A64 的 `0.0f64 / 0.0f64` 断言的是 `FDIV` 的 IEEE 行为（NaN 规范化、±Inf）。它们在各自的编译辅助函数里显式传 `strictFp: false`，而不是依赖默认值。

理由：这些用例是**opcode 语义**的回归，不是产品默认策略的回归；把默认值写进它们的语义里，会让「默认一变、语义用例跟着红」——那是把两件事绑死。

### D3 缓存键与产物

- 键格式不变（`src/<mode>/v<major>/fp<0|1>/<fnv>`），只是缺省配置现在落在 `fp1`。
- 同进程内旧的 `fp0` 键仍可能被显式关闭严格的调用命中，互不干扰。

### D4 破坏性与回退

默认从宽松变严格属**行为破坏**：依赖 `÷0 → Inf` 的源码会开始抛 `JitException(1)`。回退手段只有一行——`opts.strictFp = false`。proposal 已标注；变更说明需向调用方点明。

## 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 既有用户代码依赖 `Inf` | 默认调用开始失败（显式错误，不是静默错算） | 文档给出 `strictFp = false`；错误码 1 的语义明确 |
| 内部用例大范围转红 | 回归噪音 | 只有 6 处 IEEE 用例需要显式关闭；其余用例不涉 ÷0 |
| 默认值与 `FDIV` 的 M1 规格描述冲突 | 文档不一致 | `design-m1` §2.3.4 与 `jit-bytecode-m1` §2 同步写「缺省严格」 |

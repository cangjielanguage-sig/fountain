# 任务：回边安全点按需发射（`optimize-loop-safepoint`）

> 纯实现优化（`skip_specs: true`）。编号 L = Loop safepoint。
> 环境：`ssh running@172.16.105.2`，`cd .../.worktrees/f_jit/f_jit`，`unset CJPM_CONFIG`。

## L1 基线

- [x] L1.1 记录基线：`doc/optimize-call-path.md` §14 已有（空循环 658/665/662 ns/轮，
      去掉 poll 15/15 ns/轮）。复跑一次确认当前代码仍在 ~660 ns/轮。
- [x] L1.2 确认既有护栏现在**绿**：`AnyBridgeCall_test.p0_6_deadlineInterruptsLoop`
      （过期 deadline 在回边返回 −2 ⇒ `InterruptedException`）——这是本次改动最关键的行为锁。

## L2 AArch64 实现

- [x] L2.1 `CtxFlags` 增 `DEADLINE: Int64 = 8`；`JitContext.create` 按
      `RuntimeEnv.deadlineNanos >= 0` 写 `flags`（替代现在的 `p.write(6, 0)`）。
      注意：`JitContext` 在 `runtime` 包，可直接读同包 `RuntimeEnv`。
- [x] L2.2 `A64Lower.cj` case `0x74`：在 `helperCall0(22)` 前插
      `ldrOff(0,19,48) / movImm64(1,8) / andReg(0,0,1) / cbz(0,'skip')`，poll 后 `bind(skip)`。
      标签名用自增序号（与 x86 `this.seq` 同法）避免与既有 label 冲突。
- [x] L2.3 单跑 `AnyBridgeCall_test`（含 p0_6）：**必须仍全绿**（有期限时 poll 照常执行）。

## L3 测试

- [x] L3.1 新增 `LoopSafepoint_test`：
      - `unboundedLoopRunsToCompletion`：无 deadline 的 2M 轮循环返回 n（不误中断、不设 errCode）；
      - `boundedLoopStillInterrupts`：极短 deadline 的紧循环抛 `InterruptedException`（与 p0_6 互补，
        单列可独立定位）；
      - `loopPerIterCost`：打印每轮 ns（**软观测，不设硬门槛**，避免共享 VM 假失败）。
- [x] L3.2 变异验证（**硬要求**）：把回边的条件跳转临时改成「无条件跳过 poll」（`cbz` 去掉、直接 `b target`），
      `boundedLoopStillInterrupts` 与 `p0_6` **必须变红**；验证完恢复。

## L4 x86 同构

- [x] L4.1 `X86Lower.cj` case `0x74`：在 `helper(22,0,0)` 前插
      `mov rax,[rdi+48] / mov rdx,8 / test rax,rdx / jz skip`，`add rsp,8` 后 `bind(skip)`。
      注意 `add rsp,8` 与 `depth` 记账要保持在 poll 分支内（跳过时必须一起跳）。
- [x] L4.2 若 `X86Lower_test` 可在本机跑，加一条「回边含 `test`+`jz`」的字节断言；
      不可跑则在 verify 里注明「仅同构审查 + A64 行为验证」。

## L5 文档与收口

- [x] L5.1 更新 `doc/jit-bytecode-m1.md` 的回边描述（§5 / §12.6 附近）：
      「回边 = STACK_GUARD + （带 deadline 时）H22 + jmp」。
- [x] L5.2 更新 `doc/optimize-call-path.md` §14：把「未立项」改为「已实施（`optimize-loop-safepoint`）」，
      填实施后数据。
- [x] L5.3 全量 `cjpm test --parallel 1`：**1214/1214 / 0 失败**（新增 4 条；第一遍唯一失败是与本次无关的 `PerfM2` 比值噪声，单跑通过）。
- [x] L5.4 `verify.md`；镜像 `f_jit/doc/spec/optimize-loop-safepoint/`；
      `openspec validate optimize-loop-safepoint --strict`；归档 `2026-11-27-optimize-loop-safepoint`。

## 判定

- 性能目标：空循环 ≤ 60 ns/轮（内部目标，不设自动门槛）；未达则回滚并记录。
- 行为锁：`p0_6` 与新增两条语义用例全绿；变异验证确认「去掉条件」会红。

# 任务：窗口对象复用（`optimize-call-alloc`）

> 纯内部优化（`skip_specs: true`）。编号 W = Window pool。
> 环境：`ssh running@172.16.105.2`，`cd .../.worktrees/f_jit/f_jit`，`unset CJPM_CONFIG`。

## W1 基线

- [x] W1.1 探针复测 `openWindowWith + resetWindow(rs)`（参考 601 ns）与 `L1`（参考慢峰 5967 ns）。
- [x] W1.2 记录 `emptyAllocs`（参考 336 ns/2 个对象）。

## W2 护栏（实现前后都绿）

- [x] W2.1 新增 `WindowPool_test` 2 条：连续 1000 次开合容量正确；`append` 残留不串。
- [x] W2.2 `WindowIsolation_test` / `HandleTable*` / `UnloadConcurrency_test` 先跑一遍留底。

## W3 实现

- [x] W3.1 `RuntimeState` 加 `freeWins`（≤8）。
- [x] W3.2 `HandleTable` 加 `acquireWin` / `recycleWin`；`openWindowWith` 与 `resetWindow` 改走池。
- [x] W3.3 W2.1 + W2.2 全绿。

## W4 A/B 与判定

- [x] W4.1 5 次：`windowRs` 目标 ≤300 ns；`L1` 下降 ≥3%；`Q4` 回退 ≤2%。
- [x] W4.2 未达 MOV ⇒ 回滚并记录。

## W5 变异

- [x] W5.1 `acquireWin` / `recycleWin` 不清 `used` ⇒ `reusedWindowStartsClean` **变红**（另 2 条绿）。
- [x] W5.2 恢复后全绿。

## W6 收口

- [x] W6.1 全量 `cjpm test --parallel 1` 零失败。
- [x] W6.2 `verify.md`；镜像 `f_jit/doc/spec/optimize-call-alloc/`；`openspec validate --strict`。
- [ ] W6.3 归档 `2026-11-27-optimize-call-alloc`；提交。

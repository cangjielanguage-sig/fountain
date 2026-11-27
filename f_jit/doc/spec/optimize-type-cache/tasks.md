# 任务：`localTypeOf` 引用缓存（`optimize-type-cache`）

> 纯内部优化（`skip_specs: true`）。编号 C = type Code cache。
> 环境：`ssh running@172.16.105.2`，`cd .../.worktrees/f_jit/f_jit`，`unset CJPM_CONFIG`。

## C1 基线

- [x] C1.1 `CallPathBench_test` 5 次参考：`L1 ≈ 5967 ns`（慢峰）/ `3500 ns`（快峰）。
- [x] C1.2 探针：`localTypeOf<Int64>` 381 ns、`<注册类>` 1650 ns、`TypeInfo.of` 103 ns、
      引用稳定性 1000/1000。

## C2 护栏（实现前后都绿）

- [x] C2.1 `TypeCodeCache_test` 3 条：交替 T 不串味、同 T 重复一致、`call<Object>` 仍抛 19。
      旧实现上先跑绿（1227 total，3 passed）。
- [x] C2.2 既有 `CallMarshal*` / `JitFunction*` / `Q6Acceptance_test` 在全量中绿。

## C3 实现

- [x] C3.1 `RuntimeState.typeCodes`（≤32 条）+ `typeCodeOf`（`refEq` 线性扫）/ `rememberTypeCode`。
- [x] C3.2 `JitFunction.localTypeOf<T>(rs)`：先查缓存，未命中走 `computeTypeCode` 并登记。
- [x] C3.3 `callLocked` 传入已有的 `rs`。
- [x] C3.4 C2.1 + C2.2 全绿。

## C4 A/B 与判定

- [x] C4.1 透传注册类端到端（50k 次，best-of-3，同代码两臂）：
      无缓存 **16654 / 9748 / 8716 ns** → 有缓存 **13023 / 6845 / 7019 ns**；
      慢峰 **−21.8%**、快峰 **−22~28%**。
- [x] C4.2 判定 **keep**（远超 MOV）。

## C5 变异

- [x] C5.1 `refEq(ti, info)` 恒 false（等价无缓存）：功能全绿，用于 A/B 臂。
- [x] C5.2 `refEq(ti, info)` 恒 true（串味）：`alternatingTypesDoNotCross` **ERROR**
      （「T 与返回类型不符」），其余 2 条仍绿。已恢复，重跑绿。

## C6 收口

- [x] C6.1 全量 **1227/1227 / 0 失败**。
- [x] C6.2 `verify.md`；镜像 `f_jit/doc/spec/optimize-type-cache/`；`openspec validate --strict`。
- [ ] C6.3 归档 `2026-11-27-optimize-type-cache`；提交。

# 任务：编译期名字索引（`optimize-compile-lookup`）

> 纯测量/判定（`skip_specs: true`）。编号 L = Lookup。
> **结论：数据不支持，不做。** 保留测量记录。

## L1 基线

- [x] L1.1 探针：注册 200 个 `PredefinedFunction`，编译含 50 个调用点的源码，20 次取均值、
      best-of-3：**47.7 / 24.9 / 24.9 ms**（双峰，load 3.4–5.7）。
- [x] L1.2 名字查找上限：50 × 200 × ~5 ns ≈ **50 µs**，占快峰 24.9 ms 的 **0.2%**。

## L2 护栏

- [x] L2.1 不新增（无代码改动）。
- [x] L2.2 既有 `CompilerRegistration_test` / `CompilerSnapshotCache_test` / `Semantics_test`
      在全量中保持绿。

## L3 实现

- [x] L3.1 **不做**：`slotOf` 索引收益 0.2% < MOV。
- [x] L3.2 **不做**：`classOf` 同量级。
- [x] L3.3 **不做**：`classSnapshot` 双拷贝在无注册类时可忽略。
- [x] L3.4 不适用。

## L4 A/B 与判定

- [x] L4.1 无 A/B（不改代码）。
- [x] L4.2 判定 **不做**（收益上限 0.2%，远低于 MOV 3%）。

## L5 变异

- [x] L5.1 不适用。
- [x] L5.2 不适用。

## L6 收口

- [x] L6.1 全量保持 **1230/1230**（无代码改动）。
- [x] L6.2 `verify.md`；镜像 `f_jit/doc/spec/optimize-compile-lookup/`；`openspec validate --strict`。
- [x] L6.3 归档 `2026-11-27-optimize-compile-lookup`；提交判定记录。

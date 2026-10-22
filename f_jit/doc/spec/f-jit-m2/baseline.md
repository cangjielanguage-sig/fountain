# f-jit M2 回归基线（M1 全量）

> 本文件是 M2 每一步的对照基准：后续任何一步完成后，`cjpm test` 的 `TOTAL` 必须不少于本基线、
> `FAILED` 必须为 0；`TOTAL` 只允许因新增用例而单调增长，不允许既有用例回归。

## 测量条件

| 项 | 值 |
|---|---|
| 测量命令 | `cd f_jit && cjpm test` |
| 日期 | 2026-10-19 |
| 平台三元组 | `aarch64-unknown-linux-gnu` |
| 编译器 | Cangjie Compiler 1.3.0-alpha.20261016001051 (cjnative) |
| cjpm | Cangjie Project Manager 1.3.0-alpha.07 |
| git HEAD | `33bb02a23ae0660d21f5f5061a57baa595af560f`（分支 `feature/f_jit`） |
| 测量时点 | Q0.1 / Q0.2 代码改动之前（纯 M1 基线） |

## 结果（四元组）

| 用例总数 | 通过 | 失败 | 耗时 |
|---|---|---|---|
| 560 | 560 | 0 | 82 s（`cjpm test` 墙钟，含构建；测试执行自报 32.0 s） |

`SKIPPED = 0`、`ERROR = 0`。本次运行包含差分测试包 `fountain::f_jit.test.diff`（plan-m1 §7 全量）。

## 对照口径

- 每步完成后跑同一条命令；`FAILED` 必须为 0。
- `TOTAL` 只能因新增用例而单调增长（基线 560）。
- M1 产物与语义零变化：差分包与本基线全部用例必须保持通过。

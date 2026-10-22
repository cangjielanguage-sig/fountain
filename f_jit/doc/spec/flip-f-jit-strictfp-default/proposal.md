# Proposal

## Why

`strictFp` 目前缺省 `false`：`Float64` 的 `÷0` 静默得 `±Inf`/`NaN`，错误会沿着后续计算扩散，直到某个不相关的位置才暴露。这类「静默污染」正是本项目一贯要消灭的第三态。

严格模式的代价只是「÷0 当场以 1（`DIV_ZERO`）失败」，而它现在已经是**零运行期开销**的产物级开关（`FDIV_CHK` 替代 `FDIV`，无额外指令）。因此缺省应当是严格，需要 IEEE 语义的调用方**显式**选择放宽。

## What Changes

- `CompileOptions.strictFp` 缺省值 `false` → **`true`**；`SourceCompiler` / `Lowerer` 的同名参数缺省同步为 `true`，避免「公开入口严格、内部装配宽松」的分叉。
- 6 处**验证 IEEE 语义**的既有用例（`T2/nan`、`T8/nan|inf|neg-inf|nan-str`、A64 的 `0.0/0.0`）改为显式 `strictFp: false`——它们断言的是 `FDIV` 的行为，必须自己声明口径，不能靠默认。
- `StrictFp_test` / `AnyBridgeCall_test` 里依赖「默认即宽松」的两条断言改为显式关闭。
- 文档与规格写明缺省值；`CompileOptions` 注释给出「要 IEEE 就显式关」的指引。

## Capabilities

### Modified Capabilities

- `f-jit-facade-bridge`：`编译选项的版本与严格浮点` 增加「缺省即严格」条款与对应 Scenario。

## Impact

- **行为（破坏性）**：公开 `compile` 的默认产物从 `FDIV` 变为 `FDIV_CHK`——任何依赖 `÷0 → Inf` 的既有源码，默认调用会改为以错误码 1 失败；需显式 `strictFp = false` 恢复。
- **字节码**：`.fbc` 格式不变；`FDIV_CHK` 是既有 opcode。缺省级存键由 `fp0` 变为 `fp1`。
- **测试**：6 处 IEEE 用例显式关闭严格；新增 1 条「缺省即严格」用例；其余不变。
- **性能**：`FDIV_CHK` 与 `FDIV` 在解释器/A64 上都是单条指令 + 前置零判定（A64 已有 `fcmp`+`b.eq`），无额外调用开销。
- **不在本次范围**：`Int64` / `Decimal` 的除零（本来就是错误码 1 / 10）。

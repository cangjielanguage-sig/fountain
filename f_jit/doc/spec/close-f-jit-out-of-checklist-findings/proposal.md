# Proposal

## Why

`fix-f-jit-audit-defects` 收口了审查清单内的 26 条缺陷，但在实施过程中**在清单之外**又确认了 4 项问题。它们当时被顺手修掉或登记为「未接线」，没有走规格流程，因此留下三类风险：

1. **修了但没立规**——`CompilePipeline` 把 `verMajor` 从 M2 改成 M3、值用法 `else if` 的不可达 `while` 被删除。这两处只存在于提交信息里，规格没有对应条款，后来者改动时没有任何约束可依。
2. **修了但没修净**——常量键号称「单一事实来源」，实际 `CanonKey.f64` 产出 `f:<bits>`、`CanonKey.cell` 产出 `i:<bits>`：同一个 `Float64` 在「裸 cell」与「装箱」两条承载路径上得到**两个不同的键**。端到端用例只覆盖了裸 cell 那条，装箱路径的失配无人发现。
3. **登记了但还是假的**——`CallContext.strictFp` 写进 `ctx.flags` bit0 后全仓无人读取；`literalCopy` 自 M2 起没有消费点。两个字段都在公共 API 上，调用方按文档打开它们，行为与关闭时完全一样，正是上一轮明令要消灭的「第三态」。

这四项不单独收口，能力矩阵会继续「看起来完整」：`strictFp` 永远查不出除零，Float64 装箱键永远查不到常量 Map，编译版本仍是硬编码常量。

## What Changes

- **版本口径改为显式选项**：新增 `CompileOptions.verMajor`（缺省 `Version.LATEST`），`CompilePipeline.runSource` 不再硬编码 `M3_MAJOR`；缓存键纳入版本，不支持的值在 `compile` 时以 `SourceCompileException` 拒绝。
- **`strictFp` 归位到编译期**：新增 `CompileOptions.strictFp`，决定 `Float64` 的 `/` 发 `FDIV`（0x43，÷0 得 ±Inf）还是 `FDIV_CHK`（0x44，÷0 → 错误码 1）。两引擎的 `FDIV_CHK` 语义已一致，本次只是让前端**能**发射它。
- **删除两个无效字段**：`CallContext.literalCopy` 与 `CallContext.strictFp` 一并移除；`invoke` 不再写 `ctx.flags` bit0。`CtxFlags.STRICT_FP` 保留为历史位并在注释与规格中注明「运行期不读」。
- **值型键统一为裸 cell**：`CanonKey.f64(bits)` 改为与 `CanonKey.cell` 同形（`i:<bits>`），取消 `f:` 前缀；补「承载形态无关」不变式与装箱键端到端用例。
- **补 `else if` 的规格与门禁**：规格明确「值用法与语句用法同构」「先判 `if` 再取块，禁止不可达分支」；代码不改（上一轮已修），只补 Scenario 与回归用例。
- **清单外发现同等留痕**：差分验收规格要求「清单之外的发现」与本清单同等对待——proposal 留痕、有规格条目、有用例。

## 清单外发现（本次的四项）

| 编号 | 发现 | 上一轮处置 | 本次动作 |
|---|---|---|---|
| X1 | `CompilePipeline` 固定 `verMajor = M2`，公开 `compile` 编不了 `Any`/JSON | 改为硬编码 M3 | 改成显式选项 + 缓存键 + 拒绝不支持值 |
| X2 | 常量键根因是「常量表 `f:<bits>` vs 运行期裸 cell `i:<cell>`」 | 值型键统一 `cell`，但 `f64` 保留旧前缀 | 取消 `f:` 前缀，补承载形态不变式 |
| X3 | `strictFp` 无消费点（前端恒发 `FDIV`）；`literalCopy` 无消费点 | 登记为「未接线」 | `strictFp` 升为编译选项并真正接线；`literalCopy` 删除 |
| X4 | 值用法 `else if` 的 `while` 永不进入（先无条件 `parseBracedExpr`） | 已重写解析分支 | 规格补条款与 Scenario，代码零改动 |

## Capabilities

### New Capabilities

（无。）

### Modified Capabilities

- `f-jit-facade-bridge`：新增「调用入口与选项」「编译选项的版本与严格浮点」；`统一调用包装` 拆出选项契约、去掉 `strictFp`/`literalCopy` 的旧口径。
- `f-jit-bytecode-format`：`常量键的规范化` 明确「值型键一律裸 cell、不得另立前缀」。
- `f-jit-compiler-frontend`：`else if 链的语法` 增加值用法与「禁止不可达分支」条款。
- `f-jit-differential-acceptance`：`缺陷回归覆盖与零回归门槛` 扩到「清单外发现」并给出留痕要求。

## Impact

- **API（破坏性）**：删除 `CallContext.strictFp`、`CallContext.literalCopy`；新增 `CompileOptions.verMajor`、`CompileOptions.strictFp`。仓内调用方只有测试；对外属 0.x 破坏性变更，需在变更说明中标注。
- **字节码**：`.fbc` 格式与规则集不变。默认产物（`strictFp=false`）逐字节不变；`strictFp=true` 的产物把 `FDIV` 换成 `FDIV_CHK`，同版本内自洽。
- **缓存**：`CompileCache` 键新增版本与严格浮点标记，旧键自然失效（进程内缓存，无持久化影响）。
- **错误码**：不新增。`strictFp=true` 时 ÷0 → 1（`DIV_ZERO`），与两引擎既有 `FDIV_CHK` 语义一致。
- **测试**：改写 `CallContext_test`（字段删除）、`AnyBridgeCall_test.a3_5`（改探针口径），新增版本/严格浮点/键不变式用例；全量零回归。
- **文档**：`design-m1.md` §8（`strictFp` 从调用级改编译级）、`jit-bytecode-m1.md` §2（flags bit0 标注不读）、`CallContext` 类注释、`CompileOptions` 注释。
- **不在本次范围**：`FDIV_CHK` 的运行期 flags 门控（已明确否决，成本由全部除法承担）、`literalCopy` 的语义补建、`.fbc` 跨版本兼容策略调整。

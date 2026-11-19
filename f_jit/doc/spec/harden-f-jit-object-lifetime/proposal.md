# Proposal：对象生命周期加固（G1/G4/G5/G6 + G3 结论固化）

## Why

对"JIT 侧对象由谁维持 / GC 搬运 / 逃逸与泄漏"的审查给出 6 条结论，其中 4 条是可修的实质缺口：

| 编号 | 问题 | 性质 |
|---|---|---|
| **G1** | `JitFunction.call` 里 `unbox` 抛异常时跳过 `releaseReturnHandle`，而在此之前 `ret` 已 `escape`（逃逸）⇒ `resetWindow` 跳过 ⇒ **每次契约失败泄漏 1 槽** | **真缺陷** |
| **G4** | `isReturnedHandle` 硬编码句柄码集（`4..14` 去 12 + `15` + `16..19`），新增句柄码（M3 之后）容易漏 ⇒ 漏释放 | 可维护性缺陷 |
| **G5** | 无自动化约束"机器码不得持有对象指针"（只能靠评审） | 护栏缺失（**需 x86_64 + aarch64 双后端**） |
| **G6** | 无"调用前后资源归零"断言（`liveCount`/`windowUsed`/`NativeMem`） | 护栏缺失 |
| G2 | 逃逸闭包 `close()` 后已释放（`PromotionGroup.releaseAll` → `releaseEscaped`） | **不是缺陷**（结论入档，不改代码） |
| G3 | 容器元素在写入时已 `cellToAny` 成宿主引用 ⇒ 随容器存活，无需级联提升 | **不是缺陷**（补用例钉结论） |

## What Changes

- **G1**：`unbox` 包 `try/catch`，异常路径先 `releaseReturnHandle` 再重抛（槽归还后 `gen+1`）。
- **G4**：`isReturnedHandle` 改为从 `LocalType.isHandle(code) && code != CLOSURE` 单点派生；
  新增遍历 `0..19` 的完备性用例。
- **G5**：两侧后端加**发射审计**（记录每条内存访问的基址寄存器），新增跨架构审计用例：
  x86_64 允许 `{rsp, rbp, r15}`、aarch64 允许 `{sp, fp, x19, x20}`；越界即失败。
- **G6**：新增"调用前后归零"用例——`HandleTable.liveCount()`、`windowUsed()`、
  `NativeMem.outstanding()` 在连续 N 次调用（正常/抛错/契约失败）前后一致。
- **G3 结论固化**：新增用例——逃逸闭包捕获容器后，跨调用读其元素仍正确（证明元素是宿主引用）。

**不改**：字节码格式、opcode、helper、错误码、`§14.6` 槽级语义、三引擎语义。

## Capabilities

- **Modified Capabilities**：`f-jit-backend`（新增 4 条 Requirement：返回值句柄异常安全、
  句柄码单点派生、发射审计双后端、调用级资源归零）。

## Impact

- 代码：`f_jit/src/JitFunction.cj`（G1）、`f_jit/src/backend/BackendSelector.cj` +
  `X86Lower.cj`（G5 x86 审计）、`f_jit/src/backend/A64Emitter.cj`（G5 a64 审计）；
  测试：`f_jit/src/Lifetime_test.cj`（新）、`f_jit/src/EmitAudit_test.cj`（新）、
  `f_jit/src/base/LocalType_test.cj`/`JitFunction` 相关用例（G4）。
- 风险：G5 审计只在**降低期**记录（不改变产物字节），失败只发生在测试里；生产路径零改动。

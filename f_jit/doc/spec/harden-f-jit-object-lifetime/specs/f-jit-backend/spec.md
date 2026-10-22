# Spec Delta

## Purpose

把「对象生命周期」的四条护栏写进 `f-jit-backend`：返回值句柄在任意出口都归还、句柄码单点派生、
机器码只允许访问受控基址（双后端）、调用前后资源归零。

## ADDED Requirements

### Requirement: 返回值句柄在任意出口都归还

`JitFunction.call` 在返回值解包（`makeRetUnboxer`）**抛异常**时 SHALL 同样归还返回位置的逃逸句柄；
不得依赖 `resetWindow` 兜底（该句柄在解包前已 `escape`，窗口重置会跳过它）。

#### Scenario: 返回值类型契约不符

- **WHEN** 单元返回句柄型（如 14）而宿主以不匹配的 `T` 调用，触发契约错误
- **THEN** 抛出 `JitException`（契约类错误码）
- **AND** 连续 N 次失败后 `HandleTable.liveCount()` 与调用前**一致**（不随次数增长）

### Requirement: 句柄返回码单点派生

"是否需要在返回位置归还句柄" SHALL 由 `LocalType.isHandle(code) && code != CLOSURE` 单点判定，
不得在调用点维护硬编码码集（否则新增句柄码会漏释放）。

#### Scenario: 码表完备性

- **WHEN** 遍历 `LocalType` 全部 0–19 码
- **THEN** `isReturnedHandle` 为真的集合恰为 `4–11`、`13–19`（含 15 与 JSON 16–19）
- **AND** `12`（闭包）恒为假（闭包由提升组释放）

### Requirement: 机器码只允许访问受控基址（x86_64 与 aarch64）

降低期 SHALL 记录每条内存访问的基址寄存器，并在单元降低结束时自检：

- x86_64：基址 ∈ `{rsp(4), rbp(5), r15(15)}`；
- aarch64：基址 ∈ `{sp(31), fp(29), x19(19), x20(20)}`；

出现集合外的基址 ⇒ 该单元**放弃 JIT**（整单元退回解释器），不得生成可能触碰宿主对象的机器码。

#### Scenario: 双后端审计通过

- **WHEN** 编译含算术/字符串/容器/闭包的单元（x86_64 走 `Compiler`，aarch64 走
  `A64Compiler.compileFunction`）
- **THEN** 两侧审计记录非空且全部落在各自允许集合内
- **AND** `X86Lower`/`A64Lower` 的 `success()` 为真

#### Scenario: 越界基址被拒绝

- **WHEN** 审计集合中出现允许集外的寄存器（构造性用例）
- **THEN** 单元降低失败并退回解释器，结果/错误码/site 与纯解释一致

### Requirement: 调用级资源在返回后归零

每次 `JitFunction.call` 返回（正常/抛错/中断/契约失败）后 SHALL 满足：
`HandleTable.liveCount()` 回到调用前基线、`windowUsed() == 0`、`NativeMem.outstanding()` 不增长。

#### Scenario: 连续调用不增长

- **WHEN** 连续执行 N（≥ 20）次成功调用、N 次运行期错误调用、N 次契约失败调用
- **THEN** 三类结束后 `liveCount()` 均等于各轮基线、`windowUsed() == 0`、
  `NativeMem.outstanding()` 与首轮相同

# Spec Mirror — f-jit-facade-bridge（M2.3 增量）

> 只收录 `f-jit-m2.3` 改动的 requirement；其余仍由 `check_scenarios.sh m2` 等承担。

### Requirement: `@JitSignatures` 闭包形参的类型化 adapter

宿主 SHALL 能用 `@JitSignatures[(T1, T2) -> R, …]` 标注任一 `func`，由宏在**宿主编译期**为每个签名生成类型化 adapter 并登记进 `SignatureRegistry`，使 `CALL_HOST` 对闭包形参的调用走静态调用而非 `FunctionTypeInfo.apply`。这与 `@JitBind` 对类成员做的事同构：两者都在宿主编译期把类型固定下来，运行期只按签名查表。

宏 SHALL 生成「一个公开登记函数 + 一个调用它的包级 `let`」：包初始化即完成登记（幂等）；登记函数公开，便于用例在清空注册表后复原。生成的 adapter SHALL 是「把宿主函数值按声明函数类型取用 → 逐参 `as` 声明类型 → 静态调用」的闭包；签名结构不符 SHALL 以宿主异常报出。宏 SHALL 只接受**扁平**签名（形参为单个类型名，允许 `()`）；14 位置按类名记入 `paramNames` / `retName`。未登记签名的调用点 SHALL 维持 M2 的反射路径。

#### Scenario: 宏登记声明中的签名

- **WHEN** 对一个 `func` 标注 `@JitSignatures[(String) -> Int64, (Int64, Int64) -> Bool]`
- **THEN** `SignatureRegistry` 中出现且仅出现这两条结构；包初始化后无需再手工登记

#### Scenario: 登记后闭包形参调用走 adapter

- **WHEN** JIT 单元 `{ g: (String) -> Int64, s: String => g(s) }` 以宿主闭包调用
- **THEN** 结果正确，且该签名的条目带 adapter（不经 `FunctionTypeInfo.apply`）

#### Scenario: 未登记仍可回退

- **WHEN** 清空注册表后再编译同一单元
- **THEN** 仍能正常工作（走反射路径），adapter 是加速手段而非语义前提


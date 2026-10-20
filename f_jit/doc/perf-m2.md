# f_jit M2 性能对照（宿主闭包调用 vs user helper）

> 对应 verify 的 GAP-08；规格 `jit-bytecode-m2.md` §5 的估算为 **1.5–3×**。

## 方法

- 两条通道取**同构**的一元函数 `(Int64) -> Int64`（`x + 1`）：
  - **user helper**：`UserHelperTable.push` 注册 `UserHelperEntry`，经 `invokeHelper(ctx, 0x0100, [x])`；
  - **宿主闭包**：`HandleTable.pin(HostCallback(f, sig))`，经 `invokeHelper(ctx, HOST_CALL_TRAMPOLINE, [h, x])`。
- 预热 64 次（含首次反射元数据建立），随后各跑 2000 次，取 `DateTime.now()` 差值。
- 机器：aarch64（融合引擎，SDK 1.3.0-alpha.20261016001051），`cjpm test --filter PerfM2_test`。

## 实测

| 轮次 | user helper（ns/10k） | 宿主闭包（ns/10k） | 比值 |
|---|---|---|---|
| 第 1 次（未缓存 `FunctionTypeInfo`） | 15,271,110 | 70,732,890 | **4.63×** |
| 第 2 次（缓存 `FunctionTypeInfo` 到条目） | 16,961,740 | 97,557,920 | **5.75×** |

换算单次：user helper 约 **153 ns**，宿主闭包约 **707 ns**（第 1 次）。
两次测量间波动约 ±20%，量级稳定在 **4.6–5.8×**。

## 结论

1. **超出规格估算**（1.5–3×，实测 4.6–5.8×）。
2. **缓存 `FunctionTypeInfo` 无显著收益**（第 2 次反而更慢，属测量波动）——说明成本不在
   `FunctionTypeInfo.of` 的类型查找，而在 `apply` 本身：它走
   `MapleRuntime::MethodInfo::ApplyCJMethod`，是仓颉反射的通用调用入口（参数打包 +
   `ArgValue` 数组 + 间接分派），比静态绑定多两层。
3. 这条开销与元数无关（`apply` 按实参数组调用），换来了 **arity 不受限** 与
   **14 按具体类校验**——`HostCallDispatch` 的 1887 行组合枚举已被删除。

## 可选路径（待决）

| 方案 | 做法 | 代价 |
|---|---|---|
| **A 接受并修正规格** | 把 §5 的估算改为实测区间（4.6–5.8×），保留当前极简实现 | 性能不达标于原估算，需在规格里说明 |
| **B 快速路径** | 恢复「宿主预注册签名 → `invokeN<P..,R>` 静态绑定」，命中时走快速通道 | arity 退回 0–2；`SignatureRegistry` 复活（当前已无调用方） |
| **C 混合** | 默认反射；对已注册签名走静态绑定 | 两套路径并存，需保证语义一致（验签口径、异常码） |

当前代码停在 A 的实现形态：0 行分派表、任意 arity、14 精确校验，比值约 4.6–5.8×。
`PerfM2_test` 以 **10× 为回归门禁**（`T32/host-call-overhead-ratio`）。

## 追加实测：类型化包装闭包 vs 反射 `apply`（2026-10-20）

**动因**：用户提案——把目标函数包成 `(Array<Any>) -> Any`，包装体开头把每个实参 `as` 成形参类型，
再用**静态类型调用表达式**调用真实函数。这样每次调用退化为「普通闭包调用 + N 次 `as`」，
不再走 `MapleRuntime::MethodInfo::ApplyCJMethod` 的参数打包与 MCC stub 跳转。

**实测**（release；`PerfAdapter_test`；`ReflectUser.greet(String): String`，预热 64 × 循环 2000 次；
两条路径每次均新建 `Array<Any>`）：

| 路径 | 总耗时 | 单次 |
|---|---|---|
| `InstanceFunctionInfo.apply(instance, tail(args))`（现状） | 19,594,082 ns | ≈ **9797 ns** |
| 类型化 adapter `{ a => (a[0] as ReflectUser).greet(a[1] as String) }` | 540,157 ns | ≈ **270 ns** |
| **比值** | | **36×** |

对照前节：闭包路径（`FunctionTypeInfo.apply`）为 707 ns/次 = user helper 的 4.6×。
**类方法的反射调用比闭包更贵一个量级**（约 9.8 μs/次），而类型化 adapter 与闭包同量级（270 ns）。

### 可自动到哪一步（关键约束）

| 场景 | 能否自动生成 adapter | 原因 |
|---|---|---|
| **闭包形参** `fn: (User) -> Order` | **能（宏）** | 签名是**源码语法**，宏在编译期可展开为 `{ a => fn(a[0] as User, a[1] as Order) }` |
| **类实例方法** `u.greet(s)` | **不能** | `registerType<T>()` 的泛型体里 `T` 的成员不可见（约束只有 `T <: Object`）；宏也**无法枚举未知类型的成员**（成员清单只在反射里，编译期宏拿不到） |

另有一条**不成立**的路径需记录：JIT 前端（AST 阶段）产出的只有**字节码**，字节码里 14 是句柄 ID，
`as User` 无法出现在字节码中——所以「在 AST 阶段生成转换代码」在纯仓颉里做不到
（与 GAP-05 的死结同源：`as` 的操作数必须是**静态类型**，而签名是**运行期数据**）。

### 结论

- 提案**有效且收益巨大**：类方法 **36×**、闭包约 **2.6×**（707 → ~270 ns，回到规格原估的 1.5–3× 区间）。
- **闭包形参**可做到「用户零样板」（宏展开），建议作为 M2.1 的第一步。
- **类实例方法**只能由宿主显式提供类型化绑定（每方法一行），反射作默认回退；`PublicMethod`
  需增加可选的 `typedImpl`（与 `PublicField.hasSignature()` 同型）。
- M2 仍按用户裁定停在现状（4.6×）；本节的数字作为 M2.1 的立项依据。

## 追加实测：`overrides` 端到端（2026-10-20，M2.1 第一步）

**动因**：上一节测的是「裸闭包替换」这一层（`apply` vs 手写 adapter，36×）。真正交付的是
`registerType<T>(overrides:)`——用户看到的是 `f.call` → 预定义槽位 → `impl` 整条链，
本节测这条链上「换掉 impl」到底省多少。

**方法**（`PerfOverride_test`）：`ReflectUser.bump(Int64): Unit`，三个臂各 3000 次、预热 200 次，
两臂源码相同、仅注册方式不同（`CompileCache` 键只含源码指纹，故每臂前必须 `reset`）。
同机两次独立运行（ns/次）：

| 臂 | 说明 | 运行 1 | 运行 2 |
|---|---|---|---|
| 基线 | `{ u: ReflectUser => 0 }`（不调任何宿主方法） | 18,769 | 17,779 |
| 反射 | `{ u: ReflectUser => u.bump(1)\n 0 }` + `registerType<ReflectUser>()` | 22,743 | 27,905 |
| 覆盖 | 同源码 + `registerType<ReflectUser>(overrides: [bump])` | 21,159 | 18,004 |

扣掉基线后的**方法调用净成本**：反射 **3,973 / 10,125 ns**、覆盖 **2,390 / 224 ns**，
比值 **1.66× / 45×**。两端都比预期散：反射臂要经 MCC 打包 `ArgValue`，会触发 GC，
耗时随 GC 时机摆动；覆盖臂只做一次 `as` + 静态调用，稳定在亚微秒（与上一节手写 adapter 的
270 ns 同一量级）。**取保守值：覆盖把方法调用成本从 4–10 μs 压到 0.2–2.4 μs。**

**为什么不用 `greet(String)`**：反射臂在 String 参数/返回上必现 SIGSEGV（GAP-13），
跑不到 3000 次；值型参数不触发，且两臂的固定开销等价，比值仍具代表性。

### 两条结论

1. **端到端只有 1.1–1.6×，远不是 36×**。差额被 `JitFunction.call<T>` 的固定开销吃掉了：
   `callLocked` 每次调用都执行 `localTypeOf<T>()` → `TypeInfo.of<T>()`（`JitFunction.cj:632`），
   实测 ≈**18 μs/次**，占端到端总成本的 **65–98%**。方法调用本身只有 0.2–10 μs。
2. 因此 M2.1 的下一个高价值优化不是「继续压方法调用」，而是**把 `T` → `LocalType` 的映射缓存**
   （`localTypeOf` 走静态表 / 首次查表后按类型键缓存）。这一项不改任何语义，收益覆盖**所有**
   `call` 调用（含 M2 已有的全部用例），比 overrides 本身大一个量级。

`T32/override-beats-reflect` 的门禁因此只设 **1.25×**（拦「覆盖退化成反射」），不承担端到端加速比的表达。

闭包层的 36× 结论不受影响（上一节，直接对 `InstanceFunctionInfo.apply` 计时，不含 `call` 开销）。


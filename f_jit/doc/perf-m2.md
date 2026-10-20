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

# 调用路径：`localTypeOf<T>` 按 TypeInfo 引用缓存

## Why

`JitFunction.call<T>` 每次调用都要把 `T` 映射成 `LocalType` 码，当前实现是：

```cangjie
let info = TypeInfo.of<T>()
let n = simpleTypeName(info.name)   // 去命名空间前缀：unsafeBytes + 分配新 String
match (codeOfTypeName(n))           // 最多 19 次字符串比较
```

2026-11-27 探针（慢峰，load 3.16，探针已删）：

| 测量 | 数据 |
| --- | --- |
| `TypeInfo.of<T>()` + `.name.size` | **103 ns** |
| `TypeInfo` 引用稳定性（1000 次 `refEq`） | **1000/1000 相同** |
| `localTypeOf<注册类>` 全流程 | **1650 ns（占慢峰 L1 的 27%）** |
| `localTypeOf<Int64>` | **381 ns（6%）** |

即 **1.5 µs 花在 `name.unsafeBytes()`、去前缀分配与字符串比较上**，而不是反射查找本身。
宿主调 JIT 函数时 `T` 多为注册类（`call<User>` / `call<Order>`），这一项是当前调用路径的最大单项。

## What Changes

在 `RuntimeState` 里加一张**线程私有**的小表，键是 `TypeInfo` 的**引用**（不是名字）：

```cangjie
internal let typeCodes: ArrayList<(TypeInfo, UInt16)> = ArrayList<(TypeInfo, UInt16)>()

public func typeCodeOf(info: TypeInfo): ?UInt16              // refEq 线性扫，≤32 条
public func rememberTypeCode(info: TypeInfo, code: UInt16)   // 首次未命中后登记
```

`JitFunction.localTypeOf<T>` 改为接收调用方已持有的 `rs`：

1. `let info = TypeInfo.of<T>()`（103 ns，无法避免）；
2. `rs.typeCodeOf(info)` 命中 → **直接返回 code**（~20 ns，0 TLS、0 分配）；
3. 未命中 → 走原 `simpleTypeName` + `codeOfTypeName`，成功则 `rememberTypeCode`。

**语义不变**：映射结果逐位一致；`None`（不可解包类型）不缓存；表上限 32 条，
超出后不再登记（继续走原路径，行为不变）。

## Impact

- 收益目标：注册类调用 **−1.5 µs（−27%）**、`Int64` 调用 **−0.36 µs（−6%）**；
- 影响文件：`src/runtime/RuntimeState.cj`、`src/JitFunction.cj`（+ 新增护栏用例）；
- 风险：缓存键必须用**引用相等**（`refEq`），不能用 `==`（不同 `TypeInfo` 可能同名/同结构）；
  以「`Int64` 与注册类交替调用」用例锁住串味；表容量上限防止无界增长。

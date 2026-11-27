# 设计：`TypeInfo` 引用缓存

## D1 为什么用引用做键，而不是名字

| 方案 | 命中路径成本 | 问题 |
| --- | --- | --- |
| 每次现算（现状） | 1650 ns | `unsafeBytes` + 去前缀分配 + 19 次比较 |
| 以 `info.name` 为键的 `HashMap` | ~300 ns（取 name + 哈希） | 仍要 `unsafeBytes`/字符串哈希；小表下不划算（§15.3 同型教训） |
| **以 `TypeInfo` 引用为键的线性小表** | **~20 ns** | 依赖 `TypeInfo.of<T>()` 返回稳定实例 |

实测 `TypeInfo.of<注册类>()` 在 1000 次调用中 **1000 次 `refEq` 相同**（std 反射元数据缓存），
故引用相等是稳定判据；即使未来实现改为每次新建，最坏退化为「每次未命中」，行为仍正确。

## D2 表放在 `RuntimeState`

`JitFunction.callLocked` 已经持有本线程的 `RuntimeState`（`optimize-runtime-tls`），
把表放进去可以**零 TLS** 访问；放全局表会引入锁或 `AtomicReference`，对 20 ns 的命中路径不划算。
表是线程私有的，天然无竞争。

## D3 容量与失败语义

- 上限 **32 条**：调用点通常只有个位数 `T`；超出后不再登记，继续走原路径（正确性不变）。
- **只缓存成功的映射**：`localTypeOf` 返回 `None`（不可解包类型）时不登记 ——
  这类调用本来就会抛 19，缓存它没有收益，还会占表。
- 命中后直接返回 `Some(code)`，不再做 `ClassTypeInfo` / `InterfaceTypeInfo` 判定。

## D4 与 `codeOfTypeName` 的等价性

缓存值来自**同一套** `simpleTypeName` + `codeOfTypeName` 逻辑（原样保留为未命中路径），
因此「缓存命中」与「现算」逐位一致；不做任何码表重写。

## D5 护栏与变异

新增 `TypeCodeCache_test`：

1. **交替调用不串味**：`f1.call<Int64>` 与 `f2.call<Probe>` 交替 100 次，结果逐个正确；
2. **同 T 重复调用**：连续 1000 次 `call<Probe>`，结果一致；
3. **不可解包类型**：`call<Object>` 仍抛 19（`Object` 不是可解包类型），且不污染后续调用。

变异：

- 把 `refEq(ti, info)` 改成「恒 true」⇒ 第 1 条必须变红（`Int64` 拿到注册类 code，返回/校验错误）；
- 把 `rememberTypeCode` 改成空实现 ⇒ 功能仍绿（只是退化），因此**缓存生效**用 A/B 数据证明，
  功能护栏只保证「不串味」。

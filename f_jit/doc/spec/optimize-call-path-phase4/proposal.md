# 为什么：两处残余锁清理

## A. `JitBindSupport.mtx` —— 唯一有负面扩展证据的锁

`ReflectRegistrar.isInstanceOfHost` 是短路的：

```
isInstanceOfHost(o, name) = isInstanceOfClass(o, name) || JitBindSupport.acceptsInterface(o, name)
```

- 类实参走反射祖先链，不取锁；
- **接口实参**必然落到 `acceptsInterface`，每次取全局 `mtx` + `HashMap` 查找。

临时探针（已删除）：`acceptsInterface` 1 线程 293 ns/op，4 线程 731 ns/op ⇒ **0.40×**
（与 Phase 2 前的句柄锁同型 convoy）。即 `{ p: SomeInterface => … }` 这类单元，
每个接口实参每次调用要付 0.3–0.7 µs 的全局串行。

## B. `openWindow` 的全局 `mtx` —— 每次调用一次的纯读锁

`openWindow` 用 `synchronized(mtx) { totalSlots }` 只为了读一个高水位当窗口基址；
该值在 Phase 2 之后不再是正确性依据（窗口槽允许复用、不要求连续）。这是调用链上
**唯一残留的每调用全局锁**。

## 变更内容

1. **A**：`JitBindSupport` 的 `enrolled` / `interfaceAccepts` 两张表合成不可变快照，
   写时复制 + `AtomicReference` 发布；读路径零锁零拷贝。
2. **B**：`HandleTable.totalSlots` 改 `AtomicInt64`；`openWindow`/`resetWindow`/`liveCount`/
   `slotCount` 用 `load()`，增长仍在 `mtx` 内（保证段发布顺序）。

## 非目标

- 不改 `PromotionGroup`、`HostFieldTable.writeMtx`、`CompileCache`/`Compiler`（数据不支持）；
- 不改任何公开语义、错误码或注册顺序；
- 不做无锁空闲表 / 每槽原子字。

## 判定

- A：`acceptsInterface` 微基准 4 线程扩展比从 0.40× 提升到 ≥2×（本机 4 线程上限 2.2–2.4×），
  且并发登记/读取护栏全绿；
- B：窗口开合路径维持 2.2–2.4×（当前 2.28×）不回退，`slotCount` 并发读护栏全绿；
- 两项均要求全量 1202+ 用例零失败。

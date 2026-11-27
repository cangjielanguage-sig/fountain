# `HandleTable` 可调配置的原子化（H4）

## Why

`src/runtime/HandleTable.cj` 的两个公开可调项是普通 `public static var`：

```cangjie
public static var initialCapacity: Int64 = 128
public static var capacityLimit: Int64 = 1048576
```

调用路径（`openWindowWith` / `winStackOf` / `newSlot`）直接读它们。如果有人在线程 A 调用
中途修改，线程 B 的读取在语言层面是**数据竞争**（未定义行为）：可能读到旧值、撕裂值，
或编译器把读缓存到循环外。

实际约束只是「调用前可调，不追溯进行中的调用」，但这一点目前没有同步保证，也没有
文档承诺。

## What Changes

改为 `AtomicInt64` + `mut prop` 访问器，**赋值语法不变**：

```cangjie
HandleTable.initialCapacity = 128      // 仍然这样写
```

- `initialCapacityAtomic` / `capacityLimitAtomic` 为 `AtomicInt64`；
- `public static mut prop initialCapacity` / `capacityLimit` 的 get 用 `load()`、set 用 `store()`；
- 所有内部读点语法不变（自动走 getter）。

## Impact

- 影响文件：`src/runtime/HandleTable.cj`；
- 性能：每次 `openWindow` 多一次原子读（`initialCapacity`），在 2971 ns/call 的调用成本里
  是 1 ns 量级；`capacityLimit` 只在分配新槽时读；
- **可测性说明**：在 aarch64/x86_64 上 8 B 对齐的普通读写本身不会撕裂，因此旧实现
  无法用测试稳定复现错误——本变更的价值是消除语言级 UB、并让「运行中可调」有明确语义，
  **不主张可测的行为差异**。护栏只做回归：并发改配置时窗口容量恒为两个合法值之一。

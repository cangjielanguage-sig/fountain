# `NativeAssets` 计数原子化（H2）

## Why

`src/backend/NativeAssets.cj` 的 `allocs` / `frees` 是普通 `Int64` 静态字段，
`onAlloc()` / `onFree()` 直接 `+1`，`liveCount()` 无锁读差值。

并发编译/卸载时这是典型的 `read-modify-write` 竞争：两个线程同时读到 7 再写回 8，
其中一次增量丢失。后果：

1. `liveCount()` 偏低甚至为负——T27/T29 的「资产无泄漏」断言在并发下**不可信**；
2. 诊断数据（`allocs`/`frees`）只用于测试，不影响运行时正确性。

虽然 `NativeMem.outstanding()`（另一套计数）早已是 `AtomicInt64`，但 `NativeAssets`
这一套在 `optimize-*` 期间被漏掉了。

## What Changes

`allocs` / `frees` 改 `AtomicInt64`：

- `onAlloc` / `onFree` → `fetchAdd(1)`
- `liveCount()` → `load()` 差值
- `resetCounters()` → `store(0)`

API 不变（都是 `static func`），调用方零改动。

## Impact

- 影响文件：`src/backend/NativeAssets.cj` + 新增护栏 `src/backend/NativeAssetsConcurrency_test.cj`；
- 性能：每次资产分配/释放多一条原子加（`FnTable`/`ConstMirror` 每单元各一次，调用路径零成本）；
- 风险：低。护栏在旧实现上必须**红**（并发增量丢失），改后必须**绿**。

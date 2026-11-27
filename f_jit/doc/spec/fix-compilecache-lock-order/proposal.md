# 编译缓存与单元关闭的锁序修正（H1）

## Why

`CompileCache.finish()` 在**持有全局缓存锁**期间调用 `fn.bindCacheKey(key)`，而
`bindCacheKey` 内部要取该 `JitFunction` 的 `mtx`；`JitFunction.close()` 则相反：在
**持有单元 `mtx`** 期间调用 `CompileCache.remove(k)`，要取全局缓存锁。

两者构成经典的 ABBA 加锁顺序。当前**不可达**（`finish` 时该单元尚未写入 `ready`，
外部拿不到引用），但这依赖「先 bind、后发布」这一隐式调用图不变式：任何一次
「先发布、后 bind」的调整都会把它变成真实死锁。属于必须消掉的脆弱设计。

代码位置：

- `src/CompileCache.cj` `finish()`：`synchronized(mtx) { fn.bindCacheKey(key); ready[key] = fn; … }`
- `src/JitFunction.cj` `close()`：`synchronized(this.mtx) { …; CompileCache.remove(k); … }`

## What Changes

`finish()` 把 `bindCacheKey` 移到全局锁**之外**，先 bind、再进锁发布。

安全性：`bindCacheKey` 执行时该函数对象尚未出现在 `ready` 中，`awaitReady` 也不可能
提前返回（`compiling` 仍含该 key，且只在锁内移除），因此不存在「另一线程已持有该对象并
并发 `close`」的窗口。锁序从「缓存锁 → 单元锁」收敛为「只有单元锁」与「只有缓存锁」，
两条路径不再交叠。

## Impact

- 影响文件：`src/CompileCache.cj`（1 处顺序调整）；
- 语义不变：`finish` 的可观察结果（`ready` 发布、`compiling` 移除、失败清理）、
  以及「先 bind、后可见」的顺序都不变；
- 风险：低。护栏为现有 `CompileCache_test`（4 条）+ `ConcurrencyMatrix_test`（5 条，
  含并发编译同源/异源）+ 全量。

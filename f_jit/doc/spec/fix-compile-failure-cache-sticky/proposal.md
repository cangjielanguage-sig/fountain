# 编译失败缓存的失效与有界化

## Why

`CompileCache.failures` 是一张「源码指纹 → 失败文本」的表，写入点在 `CompilePipeline`
的两处 catch，**清理点只有一个：`CompileCache.reset()`**（测试专用，`protected`）。
生产路径上 `remove(key)` 只在成功单元 `close()` 时被调用，失败单元没有 close。

直接后果（已用探针复现）：

```
编译 { u: LateCls => u.m(1) }
  → BadParameterList「未注册的类名「LateCls」」
registerClass(LateCls)          ← 补注册
再编译同一源码
  → CompileFailed，文本仍是「未注册的类名「LateCls」」
```

1. **功能**：宿主「先尝试编译 → 失败 → 补注册 → 重试」的流程走不通。注册表已经变了，
   失败结论却仍被当作有效缓存；外部又没有清缓存的入口（`reset` 是 protected）。
2. **资源**：`failures` 随失败源码数量**无界增长**——每个新失败源码一条，永不释放。
   长期运行的服务若持续喂入不同源码（模板、动态表达式），这张表只增不减。

`ready` 表也只增不减，但那是缓存设计（有 `close` 逐出入口）；`failures` 的问题是
「错误的结论被永久固化」，性质不同。

## What Changes

1. `CompileCache` 新增 `invalidateFailures()`：锁内 `failures.clear()`。
2. `Compiler` 的**所有注册入口**在 `this.mtx` 内调用它：
   `registerFunction` / `unregisterFunction` / `registerClass` / `registerType` / `registerInterface`。
   语义：注册表发生变化 ⇒ 之前因「未注册类/函数」而失败的源码应当可重试。
3. `failures` 加**上限 256**：`fail()` 写入前若已达上限先 `clear()`，保证有界
   （代价是偶尔丢掉一批失败缓存，重编一次即可；失败路径本来就是冷路径）。
4. 新增 `failureCount()`（internal，测试与诊断用）。

**锁序**：`Compiler.mtx → CompileCache.mtx`。反向路径已在 H1（`fix-compilecache-lock-order`）
消除——`CompileCache.finish` 不再在持缓存锁时取单元锁，与 `Compiler` 无交集，因此无 ABBA。

## Impact

- 影响文件：`src/CompileCache.cj`、`src/Compiler.cj`；新增护栏 `src/CompileFailureCache_test.cj`；
- 行为变化：注册之后，之前失败的源码会**重新编译**（可能成功，也可能再失败）。语法/类型
  错误的源码会多花一次编译时间（~5 ms），这是可接受代价；
- 不改变：成功单元的缓存与 `close` 逐出逻辑；并发编译的 `claim/awaitReady` 去重；
- 风险：低。护栏两条：注册使失败失效（改前必红）、失败表有界（改前必红）。

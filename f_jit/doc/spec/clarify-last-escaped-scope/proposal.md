# `lastEscaped` 的并发语义收敛（H3）

## Why

`src/JitFunction.cj` 的普通 `call<T>` 在返回闭包（`retType=12`）时，除了把提升组登记进
`escaped` 列表（锁内），还会写单元级字段 `this.lastEscaped = Some(e)`——**在锁外**。
两个访问器 `lastEscapedClosure()` / `lastPromotionGroup()` 也是无锁读。

后果：

1. **数据竞争**：多线程同时返回闭包时互相覆盖，读者可能看到不完整/过期的引用（技术上 UB）；
2. **语义未定义**：即使加锁，「最近一次」在多线程下也没有确定含义。

生产路径不受影响：`callForFn` 早已改为每次调用私有的 `CallOut`（D5），该字段只剩
单线程诊断（`JitFunctionClosure_test` 一处手工包装）与兼容访问器。

## What Changes

1. `callLocked` 里 `lastEscaped` 的写改到 `synchronized(this.mtx)` 内（该路径本来就要
   `registerEscaped` 进同一把锁，可合并为一次临界区）；
2. `lastEscapedClosure()` / `lastPromotionGroup()` 的读同样进锁；
3. 两个访问器的文档注释写明：**单线程诊断口径**，并发下值不确定；并发场景请用 `callForFn`
   （它返回的包装绑定本次调用的提升组，不经过该字段）。

不改变任何可观察的单线程行为。

## Impact

- 影响文件：`src/JitFunction.cj`（3 处 + 注释）；
- 性能：只在「返回闭包」的调用上多一次 `synchronized`（该路径本就低频），普通调用零成本；
- 护栏：新增 `LastEscapedScope_test`（并发 `call` 返回闭包 + 并发 `callForFn` 混合，
  断言包装结果全部正确、句柄账目回基线），并保留 `JitFunctionClosure_test` 的手工包装路径。

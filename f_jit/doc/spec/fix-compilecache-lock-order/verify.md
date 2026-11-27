# 验证：fix-compilecache-lock-order

## 1. 改动

`src/CompileCache.cj` `finish()`：

```diff
 public static func finish(key: String, fn: JitFunction): Unit {
-    synchronized(mtx) {
-        fn.bindCacheKey(key)
+    fn.bindCacheKey(key)
+    synchronized(mtx) {
         ready[key] = fn
         compiling.remove(key)
         failures.remove(key)
     }
 }
```

## 2. 锁序分析

改前：

| 路径 | 加锁顺序 |
| --- | --- |
| `CompileCache.finish` | 缓存锁 → 单元锁（`bindCacheKey`） |
| `JitFunction.close` | 单元锁 → 缓存锁（`CompileCache.remove`） |

改后 `finish` 不再在缓存锁内取单元锁，两条路径各自只持一把锁，ABBA 消失。

**为什么移出锁仍然正确**：`bindCacheKey` 执行时该对象尚未写入 `ready`，`compiling`
仍在锁内（且只在稍后移除），`awaitReady` 不可能提前返回 ⇒ 不存在「外部已持有该对象
并并发 `close`」的窗口。即「先 bind、后发布」的可观察顺序不变。

## 3. 测试

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `CompileCache_test` | 4 | 全绿 |
| `ConcurrencyMatrix_test` | 5 | 全绿（含 6 线程并发编译同源/异源） |

## 4. 说明

本条是**结构加固**，没有可观测行为变化，也没有性能主张。它消除的是
「依赖调用图不变式」的隐式风险：一旦将来有人把 `finish` 改成「先发布、后 bind」，
旧实现会立刻变成真死锁，而新实现不会。

## 5. 全量

`cjpm test --parallel 1`：**1253 / 1253，0 失败 0 错误**。

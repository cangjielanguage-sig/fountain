# 验证：fix-native-assets-atomic

## 1. 新增护栏

`src/backend/NativeAssetsConcurrency_test.cj`：

- `concurrentAllocCountIsExact`：4 线程各 `FnTable.alloc(1)` 100 次并全部保留，
  断言 `NativeAssets.liveCount()` **精确等于 400**；逐个 `free()` 后回 0。

选择「全部分配、全部保留」而不是「分配后立刻释放」：后者即使丢增量也可能保持
`allocs - frees == 0` 的巧合；只有把未释放量固定为 400，才能把增量丢失放大成必现差异。

## 2. 改前：红

在**未改动**实现上运行：

```
[ FAILED ] CASE: concurrentAllocCountIsExact
Assert Failed: `(NativeAssets.liveCount() == threads * per)`
   left: 396
  right: 400
```

4 线程各 100 次分配丢了 4 次增量——正是 `allocs = allocs + 1` 的
read-modify-write 竞争。

## 3. 改动

```diff
-    private static var allocs: Int64 = 0
-    private static var frees: Int64 = 0
+    private static let allocs = AtomicInt64(0)
+    private static let frees = AtomicInt64(0)

-        NativeAssets.allocs = NativeAssets.allocs + 1
+        let _ = NativeAssets.allocs.fetchAdd(1)

-    public static func liveCount(): Int64 {
-        NativeAssets.allocs - NativeAssets.frees
+    public static func liveCount(): Int64 {
+        NativeAssets.allocs.load() - NativeAssets.frees.load()
```

`resetCounters()` 同步改 `store(0)`。API 与调用方不变。

## 4. 改后：绿

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `NativeAssetsConcurrency_test` | 1 | 全绿（改前红，left=396） |
| `NativeAssets_test` | 4 | 全绿（旧行为不变） |

## 5. 成本

`onAlloc` / `onFree` 只在**每个单元的资产分配/释放**时各调用一次（`FnTable`、`ConstMirror`），
不在调用热路径上；一条原子加的成本可忽略。

## 6. 全量

`cjpm test --parallel 1`：**1254 / 1254，0 失败 0 错误**（较改前 1253 多出本次 1 条）。

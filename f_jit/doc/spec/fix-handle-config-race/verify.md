# 验证：fix-handle-config-race

## 1. 改动

`src/runtime/HandleTable.cj`：

```diff
-    public static var initialCapacity: Int64 = 128
-    public static var capacityLimit: Int64 = 1048576
+    public static mut prop initialCapacity: Int64 {
+        get() { initialCapacityAtomic.load() }
+        set(v) { initialCapacityAtomic.store(v) }
+    }
+    public static mut prop capacityLimit: Int64 {
+        get() { capacityLimitAtomic.load() }
+        set(v) { capacityLimitAtomic.store(v) }
+    }
+    private static let initialCapacityAtomic = AtomicInt64(128)
+    private static let capacityLimitAtomic = AtomicInt64(1048576)
```

赋值语法不变（`HandleTable.initialCapacity = 8` 仍可编译），内部 9 处读点语法不变
（`winStackOf` / `openWindowWith` / 扩容 / `newSlot` / `resetForTest` 等）。

## 2. 可测性（诚实说明）

**旧实现在本机不会失败**：aarch64 上 8 B 对齐的普通 64 位读写是单指令，不会撕裂；
编译器的可见性延迟也只影响「多久看到新值」，不影响合法性。因此本变更**没有**
「改前红、改后绿」的变异证据，也不主张可测的行为差异。

它的价值是：

1. 消除语言层面的数据竞争（Cangjie 的内存模型下，`var` 的并发读写是 UB）；
2. 让「运行中可调」有明确语义（每次读都是原子快照值，不会出现复合状态的中间值）；
3. 为将来把配置扩展成多字段（如 `(initialCapacity, capacityLimit)` 的联合约束）留出正确的扩展点。

## 3. 新增护栏

`src/HandleTableConfigRace_test.cj`：1 线程在 `initialCapacity` 的 8/32 两值间切换 3000 次，
3 线程并发 `openWindowWith` + `resetWindow` 各 3000 次，断言：

- 每次拿到的 `cap` 必为 8 或 32（不会出现 0、负数或其它中间值）；
- `base` 恒为正。

这条用例在旧实现上也会通过（见 §2），作为**长期回归**：任何把配置读取改成多次读取、
或引入非对齐/复合状态的改动都会在这里露头。

## 4. 回归

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `HandleTableConfigRace_test` | 1 | 全绿（新增） |
| `HandleTable_test` | 18 | 全绿 |
| `WindowIsolation_test` | 3 | 全绿 |
| `HandleTableStripeConcurrency_test` | 2 | 全绿 |

## 5. 全量

`cjpm test --parallel 1`：**1256 / 1256，0 失败 0 错误**（较改前 1255 多出本次 1 条）。

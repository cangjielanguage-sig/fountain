# 验证：add-concurrency-matrix-tests

## 1. 基线（改前）

`cjpm test --filter CompileConcurrency_test --parallel 1`：**PASSED 1 / SKIPPED 1247，0 失败**
（1m14s，含编译）；全量基线 **1248 / 1248**。

现有并发护栏的实际覆盖：

- `ParallelCall_test`：同一已编译单元被 4 线程调用（含错误码、句柄账目、卸载）；
- `CompileConcurrency_test`：4 线程 × 10 个**不同**源码；
- `CompileCache_test.concurrentPipelineRunsOnce`：用模拟函数验证 claim/finish 状态机；
- `CallForFnConcurrency_test`：2 线程各自 `callForFn` + 调用 + `close`。

空白：并发编译**同一**源码（真编译、非模拟）、不同单元**同名 helper** 的隔离、
同一包装闭包上的**正常/错误混合**调用。

## 2. 新增用例

`src/ConcurrencyMatrix_test.cj`，5 条（每条都是直接断言）：

| 用例 | 场景 | 关键断言 | 实测耗时 |
| --- | --- | --- | --- |
| `concurrentCompileSameSource` | 6 线程 × 20 次编译同一源码（冷缓存） | `CompileCache.runs()==1`；关闭任一实例后其余实例 `isClosed()` | 8.8–20.3 ms |
| `concurrentCompileDifferentSources` | 6 线程 × 8 个唯一源码 | 48 次独立管线；每个单元只执行 `n*seed+seed` | 11.7–19.6 ms |
| `concurrentCallsOnSameClosure` | 6 线程混合正常值/除零，同一个 `callForFn` 包装 + 捕获 | 正常值恒 `x+1000`；错误线程恒 `DIV_ZERO`；结束后可调用、`close` 幂等 | 6.1–12.5 ms |
| `concurrentCallsOnDifferentClosures` | 3 个单元各自注册同名 `hh`（同一 hid、不同实现），6 线程轮转交错 | 互不串味；句柄账目回到基线 | 5.8–37.4 ms |
| `compileAndCallRunConcurrently` | 1 线程持续编译 + 4 线程持续调用 | 结果正确 | 5.6–17.4 ms |

单类运行：**PASSED 5 / 0 失败**。

## 3. 变异证据（测试必须红）

### M1：`CompileCache.claim` 去掉去重判定

```diff
-            if (ready.contains(key) || compiling.contains(key) || failures.contains(key)) {
-                return false
-            }
```

结果：**只有** `concurrentCompileSameSource` **FAILED**：

```
[ FAILED ] CASE: concurrentCompileSameSource
Assert Failed: `(CompileCache.runs() == 1)`
   left: 6
  right: 1
```

6 个线程各跑了一次管线（left=6），其余 4 条用例 PASSED。
结论：用例 1 精确命中「同键并发去重」。

### M2：`UserHelperTable` 的栈去掉 TLS（进程级共享、无锁）

```diff
-    private static let tls = ThreadLocal<ArrayList<HashMap<Int64, UserHelperEntry>>>()
-    private static func stack(): ... { match (tls.get()) { ... } }
+    private static let tls = ArrayList<ArrayList<HashMap<Int64, UserHelperEntry>>>()
+    private static func stack(): ... { if (tls.size == 0) { tls.add(...) }; tls[0] }
```

结果：**只有** `concurrentCallsOnDifferentClosures` **ERROR**：

```
[ ERROR ] CASE: concurrentCallsOnDifferentClosures
REASON: IndexOutOfBoundsException: Invalid index '2': size is '3'.
```

其余 4 条 PASSED。说明该用例对 helper 活动表的线程私有性敏感。

### M2b：进程级共享栈 + 加锁 + `pop` 不弹（模拟「单表 + 表只增不减」）

结果：**只有** `concurrentCallsOnDifferentClosures` **FAILED**：

```
[ FAILED ] CASE: concurrentCallsOnDifferentClosures
Assert Failed: `(bad == 0)`
   left: 594
  right: 0
```

594 次调用查到了别的单元的同名 `hh`（返回 20 / 30 而非 10）。这说明该用例不仅能
命中崩溃，也能命中**静默错值**——这正是并发缺陷最难发现的一类。

## 4. 恢复后

- 单类：**PASSED 5 / 0 失败**；
- 全量：**1253 / 1253，0 失败 0 错误**（较改前 1248 多出本次 5 条）。

## 5. 边界与说明

- 并发度取 6（构建机 7 核）。8 线程及以上不进常规回归：共享 VM 的 load 常年在 3–9，
  时长不稳；需要压测时用 `ParallelThroughput_test` 的观测入口（只打印不设门槛）。
- 本机为 aarch64，x86_64 路径的并发编译/调用未实跑；建议在 x86 机器上跑本类与
  `X86Exec_test`。
- 用例只钉语义（结果值、错误码、句柄账目），不钉时序，也不设吞吐/加速比门槛。

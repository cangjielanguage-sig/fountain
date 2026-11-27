# 验证：fix-compile-failure-cache-sticky

## 1. 新增护栏（先写，改前必须红）

`src/CompileFailureCache_test.cj`：

1. `registrationInvalidatesFailure`：编译 `{ u: LateCls => u.m(1) }`（类未注册，必失败）
   → `registerClass(LateCls)` → **同源码必须编出来**。
2. `failureCacheIsBounded`：连续 300 个**不同**的语法错误源码 → `failureCount() <= 256`。

## 2. 改前：两红

在未改动实现上运行（只先加了 `failureCount()` 这个纯诊断访问器）：

```
[ ERROR  ] CASE: registrationInvalidatesFailure
REASON: SourceCompileException: CompileFailed ...
        未注册的类名「LateCls」 ...          ← 注册之后仍复述旧错误

[ FAILED ] CASE: failureCacheIsBounded
Assert Failed: `(CompileCache.failureCount() <= 256 == true)`
   left: false
  right: true                              ← 300 条全留着
```

第一条是真缺陷的**直接证据**：`registerClass` 已经成功，同源码重编却拿到注册前的错误文本。

## 3. 改动

`src/CompileCache.cj`：

```diff
+    private static const FAILURES_MAX: Int64 = 256
+
 public static func fail(key: String, message: String): Unit {
     synchronized(mtx) {
+        if (failures.size >= FAILURES_MAX) {
+            failures.clear()
+        }
         failures[key] = message
         compiling.remove(key)
     }
 }
+
+    public static func invalidateFailures(): Unit {
+        synchronized(mtx) {
+            failures.clear()
+        }
+    }
```

`src/Compiler.cj`：五个注册入口（`registerFunction` / `unregisterFunction` /
`registerClass` / `registerType` / `registerInterface`）在 `this.mtx` 内、
`snapCache = None` 之后调用 `CompileCache.invalidateFailures()`。

**锁序**：`Compiler.mtx → CompileCache.mtx`。反向路径已在 H1 消除
（`CompileCache.finish` 不再持缓存锁取单元锁），无 ABBA。

## 4. 语义变化

- 注册后，之前失败的源码会**重新编译**：可能成功（如本例的补注册类），也可能再失败
  （源码本身有错）。后者多花一次 ~5 ms，可接受——注册是冷路径。
- 失败条目超过 256 时整表清空：后续同源再编译一次，不影响正确性。

## 5. 结果

| 用例 | 条数 | 改前 | 改后 |
| --- | --- | --- | --- |
| `CompileFailureCache_test` | 2 | ERROR + FAILED | 全绿 |
| `CompileCache_test` | 4 | — | 全绿 |
| `CompileAwaitTimeout_test` | 2 | — | 全绿 |
| `CompilerRegistrationConcurrency_test` | 1 | — | 全绿 |

## 6. 全量

`cjpm test --parallel 1`：**1261 / 1261，0 失败 0 错误**（较改前 1259 多出本次 2 条）。

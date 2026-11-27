# 验证：fix-await-timeout-semantics

## 1. 改动

`src/CompileCache.cj`：

```diff
+    internal static var awaitTimeoutNs: Int64 = 30000000000
+
+    public static func isCompiling(key: String): Bool {
+        synchronized(mtx) { compiling.contains(key) }
+    }
-            if ((MonoTime.now() - start).toNanoseconds() >= 30000000000) {
+            if ((MonoTime.now() - start).toNanoseconds() >= awaitTimeoutNs) {
```

`src/CompilePipeline.cj`：新增 `missingResult(key, fallback)`，两处 `None` 分支改用：

```diff
             case None =>
-                let msg = match (CompileCache.failureOf(key)) {
-                    case Some(m) => m
-                    case None => '编译失败'
-                }
-                throw SourceCompileException('CompileFailed', 0, 0, 0, '', msg)
+                let (kind, msg) = CompilePipeline.missingResult(key, '编译失败')
+                throw SourceCompileException(kind, 0, 0, 0, '', msg)
```

`runUnit` 同（fallback 为 `'装载失败'`）。

## 2. 三态语义

| 缓存状态 | kind | 消息 |
| --- | --- | --- |
| 有失败文本（首编失败被共享） | `CompileFailed` | 原始失败文本 |
| 仍在 `compiling`（等待者超时） | `CompileTimeout` | `编译等待超时（30 s）：同键编译未在期限内完成` |
| 其它（条目已被移除等） | `CompileFailed` | 调用方给的默认文案（`编译失败` / `装载失败`） |

`SourceCompileException.kind` 是自由字符串，新增 `CompileTimeout` 不触碰运行期错误码体系。

## 3. 新增护栏

`src/CompileAwaitTimeout_test.cj`（2 条）：

1. `awaitTimeoutReturnsNoneAndKeepsCompilingFlag`：`claim` 后把 `awaitTimeoutNs` 设为 1 ms，
   `awaitReady` 返回 `None`、耗时 ≥ 1 ms 且 < 30 s、`isCompiling` 仍为 true；`remove` 后转 false。
2. `missingResultDistinguishesTimeoutFromFailure`：三态各一条直接断言，含超时消息里的
   `编译等待超时` 与秒数 `30 s`。

## 4. 结果

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `CompileAwaitTimeout_test` | 2 | 全绿（新增） |
| `CompileCache_test` / `CompilePipeline_test` / `ConcurrencyMatrix_test` | — | 全量覆盖，全绿 |

## 5. 说明

本条修复的是**诊断语义**，不是正确性缺陷：正常编译路径（成功/失败）行为完全不变，
只有「等待超过上限」这一极端分支从「冒充编译失败」变为可识别的 `CompileTimeout`。
超时上限提为字段后，测试无需构造慢编译即可覆盖该分支。

## 6. 全量

`cjpm test --parallel 1`：**1259 / 1259，0 失败 0 错误**（较改前 1257 多出本次 2 条）。

# 验证：clarify-last-escaped-scope

## 1. 改动

`src/JitFunction.cj` 三处：

```diff
-    internal func lastEscapedClosure(): ?EscapedClosure {
-        this.lastEscaped
-    }
+    internal func lastEscapedClosure(): ?EscapedClosure {
+        var out: ?EscapedClosure = None
+        synchronized(this.mtx) {
+            out = this.lastEscaped
+        }
+        out
+    }

-                            case None => this.lastEscaped = Some(e)
+                            case None =>
+                                synchronized(this.mtx) {
+                                    this.lastEscaped = Some(e)
+                                }
```

`lastPromotionGroup()` 改为经 `lastEscapedClosure()` 取值，两处访问器的文档注释补充
「单线程诊断口径；并发请用 `callForFn`」。

## 2. 语义

- **单线程行为不变**：写入的值相同、读到的值相同；
- **并发行为**：从「未定义（互相覆盖，读取可能撕裂）」变为「有序但不确定是哪一次」；
- 生产路径（`callForFn`）本来就不读该字段（用每次调用私有的 `CallOut`），因此零影响。

## 3. 新增护栏

`src/LastEscapedScope_test.cj`：2 线程用普通 `call<JitClosureId>` 反复返回闭包（持续写
`lastEscaped`），2 线程同时用 `callForFn` 取包装 + 调用 + `close`，各 40 轮。断言：

- 所有 `callForFn` 包装的调用结果正确（`n + 100`）；
- 单元 `close(5000)` 后 `HandleTable.liveCount()` 回到基线（普通 `call` 登记但未承接的组
  由卸载兜底释放）。

## 4. 结果

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `LastEscapedScope_test` | 1 | 全绿 |
| `JitFunctionClosure_test` | 11 | 全绿（含 `lastEscapedClosure()` 手工包装路径） |
| `CallForFnConcurrency_test` | 2 | 全绿 |

## 5. 说明

本条**没有可测的行为差异**：旧实现在 aarch64 上不会撕裂 8 B 引用，测试无法区分。
它的价值是把一个「技术上未定义、文档未声明」的字段收敛为「有锁、有明确口径」。
因此不主张性能或正确性收益，只主张语义明确性。

## 6. 全量

`cjpm test --parallel 1`：**1255 / 1255，0 失败 0 错误**（较改前 1254 多出本次 1 条）。

# 验证：fix-da-diagnostic-classification

## 1. 改前基线（五段实验，`kindOf` 直接读 `SourceCompileException.kind`）

| 编号 | 源码 | 改前 kind | 应为 |
| --- | --- | --- | --- |
| A | `{ => y }`（值位置读未声明名） | **NotAssigned** | `UndefinedIdentifier` |
| B | `{ x: Int64 => unknownFn(x) }`（调用未注册函数） | **NotAssigned** | `UnregisteredFunction` |
| C | `{ => var x: Int64\nx }`（已声明未赋值） | NotAssigned | `NotAssigned` |
| D | `{ c: Bool => var x: Int64\nwhile (c) { x = 1 }\nx }`（循环出口） | NotAssigned | `NotAssigned` |
| E | `{ => var a: Int64\nlet f = { => a }\n1 }`（闭包捕获未赋值） | NotAssigned | `NotAssigned` |

A、B 的提示文本都是「局部变量「y」在读取路径上未必已被赋值……请在读取前显式赋值」——
而这两个名字**从未被声明**，提示与事实矛盾。

## 2. 改动

`src/compiler/DefiniteAssignment.cj` 两处，`state.get(n)` 三态化：

```diff
-                var assigned = false
-                match (state.get(n)) {
-                    case Some(v) => assigned = v
-                    case None => assigned = false
-                }
-                if (!assigned) { diagFail(NOT_ASSIGNED, …) }
+                match (state.get(n)) {
+                    case Some(v) =>
+                        if (!v) { diagFail(NOT_ASSIGNED, …) }
+                    case None =>
+                        // 未在本函数声明 ≠ 未赋值；交给名字解析
+                        return
+                }
```

`walkExprWithOuter` 同构：`outer.get(n)` 为 `None`（内层外层都没有）时放行；
为 `Some(false)` 时仍报「闭包捕获的变量……未必已被赋值」。

**规格依据**：§7 校验 10 的原文是「**非参数局部**在被读取的所有可达路径上必须已被
`STOREL` 显式写入」——只管已声明的局部；未声明名属 §8.4 的 `UndefinedIdentifier` /
`UnregisteredFunction`。本改动是让实现回到规格，不改规格。

## 3. 改后（同一五段实验）

| 编号 | 改后 kind | 结论 |
| --- | --- | --- |
| A | **UndefinedIdentifier** | 正确 |
| B | **UnregisteredFunction** | 正确 |
| C | NotAssigned | 不变 |
| D | NotAssigned | 不变 |
| E | NotAssigned | 不变 |

**没有静默通过**（A/B 都不是 `OK`）——这是改 DA 最需要确认的一点：放行后下游必须真的报错。

## 4. 测试调整

两条既有用例原本用**未声明**名字断言 `NOT_ASSIGNED`，等于固化了误分类：

| 用例 | 原源码 | 改为 | 期望 |
| --- | --- | --- | --- |
| `Semantics_test.readBeforeWriteIsRejected` | `let y = z`（`z` 未声明） | `var z: Int64` + `let y = z` | 仍 `NOT_ASSIGNED`（line 4） |
| `Semantics_test.multiAssignReadsBeforeWriting` | `(a, _) = (q, a)`（`q` 未声明） | 先 `var q: Int64` | 仍 `NOT_ASSIGNED` |

这样两条用例**保持原意图**（读未赋值被拒），而「未声明名报什么」由新用例覆盖。

## 5. 新增护栏

`src/DaDiagnostic_test.cj`（4 条，直接断言 kind 字符串）：

1. `undefinedValueIsNotReportedAsUnassigned` → `UndefinedIdentifier`
2. `unregisteredCalleeIsNotReportedAsUnassigned` → `UnregisteredFunction`
3. `declaredUnassignedLocalStaysNotAssigned` → `NotAssigned`（含循环出口）
4. `capturingUnassignedLocalStaysNotAssigned` → `NotAssigned`（§8.5）

## 6. 回归与全量

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `DaDiagnostic_test`（新增） | 4 | 全绿 |
| `Semantics_test` | 11 | 全绿（两条改用已声明未赋值，意图不变） |
| `AstM2_test` | 4 | 全绿（13/14 槽的 NotAssigned 未受影响） |
| `AnyFrontend_test` | 22 | 全绿 |

`cjpm test --parallel 1`：**1265 / 1265，0 失败 0 错误**（较改前 1261 多出本次 4 条）。

# 明确赋值分析只校验「已声明的局部」（诊断分类修正）

## Why

`DefiniteAssignment.walkExpr` 的 `AstExpr.Var` 分支把「名字不在局部表里」一律当成
「未赋值」，报 `NotAssigned`：

```cangjie
match (state.get(n)) {
    case Some(v) => assigned = v
    case None => assigned = false      // ← 未声明 ≠ 未赋值
}
if (!assigned) { diagFail(DiagKind.NOT_ASSIGNED, ...) }
```

`state` 只记录**本函数声明过的局部**，所以 `None` 同时覆盖三种情况：

1. 名字从未声明（应 `UndefinedIdentifier`）；
2. 名字是未注册的预定义函数（应 `UnregisteredFunction`）；
3. 名字是外层闭包变量（`walkExprWithOuter` 另有处理）。

因为管线是 `parse → DA → lower`（`SourceCompiler.compile`），DA 先抛，`NameResolver`
根本没有机会给出正确诊断。用户看到的是：

```
局部变量「unknownFn」在读取路径上未必已被赋值（局部无默认值，请在读取前显式赋值）
```

——而 `unknownFn` 从未被声明过，这句提示会把人往「补一个赋值」上带。

**规格依据**：`doc/jit-bytecode-m1.md` §7 校验 10 的原文是「**非参数局部**在被读取的
所有可达路径上必须已被 `STOREL` 显式写入」，它管的是**已声明的局部**；未声明的标识符
属于 §8.4 的 `UndefinedIdentifier`，未注册函数属于 `UnregisteredFunction`。
当前实现**超出了规格**，不是规格本身的问题，因此不需要改规格。

## What Changes

`state.get(n)` 三态化：

| 状态 | 含义 | 改后行为 |
| --- | --- | --- |
| `Some(true)` | 已声明且已赋值 | 放行 |
| `Some(false)` | **已声明未赋值** | 报 `NotAssigned`（不变） |
| `None` | **未声明**（本函数与闭包外层都没有） | **放行**，交给名字解析 |

改动点两处：

- `walkExpr` 的 `AstExpr.Var`（197–214）：`None` 分支由「报错」改为 `return`；
- `walkExprWithOuter` 的 `AstExpr.Var`（346–361）：`state` 与 `outer` 都无 → `return`。

`walkCallee` 无需改动：它对非内建/非类名的被调名走 `walkExpr`，改后自动放行，
由 `NameResolver` 报 `UnregisteredFunction`。

## Impact

- 影响文件：`src/compiler/DefiniteAssignment.cj`；新增护栏 `src/compiler/DaDiagnostic_test.cj`；
- **两条既有用例在断言缺陷行为，需要修正期望**：
  - `Semantics_test.readBeforeWriteIsRejected`：`let y = z`（`z` 未声明）原断言
    `NOT_ASSIGNED` → 改后应为 `UNDEFINED_IDENTIFIER`；
  - `Semantics_test.multiAssignReadsBeforeWriting`：`(a, _) = (q, a)`（`q` 未声明）
    同上。
  
  这两条不是「迁就新实现」，而是**测试本身固化了误分类**：源码里从未出现 `z` / `q`
  的声明，报「局部未赋值」与事实矛盾。
- 其余 11 处 `NOT_ASSIGNED` 断言（`var x: Int64` 后读、循环出口、分支汇合、闭包捕获、
  `PULL_NULL` 直存）都是「已声明未赋值」，状态为 `Some(false)`，行为不变。
- 风险：DA 放行后必须确认下游真的报错，不能让未声明名静默通过。先做四段小实验确认落点，
  再改代码（见 `verify.md`）。

# 任务：fix-da-diagnostic-classification

- [x] T1.1 四段实验（改前基线）：未定义值 / 未注册函数 / 已声明未赋值 / 循环出口，记录各自 kind。
- [x] T1.2 确认改前「未定义值」「未注册函数」都是 `NotAssigned`（缺陷证据）。
- [x] T2.1 `walkExpr` 的 `None` 分支放行。
- [x] T2.2 `walkExprWithOuter` 的 `None` 分支放行。
- [x] T3.1 四段实验复跑：未定义值 → `UndefinedIdentifier`、未注册函数 → `UnregisteredFunction`、
      已声明未赋值 / 循环出口仍为 `NotAssigned`。
- [x] T3.2 修正 `Semantics_test` 两条断言（`z` / `q` 未声明 → 改期望 `UNDEFINED_IDENTIFIER`）。
- [x] T3.3 新增 `DaDiagnostic_test`（4 条直接断言）。
- [x] T4.1 全量零失败。
- [x] T5.1 `verify.md`（改前四段 + 改后四段）；T5.2 镜像；T5.3 归档 + 提交。

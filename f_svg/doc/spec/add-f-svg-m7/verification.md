# add-f-svg-m7 验证记录

> 验证命令均在 `f_svg/` 下执行。基线：M6 结束时 209 个 `@Test` 类、1187 条 `@TestCase`。

## 1. 基线（任务 1.2 / 1.3）

| 项 | 命令 | 结果 |
|---|---|---|
| 单元测试 | `cjpm test` | `TOTAL: 1187`、`PASSED: 1187`、`SKIPPED: 0`、`ERROR: 0`、`FAILED: 0`；测试耗时约 87.9s，命令实际耗时 1m48s |
| 构建 | `cjpm build` | `cjpm build success`；`f_svg/src` 0 warning。编译器共打印 22 条 warning，全部来自依赖模块 `f_xml` / `f_base`，与 M7 无关 |

### 1.1 分支与工作区

- 分支：`feature/f_svg`（与前序里程碑一致，未新建分支、未使用 `git worktree`）。
- 开工时 `git status --short` 为空。

### 1.2 已裁决偏差

见 `tasks.md` 末尾「已裁决偏差与不做清单」：D1 文件名冲突落到 `SvgAuthoringBuilder.cj`；D9 `save` 失败使用 `SvgErrorKind.InvalidValue`。

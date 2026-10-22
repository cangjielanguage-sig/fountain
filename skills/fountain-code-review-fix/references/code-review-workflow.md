# 代码审查 → OpenSpec 修复（工作流 L 展开）

**目标**：对当前目录的项目、或项目里的指定模块做一次可追溯的代码审查，产出审查报告，再把报告里的问题按 OpenSpec 六步修复并归档。

## 1. 定范围与基线（只读）

| 项 | 取法 |
| --- | --- |
| `target` | 用户说「当前目录」→ cwd；说「某个模块」→ 该模块目录；说「某个项目」→ 项目根 |
| `project_root` | `git -C <target> rev-parse --show-toplevel`；没有 git / git 不可用时用 `<target>` 向上找 `cjpm.toml` / `openspec/` 的目录 |
| `scope` | 模块模式 = 模块相对 `project_root` 的路径；项目模式 = `.` |
| `source_branch` | 当前分支（`git branch --show-current`） |
| `target_branch` | `master` 存在用 `master`，否则 `main`；用户显式指定优先 |

**基线二选一**（按可观察条件自动判定，不凭感觉）：

- **分支差异模式**：`source_branch != target_branch` 且 `git diff --stat <target>...<source>` 非空 → 审查这条分支相对目标的全部改动（审查技能的阶段零会 squash 到临时审查分支）。
- **工作区快照模式**：没有 git、`source_branch == target_branch`、或 diff 为空 → 审查当前工作区（或指定模块）的现状；**跳过审查技能的阶段零**，从阶段一开始，`scope.md` 写明「基线 = 工作区快照」。

**工作区必须干净**（`git status --porcelain` 为空）才能走分支差异模式。不干净时停下问用户三选一：先提交 / 先 stash / 改为工作区快照审查；**不擅自提交或 stash**。

## 2. 调用 cangjie-code-review-harness

按该技能自己的「调用参数」准备：

```
workdir        = <project_root>/reviews/<YYYYMMDDHHMM>_<简述>/
project_root   = <project_root>
source_branch  = <source_branch>
target_branch  = <target_branch>
parallel_per_batch = 2（默认）
```

`<YYYYMMDDHHMM>` 用 `date +%Y%m%d%H%M` 生成；`<简述>` 用模块名或审查主题（ASCII 更稳，如 `f_store` / `review`）。

执行约束：

- **主 Agent 不读被审源码**：不 `Read` / `Grep` / `Glob` 源文件、不 `git diff` 看内容；所有代码阅读交给 reviewer 子 agent。
- 分支差异模式：严格按技能阶段零→四；阶段零的 `git checkout / merge --squash` 只操作审查分支。阶段零的 `git pull` 因网络 / 凭据失败时**不要卡住**：改用工作区快照模式（跳过阶段零），`scope.md` 写明基线，报告里注明「未对照远端目标分支」。
- 工作区快照模式：跳过阶段零；由主 Agent 写 `scope.md`（模板见下），从阶段一（范围抽取已由 scope.md 完成）→ 阶段二（轮次规划）→ 阶段三（并行审查）→ 阶段四（汇总）。
- reviewer 子 agent 按 `reviewer.md` 主动查阅 `cangjie-coding` / `cangjie-doc-lookup` 核对语言特性与 std/stdx API，不凭记忆判断。
- 轮次规划按**模块边界 / 目录**切分，单轮覆盖不超过约 8–12 个源文件；项目很大时按模块分批，不一次性铺开。
- 阶段四除 `todo.md` 外，让汇总子 agent 再写 `review_summary.md`：审查范围、轮次、各轮严重/一般/轻微统计、总评。

`scope.md` 模板：

```markdown
# 审查范围

- 项目根：<project_root>
- 审查范围：<scope（模块路径或 .）>
- 基线：<分支 source → target 的 diff / 工作区快照>
- 审查重点：正确性、设计合理性、仓颉语言特性、可读性/可维护性、性能、安全性
- 排除：<明确不审的目录，如 generated/、third_party/>
- 报告目录：<workdir>
```

## 3. 审查结束后的收尾

- 分支差异模式会留下临时审查分支与暂存内容：先 `git checkout <原分支>`；若因暂存内容失败，**问用户**是否丢弃审查分支的暂存内容（那是审查技能生成的 squash 副本，不是用户改动），确认后再 `git checkout -f`；审查分支是否删除也问用户，不擅自 `branch -D`。
- `reviews/` 是审查产物目录：确认它在 `.gitignore` / `.git/info/exclude` 里；没有就提醒用户，不擅自改仓库的 `.gitignore`。也可以把 `workdir` 放到项目外（如 `~/.workbuddy/reviews/<项目>-<时间>/`），避免污染工作区。
- 审查阶段**不改任何源码**；发现的问题只进报告。

## 4. 报告 → OpenSpec propose

主 Agent 可以读 `todo.md` 与 `review_summary.md`（这是汇总产物，不是源码）：

1. 统计严重 / 一般 / 轻微数量；**修复范围默认 = 严重 + 一般**；轻微项列在报告里由用户决定是否纳入，不静默丢弃。
2. 给每条问题编号：`R<轮次>-<序号>`（如 `R1-1`），后续 tasks 逐条引用。
3. `openspec update` + `openspec list --json`；未初始化按 `openspec-workflow.md` 第 1–2 节（`<tool>` 问用户）。
4. 执行 `opsx:propose "根据代码审查报告 <workdir>/todo.md 修复 <项目/模块> 的严重与一般问题（严重 X、一般 Y）"`：
   - `proposal.md`：审查范围与基线、问题统计、修复目标与非目标、验收口径；
   - `design.md`：每类问题的修复方案、风险、是否动公开 API / 行为；
   - `tasks.md`：**逐条映射** `todo.md` 的问题，标题带 `[R1-1][严重]`，每条含复现点与测试点；禁止漏项或合并成模糊任务；
   - 把 `todo.md` + `review_summary.md` 复制到 `doc/spec/<变更名>/review.md`（随变更入库，作为修复依据）。
5. 本步只写规划产物，不改代码；完成后停下等用户评审。

## 5. 修复与验收

- **REQUIRED SUB-SKILL:** `test-driven-development`；`opsx:apply` 里逐任务 Red-Green-Refactor：先写能复现该审查问题的失败用例，再最小修复，跑绿才勾任务。
- 审查报告的「建议」只作参考；最终以 `design.md` 为准。修复涉及设计变更 / 公开 API 时回步骤 3 问用户，不自行扩大范围。
- `opsx:verify` 前：受影响模块 + 全量回归（`cjpm test` / `fboot test`）+ `fboot build`；涉及启动链做冒烟。
- 对照 `todo.md` 逐条核对覆盖：未修项必须写明原因并经用户同意；verify CRITICAL 清零。
- 交付说明附审查报告路径与问题清单；`opsx:archive` 后用最终版覆盖 `doc/spec/<变更名>/`（四件套 + `review.md`）。

## 6. 只出报告、不修复

用户明确说「只审查、不修」时，在阶段四输出报告后结束，不进入 OpenSpec。这是工作流 L 唯一不执行六步的情况；用户没说就默认按审查报告修复。

## 7. 红旗

| 你正想做 | 现实 |
| --- | --- |
| 主 Agent 先读一遍源码再派审查 | 审查技能禁止主 Agent 读被审文件；代码阅读交给 reviewer 子 agent |
| 工作区不干净，先提交了再审查 | 提交是用户决定；先问「提交 / stash / 快照审查」三选一 |
| 审查报告只统计不建任务 | tasks 必须逐条映射 `todo.md` 的严重/一般问题，编号可追溯 |
| 顺手把轻微项也全修了 | 修复范围默认严重 + 一般；轻微项是否纳入由用户拍板 |
| 审查后直接改代码，不走 propose | 审查报告是输入，propose 是门禁；未评审 design/tasks 不进 apply |
| 审查分支的暂存内容直接 `reset --hard` | 先问用户；那是审查副本，不是用户改动，但仍需确认 |

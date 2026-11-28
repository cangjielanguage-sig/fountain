# 代码审查 → OpenSpec 修复（工作流 L 展开）

**目标**：对当前目录的项目、或项目里的指定模块做一次可追溯的代码审查，产出审查报告，再把报告里的问题按 OpenSpec 六步修复并归档。

## 1. 定范围与基线（只读）

| 项 | 取法 |
| --- | --- |
| `target` | 用户说「当前目录」→ cwd；说「某个模块」→ 该模块目录；说「某个项目」→ 项目根 |
| `project_root` | `git -C <target> rev-parse --show-toplevel`；没有 git / git 不可用时用 `<target>` 向上找 `cjpm.toml` / `openspec/` 的目录 |
| `scope` | 模块模式 = 模块相对 `project_root` 的路径；项目模式 = `.`（默认范围：所有 `f_*` + `fboot` / `fdbm` / `fmq` / `fprobe`，不含 `f*demo` 与 `.worktrees`） |
| `source_branch` | 当前分支（`git branch --show-current`） |
| `target_branch` | `master` 存在用 `master`，否则 `main`；用户显式指定优先 |

**基线二选一**（按可观察条件自动判定，不凭感觉）：

- **分支差异模式**：`source_branch != target_branch` 且 `git diff --stat <target>...<source>` 非空 → 阶段零 squash 到临时审查分支；基线只用于判定问题来源（本次改动 / 存量），**审查仍是全量**：全部模块、每个 `.cj` 与 `.md`。
- **工作区快照模式**：没有 git、`source_branch == target_branch`、或 diff 为空 → 审查当前工作区（或指定模块）的现状；**跳过审查引擎的阶段零**，`scope.md` 写明「基线 = 工作区快照」。

**工作区必须干净**（`git status --porcelain` 为空）才能走分支差异模式。不干净时停下问用户三选一：先提交 / 先 stash / 改为工作区快照审查；**不擅自提交或 stash**。

## 2. 执行审查（本技能内建引擎）

按 SKILL.md「审查引擎」准备参数：

```
workdir        = <project_root>/reviews/<YYYYMMDDHHMM>_<简述>/
project_root   = <project_root>
source_branch  = <source_branch>
target_branch  = <target_branch>
report_dir     = <project_root>/docs/review/<YYYY-MM-DD>/    # 模块报告，随代码入库
files_dir      = <workdir>/files/                            # 每模块全部 .cj/.md 清单
date           = <YYYY-MM-DD>
parallel_per_batch = 2（默认，按模块计）
```

`<YYYYMMDDHHMM>` / `date` 由 `scripts/review_workdir.py` 生成（同时写 `scope.md`、`modules.md`，并打印 `BRANCH=` / `DATE=` / `MODULE_COUNT=`）；`<简述>` 用模块名或审查主题（ASCII 更稳，如 `f_store` / `review`）。

执行约束：

- **主 Agent 不读被审源码**：不 `Read` / `Grep` / `Glob` 源文件、不 `git diff` 看内容；所有代码阅读交给 reviewer 子 agent。
- **审查引擎自包含**：reviewer 指令在 `reviewer.md`，清单在 `references/review-checklist.md`；不安装、不加载 `cangjie-code-review-harness`。
- **审查单元是模块**：一个模块一个 reviewer 子 agent、一份报告；模块太大（> 15 个文件，`.cj` + `.md`）拆子轮写 `{workdir}/parts/`，由主 Agent 合并成一份模块报告。
- **全量逐文件**：`files/<module>.txt` 列出该模块**全部** `.cj` 与 `.md`（含 README、`README_en`、`doc/**`）。每个文件都要读到，不抽样、不只审 `src/`；报告必须有「文件覆盖」表且与清单逐行对应。
- **每次全量推进**：一次运行覆盖 `modules.md` 全部模块；`modules.md` 全部 `已审` 才进汇总，失败/未审模块先补齐（补不齐须经用户同意）。不按 diff 挑模块，也不沿用上次结论。
- **审完即落盘**：每完成一个模块，报告写入 `docs/review/<YYYY-MM-DD>/<module>.md`，并把 `modules.md` 该行改为 `已审`；同日重审不覆盖，改存 `_v2`。
- 分支差异模式：严格按阶段零→四；阶段零的 `git checkout / merge --squash` 只操作审查分支。阶段零的 `git pull` 因网络 / 凭据失败时**不要卡住**：改用工作区快照模式（跳过阶段零），`scope.md` 写明基线，报告里注明「未对照远端目标分支」。
- 工作区快照模式：跳过阶段零；由主 Agent 写 `scope.md`（模板见下），从阶段一开始。
- reviewer 子 agent 按 `reviewer.md` 主动查阅 `cangjie-doc-lookup` / `fountain-api-lookup` 核对语言特性与 API，不凭记忆判断。
- 阶段四按 `modules.md` 汇总成 `todo.md`（按模块分组）与 `review_summary.md`（跨模块统计、覆盖缺口、总评）。

`scope.md` 模板：

```markdown
# 审查范围

- 项目根：<project_root>
- 审查范围：<scope（模块路径或 .）>
- 默认范围：所有 `f_*` 模块 + `fboot` / `fdbm` / `fmq` / `fprobe`；不含 `f*demo` 示例模块与 `.worktrees`
- 全量要求：模块内每个 `.cj` 与 `.md` 都要读到，文件清单见 `{workdir}/files/<module>.txt`
- 基线：<分支 source → target 的 diff / 工作区快照>
- 审查单元：模块（清单见 `modules.md`，一模块一报告）
- 审查重点：正确性、设计合理性、仓颉语言特性、可读性/可维护性、性能、安全性；
  死代码、表现形式不同的重复逻辑、空实现、栈溢出、OOM、热点瓶颈定位、大粒度锁热点、
  并发串行、低效算法、现有代码的存量 BUG（来源标 `[存量]`）、
  降堆内存 / 降 CPU 可行性方案（含 local mode）
- 已有性能资料：<bench 结果 / profile 输出 / `doc/` 下的优化方案；没有则写"未提供"，
  热点类结论只能按代码结构给「疑似热点（需实测）」>
- 排除：<明确不审的目录，如 generated/、third_party/>
- 过程目录：<workdir>
- 报告目录：<project_root>/docs/review/<YYYY-MM-DD>/
```

## 3. 审查结束后的收尾

- 分支差异模式会留下临时审查分支与暂存内容：先 `git checkout <原分支>`；若因暂存内容失败，**问用户**是否丢弃审查分支的暂存内容（那是审查引擎生成的 squash 副本，不是用户改动），确认后再 `git checkout -f`；审查分支是否删除也问用户，不擅自 `branch -D`。
- `reviews/` 是过程产物目录（`scope.md` / `modules.md` / `todo.md`）：确认它在 `.gitignore` / `.git/info/exclude` 里；没有就提醒用户，不擅自改仓库的 `.gitignore`。也可以把 `workdir` 放到项目外（如 `~/.workbuddy/reviews/<项目>-<时间>/`），避免污染工作区。
- **`docs/review/` 与 `reviews/` 相反：模块报告是交付物，要入库**。不要把它加进 `.gitignore`，也不要在收尾时删掉。
- 审查阶段**不改任何源码**；发现的问题只进报告。

## 4. 报告 → OpenSpec propose

主 Agent 可以读 `todo.md` 与 `review_summary.md`（这是汇总产物，不是源码）：

1. 统计严重 / 一般 / 轻微数量与**存量缺陷**条数（`[存量]` 标记）；**修复范围默认 = 本次改动的严重 + 一般**；轻微项与存量缺陷由用户决定是否纳入，既不静默丢弃也不静默扩大范围。
2. 给每条问题编号：`<module>-<序号>`（如 `f_orm-3`），后续 tasks 逐条引用；存量问题加 `S` 后缀（如 `f_orm-3S`），便于在 tasks 里区分来源。
3. `openspec update` + `openspec list --json`；未初始化按 `openspec-workflow.md` 第 1–2 节（`<tool>` 问用户）。
4. 执行 `opsx:propose "根据代码审查报告 <workdir>/todo.md 修复 <项目/模块> 的严重与一般问题（严重 X、一般 Y）"`：
   - `proposal.md`：审查范围与基线、问题统计、修复目标与非目标、验收口径；
   - `design.md`：每类问题的修复方案、风险、是否动公开 API / 行为；
   - `tasks.md`：**逐条映射** `todo.md` 的问题，标题带 `[R1-1][严重]`，每条含复现点与测试点；禁止漏项或合并成模糊任务；
   - 把 `todo.md` + `review_summary.md` 复制到 `doc/spec/<变更名>/review.md`（随变更入库，作为修复依据）。
5. 本步只写规划产物，不改代码；完成后停下等用户评审。

## 5. 修复与验收

- **REQUIRED SUB-SKILL:** `test-driven-development`；`opsx:apply` 里逐任务 Red-Green-Refactor：先写能复现该审查问题的失败用例，再最小修复，跑绿才勾任务。
- **性能类任务（CPU 热点 / 内存 / GC / local mode）必须先有基线数据**：改前基线 + 改后对照，同 SDK、同机器、`-O2`、同输入与并发，报中位数与离散程度。没有数据的性能项——**包括没有 profile 的热点结论**——不进 `tasks.md`，只能作为「待验证假设」留在报告里；数据不成立的优化撤回。
- 审查报告的「建议」只作参考；最终以 `design.md` 为准。修复涉及设计变更 / 公开 API 时回步骤 3 问用户，不自行扩大范围。
- `opsx:verify` 前：受影响模块 + 全量回归（`cjpm test` / `fboot test`）+ `fboot build`；涉及启动链做冒烟。
- 对照 `todo.md` 逐条核对覆盖：未修项必须写明原因并经用户同意；verify CRITICAL 清零。
- 交付说明附审查报告路径、问题清单与**性能类改动的前后数据**；`opsx:archive` 后用最终版覆盖 `doc/spec/<变更名>/`（四件套 + `review.md`）。

## 6. 只出报告、不修复

用户明确说「只审查、不修」时，在阶段四输出报告后结束，不进入 OpenSpec。这是工作流 L 唯一不执行六步的情况；用户没说就默认按审查报告修复。

## 7. 红旗

| 你正想做 | 现实 |
| --- | --- |
| 主 Agent 先读一遍源码再派审查 | 审查引擎禁止主 Agent 读被审文件；代码阅读交给 reviewer 子 agent |
| 为了审查先装 `cangjie-code-review-harness` | 已并入本技能，不需要；装了也不会被使用 |
| 工作区不干净，先提交了再审查 | 提交是用户决定；先问「提交 / stash / 快照审查」三选一 |
| 审查报告只统计不建任务 | tasks 必须逐条映射 `todo.md` 的严重/一般问题，编号可追溯 |
| 顺手把轻微项也全修了 | 修复范围默认严重 + 一般；轻微项是否纳入由用户拍板 |
| 性能项没有基线就直接改 | 先补 bench / 峰值内存基线，否则不进 tasks；改完必须有对照数据 |
| 审查后直接改代码，不走 propose | 审查报告是输入，propose 是门禁；未评审 design/tasks 不进 apply |
| 审查分支的暂存内容直接 `reset --hard` | 先问用户；那是审查副本，不是用户改动，但仍需确认 |

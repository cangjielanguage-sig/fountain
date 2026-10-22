---
name: fountain-code-review-fix
description: 当用户要求审查当前项目或项目内指定模块，并按审查报告修复时使用；代码审查后走 OpenSpec 六步 + 严格 TDD。
---

# fountain-code-review-fix — 代码审查 → OpenSpec 修复（工作流 L）

## 执行步骤

**适用**：用户要求审查当前目录的项目、或项目里的指定模块，并按审查结论修复。产出 = **审查报告**（`review_v{N}.md` 分轮报告、`todo.md` 严重 + 一般问题清单、`review_summary.md` 统计与总评）+ **OpenSpec 六步修复**（propose → 用户评审 → apply 逐任务 TDD → verify → archive + `doc/spec/`）。展开见 `references/code-review-workflow.md`。

**开工前置（自动执行，无需用户要求）**：
- **`cangjie-code-review-harness`（REQUIRED SUB-SKILL）**：没装就 `python <skill-root>/scripts/install_skill.py harness`——从 `https://gitcode.com/zhangyin_gitcode/cangjie_harness.git` 装全部审议式技能（代码审查 / 架构设计 / 需求设计等），装完再加载；本机没有 git 时脚本自动借融合侧 git 或归档下载。
- **`cangjie-doc-lookup`**：没装就 `python <skill-root>/scripts/install_skill.py fountain`——从 fountain 仓库 `skills/` 装全部技能（含 `cangjie-doc-lookup`、12 个 `opsx-*`、`fountain-tag` 等），装完跑 `python <cangjie-doc-lookup 技能目录>/scripts/skill_paths.py check`。
- **`opsx-*`（12 个）**：缺任一（`install_skill.py list` 不是 `12/12`）同样用 `install_skill.py fountain` 一次装齐，并确认运行器 `~/.workbuddy/scripts/opsx_fusion.py` 已部署。
- **`test-driven-development`**：进入步骤 4 前必须加载（**REQUIRED SUB-SKILL:**），apply 里逐任务 Red-Green-Refactor。

1. **步骤 0 — 定范围与基线（只读）**：`project_root` = `git -C <目标> rev-parse --show-toplevel`（无 git 时向上找 `cjpm.toml` / `openspec/`）；「当前目录」→ 项目根 + `scope=.`，「指定模块」→ 项目根 + 该模块相对路径。基线二选一：**分支差异**（`source_branch != target_branch` 且 diff 非空）或**工作区快照**（无 git / 同分支 / diff 为空）；工作区不干净时停下问用户「提交 / stash / 快照审查」，不擅自处理。
2. **步骤 1 — 执行代码审查（`cangjie-code-review-harness`）**：按它的调用参数准备 `workdir=<project_root>/reviews/<YYYYMMDDHHMM>_<简述>/`、`project_root`、`source_branch`、`target_branch`、`parallel_per_batch=2`；分支模式走阶段零→四，快照模式跳过阶段零、由主 Agent 写 `scope.md` 后从阶段一开始。**主 Agent 不读被审源码**（Read / Grep / git diff 内容都不行），代码阅读交给 reviewer 子 agent；审查阶段**不改源码**。产出分轮报告 + `todo.md` + `review_summary.md`。
3. **步骤 2 — 审查报告 → `opsx:propose`**：读 `todo.md` / `review_summary.md`，统计严重 X / 一般 Y / 轻微 Z；**修复范围默认严重 + 一般**，轻微项由用户决定是否纳入（不静默丢弃）。给每条问题编号 `R<轮次>-<序号>`；`openspec update` + `openspec list --json` 后执行 `opsx:propose "根据代码审查报告 <workdir>/todo.md 修复 <项目/模块> 的严重与一般问题（严重 X、一般 Y）"`——proposal 写审查范围/基线与统计，design 写修复方案与风险，**tasks 逐条映射 `[R1-1][严重]`（含复现点与测试点，禁止漏项）**；把 `todo.md` + `review_summary.md` 复制到 `doc/spec/<变更名>/review.md`。**本步只写规划产物，不改代码**，完成后停下等评审。
4. **步骤 3 — 用户评审（门禁）**：逐条确认 `design.md` / `tasks.md` 与 `todo.md` 的覆盖关系（严重/一般是否全部有任务、修复方案是否改变公开 API / 行为、轻微项取舍）；缺口用 `opsx:update` 折回。**未确认不进 apply。**
5. **步骤 4 — `opsx:apply` 逐任务 TDD 修复**：严格按 tasks 顺序；每条问题**先写能复现该问题的失败用例**（Red）→ 最小修复（Green）→ 重构；跑绿才勾任务；不允许「改了但没测试」。审查报告的「建议」只作参考，以 design 为准；涉及设计变更 / 公开 API 时回步骤 3 问用户，不自行扩大范围。
6. **步骤 5 — 回归 + `opsx:verify`**：受影响模块 + 全量回归（`cjpm test` / `fboot test`）+ `fboot build`；涉及启动链做冒烟（delivery-workflow 第 5 节）；`opsx:verify` CRITICAL 清零；对照 `todo.md` 逐条核对覆盖，未修项写明原因并经用户同意。
7. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 提交（交付说明附审查报告路径与问题清单）；执行 `opsx:archive`；最后用最终版覆盖更新 `doc/spec/<变更名>/`（四件套 + `review.md`）。

**唯一例外**：用户明确说「只审查、不修」时，在步骤 1 输出报告后结束，不进入 OpenSpec；用户没说就默认按报告修复。

## 前置与依赖

无强制前置；本技能会自动加载 / 安装 `cangjie-code-review-harness`、`cangjie-doc-lookup`、12 个 `opsx-*` 与 `test-driven-development`（见通用规则）。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/code-review-workflow.md`
- `references/delivery-workflow.md`
- `references/environment.md`
- `references/openspec-workflow.md`
- `references/opsx-waiting.md`
- `references/project-setup.md`
- `references/sdk-bug-handling.md`
- `references/skill-infra.md`
- `references/common-rules.md`（通用规则）
- `scripts/fountain_lookup.py`
- `scripts/install_fboot.sh`
- `scripts/install_skill.py`
- `scripts/migrate_fountain_imports.py`
- `scripts/opsx_fusion.py`
- `scripts/opsx_progress.py`

## 完成后的汇报

报告审查范围 / 统计、修复摘要、verify 结果与 `doc/spec/<变更名>/review.md`；下一步是交付 / archive。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。

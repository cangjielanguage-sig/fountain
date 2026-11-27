---
name: fountain-review
description: 当用户要求审查 fountain 仓库或其中的仓颉模块 / 分支 / 工作区快照，并按审查报告修复时使用；产出分轮审查报告与问题清单，覆盖死代码、表现形式不同的重复逻辑、空实现、栈溢出、OOM、大粒度锁热点、并发串行、低效算法、降低堆内存与 CPU 占用的可行性方案（含 local mode 探索），再走 OpenSpec 六步 + 严格 TDD 修复；主 Agent 不读被审源码。
---

# fountain-review — 代码审查 → OpenSpec 修复（工作流 L）

审查与修复一条线：内置**只读**审查引擎（并行 reviewer 子 agent）产出分轮报告与问题清单，再按 OpenSpec 六步 + 严格 TDD 把问题修完并归档。原 `fountain-code-review-fix` 已整体并入本技能；审查不再依赖 `cangjie-code-review-harness`。

两条不可让渡的原则：

1. **主 Agent 不读被审源码**——代码阅读由 reviewer 子 agent 完成，主 Agent 只操作 `scope.md` / `review_v{N}.md` / `todo.md` / `review_summary.md`。
2. **所有性能优化必须有性能测试数据**——CPU、内存、GC 压力、local mode 改造一律如此，见「性能结论的取证纪律」。

## 执行步骤

**适用**：审查当前项目 / 指定模块 / 指定分支，并按结论修复。产出 = **审查报告**（`review_v{N}.md`、`todo.md`、`review_summary.md`）+ **OpenSpec 修复**（propose → 用户评审 → apply 逐任务 TDD → verify → archive + `doc/spec/`）。

**开工前置（自动执行，无需用户要求）**：
- **`cangjie-doc-lookup`**：没装就 `python <skill-root>/scripts/install_skill.py fountain`（从 fountain 仓库 `skills/` 装全部技能），装完跑 `python <cangjie-doc-lookup 技能目录>/scripts/skill_paths.py check`。
- **`opsx-*`（12 个）**：缺任一（`install_skill.py list` 不是 `12/12`）同样用 `install_skill.py fountain` 或 `install_skill.py opsx` 装齐，并确认运行器 `~/.workbuddy/scripts/opsx_fusion.py` 已部署。
- **`test-driven-development`**：进入步骤 4 前必须加载（**REQUIRED SUB-SKILL:**），apply 里逐任务 Red-Green-Refactor。
- **不需要** `cangjie-code-review-harness`：审查引擎随本技能分发（`reviewer.md` + `references/review-checklist.md`）。

1. **步骤 0 — 定范围与基线（只读）**：`project_root` = `git -C <目标> rev-parse --show-toplevel`（无 git 时向上找 `cjpm.toml` / `openspec/`）；「当前目录」→ 项目根 + `scope=.`，「指定模块」→ 项目根 + 该模块相对路径。基线二选一：**分支差异**（`source_branch != target_branch` 且 diff 非空）或**工作区快照**（无 git / 同分支 / diff 为空）；工作区不干净时停下问用户「提交 / stash / 快照审查」，不擅自处理。
2. **步骤 1 — 执行审查（本技能内建引擎）**：按下面「审查引擎」准备参数与 `scope.md`，分支模式走阶段零→四，快照模式跳过阶段零。**主 Agent 不读被审源码**；审查阶段**不改源码**。产出分轮报告 + `todo.md` + `review_summary.md`。
   - 用户明确说「只审查、不修」→ 本步结束，交报告，不进 OpenSpec。
3. **步骤 2 — 报告 → `opsx:propose`**：读 `todo.md` / `review_summary.md`（这是汇总产物，不是源码），统计严重 X / 一般 Y / 轻微 Z；**修复范围默认严重 + 一般**，轻微项由用户决定是否纳入（不静默丢弃）。给每条问题编号 `R<轮次>-<序号>`；`openspec update` + `openspec list --json` 后执行 `opsx:propose "根据代码审查报告 <workdir>/todo.md 修复 <项目/模块> 的严重与一般问题（严重 X、一般 Y）"`——proposal 写审查范围/基线与统计，design 写修复方案与风险，**tasks 逐条映射 `[R1-1][严重]`（含复现点与测试点，禁止漏项）**；把 `todo.md` + `review_summary.md` 复制到 `doc/spec/<变更名>/review.md`。**本步只写规划产物，不改代码**，完成后停下等评审。
4. **步骤 3 — 用户评审（门禁）**：逐条确认 `design.md` / `tasks.md` 与 `todo.md` 的覆盖关系（严重/一般是否全部有任务、修复方案是否改变公开 API / 行为、轻微项取舍）；缺口用 `opsx:update` 折回。**未确认不进 apply。**
5. **步骤 4 — `opsx:apply` 逐任务 TDD 修复**：严格按 tasks 顺序；每条问题**先写能复现该问题的失败用例**（Red）→ 最小修复（Green）→ 重构；跑绿才勾任务；不允许「改了但没测试」。审查报告的「建议」只作参考，以 design 为准；涉及设计变更 / 公开 API 时回步骤 3 问用户，不自行扩大范围。**性能类任务必须先补基线再改代码**（见下方硬规则），没有数据的性能项不进 tasks。
6. **步骤 5 — 回归 + `opsx:verify`**：受影响模块 + 全量回归（`cjpm test` / `fboot test`）+ `fboot build`；涉及启动链做冒烟；`opsx:verify` CRITICAL 清零；对照 `todo.md` 逐条核对覆盖，未修项写明原因并经用户同意。
7. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 提交（交付说明附审查报告路径、问题清单、**性能类改动的前后数据**）；执行 `opsx:archive`；最后用最终版覆盖更新 `doc/spec/<变更名>/`（四件套 + `review.md`）。

## 审查引擎

### 调用参数

- **`workdir`**（必填）— 报告目录绝对路径，`{project_root}/reviews/{YYYYMMDDHHMM}_{简述}/`
- **`project_root`**（必填）— 仓颉项目根目录绝对路径
- **`source_branch`**（必填）— 待审查源分支；快照模式填当前分支
- **`target_branch`**（必填）— squash 目标分支；快照模式与 source 相同
- **`scope`**（可选，默认 `.`）— 模块相对路径，限定审查子目录
- **`baseline`**（可选）— `branch`（分支差异）或 `snapshot`（工作区快照）；缺省时按可观察条件判定
- **`parallel_per_batch`**（可选，默认 `2`）— 每批并行子 agent 数

基线判定：`source != target` 且 `git diff --stat {target}...{source}` 非空 → `branch`；否则（无 git / 同分支 / diff 为空）→ `snapshot`。

### 文件约定

全部写入 `{workdir}/`：

| 文件 | 生产者 | 用途 |
| --- | --- | --- |
| `scope.md` | 主 Agent | 范围、基线、重点、排除项 |
| `review_v{N}.md` | reviewer 子 agent | 第 N 轮报告：发现 + 优化可行性方案 + 覆盖自检 + 统计 |
| `todo.md` | 汇总子 agent | 全部轮次的「严重 + 一般」缺陷，按轮次分组 |
| `review_summary.md` | 汇总子 agent | 审查范围、轮次、各级数量、总评 |

子 agent 指令：`reviewer.md`（启动时让 agent 自己读，不复制进 prompt）。
审查清单：`references/review-checklist.md`；项目约定：`references/fountain-baseline.md`；深度手册：`references/performance-optimization.md`、`references/memory-optimization.md`。

### 阶段零：分支准备（仅 `baseline=branch`）

`{branch}` 取 `workdir` 路径的最后一段。若 `workdir` 还没生成，先跑阶段一的脚本拿 `WORKDIR=` / `BRANCH=`，再回到本阶段——两者顺序可对调，只要 squash 在阶段三之前完成。

```bash
git checkout {target_branch} && git pull
git checkout -b {branch}
git merge --squash {source_branch}
```

审查范围自动锚定为暂存区变更（`git diff --cached`）。`git pull` 因网络 / 凭据失败时**不要卡住**：退化为快照模式，`scope.md` 注明「未对照远端目标分支」，报告里也注明。

### 阶段一：范围抽取（不询问用户）

根据用户原话把范围落成 `scope.md`。信息确实不足时用对话确认，**不要**用提问工具发问卷。

```bash
python <skill_dir>/scripts/review_workdir.py \
  --project-root <project_root> \
  --scope <模块路径或 .> \
  --baseline "分支 {source} → {target}" \
  --focus "正确性、死代码、重复逻辑、空实现、栈溢出、OOM、低性能、内存/CPU 优化空间、local mode 可行性" \
  --exclude "generated/,third_party/,target/"
```

脚本会创建目录、写 `scope.md`、打印 workdir 路径。已有 `scope.md` 时不要覆盖，改用 `--force`。

### 阶段二：轮次规划（用户门禁）

1. 按**模块边界 / 目录**切分，单轮覆盖约 8–12 个源文件；大模块拆成多轮（如 `f_cache` 的 heap / lru / expire 各一轮）。
2. 每轮指定一个明确目标 + 需要重点覆盖的专项（例如「R3：`f_orm` 的 executor 生命周期与连接池——重点 OOM、大粒度锁」）。
3. 向用户展示轮次表，问「是否启动？」，确认后进阶段三。

### 阶段三：并行审查循环

按 `parallel_per_batch` 分批启动，每批 K 个 agent 并行，每个 agent 只做 1 轮：

```
请先阅读文件 {skill_dir}/reviewer.md 获取完整工作指令，然后按要求完成以下任务：

范围界定文件：{workdir}/scope.md
审查报告输出文件：{workdir}/review_v{N}.md
项目根目录：{project_root}
本轮审查目标：{该轮覆盖的模块 + 重点专项}
```

- 用当前 Agent 的子 agent 机制（`Task` 工具）；平台有专用高强度类型就用，没有就用默认类型。
- 等本批全部返回 `REVIEW_WRITTEN:{路径}` 再启动下一批，避免并发写同一 workdir 的资源争抢。
- 某轮失败：重试一次；仍失败则记录缺失轮次，继续后续批次，并在汇总里标注覆盖缺口。

### 阶段四：问题汇总 + 审查总结

1. 启动一个汇总子 agent：

```
请读取 {workdir} 下所有 review_v*.md，生成两个文件：

1. {workdir}/todo.md
   - 只收「严重」「一般」两类缺陷，忽略「轻微」与「优化可行性方案」
   - 保留：题目、位置、判据、描述；忽略：建议
   - 按轮次分组，每组前加 `## R{N}`
   - 每条用 `### [严重] {题目}` / `### [一般] {题目}`，下用 bullet 列 **位置** / **判据** / **描述**

2. {workdir}/review_summary.md
   - 审查范围与基线、轮次清单、各轮 严重/一般/轻微/优化方案 数量、总计
   - 按主题归纳主要风险（并发正确性、资源生命周期、内存边界、死代码与空实现…）
   - 明确覆盖缺口（未审目录、失败轮次）与整体结论
```

2. 主 Agent 读 `todo.md` + `review_summary.md`，向用户返回：审查范围、轮次数、问题统计、主要风险、覆盖缺口。**不输出报告全文**，引导用户看 `todo.md`。

3. 收尾：`baseline=branch` 时先 `git checkout <原分支>`；暂存内容挡住切换时**问用户**是否丢弃（那是审查副本，不是用户改动）。审查分支与 `reviews/` 目录的清理同样问用户，不擅自 `branch -D` / 删除。

## 性能结论的取证纪律（硬规则）

**所有性能优化——CPU 消耗、内存占用、GC 压力、local mode 改造——都必须以性能测试数据为依据。** 这条同时约束审查报告、`tasks.md` 与交付说明。

| 要求 | 判据 |
| --- | --- |
| 改前基线 + 改后对照 | 同一 SDK、同一机器、同一构建配置（**`-O2`**；`cjpm test` 默认 `-O0`，同代码可能差一个数量级）、同一输入规模与分布、同一并发度、同一预热与轮数 |
| 数据形状 | 绝对值 + 单位 + 中位数 + 离散程度 + 测量方法；**一次最快值不算**，只报比例不报绝对值不算 |
| 指标对应 | CPU / 延迟用 `cjpm bench` 或 `cjprof record/report`；内存看**峰值 + 稳态**（`getAllocatedHeapSize()` / `getUsedHeapSize()` / RSS / 业务对象计数，按 `mem §1`）；GC 压力用分配量、GC 次数、峰值内存 |
| 无数据时 | 只能写成「待验证假设」：**不得**进 `todo.md`、不得进 `tasks.md`、不得在交付说明里写成结论；先补基线再立项 |
| 数据不成立 | 差异落在离散范围内、或换输入就反转 → 撤回该优化，不留「看起来更快」的代码 |

local mode 的探索同样按这条执行：它降低的是**峰值内存**而非吞吐（官方语义），必须用峰值内存对照来证明，不能只凭「临时对象提前释放」推断收益。

## 红旗

| 你正想做 | 现实 |
| --- | --- |
| 先自己读一遍源码 / 看 `git diff` 内容再派活 | 主 Agent 不读被审源码；代码阅读交给 reviewer 子 agent |
| 一轮铺 30 个文件「一次审完」 | 单轮 ≤ 8–12 个文件；范围大就多轮 |
| 报告没有「覆盖自检」表，或表里缺行 | 该表是结构性要求；缺行视为本轮未完成，打回重跑 |
| 死代码 / 重复逻辑两栏写「未发现」却没做符号搜索 | 这两类必须机械过一遍（`review-checklist §1 / §2` 的机械动作） |
| 把「优化可行性方案」写进 `todo.md` | `todo.md` 只收严重 + 一般缺陷；优化方案留在分轮报告里 |
| 说「这个改动更快 / 更省内存」但没跑测试 | 必须有改前基线 + 改后对照（`-O2`、同输入、中位数）；否则只能写「待验证假设」 |
| 拿一次最快值或「关掉日志后变快了」当结论 | 不算证据：要中位数 + 离散程度 + 同环境对照 |
| 没数据也把性能项写进 `tasks.md` | 先补基线（Red 用例 + bench）再立项；无数据项不进 apply |
| 审到问题顺手改掉 | 审查阶段禁改源码；修复走步骤 2–6 |
| 用户说「只审查」还继续 propose | 唯一例外：只出报告时在步骤 1 结束 |
| 说「这个函数没人用」却只在单文件搜过 | 必须全仓搜索；`public` 符号还要看下游依赖 |
| 说「这里是热点 / 会泄漏」但没证据 | 写清输入规模、调用频次、持有路径；无证据只能定轻微 |
| 把 `Timer.after` 回调只返回一个 `Duration` 报成一次性定时器 | 回调返回值就是下次延迟，`Some` 自动重排（`fountain-baseline.md §5`） |
| 工作区不干净先 `merge --squash` | 先问用户：提交 / stash / 改快照审查 |
| 用提问工具给用户发范围问卷 | 信息不足用对话确认，阶段一不打断 |
| 审查后直接改代码，不走 propose | propose 是门禁；未评审 design/tasks 不进 apply |
| 顺手把轻微项也全修了 | 修复范围默认严重 + 一般；轻微项由用户拍板 |

## 前置与依赖

- 联动技能 `cangjie-doc-lookup`、12 个 `opsx-*`、`test-driven-development`：加载失败按 `references/common-rules.md`「技能格式与联动技能」自动安装，不中断任务、不问用户。
- **不再需要** `cangjie-code-review-harness`（旧工作流 L 的依赖已取消）；reviewer 指令与清单随本技能分发。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（TDD / OpenSpec 六步 / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `reviewer.md` — reviewer 子 agent 的完整指令与报告模板
- `references/review-checklist.md` — 筛查主线（十类专项 + 通用维度 + local mode）
- `references/fountain-baseline.md` — fountain 项目约定
- `references/performance-optimization.md` — 性能深度手册
- `references/memory-optimization.md` — 内存深度手册
- `references/code-review-workflow.md` — 工作流 L 展开（范围模板、收尾、报告 → propose 映射）
- `references/openspec-workflow.md`、`references/delivery-workflow.md`、`references/opsx-waiting.md`、`references/sdk-bug-handling.md`、`references/environment.md`、`references/project-setup.md`、`references/common-rules.md`、`references/skill-infra.md` — 与其它工作流技能共用
- `scripts/review_workdir.py` — 生成 workdir 与 `scope.md`
- `scripts/install_skill.py`、`scripts/fountain_lookup.py`、`scripts/install_fboot.sh`、`scripts/migrate_fountain_imports.py`、`scripts/opsx_fusion.py`、`scripts/opsx_progress.py` — 联动技能与仓库查询

## 完成后的汇报

报告审查范围 / 统计、修复摘要、verify 结果、性能类改动的前后数据，以及 `doc/spec/<变更名>/review.md` 路径；下一步是交付 / archive。

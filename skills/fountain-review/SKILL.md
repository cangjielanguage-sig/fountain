---
name: fountain-review
description: 当用户要求审查 fountain 仓库或其中的仓颉模块 / 分支 / 工作区快照，并按审查报告修复时使用；逐模块、逐文件审查（模块内全部 .cj 与 .md），一个模块一份报告写到 `docs/review/日期/模块名.md`，覆盖死代码、表现形式不同的重复逻辑、空实现、栈溢出、OOM、并发安全与锁粒度、热点瓶颈定位、大粒度锁热点、并发串行、低效算法、现有代码存量 BUG、功能完备性与 README 覆盖、降低堆内存与 CPU 占用的可行性方案（含 local mode 探索），再走 OpenSpec 六步 + 严格 TDD 修复；主 Agent 不读被审源码。
---

# fountain-review — 代码审查 → OpenSpec 修复（工作流 L）

审查与修复一条线：内置**只读**审查引擎（并行 reviewer 子 agent）产出分轮报告与问题清单，再按 OpenSpec 六步 + 严格 TDD 把问题修完并归档。审查引擎随本技能分发，不依赖 `cangjie-code-review-harness`。

两条不可让渡的原则：

1. **主 Agent 不读被审源码**——代码阅读由 reviewer 子 agent 完成，主 Agent 只操作 `scope.md` / `modules.md` / 模块报告 / `todo.md` / `review_summary.md`。
2. **逐模块、逐文件审查**——以模块为审查单元，模块内**每个 `.cj` 与 `.md` 都必须读到**（全量，不抽样）；每审完一个模块立即把报告写到 `{project_root}/docs/review/<YYYY-MM-DD>/<module>.md`。
3. **每次审查都是全量推进**——一次运行覆盖 `modules.md` 的**全部模块**、每个模块的**全部 `.cj` 与 `.md`**；不做增量（不按 diff 挑模块、不沿用上次结论）、不留未审模块。全量是默认，**开始前不询问用户**。
4. **并发默认按"会被多线程调用"审**——先证明安全，再谈锁粒度；锁能不要就不要，要就要小。
5. **所有性能优化必须有性能测试数据**——CPU、内存、GC 压力、local mode 改造一律如此，见「性能结论的取证纪律」。

## 执行步骤

**适用**：审查当前项目 / 指定模块 / 指定分支，并按结论修复。产出 = **逐模块审查报告**（`docs/review/<YYYY-MM-DD>/<module>.md`）+ **汇总**（`todo.md`、`review_summary.md`）+ **逐问题 OpenSpec 修复**（每个问题一次 change：propose → 用户评审 → apply TDD → verify → archive → 一次提交），修复在独立 worktree 内完成，最后合入源分支并清理。

**开工前置（自动执行，无需用户要求）**：
- **`cangjie-doc-lookup`**：没装就 `python <skill-root>/scripts/install_skill.py fountain`（从 fountain 仓库 `skills/` 装全部技能），装完跑 `python <cangjie-doc-lookup 技能目录>/scripts/skill_paths.py check`。
- **`opsx-*`（12 个）**：缺任一（`install_skill.py list` 不是 `12/12`）同样用 `install_skill.py fountain` 或 `install_skill.py opsx` 装齐，并确认运行器 `~/.workbuddy/scripts/opsx_fusion.py` 已部署。
- **`test-driven-development`**：进入步骤 4 前必须加载（**REQUIRED SUB-SKILL:**），apply 里逐任务 Red-Green-Refactor。
- **查证优先**：API 签名 / 标准库语义 / 语言特性拿不准时，先查 `cangjie-doc-lookup`（`scripts/skill_paths.py check` → `scripts/search_docs.py`），模块 API 查 `fountain-api-lookup`；报告里引文档位置作判据，查不到就写 `待确认`，不凭记忆断言。
- **不需要** `cangjie-code-review-harness`：审查引擎随本技能分发（`reviewer.md` + `references/review-checklist.md`）。

1. **步骤 0 — 定范围与基线（只读）**：`project_root` = `git -C <目标> rev-parse --show-toplevel`（无 git 时向上找 `cjpm.toml` / `openspec/`）；「当前目录」→ 项目根 + `scope=.`，「指定模块」→ 项目根 + 该模块相对路径。基线二选一：**分支差异**（`source_branch != target_branch` 且 diff 非空）或**工作区快照**（无 git / 同分支 / diff 为空）；工作区不干净时停下问用户「提交 / stash / 快照审查」，不擅自处理。
2. **步骤 1 — 执行审查（本技能内建引擎）**：按下面「审查引擎」准备参数、`scope.md` 与 `modules.md`，分支模式走阶段零→四，快照模式跳过阶段零。**主 Agent 不读被审源码**；审查阶段**不改源码**。审查对象是**本次改动 + 本轮读到的现有代码**——现有代码里的缺陷同样要报，标 `[存量]`（`review-checklist §11`）。**一个模块一份报告，写到 `docs/review/<YYYY-MM-DD>/`**，全部模块完成后汇总 `todo.md` + `review_summary.md`。
   - 用户明确说「只审查、不修」→ 本步结束，交报告，不进 OpenSpec。
3. **步骤 2 — 汇总修复清单**：读 `todo.md` / `review_summary.md`（汇总产物，不是源码），统计严重 X / 一般 Y / 轻微 Z 与**存量 N 条**；**修复范围默认 = 本次改动的严重 + 一般**，轻微与存量由用户决定（既不静默丢弃，也不静默扩大）。给每条问题编号 `<module>-<序号>`（存量加 `S`）；`openspec update` + `openspec list --json` 确认工程可用。
4. **步骤 3 — 审查报告入库并推送**：`docs/review/<YYYY-MM-DD>/*.md` 是交付物，**提交并推送**到当前源分支（`docs(review): <日期> 模块审查报告`）；`reviews/` 是过程目录，不入库（写进 `.git/info/exclude` 或放项目外）。提交前确认工作区干净。
5. **步骤 4 — 建修复工作树（自动，不询问）**：加载 `using-git-worktrees`，从当前源分支创建 `.worktrees/review-fix-<YYYYMMDD>`（分支 `fix/review-<YYYYMMDD>`）；后续修复全部在这个 worktree 里做，主工作区不动。
6. **步骤 5 — 逐问题走 OpenSpec 全流程（自动循环）**：对修复范围内的每个 `<module>-<n>`，一次只做一个问题：`opsx:propose "<id> <标题>"` → 用户评审 `design.md` / `tasks.md` → `opsx:apply` 严格 TDD（Red → Green → Refactor）→ `opsx:verify` → `opsx:archive` → `git commit`（**一个 issue 一个提交**，`fix(<module>): <id> <摘要>`）。详见「修复流水线」。
7. **步骤 6 — 收尾（自动）**：全部问题修完且回归通过后，把 worktree 分支合入**创建它时的源分支**并推送（能快进就快进，否则普通合并）；`git worktree remove <path>` + `git branch -d <branch>`（只删本流程创建的那一个）；汇报每个问题的提交、报告路径与 verify 结果。

## 修复流水线（审查完成后自动执行）

**触发条件**：`todo.md` 与 `review_summary.md` 已生成（即全量审查完成）。缺任何一个都说明审查没跑完，**不得进入修复**。

**自动加载的技能**（缺一不可，进步骤 4 前加载）：

| 技能 | 用途 | 标记 |
| --- | --- | --- |
| `using-git-worktrees` | 创建 / 管理修复工作树 | **REQUIRED SUB-SKILL** |
| `test-driven-development` | 每个问题的 Red → Green → Refactor | **REQUIRED SUB-SKILL** |
| `cangjie-doc-lookup` | 改代码时核对 API / 语言特性（不凭记忆） | **REQUIRED BACKGROUND** |
| `fountain-develop-framework` | 改的是 fountain 自身模块时的工程约定 | **REQUIRED BACKGROUND** |
| `opsx-propose` / `opsx-apply` / `opsx-verify` / `opsx-archive` | 单问题 OpenSpec 六步 | **REQUIRED SUB-SKILL**（按步骤加载） |

**步骤 3 报告入库**：

```bash
git add docs/review/<YYYY-MM-DD>
git commit -m "docs(review): <YYYY-MM-DD> 模块审查报告"
git push
```

`reviews/<时间>_<简述>/` 只留在本地：写进 `.git/info/exclude`（本地生效、不改仓库 `.gitignore`），或把 workdir 放到项目外。

**步骤 4 建工作树**（按 `using-git-worktrees` 的约定）：

```bash
git worktree add .worktrees/review-fix-<YYYYMMDD> -b fix/review-<YYYYMMDD> <源分支>
```

**步骤 5 逐问题循环**（每个问题一轮，不合并、不跳过）：

```bash
cd .worktrees/review-fix-<YYYYMMDD>
# 1) 规划：一次只描述一个问题
opsx:propose "<module>-<n> <问题标题>"
# 2) 用户评审 design.md / tasks.md（门禁，未确认不进 apply）
# 3) TDD 修复
opsx:apply
# 4) 验证
opsx:verify
# 5) 归档
opsx:archive
# 6) 一个 issue 一个提交（含代码、用例、doc/spec/<变更名>/）
git add -A && git commit -m "fix(<module>): <module>-<n> <摘要>"
```

- 每个问题独立成 change，`proposal` / `design` 里引用 `docs/review/<日期>/<module>.md` 的对应条目与 `todo.md` 编号。
- 修不动的（复现不了、方案有争议、需要改公开 API）：**停下来问用户**，不要跳过、不要塞进下一个问题。
- 用户明确同意跳过的，在最后汇报里单列，不混进"已修复"。

**步骤 6 收尾**：

```bash
git checkout <源分支>
git merge fix/review-<YYYYMMDD>          # 能快进就快进
git push
git worktree remove .worktrees/review-fix-<YYYYMMDD>
git branch -d fix/review-<YYYYMMDD>
```

只删除本流程创建的工作树与分支；其它 worktree / 分支一律不动。

## 审查引擎

### 调用参数

- **`workdir`**（必填）— 报告目录绝对路径，`{project_root}/reviews/{YYYYMMDDHHMM}_{简述}/`
- **`project_root`**（必填）— 仓颉项目根目录绝对路径
- **`source_branch`**（必填）— 待审查源分支；快照模式填当前分支
- **`target_branch`**（必填）— squash 目标分支；快照模式与 source 相同
- **`scope`**（可选，默认 `.`）— 模块相对路径。默认范围 = 当前分支所有 `f_*` 模块 + `fboot` / `fdbm` / `fmq` / `fprobe`，排除 `f*demo` 与 `.worktrees`
- **`baseline`**（可选）— `branch`（分支差异）或 `snapshot`（工作区快照）；缺省时按可观察条件判定
  - 基线**只决定「来源」标注**（本次改动 / 存量），不缩小审查范围——两种基线下都全量审全部模块与文件
- **`report_dir`**（默认 `{project_root}/docs/review/<YYYY-MM-DD>/`）— 模块报告落盘目录
- **`date`**（默认今天，`YYYY-MM-DD`）— 报告目录名
- **`parallel_per_batch`**（可选，默认 `2`）— 每批并行子 agent 数（按模块计）

基线判定：`source != target` 且 `git diff --stat {target}...{source}` 非空 → `branch`；否则（无 git / 同分支 / diff 为空）→ `snapshot`。

### 文件约定

过程文件在 `{workdir}/`，**模块报告写仓库的 `docs/review/<YYYY-MM-DD>/`**（随代码入库）：

| 文件 | 位置 | 生产者 | 用途 |
| --- | --- | --- | --- |
| `scope.md` | `{workdir}/` | 主 Agent | 范围、基线、重点、排除项 |
| `modules.md` | `{workdir}/` | 主 Agent（脚本生成） | 模块清单与状态：模块 / 路径 / `.cj` 数 / `.md` 数 / 报告文件 / `待审`→`已审` |
| `files/<module>.txt` | `{workdir}/` | 主 Agent（脚本生成） | 该模块待审的**全部** `.cj` 与 `.md`，是文件覆盖的比对基线 |
| `<module>.md` | `{project_root}/docs/review/<YYYY-MM-DD>/` | reviewer 子 agent | **一模块一份**：发现 + 优化可行性方案 + 覆盖自检 + 统计 |
| `todo.md` | `{workdir}/` | 汇总子 agent | 全部模块的「严重 + 一般」缺陷，按模块分组 |
| `review_summary.md` | `{workdir}/` | 汇总子 agent | 跨模块统计、主要风险、覆盖缺口、总评 |

模块名取相对路径并把 `/` 换成 `_`（`fdemo/user` → `fdemo_user`），报告文件名以 `modules.md` 为准。
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

### 阶段一：范围抽取与模块发现（不询问用户）

根据用户原话把范围落成 `scope.md`，并扫描模块生成 `modules.md`。信息确实不足时用对话确认，**不要**用提问工具发问卷。

```bash
python <skill_dir>/scripts/review_workdir.py \
  --project-root <project_root> \
  --scope <模块路径或 .> \
  --baseline "分支 {source} → {target}" \
  --focus "正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点瓶颈、低性能、存量 BUG、内存/CPU 优化空间、local mode 可行性" \
  --perf-notes "doc/ 下的优化方案与 bench 结果（如有）" \
  --exclude "generated/,third_party/,target/,.worktrees/"
```

脚本会创建 `{workdir}/`、写 `scope.md` 与 `modules.md`、确保 `docs/review/<YYYY-MM-DD>/` 存在，并打印 `WORKDIR` / `BRANCH` / `DATE` / `REPORT_DIR` / `MODULE_COUNT`。

模块判定：目录含 `cjpm.toml` 且 `src/` 下至少一个 `.cj`（工作区根因无 `src` 被跳过）；每个模块会同时统计 `.cj` 数与 `.md` 数，并生成 `files/<module>.txt` 文件清单（含 README 与 `doc/**`）。

**默认审查范围**：当前分支**所有 `f_*` 模块 + `fprobe` / `fboot` / `fdbm` / `fmq`**。**不含 `.worktrees/` 下的任何代码，也不含 `fdemo` / `fdbmdemo` / `fmqdemo` / `frpcdemo` 等 `f*demo` 示例模块**（`fleet`、`src`、`docs`、`scripts` 等非模块目录同理）。显式 `--scope <目录>` 时按该目录审、不再套默认过滤；需要连示例模块一起扫时加 `--include-all`。

已有 `scope.md` 时不要覆盖，改用 `--force`。

### 阶段二：模块排队（无需确认，直接开跑）

1. 以 `modules.md` 为排期表，**一个模块一轮**，且**排期必须全覆盖**——不允许只挑部分模块；`parallel_per_batch` 只决定并发度，不减少覆盖范围。
2. 模块内文件超过约 15 个（`.cj` + `.md`）时拆成多个子轮（`part1/part2…`），各部分写 `{workdir}/parts/<module>.part{N}.md`，全部分完后由主 Agent 合并成一份模块报告。**拆的是轮次，不是范围**：`files/<module>.txt` 里每个文件都必须被某个子轮覆盖。**同一模块的子轮必须串行**（前一部分写完再开下一部分），因为后一轮要接前一轮的发现做去重与续接。
3. 给每个模块标一个重点（例如「`f_orm`：executor 生命周期与连接池——重点 OOM、大粒度锁」）。排期直接生效：**不要问「是否启动」「要不要全量」**——全量已是默认，标注完直接进阶段三。

### 阶段三：逐模块审查（模块间并行、模块内串行）

按 `parallel_per_batch` 分批启动，每批 K 个**不同模块**的 agent 并行；**同一个模块内部一律串行**——包括被拆开的子轮，前一轮落盘后再启动下一轮，同一模块同一时刻只能有一个 reviewer。理由：同模块并发会重复发现、互相覆盖同一份报告，且后轮无法接续前轮的结论。

```
请先阅读文件 {skill_dir}/reviewer.md 获取完整工作指令，然后按要求完成以下任务：

范围界定文件：{workdir}/scope.md
模块清单：{workdir}/modules.md
本模块文件清单：{workdir}/files/<module>.txt（全部 .cj 与 .md，逐个读完）
审查报告输出文件：{project_root}/docs/review/<YYYY-MM-DD>/<module>.md
项目根目录：{project_root}
本轮审查目标：模块 <module>（路径 <rel>，<cj> 个 .cj + <md> 个 .md），重点：<专项>
```

- 用当前 Agent 的子 agent 机制（`Task` 工具）；平台有专用高强度类型就用，没有就用默认类型。
- **审完一个模块立即落盘**：报告写完 → 主 Agent 把 `modules.md` 该行改成 `已审`，再启动下一批；不要等所有模块审完才写。合并子轮时核对报告「文件覆盖」表与 `files/<module>.txt` 行数一致。
- 同名报告已存在（同日重审）时**不静默覆盖**：改存 `<module>_v2.md`，报告头注明与上一份的关系。
- 某模块失败：重试一次；仍失败则把 `modules.md` 标 `失败（原因）`，继续其它模块；**全部批次跑完后回头补齐失败与未审模块**，直到 `modules.md` 没有 `待审` / `失败`。确实补不齐时必须先告知用户并取得同意，才能带缺口结束——**不得默认带缺口进入汇总**。

### 阶段四：跨模块汇总

0. **全量门禁**：先看 `modules.md`——必须全部 `已审`。存在 `待审` / `失败` 就回到阶段三补齐，不得汇总不完整结果；用户明确同意带缺口时，在 `review_summary.md` 里单列缺口与原因。
1. 启动一个汇总子 agent（按 `modules.md` 里状态为 `已审` 的报告汇总）：

```
请读取 {workdir}/modules.md，按清单读取 docs/review/<YYYY-MM-DD>/ 下各模块报告；先核对每份报告的「文件覆盖」表与 {workdir}/files/<module>.txt 是否逐行对应，再生成两个文件：

1. {workdir}/todo.md
   - 只收「严重」「一般」两类缺陷，忽略「轻微」、「优化可行性方案」与「待验证假设」
   - 保留：题目、位置、来源、判据、描述；忽略：建议
   - 按模块分组，每组前加 `## <module>`
   - 每条用 `### [严重] {题目}` / `### [一般] {题目}`，下用 bullet 列 **位置** / **来源** / **判据** / **描述**
   - 来源为存量的在标题加 `[存量]`，并在文末统计存量为「严重 a / 一般 b」

2. {workdir}/review_summary.md
   - 审查范围与基线、模块清单与状态、各模块 严重/一般/轻微/优化方案 数量、总计
   - 按主题归纳主要风险（并发正确性、资源生命周期、内存边界、死代码与空实现…）
   - 明确覆盖缺口（未审模块、失败模块、拆分子轮未合并的部分）与整体结论
```

2. 主 Agent 读 `todo.md` + `review_summary.md`，向用户返回：模块数、各模块问题统计、主要风险、覆盖缺口。**不输出报告全文**，引导用户看 `docs/review/<YYYY-MM-DD>/` 与 `todo.md`。

3. 收尾：`baseline=branch` 时先 `git checkout <原分支>`；暂存内容挡住切换时**问用户**是否丢弃（那是审查副本，不是用户改动）。审查分支与 `reviews/` 目录的清理同样问用户，不擅自 `branch -D` / 删除。**`docs/review/` 下的模块报告要入库**——不要删除，也不要把该目录加进 `.gitignore`。

## 性能结论的取证纪律（硬规则）

**所有性能优化——CPU 消耗、内存占用、GC 压力、local mode 改造——都必须以性能测试数据为依据。** 这条同时约束审查报告、`tasks.md` 与交付说明。

| 要求 | 判据 |
| --- | --- |
| 改前基线 + 改后对照 | 同一 SDK、同一机器、同一构建配置（**`-O2`**；`cjpm test` 默认 `-O0`，同代码可能差一个数量级）、同一输入规模与分布、同一并发度、同一预热与轮数 |
| 数据形状 | 绝对值 + 单位 + 中位数 + 离散程度 + 测量方法；**一次最快值不算**，只报比例不报绝对值不算 |
| 指标对应 | CPU / 延迟用 `cjpm bench` 或 `cjprof record/report`；内存看**峰值 + 稳态**（`getAllocatedHeapSize()` / `getUsedHeapSize()` / RSS / 业务对象计数，按 `mem §1`）；GC 压力用分配量、GC 次数、峰值内存 |
| **热点定位** | 必须先定位瓶颈再谈优化：函数 + **自耗时占比** + 调用路径 + 输入规模 + 工具；锁竞争 / 线程饥饿要另给线程状态证据（CPU profile 里看不到）。按 Amdahl 估「占比 × 预期降幅」，低于噪声（约 5%）不做 |
| 无数据时 | 只能写成「待验证假设」：**不得**进 `todo.md`、不得进 `tasks.md`、不得在交付说明里写成结论；先补基线再立项 |

**「热点瓶颈」同样受这条约束**：没有 `cjprof` / `cjpm bench` / 分段计时数据，就不能报成缺陷——「调用次数多」「循环嵌套深」「用了锁」只是线索。缺数据的猜测进报告末尾的「待验证假设」（写明缺什么数据、怎么采），不算发现、不计入统计。
| 数据不成立 | 差异落在离散范围内、或换输入就反转 → 撤回该优化，不留「看起来更快」的代码 |

local mode 的探索同样按这条执行：它降低的是**峰值内存**而非吞吐（官方语义），必须用峰值内存对照来证明，不能只凭「临时对象提前释放」推断收益。

## 红旗

| 你正想做 | 现实 |
| --- | --- |
| 先自己读一遍源码 / 看 `git diff` 内容再派活 | 主 Agent 不读被审源码；代码阅读交给 reviewer 子 agent |
| 按文件数切轮，或一个 agent 铺 30 个文件 | 单位是**模块**，一模块一轮；模块太大拆子轮，最后合并成一份模块报告 |
| 两个 agent 同时审同一个模块（含子轮） | 模块内一律串行；并行只发生在不同模块之间 |
| 报告先写到 `reviews/`，事后再整理 | 模块报告直接写 `docs/review/<YYYY-MM-DD>/<module>.md`，随代码入库 |
| 只审 `src/`，README 与 `doc/**` 跳过不看 | 模块内**全部** `.cj` 与 `.md` 都要读；文件清单见 `files/<module>.txt` |
| README 说有、代码里没有 | 按 §14.1 报功能缺失：**承诺源 + 缺失证据**，不要只说「文档过期」 |
| 新加的 public API 没写进 README | 按 §14.2 逐个公开声明对照 README，缺的列符号名 |
| 审完就地在主工作区改代码 | 修复在 `using-git-worktrees` 建的 worktree 里做，主工作区不动 |
| 多个问题合成一个 change / 一个提交 | 一个问题一个 OpenSpec change、一个提交 |
| 修完不删 worktree 与分支 | 合入源分支并推送后，删掉本流程创建的那一个 |
| 把 `reviews/` 也提交了 | 只有 `docs/review/` 入库；`reviews/` 是过程目录，留在本地 |
| 先问「要不要现在做全量审查」/「是否启动」 | 全量是默认，直接开跑；只在真需要用户裁决（工作区脏、删分支、扩大修复范围）时才问 |
| 上次审过了，这次只看改动 / 只看 diff | 每次审查都是全量重读；历史报告只能当线索，结论要重新取证 |
| 先审几个关键模块，其余下次 | 一次运行必须覆盖 `modules.md` 的全部模块，不分批交付 |
| 有模块审失败，先把报告汇总了 | 先补齐（重试 / 重跑），补不齐须经用户同意才能带缺口，不得默认交付 |
| 文件太多就抽样，或只审改动过的文件 | 全量审查，抽样即漏项；文件多就拆子轮，范围不能缩 |
| 同日重审直接覆盖同名报告 | 改存 `_v2` 并在报告头注明，不静默丢历史 |
| 报告没有「覆盖自检」表，或表里缺行 | 该表是结构性要求；缺行视为本轮未完成，打回重跑 |
| 死代码 / 重复逻辑两栏写「未发现」却没做符号搜索 | 这两类必须机械过一遍（`review-checklist §1 / §2` 的机械动作） |
| 只审 diff 里改过的行，现有代码的缺陷视而不见 | 本轮读到的现有逻辑也要按 `review-checklist §11` 过一遍；存量标 `[存量]` |
| 把存量缺陷当成本次改动的回归，或直接塞进修复范围 | 来源用 `git blame` 判定；存量默认只报，纳入与否由用户在门禁决定 |
| 把「优化可行性方案」写进 `todo.md` | `todo.md` 只收严重 + 一般缺陷；优化方案留在模块报告里 |
| 说「这个改动更快 / 更省内存」但没跑测试 | 必须有改前基线 + 改后对照（`-O2`、同输入、中位数）；否则只能写「待验证假设」 |
| 拿一次最快值或「关掉日志后变快了」当结论 | 不算证据：要中位数 + 离散程度 + 同环境对照 |
| 没数据也把性能项写进 `tasks.md` | 先补基线（Red 用例 + bench）再立项；无数据项不进 apply |
| 审到问题顺手改掉 | 审查阶段禁改源码；修复走步骤 2–6 |
| 用户说「只审查」还继续 propose | 唯一例外：只出报告时在步骤 1 结束 |
| 说「这个类是公共的，多线程用也没事」 | 并发安全要指出共享路径与同步手段；没找到共享路径就写线程封闭，别默认安全 |
| 为了性能把锁去掉 / 缩小 | 去锁是设计变更：先证明不变量有替代保护（不可变 / 线程封闭 / 原子），再附多线程压力测试 |
| 凭记忆断言标准库签名 / 语言特性 | 先查 `cangjie-doc-lookup`，报告里引文档位置；查不到写 `待确认` |
| 说「这个函数没人用」就要删 | 对外可达的 `public` 不算死代码；但**非公共顶级声明里的 `public` 成员**（类型 internal/private/protected）全项目无使用就算；`protected` 只有 `public open` / `public abstract`（非 `sealed`）类成员豁免 |
| 说「这个函数没人用」却只在单文件搜过 | `private` 搜全仓、`internal` 搜本包及子包、`protected` 先判所属类再定范围 |
| 说「这里是热点」但只有调用次数，没有 self time 占比 | 调用次数多 ≠ 最热；没数据就不是发现——写进「待验证假设」，不进 todo |
| 把「疑似热点 / 可能慢」当缺陷写进 `todo.md` | 无测量数据的热点结论一律不算发现；`todo.md` 只收有证据的缺陷 |
| 用单线程 profile 下并发瓶颈的结论 | 锁竞争 / 线程池饥饿在 CPU profile 里几乎不出现；补线程状态与等待时长 |
| 说「这里是热点 / 会泄漏」但没证据 | 写清输入规模、调用频次、持有路径；无证据只能定轻微 |
| 把 `Timer.after` 回调只返回一个 `Duration` 报成一次性定时器 | 回调返回值就是下次延迟，`Some` 自动重排（`fountain-baseline.md §5`） |
| 工作区不干净先 `merge --squash` | 先问用户：提交 / stash / 改快照审查 |
| 用提问工具给用户发范围问卷 | 信息不足用对话确认，阶段一不打断 |
| 审查后直接改代码，不走 propose | propose 是门禁；未评审 design/tasks 不进 apply |
| 顺手把轻微项也全修了 | 修复范围默认严重 + 一般；轻微项由用户拍板 |

## 前置与依赖

- 联动技能 `cangjie-doc-lookup`、12 个 `opsx-*`、`test-driven-development`、`using-git-worktrees`、`fountain-develop-framework`：加载失败按 `references/common-rules.md`「技能格式与联动技能」自动安装，不中断任务、不问用户。
- **不再需要** `cangjie-code-review-harness`（旧工作流 L 的依赖已取消）；reviewer 指令与清单随本技能分发。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（TDD / OpenSpec 六步 / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `reviewer.md` — reviewer 子 agent 的完整指令与报告模板
- `references/review-checklist.md` — 筛查主线（10 类代码专项 + 存量 BUG + local mode + 通用维度）
- `references/fountain-baseline.md` — fountain 项目约定
- `references/performance-optimization.md` — 性能深度手册
- `references/memory-optimization.md` — 内存深度手册
- `references/code-review-workflow.md` — 工作流 L 展开（范围模板、收尾、报告 → propose 映射）
- `references/openspec-workflow.md`、`references/delivery-workflow.md`、`references/opsx-waiting.md`、`references/sdk-bug-handling.md`、`references/environment.md`、`references/project-setup.md`、`references/common-rules.md`、`references/skill-infra.md` — 与其它工作流技能共用
- `scripts/review_workdir.py` — 生成 workdir、`scope.md`、`modules.md`（模块清单），并确保 `docs/review/<YYYY-MM-DD>/` 存在
- `scripts/install_skill.py`、`scripts/fountain_lookup.py`、`scripts/install_fboot.sh`、`scripts/migrate_fountain_imports.py`、`scripts/opsx_fusion.py`、`scripts/opsx_progress.py` — 联动技能与仓库查询

## 完成后的汇报

只审查时：报告已审模块数 / 失败模块、各模块报告路径（`docs/review/<YYYY-MM-DD>/<module>.md`）、跨模块统计与覆盖缺口。

进入修复时：按问题列出「编号 / 提交号 / verify 结果 / 性能类前后数据」，说明 worktree 分支已合入哪个源分支并推送、worktree 与分支已删除；跳过的问题单列并注明原因。

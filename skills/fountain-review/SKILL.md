---
name: fountain-review
description: 当用户要求审查 fountain 仓库或其中的仓颉模块 / 分支 / 工作区快照，并按审查报告修复时使用；逐模块审查，一个模块一份报告写到 docs/review 下（module_review_日期.md），覆盖死代码、表现形式不同的重复逻辑、空实现、栈溢出、OOM、并发安全与锁粒度、热点瓶颈定位、大粒度锁热点、并发串行、低效算法、现有代码存量 BUG、降低堆内存与 CPU 占用的可行性方案（含 local mode 探索），再走 OpenSpec 六步 + 严格 TDD 修复；主 Agent 不读被审源码。
---

# fountain-review — 代码审查 → OpenSpec 修复（工作流 L）

审查与修复一条线：内置**只读**审查引擎（并行 reviewer 子 agent）产出分轮报告与问题清单，再按 OpenSpec 六步 + 严格 TDD 把问题修完并归档。原 `fountain-code-review-fix` 已整体并入本技能；审查不再依赖 `cangjie-code-review-harness`。

两条不可让渡的原则：

1. **主 Agent 不读被审源码**——代码阅读由 reviewer 子 agent 完成，主 Agent 只操作 `scope.md` / `modules.md` / 模块报告 / `todo.md` / `review_summary.md`。
2. **逐模块审查、一模块一报告**——以模块为审查单元，每审完一个模块立即把报告写到 `{project_root}/docs/review/<module>_review_<YYYYMMDD>.md`。
3. **并发默认按"会被多线程调用"审**——先证明安全，再谈锁粒度；锁能不要就不要，要就要小。
4. **所有性能优化必须有性能测试数据**——CPU、内存、GC 压力、local mode 改造一律如此，见「性能结论的取证纪律」。

## 执行步骤

**适用**：审查当前项目 / 指定模块 / 指定分支，并按结论修复。产出 = **逐模块审查报告**（`docs/review/<module>_review_<YYYYMMDD>.md`）+ **汇总**（`todo.md`、`review_summary.md`）+ **OpenSpec 修复**（propose → 用户评审 → apply 逐任务 TDD → verify → archive + `doc/spec/`）。

**开工前置（自动执行，无需用户要求）**：
- **`cangjie-doc-lookup`**：没装就 `python <skill-root>/scripts/install_skill.py fountain`（从 fountain 仓库 `skills/` 装全部技能），装完跑 `python <cangjie-doc-lookup 技能目录>/scripts/skill_paths.py check`。
- **`opsx-*`（12 个）**：缺任一（`install_skill.py list` 不是 `12/12`）同样用 `install_skill.py fountain` 或 `install_skill.py opsx` 装齐，并确认运行器 `~/.workbuddy/scripts/opsx_fusion.py` 已部署。
- **`test-driven-development`**：进入步骤 4 前必须加载（**REQUIRED SUB-SKILL:**），apply 里逐任务 Red-Green-Refactor。
- **不需要** `cangjie-code-review-harness`：审查引擎随本技能分发（`reviewer.md` + `references/review-checklist.md`）。

1. **步骤 0 — 定范围与基线（只读）**：`project_root` = `git -C <目标> rev-parse --show-toplevel`（无 git 时向上找 `cjpm.toml` / `openspec/`）；「当前目录」→ 项目根 + `scope=.`，「指定模块」→ 项目根 + 该模块相对路径。基线二选一：**分支差异**（`source_branch != target_branch` 且 diff 非空）或**工作区快照**（无 git / 同分支 / diff 为空）；工作区不干净时停下问用户「提交 / stash / 快照审查」，不擅自处理。
2. **步骤 1 — 执行审查（本技能内建引擎）**：按下面「审查引擎」准备参数、`scope.md` 与 `modules.md`，分支模式走阶段零→四，快照模式跳过阶段零。**主 Agent 不读被审源码**；审查阶段**不改源码**。审查对象是**本次改动 + 本轮读到的现有代码**——现有代码里的缺陷同样要报，标 `[存量]`（`review-checklist §11`）。**一个模块一份报告，写到 `docs/review/`**，全部模块完成后汇总 `todo.md` + `review_summary.md`。
   - 用户明确说「只审查、不修」→ 本步结束，交报告，不进 OpenSpec。
3. **步骤 2 — 报告 → `opsx:propose`**：读 `todo.md` / `review_summary.md`（这是汇总产物，不是源码），统计严重 X / 一般 Y / 轻微 Z 与**存量 N 条**；**修复范围默认 = 本次改动的严重 + 一般**，轻微项与存量缺陷由用户决定是否纳入（既不静默丢弃，也不静默扩大范围）。给每条问题编号 `<module>-<序号>`（如 `f_orm-3`，存量加 `S` 后缀）；`openspec update` + `openspec list --json` 后执行 `opsx:propose "根据代码审查报告 <workdir>/todo.md 修复 <项目/模块> 的严重与一般问题（严重 X、一般 Y）"`——proposal 写审查范围/基线与统计，design 写修复方案与风险，**tasks 逐条映射 `[f_orm-3][严重]`（含复现点与测试点，禁止漏项）**；把 `todo.md` + `review_summary.md` 复制到 `doc/spec/<变更名>/review.md`，模块报告保留在 `docs/review/`。**本步只写规划产物，不改代码**，完成后停下等评审。
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
- **`report_dir`**（默认 `{project_root}/docs/review/`）— 模块报告落盘目录
- **`date`**（默认今天）— 报告文件名里的 `YYYYMMDD`
- **`parallel_per_batch`**（可选，默认 `2`）— 每批并行子 agent 数（按模块计）

基线判定：`source != target` 且 `git diff --stat {target}...{source}` 非空 → `branch`；否则（无 git / 同分支 / diff 为空）→ `snapshot`。

### 文件约定

过程文件在 `{workdir}/`，**模块报告写仓库的 `docs/review/`**（随代码入库）：

| 文件 | 位置 | 生产者 | 用途 |
| --- | --- | --- | --- |
| `scope.md` | `{workdir}/` | 主 Agent | 范围、基线、重点、排除项 |
| `modules.md` | `{workdir}/` | 主 Agent（脚本生成） | 模块清单与状态：模块 / 路径 / 源文件数 / 报告文件 / `待审`→`已审` |
| `<module>_review_<YYYYMMDD>.md` | `{project_root}/docs/review/` | reviewer 子 agent | **一模块一份**：发现 + 优化可行性方案 + 覆盖自检 + 统计 |
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

脚本会创建 `{workdir}/`、写 `scope.md` 与 `modules.md`、确保 `docs/review/` 存在，并打印 `WORKDIR` / `BRANCH` / `DATE` / `REPORT_DIR` / `MODULE_COUNT`。

模块判定：目录含 `cjpm.toml` 且 `src/` 下至少一个 `.cj`（工作区根因无 `src` 被跳过；`fdemo/user` 这类子模块单独算一个）。已有 `scope.md` 时不要覆盖，改用 `--force`。

### 阶段二：模块排队（用户门禁）

1. 以 `modules.md` 为排期表，**一个模块一轮**；不再按「每轮 8–12 个文件」切。
2. 模块内 `src/` 源文件超过约 15 个时，拆成多个子轮（`part1/part2…`），各部分写 `{workdir}/parts/<module>.part{N}.md`，全部分完后由主 Agent 合并成一份模块报告（合并的是报告，不是源码）。
3. 给每个模块标一个重点（例如「`f_orm`：executor 生命周期与连接池——重点 OOM、大粒度锁」），把模块排期展示给用户，问「是否启动？」，确认后进阶段三。

### 阶段三：逐模块审查（并行）

按 `parallel_per_batch` 分批启动，每批 K 个**不同模块**的 agent 并行（同一模块同一时刻只跑一个 agent，避免两份报告抢同一路径）：

```
请先阅读文件 {skill_dir}/reviewer.md 获取完整工作指令，然后按要求完成以下任务：

范围界定文件：{workdir}/scope.md
模块清单：{workdir}/modules.md
审查报告输出文件：{project_root}/docs/review/<module>_review_<YYYYMMDD>.md
项目根目录：{project_root}
本轮审查目标：模块 <module>（路径 <rel>，<n> 个源文件），重点：<专项>
```

- 用当前 Agent 的子 agent 机制（`Task` 工具）；平台有专用高强度类型就用，没有就用默认类型。
- **审完一个模块立即落盘**：报告写完 → 主 Agent 把 `modules.md` 该行改成 `已审`，再启动下一批；不要等所有模块审完才写。
- 同名报告已存在（同日重审）时**不静默覆盖**：改存 `<module>_review_<YYYYMMDD>_v2.md`，报告头注明与上一份的关系。
- 某模块失败：重试一次；仍失败则把 `modules.md` 标 `失败（原因）`，继续其它模块，并在汇总里列覆盖缺口。

### 阶段四：跨模块汇总

1. 启动一个汇总子 agent（按 `modules.md` 里状态为 `已审` 的报告汇总）：

```
请读取 {workdir}/modules.md，按清单读取 docs/review/ 下各模块报告，生成两个文件：

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

2. 主 Agent 读 `todo.md` + `review_summary.md`，向用户返回：模块数、各模块问题统计、主要风险、覆盖缺口。**不输出报告全文**，引导用户看 `docs/review/` 与 `todo.md`。

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
| 两个 agent 同时审同一个模块 | 同模块串行（避免抢同一份报告），不同模块才并行 |
| 报告先写到 `reviews/`，事后再整理 | 模块报告直接写 `docs/review/<module>_review_<YYYYMMDD>.md`，随代码入库 |
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

- 联动技能 `cangjie-doc-lookup`、12 个 `opsx-*`、`test-driven-development`：加载失败按 `references/common-rules.md`「技能格式与联动技能」自动安装，不中断任务、不问用户。
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
- `scripts/review_workdir.py` — 生成 workdir、`scope.md`、`modules.md`（模块清单），并确保 `docs/review/` 存在
- `scripts/install_skill.py`、`scripts/fountain_lookup.py`、`scripts/install_fboot.sh`、`scripts/migrate_fountain_imports.py`、`scripts/opsx_fusion.py`、`scripts/opsx_progress.py` — 联动技能与仓库查询

## 完成后的汇报

只审查时：报告已审模块数 / 失败模块、各模块报告路径（`docs/review/<module>_review_<YYYYMMDD>.md`）、跨模块统计与覆盖缺口。

进入修复时：追加修复摘要、verify 结果、性能类改动的前后数据与 `doc/spec/<变更名>/review.md`；下一步是交付 / archive。

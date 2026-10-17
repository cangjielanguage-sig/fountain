# OpenSpec 规格驱动流程（工作流 F / G / H / I / J 全程）

**工作流 F / G / H / I / J 五个开发类工作流全程自动走 OpenSpec 六步**（无需用户额外要求）：F（按需求文档开发服务器应用）、G（其他语言 → 仓颉）、H（仓颉项目 → fountain 风格）、I（旧版本升级）、J（fountain 仓库内开发：新建模块 / 加功能 / 修缺陷一律）。
OpenSpec 把「需求 → 规格 → 设计 → 任务 → 实现 → 校验 → 归档」固化成仓库里的文件；本技能原有的门禁（TDD / 全量回归 / 冒烟 / 提交 / 建 tag）**不变**，只是把「读需求 + 拆功能点」从对话里的临时结论变成可评审、可回溯的产物。
**产物必须落盘 `doc/spec/<变更名>/`**：fountain 放相应模块的 `doc/`，其他项目放项目根的 `doc/`（详见第 5.1 节）。

> **在鸿蒙 PC 上，第 4 节六步里的每一步都经 12 个 `opsx-*` 技能走 ssh 投递到融合开发引擎执行**（连接信息首次访问问用户并固化、IP 失效重问）。通道、对应关系、安装与两套技能的区别见**第 9 节**。

## 1. 环境准备（每个项目一次）

**先检测，再决定装不装**（不要无条件重装）：

```bash
openspec --version                              # 有版本号即已装（要求 Node >= 20.19）
npm install -g @fission-ai/openspec@latest      # 只有查不到命令 / 版本过低时才装
```

- 装完复验 `openspec --version`；命令仍找不到时看 `npm prefix -g`（Windows 是 `<prefix>\openspec.cmd`，Linux/macOS 是 `<prefix>/bin/openspec`）并把该目录加进 PATH。
- 有些环境（如 WorkBuddy 托管的 Node）把全局 shim 转接到受管 Node 目录：这时用该 Node 自带的 npm 装，别手工改 shim。

**项目初始化**（`openspec list --json` 返回 `"root": null` 且退出码非零 ⇒ 这个项目还没初始化，不是 CLI 坏了）：

```bash
openspec init --tools <tool>
```

- **`<tool>` 必须问用户**：让用户指定自己用的开发工具，不要替他选、也不要默认 `all`。常见取值：`codebuddy`、`claude`、`cursor`、`codex`、`agents`（通用目录）、`none`；完整列表见 `openspec init --help`。
- `--tools` 可给逗号分隔的多个值（如 `codebuddy,claude`）；`all` 会把所有工具的指令文件都写进仓库，一般不要。
- 产出：`openspec/`（`config.yaml` + `changes/` + `specs/`）与该工具的技能/命令目录（CodeBuddy 是 `.codebuddy/skills/openspec-*`，Claude Code 是 `.claude/commands/opsx/*`）。
- 已初始化过的项目重复执行 `openspec init` 是加装别的工具，不是「重置」；不确定时先问用户。
- **只读判断**：`openspec context --json` 返回 `root.path` 即已有根；返回 `no_openspec_root` 就是没初始化。

## 2. `openspec/config.yaml`（每个项目一次）

初始化会生成 `openspec/config.yaml`（旧版是 `config.yml`；**优先读 `config.yaml`**）。必须确认 `context` 里有这一条：

```yaml
context: |
  所有产出物用简体中文撰写
```

- **追加，不覆盖**：`context` 下已有其他内容时另起一行加进去；`schema`（默认 `spec-driven`）、`rules`、`operations` 段原样保留。
- 文件不存在时按上面的最小内容新建（只有 `context` 也需要 `schema: spec-driven` 一起写）。
- 这个 context 是给 AI 的**约束**，不会被抄进产物文件；它保证 propose / apply / verify / archive 写出来的 `proposal.md`、`design.md`、`tasks.md`、规格 delta 都是简体中文。

## 3. 每次开工前：先更新一次 OpenSpec（工作流 F / J 的第一步）

```bash
openspec update            # 刷新本项目的 OpenSpec 指令文件与技能，使其与当前 CLI 同版
openspec list --json       # 看有没有在途变更；有则先决定「继续 / 归档 / 新建」，别并行开第二个
```

`openspec update` 刷新的是**指令文件**（技能 / 命令），不是「更新某个变更」；要改变更内容用 `opsx:update`（openspec-update-change，见第 4 节步骤 3）。CLI 升级过、或 `openspec init` 是很久以前跑的，这一步尤其重要。

## 4. 六步流程（F / G / H / I / J 全程）

> **在鸿蒙 PC 上，下面每步的「加载技能」一律指加载对应的 `opsx-*` 技能**（`opsx:propose` → `opsx-propose`，依次类推）——它是你的执行通道。本节提到的 `openspec-propose` / `openspec-apply-change` 等项目内技能文件，是**融合侧 CodeBuddy** 读的指令文件，不是你自己的加载对象；两套的区别与分工见第 9 节。

**各工作流在本流程中的专属动作**

| 工作流 | 步骤 1（环境与刷新） | 步骤 2（propose 前） | 步骤 4（apply） |
| --- | --- | --- | --- |
| F 需求开发 | init / update / list + 读需求拆功能点 | 能力映射 + 缺口处理（a–d） | 搭骨架 + 逐任务 TDD |
| G 跨语言转换 | update / list + 取源码、侦察 | 映射表 + 缺口 + 分期计划 | 搭骨架 + 分批转换 |
| H 仓颉 → fountain | update / list + 现状评估 | 能力映射 + 缺口 + 改造计划 | 骨架 + 拆 main + 能力替换 |
| I 旧版升级 | fboot 版本对齐 + update / list + 现状评估 | 升级范围 + 硬差异 + 适配计划 | 依赖 / import / API 适配 |
| J 框架自身 | update / list + 先复用再实现查证 | 缺口拍板 + propose | 按 tasks 逐任务 TDD |

### 步骤 1 — 环境与刷新

```bash
openspec --version                 # 没装先装（见第 1 节）
openspec update                    # 刷新本项目指令文件与技能
openspec list --json               # 看在途变更；有则先决定「继续 / 归档 / 新建」
```

- 每个项目**只初始化一次**（`openspec init --tools <tool>`，见第 1 节）；转换 / 升级类工作流在**产出项目根**初始化，不是原项目。
- 首次开工还要确认 `config.yaml` 的 `context` 含「所有产出物用简体中文撰写」（第 2 节，追加不覆盖）。
- 本步无产物：它保证步骤 2 的 `openspec new change` / `openspec instructions` 用的是当前版本的指令文件。

### 步骤 2 — `opsx:propose 实现 XX 功能`

**加载 `opsx-propose` 技能**（鸿蒙 PC 上的执行通道，见第 9 节；`openspec-propose` 是融合侧 CodeBuddy 读的指令文件，不是你的加载对象）。等价的 CLI 链路：

```bash
openspec new change "<变更名>"                                  # 变更名用 kebab-case
openspec status --change "<变更名>" --json                      # 取 applyRequires 与各 artifact 的 requires 边
openspec instructions <artifact> --change "<变更名>" --json     # 逐个取 template / instruction / 输出路径
```

产物（默认 `spec-driven` schema，即 `openspec/changes/<变更名>/` 下的**五件套**）：

| 产物 | 内容 |
| --- | --- |
| `proposal.md` | 做什么、为什么（what & why） |
| `specs/<capability-path>/spec.md` | 规格 **delta**（ADDED / MODIFIED / REMOVED / RENAMED 需求），不是主规格 |
| `design.md` | 怎么做（架构、模块边界、数据模型、取舍） |
| `tasks.md` | 实施步骤清单 |
| `.openspec.yaml` | schema 与 `skip_specs` 等元数据（由 `openspec new change` 生成） |

- 把工作流 F 步骤 2 的能力映射与缺口结论、工作流 J 步骤 1–2 的复用查证与拍板选项**写进** proposal / design，不要留在对话里。
- `apply.requires` 只列最小集，但要把 `requires` 边的**传递闭包**都写出来（proposal / specs / design / tasks），别只交 tasks.md。
- **规划边界**：本步只写规划产物，**不改项目代码**。产物交出来后停下，等用户确认再进 apply。
- 同一变更名已存在时，问用户是继续它还是新建。
- **propose 完成后立即落盘**：按第 5.1 节把四件套同步到 `doc/spec/<变更名>/`（新建副本，供评审与入库）；评审期间的修订以 `openspec/changes/` 为准，archive 后再用最终版覆盖。

### 步骤 3 — 用户评审 design.md / tasks.md（门禁）

把 `design.md` 与 `tasks.md` **全文**交用户评审，逐条确认：

- **模块边界与依赖方向**：职责划在哪个模块 / 包，谁依赖谁；是否符合仓库既有分层；
- **数据模型与迁移**：表结构、字段、索引、兼容旧数据；
- **异常与错误码**：错误语义、HTTP / RPC 返回约定；
- **边界场景**：空值 / 缺参、超限与溢出、并发与幂等、重复提交、重启恢复、超时与重试；
- **验收判据**：每条需求怎么验收（接口、返回值、日志）；
- **兼容性与发布影响**（工作流 J 尤其）：是否动公开 API、是否破坏既有调用方、`README` 中英是否需同步。

用户反馈用 `opsx:update`（openspec-update-change）折回产物并保持各项一致。**用户明确确认前不得进入 apply，也不得提前写实现代码。**

### 步骤 4 — `opsx:apply`

**加载 `opsx-apply` 技能**（见第 9 节）；等价 CLI：

```bash
openspec instructions apply --change "<变更名>" --json   # 取 contextFiles 与任务进度
```

- **严格跟随 design.md**：实现与 design 冲突时**不要自行改设计**，回到步骤 3（评审门禁）问用户。
- **逐任务 TDD**（**REQUIRED SUB-SKILL:** `test-driven-development`）：每个任务先写失败用例（Red）→ 最小实现（Green）→ 重构（Refactor），跑绿之后才勾掉任务。**不许出现「任务已勾选但没有对应测试」的进度**——那是假进度。
- 实现中需要新的 fountain 模块，按工作流 D 随时补根 `cjpm.toml` 依赖。
- 批次末跑全量回归；`fboot build` 通过。

### 步骤 5 — `opsx:verify`（不在 core 档，需先启用，见第 6 节）

**加载 `opsx-verify` 技能**（见第 9 节）。三个维度：

| 维度 | 查什么 |
| --- | --- |
| Completeness | tasks 是否全部完成、delta 规格的需求是否都有落点 |
| Correctness | 需求与场景是否**真的**实现（不是文件存在就算） |
| Coherence | 是否遵循 design.md 与仓库既有模式 |

- 报告按 **CRITICAL / WARNING / SUGGESTION** 分级；**CRITICAL 未清零不进 archive**，WARNING / SUGGESTION 逐条与用户确认「现在修 / 记录为遗留」。
- verify 只做校验：**不实现任务、不归档**。
- schema 未定义、或状态标记为 `skipped`（如 `skip_specs: true`）的检查项记 **Not applicable**，不计入未通过项，也不要为了刷绿报告去补造产物。

**回退（verify 不可用时）**：`openspec validate <变更名> --strict` + 人工三对齐——
design 的每个决定能在代码里找到落点；tasks 全部勾选且逐条有对应用例；delta 规格的每个 scenario 都能被验收步骤覆盖。

### 步骤 6 — `opsx:archive` + 产物落盘

**加载 `opsx-archive` 技能**（见第 9 节）；等价 CLI：

```bash
openspec archive <变更名>          # 把 delta 规格合并进 openspec/specs/，变更目录移进 changes/archive/
```

- 前置：tasks 全部完成、verify 无 CRITICAL、代码门禁（`fboot build` + 全量回归 + 冒烟）已过、提交与 tag 已完成（见第 7 节顺序）。
- 归档后用最终版**覆盖更新** `doc/spec/<变更名>/`（第 5.1 节；fountain 为相应模块 doc、其他项目为项目根 doc）。
- `--skip-specs` 只用于纯基建 / 纯文档变更，业务变更不要用。
- `--no-validate` 除用户明确同意外不要用。

## 5. 目录地图

```
openspec/
├── config.yaml                 # schema + context（含「所有产出物用简体中文撰写」）
├── specs/<capability>/spec.md  # 主规格：archive 时由 delta 合并沉淀
└── changes/
    ├── <变更名>/               # 在途变更（五件套）
    └── archive/                # 已归档变更
```

是否把 `openspec/` 提交进 git 由项目决定（fountain 仓库当前在 `.gitignore` 里忽略它，即归档只作本地沉淀）。换项目时先确认落库策略再动手。

### 5.1 产物落盘 `doc/spec/<变更名>/`（必做）

OpenSpec 的 `openspec/specs` 路径由 CLI 固定，不能改到别处；**入库与回溯用的规格副本统一落盘 `doc/spec/`**：

| 项目类型 | 落盘位置 | 说明 |
| --- | --- | --- |
| fountain 仓库（工作流 J） | `<相应模块>/doc/spec/<变更名>/` | 跨多个模块时，各模块放与其 capability 相关的 `spec.md`；`proposal.md` / `design.md` / `tasks.md` 放**主模块** |
| 其他项目（工作流 F / G / H / I） | `<项目根>/doc/spec/<变更名>/` | 转换 / 升级类是**产出项目根**，不是原项目 |

- **四件套全存**：`proposal.md`、`spec.md`（规格 delta；多 capability 时保留 `specs/<capability-path>/spec.md` 结构）、`design.md`、`tasks.md`。
- **时机**：① 步骤 2 propose 完成后新建副本（评审与入库可见）；② 步骤 6 archive 完成后用 OpenSpec 最终版**覆盖更新**（以最终版为准）。
- **原因**：`openspec/` 可能被 `.gitignore` 忽略（fountain 仓库当前如此）；`doc/spec/` 是随代码入库、可评审、可回溯的规格副本，不得省略。
- 主模块 = 变更的主要落点（步骤 2 确定，步骤 3 评审时确认）。

## 6. 工作流档位（profile）：启用 core 之外的 6 个工作流

OpenSpec 的工作流分两处来：**core 档固定 6 个**——`propose` / `explore` / `apply` / `update` / `sync` / `archive`，初次 `openspec init` 只生成这 6 个技能与命令；**其余 6 个**——`new` / `continue` / `ff` / `verify` / `bulk-archive` / `onboard`，必须在全局档位里显式启用才会生成。

本技能用到 core 之外的两个：`verify`（步骤 5，代码与规范一致性校验）与 `bulk-archive`（多个已完成变更一次归档）。

```bash
openspec config list                    # 先看当前 profile 与 workflows
openspec config set profile custom      # 必须：profile=core 时 workflows 数组被完全忽略
openspec config set workflows '["propose","explore","new","continue","apply","update","ff","sync","archive","bulk-archive","verify","onboard"]'
openspec update --force                 # 重新生成项目内的技能/命令，这时才出现 openspec-verify-change 等
```

- **`profile` 只有 `core` / `custom` 两个取值**，没有第三档。要自定义就必须 `custom`；留在 `core` 时 `workflows` 数组会被直接忽略——配置写得进去、也不报错，就是不生效，这是最容易白忙一场的坑。
- **`openspec config profile [preset]` 只有一个 preset：`core`。** 不带参数会进交互式选择器，它能勾选 core 之外的候选（`new` / `continue` / `ff` / `bulk-archive` / `verify` / `onboard`），但选择器**要求 TTY**——非交互环境（脚本、CI、编辑器托管的终端）里直接报 `Interactive mode required` 并退出。所以自动化场景只能走上面的 `config set`。
- **选 `custom` 后必须显式列出全部想用的工作流**——漏掉的会被卸掉（项目里对应的技能与命令文件被清掉）；`archive` / `bulk-archive` 会自动带上 `sync`。
- **`openspec config set` 传数组在 Windows PowerShell 下会失败**（报 `Invalid input: expected array, received string`——PowerShell 把内层双引号剥掉，值解析不出数组）。两条出路：改用 `cmd /c` / Git Bash 跑上面这条命令；或直接编辑全局配置文件（Windows `%APPDATA%\openspec\config.json`，Unix/macOS `~/.config/openspec/config.json`，有 `$XDG_CONFIG_HOME` 时在它下面），把 `"workflows"` 数组补齐，再 `openspec update --force`。改完都用 `openspec config list` 复验。
- **这是全局配置**（`openspec config` 只支持 global scope，没有项目级档位），影响本机所有项目——其它项目下次 `openspec update` 也会多拿到这些工作流；改之前跟用户说一声。
- **改完配置不会自动同步**，必须到项目里跑一次 `openspec update`。工作流集合发生变化时它会自动识别并重新生成，无需 `--force`；`--force` 只是保险（用于怀疑"判定已最新而跳过"时）。
- **生效判据**：`openspec update` 输出里的「N more workflows are available」提示消失（或数字变小），且项目技能目录里出现对应的 `openspec-verify-change` / `openspec-bulk-archive-change` 等。
- 装好 `verify` 后，本技能的工作流 F / G / H / I / J 走步骤 5 的完整校验；没装就按步骤 5 的**回退**执行，不静默跳过。

## 7. 与交付门禁的关系（顺序）

OpenSpec 管「做什么、为什么、怎么设计、进度」；本技能管「在 fountain 里怎么把它做对」。二者叠加，顺序：

```
openspec update                     （步骤 1 环境与刷新）
  → opsx:propose                    （步骤 2：只出规划产物，不改代码；落盘 doc/spec/）
  → 用户评审 design / tasks          （步骤 3 门禁：未确认不进 apply）
  → opsx:apply                      （步骤 4：逐任务 TDD + 批次回归）
  → fboot build + 全量回归 + 冒烟     （步骤 5 前置门禁）
  → opsx:verify                     （步骤 5：CRITICAL 清零）
  → 提交 / 推送 / 建 tag             （delivery-workflow 第 6 / 7 节）
  → opsx:archive + 落盘最终版        （步骤 6：覆盖更新 doc/spec/<变更名>/）
```

`archive` 放最后：万一后续发现问题还要补代码，变更目录还在，可以继续 apply。**OpenSpec 的归档不替代提交与 tag**，也不替代全量回归与冒烟。

## 8. 常见坑

- `openspec list --json`  `"root": null` + 非零退出 = 项目未初始化（不是 CLI 坏了）；自动选中的流程不要顺手建 `openspec/`，只有用户明确要求初始化时才 `openspec init`。
- `openspec update` ≠ `opsx:update`：前者刷新指令文件，后者修订某个变更的规划产物。
- `openspec validate` 只校验**文件结构与规格格式**，不代表代码实现了；代码与规范是否一致靠 `opsx:verify`。
- propose 阶段的 `design.md` 在 `spec-driven` schema 里是**可选**产物（`skip_specs` 场景同理），但工作流 F / G / H / I / J 依赖它做评审门禁 —— 本技能要求必须产出。
- `doc/spec/` 不是可选副本：propose 后与 archive 后各同步一次；fountain 放相应模块 `doc/spec/<变更名>/`、其他项目放项目根 `doc/spec/<变更名>/`（第 5.1 节）。只留 `openspec/` 本地目录 = 交付无凭据（fountain 仓库还会被 `.gitignore` 掉）。
- G / H / I 不是 OpenSpec 的例外：转换 / 升级同样六步全程，propose 前的能力映射与缺口结论必须写进 proposal / design（别留在对话里）。
- 一个仓库可能有多个在途变更：开工前 `openspec list` 看清，别把别人的变更当自己的继续做。
- Windows 下 `openspec` 是 npm 全局 shim（`.cmd`）：命令找不到先查 `npm prefix -g` 与 PATH，别急着卸载重装。
- 在鸿蒙 PC 上，OpenSpec 的**工作流步骤**由 12 个 `opsx-*` 技能生成 ssh 命令、代跑到**融合开发引擎**执行；`openspec` CLI 只在鸿蒙侧做**环境与查询**（`init` / `update` / `list` / `config` / `validate`）。两者别混：混了会漏掉 `/mnt/linux_share` 前缀与预检，或误在融合侧重装 CLI（第 9 节）。

## 9. 在鸿蒙 PC 上执行：用 `opsx-*` 技能族（12 个）

**在鸿蒙 PC 上，六步流程的每一步都经 12 个 `opsx-*` 技能投递，访问通道是 ssh。** 技能先探测与**融合开发引擎**（Linux 子系统）的 ssh 连接（首次访问问用户 IP / 用户名 / 密码并固化，IP 失效重问），再生成 ssh 命令、由你用 Bash 工具代跑到那边 CodeBuddy CLI，跑完读回输出汇报。12 个技能与 OpenSpec 的 12 个工作流一一对应。

### 9.1 先做这一步（条件判断，别跳过）

```
本机能加载 opsx-<工作流> 技能  →  直接加载，按它的流程执行（ssh 探测 → 生成命令 → 代跑 → 汇报）
本机没装这批技能              →  先 install_skill.py opsx 装上，再加载
```

`opsx-*` 技能的来源是 **fountain 仓库的 `skills/opsx-*`**。本机没装就用本技能自带的脚本从那份源装上（**不要手工 `git clone` + `cp`、不要改用手写规格代替**）：

```bash
python <skill-root>/scripts/install_skill.py opsx      # 装 12 个 opsx-* 技能
python <skill-root>/scripts/install_skill.py list      # 复验：opsx-* 那组应显示 12/12 已装
```

- 安装目标是**当前 Agent 的技能目录**——在鸿蒙 PC 的 WorkBuddy 上就是 `~/.workbuddy/skills/`（脚本会优先选中「放着 `fountain-developer` 的那个技能目录」）。
- 脚本会**自动跳过**被 openspec 托管的项目内 `.codebuddy/skills`（那是 `openspec update` 生成、会被整片重刷的目录，装进去会静默消失）。
- 源里没有这批技能时（例如检出的分支还没合入它们），脚本会明确报「该切哪个分支」；按提示 `git -C <fountain> switch sts/1.3.x`，或 `--fountain-root` 指到含 `skills/opsx-*` 的源码。
- 同一脚本的 `all` 会把三组联动技能（cangjie-coding / cangjie-doc-lookup / 12 个 opsx-*）一次装齐；单个技能名可单装。
- 装 12 个 `opsx-*` 时会把**运行器 `opsx_fusion.py` 一并部署**到 `~/.workbuddy/scripts/`（ssh 探测 / 连接固化 / 生成命令都靠它，缺了技能第一步就失败；源在仓库 `skills/fountain-developer/scripts/`）。

### 9.2 12 个技能 ↔ 12 个工作流

| 技能 | 对应 `/opsx:` | 本流程里什么时候用 |
| --- | --- | --- |
| `opsx-propose` | `propose` | 步骤 2：建变更 + 一次性产出规划产物 |
| `opsx-explore` | `explore` | 步骤 2 之前：需求还没想清楚，先调研再写 |
| `opsx-new` | `new` | 只要脚手架、明确不要任何产物 |
| `opsx-continue` | `continue` | 变更只产出了一部分，补下一份 |
| `opsx-ff` | `ff` | 快速路线：一次性出全部规划产物 |
| `opsx-apply` | `apply` | 步骤 4：按 tasks.md 编码 |
| `opsx-update` | `update` | 步骤 3 评审后：修订产出的规划文档 |
| `opsx-verify` | `verify` | 步骤 5：实现与规范一致性校验 |
| `opsx-sync` | `sync` | 把 delta 规格合进主规范 `openspec/specs/` |
| `opsx-archive` | `archive` | 步骤 6：归档变更 + 落盘
| `opsx-bulk-archive` | `bulk-archive` | 多个已完成的变更一次归档 |
| `opsx-onboard` | `onboard` | 给还没有规范的老项目反向生成初始规范 |

### 9.3 每个技能做什么、谁在哪一侧

每个技能的流程：**ssh 探测（`ssh-check`）→ 生成命令（`plan`，一条 ssh + heredoc 命令）→ 代跑 → 汇报**。命令内三段固定顺序：

1. `cd /mnt/linux_share/<鸿蒙侧家目录>/...`——**融合侧路径 = 鸿蒙侧路径前加 `/mnt/linux_share`**；
2. 预检：确认此处是 openspec 根（有 `openspec/config.yaml`）、确认融合侧有 `codebuddy`，缺了就打安装命令并中止；
3. `codebuddy -p "/opsx:<工作流> <主题>" --permission-mode acceptEdits`。

命令由你按技能指引用 Bash 工具（长任务后台模式）**原样代跑**到融合开发引擎；连接信息（IP / 用户名 / 密码）首次访问问用户后用 `ssh-set` 固化在 `~/.workbuddy/openspec-fusion.json` 的 `fusion.ssh` 段，IP 失效重问。**等待期间按 `references/opsx-waiting.md` 的协议每 5 分钟报告一次进度**（六阶段状态 + 进行中客观详情；连续 3 轮无进展即暂停报告、转停滞诊断）。**技能不建目录、不改文件**（除固化自身连接配置外）。

| 动作 | 在哪一侧 | 谁做 |
| --- | --- | --- |
| `openspec init` / `update` / `list` / `config` / `validate` | **鸿蒙侧** | 你（直接跑） |
| ssh 连接探测与固化 | 鸿蒙侧（`ssh-check` / `ssh-set` / `ssh-push-key`） | 你（按技能流程） |
| `/opsx:<工作流>` 的实际执行 | **融合开发引擎**（ssh 投递，路径 `/mnt/linux_share/...`） | 你（Bash 工具代跑技能生成的命令） |
| 产出物落盘 | 融合侧写入共享目录 = 鸿蒙侧同一份文件 | — |

- `openspec` CLI 跑在**鸿蒙侧**；**不要在融合侧重装它**，融合侧只需要仓库里那份 `.codebuddy/commands/opsx/` 与 `.codebuddy/skills/openspec-*`。
- **两套东西别混**：12 个 `opsx-*` 技能 = **你这个 Agent 的执行通道**（由 fountain 仓库分发、用 `install_skill.py opsx` 装）；`openspec update` 生成的 `openspec-*`（项目内 `.codebuddy/skills/`）= **融合侧 CodeBuddy 读的指令文件**（由 openspec CLI 生成、不要手工写）。两套都要在。
- 目标 worktree 与子目录由技能的参数决定，缺省回落配置文件（项目内 `<repo>/.workbuddy/openspec-fusion.json` 优先，回落到用户级）；现有 worktree 多于一个而用户没说时，**停下来问**，不要替用户挑。

### 9.4 缺哪一件会怎样

| 缺 | 症状 | 处理 |
| --- | --- | --- |
| 12 个 `opsx-*` 技能 | 你不知道六步该怎么执行，容易自己拼 `openspec` 命令，或直接去拉 `codebuddy` | `python <skill-root>/scripts/install_skill.py opsx` |
| 融合引擎 ssh 连接信息 | `ssh-check` 退出码 2（配置缺失），技能会问用户三项再固化 | 按技能流程提供 IP / 用户名 / 密码（已配置免密可留空），`ssh-set` 固化后复探 |
| 融合侧 codebuddy | 命令的第 ② 步预检就中止，并打印安装命令 | 按提示处理（融合侧跑 `~/.local/opt/codebuddy-linux/install.sh`） |
| 工作流未启用（如 `verify`） | 对应 `opsx-<工作流>` 技能加载后预检会硬拦截 | 按第 6 节把 profile 设为 `custom` 并启用该工作流 |
| 项目未初始化 OpenSpec | 命令的预检找不到 `openspec/config.yaml` | 按第 1–2 节装 CLI / `openspec init --tools <tool>`（**`<tool>` 问用户**） |

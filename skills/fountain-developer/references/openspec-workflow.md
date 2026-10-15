# OpenSpec 规格驱动流程（工作流 F 全程 / 工作流 J 新建模块）

**工作流 F**（按需求文档开发服务器应用）**全程**走 OpenSpec；**工作流 J**（在 fountain 仓库内开发框架自身）在**新建模块**时走同一套流程。
OpenSpec 把「需求 → 规格 → 设计 → 任务 → 实现 → 校验 → 归档」固化成仓库里的文件；本技能原有的门禁（TDD / 全量回归 / 冒烟 / 提交 / 建 tag）**不变**，只是把「读需求 + 拆功能点」从对话里的临时结论变成可评审、可回溯的产物。

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

`openspec update` 刷新的是**指令文件**（技能 / 命令），不是「更新某个变更」；要改变更内容用 `opsx:update`（openspec-update-change，见第 4 步）。CLI 升级过、或 `openspec init` 是很久以前跑的，这一步尤其重要。

## 4. 五步流程

### 第 1 步 — `opsx:propose 实现 XX 功能`

加载 `openspec-propose` 技能（说「openspec propose」/「opsx propose」等价）。等价 CLI 链路：

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

- 把工作流 F 第 2 步的能力映射、第 3 步的缺口结论、工作流 J 第 1–2 步的复用查证与拍板选项**写进** proposal / design，不要留在对话里。
- `apply.requires` 只列最小集，但要把 `requires` 边的**传递闭包**都写出来（proposal / specs / design / tasks），别只交 tasks.md。
- **规划边界**：本步只写规划产物，**不改项目代码**。产物交出来后停下，等用户确认再进 apply。
- 同一变更名已存在时，问用户是继续它还是新建。

### 第 2 步 — 用户评审 design.md / tasks.md（门禁）

把 `design.md` 与 `tasks.md` **全文**交用户评审，逐条确认：

- **模块边界与依赖方向**：职责划在哪个模块 / 包，谁依赖谁；是否符合仓库既有分层；
- **数据模型与迁移**：表结构、字段、索引、兼容旧数据；
- **异常与错误码**：错误语义、HTTP / RPC 返回约定；
- **边界场景**：空值 / 缺参、超限与溢出、并发与幂等、重复提交、重启恢复、超时与重试；
- **验收判据**：每条需求怎么验收（接口、返回值、日志）；
- **兼容性与发布影响**（工作流 J 尤其）：是否动公开 API、是否破坏既有调用方、`README` 中英是否需同步。

用户反馈用 `opsx:update`（openspec-update-change）折回产物并保持各项一致。**用户明确确认前不得进入 apply，也不得提前写实现代码。**

### 第 3 步 — `opsx:apply`

加载 `openspec-apply-change` 技能；等价 CLI：

```bash
openspec instructions apply --change "<变更名>" --json   # 取 contextFiles 与任务进度
```

- **严格跟随 design.md**：实现与 design 冲突时**不要自行改设计**，回到第 2 步问用户。
- **逐任务 TDD**（**REQUIRED SUB-SKILL:** `test-driven-development`）：每个任务先写失败用例（Red）→ 最小实现（Green）→ 重构（Refactor），跑绿之后才勾掉任务。**不许出现「任务已勾选但没有对应测试」的进度**——那是假进度。
- 实现中需要新的 fountain 模块，按工作流 D 随时补根 `cjpm.toml` 依赖。
- 批次末跑全量回归；`fboot build` 通过。

### 第 4 步 — `opsx:verify`（需 extended，见第 6 节）

加载 `openspec-verify-change` 技能。三个维度：

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

### 第 5 步 — `opsx:archive`

加载 `openspec-archive-change` 技能；等价 CLI：

```bash
openspec archive <变更名>          # 把 delta 规格合并进 openspec/specs/，变更目录移进 changes/archive/
```

- 前置：tasks 全部完成、verify 无 CRITICAL、代码门禁（`fboot build` + 全量回归 + 冒烟）已过、提交与 tag 已完成（见第 7 节顺序）。
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

## 6. 启用 `opsx:verify`（extended）

`verify` **不在默认的 core profile 里**（core 只有 `propose` / `explore` / `apply` / `update` / `sync` / `archive`），所以初次 `openspec init` 不会生成 `openspec-verify-change`。

```bash
openspec config list                    # 先看当前 profile 与 workflows
openspec config set profile custom
openspec config set workflows '["propose","explore","apply","update","sync","archive","verify"]'
openspec update --force                 # 重新生成项目内的技能/命令，此时才出现 openspec-verify-change
```

- **`openspec config set` 传数组在 Windows PowerShell 下会失败**（报 `Invalid input: expected array, received string`——PowerShell 把内层双引号剥掉，值解析不出数组）。两条出路：改用 `cmd /c` / Git Bash 跑上面这条命令；或直接编辑全局配置文件（Windows `%APPDATA%\openspec\config.json`，Unix/macOS `~/.config/openspec/config.json`，有 `$XDG_CONFIG_HOME` 时在它下面），把 `"workflows"` 数组补上 `"verify"`，再 `openspec update --force`。改完都用 `openspec config list` 复验。
- **这是全局配置**，影响本机所有项目；改之前跟用户说一声。
- 选 `custom` 后必须显式列出**全部**想用的工作流——漏掉的会被卸掉；`archive` / `bulk-archive` 会自动带上 `sync`。
- 也可用交互式选择器 `openspec config profile`（需要 TTY），它会给出 core 之外的候选（`new` / `continue` / `ff` / `bulk-archive` / `verify` / `onboard`）。
- 生效判据：`openspec update` 提示里的「N more workflows are available」数字变小，且项目技能目录里出现 `openspec-verify-change`。
- 装好 `verify` 后，本技能的工作流 F / J 走第 4 步的完整校验；没装就按第 4 步的**回退**执行，不静默跳过。

## 7. 与交付门禁的关系（顺序）

OpenSpec 管「做什么、为什么、怎么设计、进度」；本技能管「在 fountain 里怎么把它做对」。二者叠加，顺序：

```
openspec update
  → opsx:propose            （只出规划产物，不改代码）
  → 用户评审 design / tasks （门禁：未确认不进 apply）
  → opsx:apply              （逐任务 TDD + 批次回归）
  → fboot build + 全量回归 + 冒烟
  → opsx:verify             （CRITICAL 清零）
  → 提交 / 推送 / 建 tag     （delivery-workflow 第 6 / 7 节）
  → opsx:archive            （沉淀规范、归档变更）
```

`archive` 放最后：万一后续发现问题还要补代码，变更目录还在，可以继续 apply。**OpenSpec 的归档不替代提交与 tag**，也不替代全量回归与冒烟。

## 8. 常见坑

- `openspec list --json`  `"root": null` + 非零退出 = 项目未初始化（不是 CLI 坏了）；自动选中的流程不要顺手建 `openspec/`，只有用户明确要求初始化时才 `openspec init`。
- `openspec update` ≠ `opsx:update`：前者刷新指令文件，后者修订某个变更的规划产物。
- `openspec validate` 只校验**文件结构与规格格式**，不代表代码实现了；代码与规范是否一致靠 `opsx:verify`。
- propose 阶段的 `design.md` 在 `spec-driven` schema 里是**可选**产物（`skip_specs` 场景同理），但工作流 F / J 依赖它做评审门禁 —— 本技能要求必须产出。
- 一个仓库可能有多个在途变更：开工前 `openspec list` 看清，别把别人的变更当自己的继续做。
- Windows 下 `openspec` 是 npm 全局 shim（`.cmd`）：命令找不到先查 `npm prefix -g` 与 PATH，别急着卸载重装。

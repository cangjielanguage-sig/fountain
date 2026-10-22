# 技能格式与联动技能（SKILL.md「技能格式与联动技能」小节的展开）

## 1. 技能格式与通用性

本技能是标准的 Agent Skills 布局（`SKILL.md` + `references/` + `scripts/`），**不绑定任何特定编程智能体**：

- 支持技能机制的 Agent：把 `skills/fountain-developer/` 放进它的技能目录即可（如 CodeBuddy 的 `~/.codebuddy/skills/`、Claude Code 的 `~/.claude/skills/`，或项目内的技能目录）；
- 不支持技能机制的 Agent：直接让它阅读 `SKILL.md` 并按流程执行，效果相同；
- `scripts/` 下的 `fountain_lookup.py`、`install_skill.py`（纯 Python 3 标准库）与 `install_fboot.sh`（bash）可独立运行，与 Agent 平台无关。

「加载技能」（如 `cangjie-coding` / `cangjie-doc-lookup`）一律指：按当前 Agent 的能力加载——支持技能机制的按其机制加载，不支持的直接读该技能目录下的 `SKILL.md`。

## 2. 联动技能的加载与自动安装

`cangjie-coding`（仓颉知识库 / 构建测试规范）、`cangjie-doc-lookup`（本地官方文档查阅）与 **12 个 `opsx-*` 技能**（在鸿蒙 PC 上执行 OpenSpec 的通道）**加载失败（技能没装）时不要中断任务、也不要停下来问用户**：直接用下面的脚本从权威来源装进当前 Agent 的技能目录，然后按正常方式加载。

```bash
python <skill-root>/scripts/install_skill.py list                # 先看各组装没装、来源在哪
python <skill-root>/scripts/install_skill.py cangjie-doc-lookup  # 从已克隆的 fountain 项目 skills/ 子目录装
python <skill-root>/scripts/install_skill.py cangjie-coding      # 从 CangjieSkills 仓装
python <skill-root>/scripts/install_skill.py opsx                # 装 12 个 opsx-* 技能（同源：fountain 的 skills/）
python <skill-root>/scripts/install_skill.py harness             # 装 cangjie_harness 仓全部审议式技能（工作流 L）
python <skill-root>/scripts/install_skill.py fountain            # 装 fountain 仓 skills/ 下全部技能（含 opsx-*）
python <skill-root>/scripts/install_skill.py workflows           # 装 12 个独立工作流技能（A-L）
python <skill-root>/scripts/install_skill.py all                 # 三组旧联动全装
```

| 加载失败的是 | 安装来源 | 说明 |
| --- | --- | --- |
| `cangjie-doc-lookup` | **已克隆的 fountain 项目**的 `<fountain-root>/skills/cangjie-doc-lookup` | fountain 仓库根按 `fountain_lookup.py` 同一套规则定位（`--root` > `$FOUNTAIN_ROOT` > 当前目录上溯 > 技能相对位置 > 技能目录下的克隆副本；都没有会先克隆文档副本）。若那份源码停在还没有该技能的旧版本，脚本会给出提示：切到较新的版本（文档副本用 `python <skill-root>/scripts/fountain_lookup.py switch latest`）或 `--fountain-root` 指到含它的源码 |
| `cangjie-coding` | `https://gitcode.com/Cangjie-SIG/CangjieSkills.git` | 默认**稀疏克隆**到 `~/.cangjie-skills/CangjieSkills`（只取 `.agents/skills`，`--repo-dir` 可改；已存在则 `git pull --ff-only`），再从 `.agents/skills/cangjie-coding` 复制进技能目录 |
| 12 个 `opsx-*` | **已克隆的 fountain 项目**的 `<fountain-root>/skills/opsx-<工作流>` | 与 `cangjie-doc-lookup` 同一套仓库定位规则；子命令 `opsx` 一次装齐 12 个（也可用 `install_skill.py opsx-propose` 单个装）。检出分支还没这批技能时（如停在未合入的 master），脚本会报该切哪个分支；用于鸿蒙 PC 上执行 OpenSpec，展开见 `references/openspec-workflow.md` 第 9 节 |
| `cangjie-code-review-harness`（及 harness 仓其它审议式技能） | `https://gitcode.com/zhangyin_gitcode/cangjie_harness.git` 的 `.opencode/skills/*` | 子命令 `harness` 装全部技能；默认检出到 `~/.cangjie-harness/cangjie_harness`（`--harness-dir` 可改）。本机没有 git 时优先借融合侧 git 克隆到共享目录，失败再用 GitCode 归档下载。工作流 L 依赖其中的 `cangjie-code-review-harness` |
| fountain 全部技能 | **已克隆的 fountain 项目**的 `<fountain-root>/skills/*` | 子命令 `fountain` 一次装 `cangjie-doc-lookup`、12 个 `opsx-*`、`fountain-tag`、`installing-cangjie-sdk`、`skill-generator` 等；跳过 `fountain-developer` 自身，避免边运行边覆盖。工作流 L 用它一次补齐 OpenSpec 通道与文档查阅 |
| 12 个工作流技能 | **已克隆的 fountain 项目**的 `<fountain-root>/skills/fountain-*` | 由 `fountain-developer` 拆分的 A-L 独立技能（`fountain-install-fboot` / `fountain-build-server` / `fountain-code-review-fix` 等）；子命令 `workflows` 一次装齐。每个技能自带 `references/common-rules.md` 与所需脚本，可独立加载；`fountain-developer` 只做调度 |

- 安装目标目录默认自动探测：优先**当前放着 `fountain-developer` 的那个技能目录**（`~/.workbuddy/skills`、`~/.codebuddy/skills`、`~/.claude/skills`、`~/.agents/skills` 等），也可 `--skills-root DIR` 指定；已装过的技能默认不覆盖，要升级加 `--force`。**被 openspec 托管的项目内 `.codebuddy/skills` 会被自动跳过**（它是 `openspec update` 生成、会被整片重刷的目录，装进去会静默消失）。
- 装完**复验**：`install_skill.py list` 显示各组状态（`opsx-*` 那组应为 `12/12`，`fountain 工作流技能` 应为 `12/12`，`fountain 全部技能` 应为全装，`cangjie-code-review-harness` 应为已装）。装好 `cangjie-doc-lookup` 后**必须**再跑它自己的执行前检查（`python <skills>/cangjie-doc-lookup/scripts/skill_paths.py check`），文档源路径对不上时按它 SKILL.md「执行前检查」的四选一处理。
- 装 12 个 `opsx-*` 时会把它依赖的**运行器 `opsx_fusion.py` 一并部署**到 `~/.workbuddy/scripts/`（ssh 探测 / 连接信息固化 / 生成执行命令都靠它，缺了技能第一步就失败）。源在 fountain 仓库 `skills/fountain-developer/scripts/opsx_fusion.py`；`list` 里会显示它的部署状态，已存在不一致时加 `--force` 更新。
- 不支持的技能机制的 Agent 不需要「安装」这一步：直接按上面的来源读该技能的 `SKILL.md` 即可（脚本也能用，只是把文件放到一个目录）。

## 3. 另外两类联动技能（test-driven-development / openspec 技能组）

### 3.1 `test-driven-development`

**工作流 F / G / H / I / J / L 开工前必须加载**（**REQUIRED SUB-SKILL:**）；它定义 Red-Green-Refactor 循环与反合理化清单，本技能的 TDD 门禁以它为准。
它随 **superpowers** 技能集分发，不归 `install_skill.py` 管；常见位置：

| 场景 | 位置 |
| --- | --- |
| 已装进当前 Agent（CodeBuddy） | `~/.codebuddy/skills/test-driven-development/`（含 `SKILL.md` + `writing-good-tests.md`） |
| 已装进当前 Agent（WorkBuddy / 鸿蒙 PC） | `~/.workbuddy/skills/test-driven-development/` |
| superpowers 插件本体 | `~/.codebuddy/plugins/marketplaces/codebuddy-plugins-official/external_plugins/superpowers/skills/test-driven-development/` |
| Claude Code | `~/.claude/skills/test-driven-development/`（或该平台的 superpowers 插件目录） |

处理顺序：能加载就加载 → 加载失败**不要中断任务、也不要停下来问用户**：按上表在本机找一份拷进当前 Agent 的技能目录（如 `~/.codebuddy/skills/`）→ 本机确实没有时，按 SKILL.md「严格 TDD」与 `references/delivery-workflow.md` 第 3 节的 Red-Green-Refactor 循环执行，并在交付说明里写明「未加载 `test-driven-development` 技能」。
不支持的技能机制的 Agent 直接读该技能目录下的 `SKILL.md`。

### 3.2 openspec 相关的两套技能（别混）

| | `opsx-*`（12 个） | `openspec-*`（项目内） |
| --- | --- | --- |
| 是什么 | **你这个 Agent 的执行通道**：ssh 探测连接 → `opsx_fusion.py` 生成命令 → Bash 工具代跑到融合开发引擎 | **融合侧 CodeBuddy 读的指令文件** |
| 谁生成 | fountain 仓库的 `skills/opsx-*`，用 `install_skill.py opsx` 安装 | `openspec init` / `openspec update`（**不要手工写、也不要手工拷**） |
| 位置 | 当前 Agent 的技能目录（鸿蒙 PC 上是 `~/.workbuddy/skills/`） | `<项目>/.codebuddy/skills/openspec-*` 与 `<项目>/.codebuddy/commands/opsx/*`（按 `--tools <tool>` 落地；Claude Code 是 `<项目>/.claude/commands/opsx/*`）|
| 加载时机 | **工作流 F / G / H / I / J / L 全程**，六步的每一步 | 不归你加载——由融合侧 CodeBuddy 读 |
| 缺失时 | `python <skill-root>/scripts/install_skill.py opsx` | 这个项目还没初始化 OpenSpec：按 `references/openspec-workflow.md` 第 1–2 节装 CLI、`openspec init --tools <tool>`（**`<tool>` 问用户**）、确认 `config.yaml` 的 `context` 含「所有产出物用简体中文撰写」 |

- CLI 升级后用 `openspec update` 重新生成指令文件，别沿用旧版。
- `verify` / `bulk-archive` 等 core 之外的工作流需先在全局档位启用（`profile=custom` + `workflows` 列全），启用与回退见 openspec-workflow 第 6 节。
- 执行通道的完整说明（ssh 连接管理、对应关系、命令形状、两侧分工、缺件症状）见 `references/openspec-workflow.md` **第 9 节**。

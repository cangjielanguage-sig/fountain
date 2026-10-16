---
name: opsx-propose
description: Use when 用户要在鸿蒙 PC 的 WorkBuddy 上，把 openspec 的 `propose` 这一步经 ssh 交给融合开发引擎（Linux 子系统）里的 CodeBuddy CLI 自动执行，目标为指定 worktree 与子目录——用户要新开一个变更、写提案、提出新需求、'帮我做 XX 功能'、要生成 proposal/specs/design/tasks 规划文档，或直接点名 `/opsx:propose`。不适用于实施代码（那是 opsx-apply）、只建空骨架（opsx-new），或给既有变更一次补齐四件套（opsx-ff）。
---

# opsx:propose — 创建变更 + 一次性产出全部规划文档

`核心`工作流 · 对应斜杠命令 `/opsx:propose`

## 用途

这一步同时做两件事：建出变更目录，并把 schema 定义的规划产物一次写全——`proposal.md`（为什么、改什么）、`specs/<capability-path>/spec.md`（系统**必须**做什么，是增量不是主规范）、`design.md`（怎么做）、`tasks.md`（实施步骤）。

`proposal.md` 的 Why / What Changes / Impact 是后续所有产物的锚点，因此先把它写扎实，再往下铺。`<capability-path>` 是 `specs/` 下的相对路径（如 `user-auth` 或 `identity/user-auth`）：已有 capability 要沿用原路径，新 capability 跟项目既有组织方式走。

## 边界

**只写规划产物，不改项目代码。** 哪怕用户的原始请求里说了「顺便把它实现掉」，propose 也不接着实施——产物呈现完就停，等用户评审 `design.md` 与 `tasks.md`。这是这套流程里最容易被越过的门禁。

## 入参

`--request "<一句话需求或变更名>"`（**必需**，缺了 `plan` 会硬拦截）

## 产物

`openspec/changes/<变更名>/` 下的 `proposal.md`、`specs/<capability-path>/spec.md`、`design.md`、`tasks.md`

## 下一棒

评审通过 → 用 `opsx-apply` 实施；要改规划 → 用 `opsx-update`。

## 尾参怎么给

`plan` 会强制要求尾参，但**不要**自己编一个变更名糊过去。

* **用户给了需求但没给变更名** → 直接用 `--request "<那句话>"`，变更名由 propose 自己派生。**不必**为了名字再往返一轮。
* **用户主动要固定变更名** → 用 `--change "<名字>"`。名字规范：kebab-case、动词开头、一眼看出改什么（`add-wal-module`、`split-store-lock`）。
* **用户给的需求太虚**（如「优化一下 f_store 性能」）→ 先问出一个能写进 `proposal.md` 的 Why 再执行。这一问在执行之前，不影响输出契约。
* **用户说「尾参我自己定、我自己手动跑」** → 才加 `--allow-empty`。

## 前置

* 融合开发引擎的 ssh 连接已固化且可达（首次访问要先询问用户——见下面的「融合引擎连接」）。
* 目标目录里必须有 `openspec/config.yaml` —— openspec 根就是它所在的那一层。
* 融合开发引擎（Linux 子系统）里要有 CodeBuddy CLI；没有就把安装命令交给用户。
* 本工作流要已装进 `<目标>/.codebuddy/commands/opsx/<工作流>.md`，否则 `/opsx:<工作流>` 在融合侧不会被识别。扩展工作流常常没装。
* 上面几条**都不准**用 `openspec init` / `git worktree add` / 重装 CLI 去「绕过」——预检不过就停下来报告，让用户决定。

## 融合引擎连接（ssh）

连接信息固化在技能配置里（`~/.workbuddy/openspec-fusion.json` 的 `fusion.ssh` 段）。每轮先探测，**不要**手画地址、也不要每次重新问用户：

```bash
python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py ssh-check
```

按退出码分流：

* `0` → 连接可用，继续。
* `2`（配置缺失）→ **首次访问**：用 AskUserQuestion 问用户三项——融合开发引擎 IP、登录用户名、密码（已配置免密的机器密码可留空）。随后固化：

```bash
printf '%s\n' '<密码>' | python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py ssh-set --host <IP> --user <用户名> --password-stdin
```

密码留空时改用 `--no-password`：

```bash
python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py ssh-set --host <IP> --user <用户名> --no-password
```

* `3`（连接失败）→ **IP 失效了就重新询问**：把 ssh 原始输出给用户看，重新问 IP（用户名/密码有变一起问），用 `ssh-set` 更新并重跑 `ssh-check`；分类是 `auth-failed` 且配置里存了密码时，先跑 `python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py ssh-push-key` 自动配免密。

问到的值必须**当场**用 `ssh-set` 固化——只在对话里记着，下轮会话就丢了。探测始终不通就停下来报告，不要硬闯。

## 执行

1. 先看现有 worktree（只读）：

```bash
python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py worktrees
```

2. 生成命令块：

```bash
python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py plan \
  --workflow propose \
  --worktree <worktree 名> \
  --subdir <子目录> \
  --request "<一句话需求或变更名>"
```

3. 把 `plan` 输出的**原文**交给 Bash 工具执行——它本身就是一条 ssh 命令。CodeBuddy 任务通常跑数分钟，一律用 `run_in_background` 后台执行，收到完成通知后读取输出并汇报。命令一个字符都不改：不改写、不拆段、不合并、不补步骤。

4. 想无人值守（`--dangerously-skip-permissions`）再加 `--yolo`；默认是 `--permission-mode acceptEdits`。

目标取值优先级：**用户显式给出** > 配置文件（项目内 `<repo>/.workbuddy/openspec-fusion.json` 优先，回落用户级 `~/.workbuddy/openspec-fusion.json`）> 现有 worktree。
现有 worktree 多于一个而用户又没说 → **停下来问**，不要替用户挑。子目录省略时默认 worktree 根（`.`）。

需要用户拍板的信息（变更名、worktree、子目录，以及首次的连接信息）一律在**执行之前**问清楚。提问不算交付内容，不受下面的输出契约限制；只有「问完之后的最终回复」才按契约交付。

## 输出契约

执行完成后，按顺序交付这四样，除此之外不要输出别的东西：

1. 一行目标：`worktree=…  子目录=…  权限=…  融合引擎=<user>@<host>`
2. 结果汇报：ssh 探测 ✓ + CodeBuddy 的产出（实现型给改动与验证摘要；讨论/规划型给关键结论；失败时给原始错误与下一步建议）
3. 一行「预期产物」
4. 一行「执行后怎么验收」

用户明确要「先看命令」时才把 `plan` 输出的原文贴出来。不给「纯 CLI 等价回退」，不在命令里加 `npm install` / `openspec init` / `git worktree add`。

## Red flags — 命中就停下

| 你正想做 | 现实 |
| --- | --- |
| 自己 `git worktree add` 建一个 worktree | 用户要的是「指定的 worktree」。列表里有就用；没有就停下来问名字、分支、父目录 |
| 把「子目录」理解成 `specs/<capability-path>` | 子目录 = worktree 内承载 `openspec/` 根的那一层，不是产物里的 capability path |
| 在融合环境里 `npm install -g @fission-ai/openspec` | openspec CLI 跑在鸿蒙侧（`~/.local/bin/openspec`）；融合侧只需要仓库里的 `.codebuddy/` 命令文件 |
| `cd ~/Documents/...` | 融合侧看不到鸿蒙家目录，路径必须带 `/mnt/linux_share/storage/Users/currentUser/` 前缀 |
| 把 ssh 连接信息手抄进命令、或只在对话里记着 | 一律用 `ssh-set` 固化到配置文件——下轮会话不在你的上下文里 |
| ssh 探测失败硬闯 / 自己编一个 IP | 配置缺失就问用户三项再固化；IP 失效就重问再更新配置；不许拿默认值兜底 |
| 不给权限参数 | 必须显式 `--permission-mode acceptEdits`；只有明确要无人值守时才 `--dangerously-skip-permissions` |
| 顺手附一段「纯 CLI 等价回退」 | 用户要的是把 `/opsx:*` 交给 CodeBuddy 跑，不是另起一套 `openspec` CLI 流程 |
| 在命令里塞 `git worktree add` / `openspec init` / `npm install` | 这些会静默创建用户没要的东西。预检不过就停下报告 |
| 改写/拆段/合并 `plan` 输出的命令 | 命令一个字符都不改——要改就改参数重跑 `plan`，不要手改命令 |

## 排障

| 现象 | 怎么处理 |
| --- | --- |
| `plan` 退出码 2 并报「子目录下没有 openspec/config.yaml」 | 子目录选错了。回第 1 步重看 worktree，或问用户 openspec 根到底在哪一层。**不要**在命令里补 `openspec init` |
| 报「工作流 xxx 已装」为 ✗ | 该工作流没装进 `.codebuddy/commands/opsx/`。让用户在目标目录跑 `openspec config profile`（把该工作流纳入档位）再 `openspec update` |
| `ssh-check` 报 `host-key-changed` | 融合引擎重装/换机导致指纹变了。让用户确认无误后清理旧指纹（`ssh-keygen -R <host>`），再重跑 `ssh-check` |
| ssh 通了，但 CodeBuddy 报未登录/认证失败 | 让用户先在融合引擎上跑一次 `codebuddy` 完成登录，再重试本命令 |
| 用户说「随便挑个 worktree」 | 那就把 `worktrees` 的输出列给他选，仍然不要替他挑 |
| 用户没说子目录、仓库根就是 openspec 根 | 省略 `--subdir`（等价 `.`），不要自己编一个 |

## 配套

* 契约的唯一事实来源：`/storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py`（`--help` 看全部参数）。
* 连接信息固化在 `~/.workbuddy/openspec-fusion.json`（`fusion.ssh` 段；项目内 `.workbuddy/openspec-fusion.json` 可覆盖）——由 `ssh-set` 写入，不要手改。
* 本技能的文案由 `/storage/Users/currentUser/.workbuddy/scripts/opsx_skills_gen.py` 生成——12 份技能的「前置/融合引擎连接/执行/输出契约/红旗」五段必须逐字一致，**要改就改生成器再重跑**，不要只手改一份。
* 用户没提是哪个工作流、只说「用 openspec 做点事」→ 先问清楚要哪一步，再进对应的 `opsx-*` 技能。

## 关于这套技能

12 个技能与 openspec 的 12 个工作流一一对应：核心 6（`propose` `explore` `apply` `update` `sync` `archive`）+ 扩展 6（`new` `continue` `ff` `verify` `bulk-archive` `onboard`）。
每个技能都通过 **ssh** 把对应工作流交给融合开发引擎上的 CodeBuddy CLI 执行，并把结果收回来汇报——预检与命令生成在鸿蒙侧只读完成；连接信息首次询问后固化、IP 失效自动重问。


---
name: opsx-verify
description: Use when 用户要在鸿蒙 PC 的 WorkBuddy 上，把 openspec 的 `verify` 这一步交给融合开发环境（Linux 子系统）里的 CodeBuddy CLI 执行，目标为指定 worktree 与子目录——用户要在归档前校验实现与变更产物是否一致、'对一下有没有漏做'、'查完成度/一致性'，或点名 `/opsx:verify`。不适用于实施代码（那是 opsx-apply）、修订产物（opsx-update）或归档（opsx-archive）。
---

# opsx:verify — 校验实现与变更产物是否一致

`扩展`工作流 · 对应斜杠命令 `/opsx:verify`

## 用途

归档前的质检：拿 `specs` 里的 requirement / scenario 和 `tasks.md` 的勾选，逐条对实施结果，查完成度、正确性、一致性。产物是**校验报告**。

## 边界

**扩展工作流**，可能未安装。它只出报告、**不替你改产物**——查出「tasks 勾了但代码没写」这类问题，要让用户决定走 `opsx-update`（改规划）还是回 `opsx-apply`（补实现）。别在校验环节顺手改代码。

## 入参

`--change "<变更名>"`（**必需**——校验错变更等于白跑，所以 `plan` 不接受省略）

## 产物

校验报告（不自动修改任何产物）

## 下一棒

有问题 → `opsx-update` 或 `opsx-apply`；没问题 → 用 `opsx-archive`。

## 用户想跳过验证直接归档

照 `opsx-archive` 的做法办：先把没做完的项列出来让用户决定，不要因为「用户催」就跳过——`opsx-archive` 那边有同样的门禁。

## 校验结果不要自己动手改

报告里出现「tasks 勾了但代码没写」这类不一致时，把选择摆给用户：改规划走 `opsx-update`，补实现走 `opsx-apply`。**不要**在校验环节顺手改代码或改 `tasks.md`。

## 前置

* 目标目录里必须有 `openspec/config.yaml` —— openspec 根就是它所在的那一层。
* 融合环境（Linux 子系统）里要有 CodeBuddy CLI；没有就把安装命令交给用户。
* 本工作流要已装进 `<目标>/.codebuddy/commands/opsx/<工作流>.md`，否则 `/opsx:<工作流>` 在融合侧不会被识别。扩展工作流常常没装。
* 上面三条**都不准**用 `openspec init` / `git worktree add` / 重装 CLI 去「绕过」——预检不过就停下来报告，让用户决定。

## 执行

1. 先看现有 worktree（只读）：

```bash
python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py worktrees
```

2. 生成命令块：

```bash
python3 /storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py plan \
  --workflow verify \
  --worktree <worktree 名> \
  --subdir <子目录> \
  --change "<变更名>"
```

3. 想无人值守（`--dangerously-skip-permissions`）再加 `--yolo`；默认是 `--permission-mode acceptEdits`。

目标取值优先级：**用户显式给出** > 配置文件（项目内 `<repo>/.workbuddy/openspec-fusion.json` 优先，回落用户级 `~/.workbuddy/openspec-fusion.json`）> 现有 worktree。
现有 worktree 多于一个而用户又没说 → **停下来问**，不要替用户挑。子目录省略时默认 worktree 根（`.`）。

需要用户拍板的信息（变更名、worktree、子目录）一律在**生成命令块之前**问清楚。提问不算交付内容，不受下面的输出契约限制；只有「问完之后的最终回复」才按契约交付。

## 输出契约

按顺序交付这四样，除此之外不要输出别的东西：

1. 一行目标：`worktree=…  子目录=…  权限=…`
2. **一个** bash 代码块，块内就是 `plan` 命令输出的原文——不改写、不拆段、不合并、不补步骤
3. 一行「预期产物」
4. 一行「执行后怎么验收」

不要给第二个代码块，不要给「纯 CLI 等价回退」，不要在块里加 `npm install` / `openspec init` / `git worktree add`。

## Red flags — 命中就停下

| 你正想做 | 现实 |
| --- | --- |
| 自己 `git worktree add` 建一个 worktree | 用户要的是「指定的 worktree」。列表里有就用；没有就停下来问名字、分支、父目录 |
| 把「子目录」理解成 `specs/<capability-path>` | 子目录 = worktree 内承载 `openspec/` 根的那一层，不是产物里的 capability path |
| 在融合环境里 `npm install -g @fission-ai/openspec` | openspec CLI 跑在鸿蒙侧（`~/.local/bin/openspec`）；融合侧只需要仓库里的 `.codebuddy/` 命令文件 |
| `cd ~/Documents/...` | 融合侧看不到鸿蒙家目录，路径必须带 `/mnt/linux_share/storage/Users/currentUser/` 前缀 |
| 不给权限参数 | 必须显式 `--permission-mode acceptEdits`；只有明确要无人值守时才 `--dangerously-skip-permissions` |
| 顺手附一段「纯 CLI 等价回退」 | 用户要的是把 `/opsx:*` 交给 CodeBuddy 跑，不是另起一套 `openspec` CLI 流程 |
| 在命令块里塞 `git worktree add` / `openspec init` / `npm install` | 这些会静默创建用户没要的东西。预检不过就停下报告 |
| 把命令写成多段、多个代码块 | 契约只有一个代码块；多段一定会漏步骤 |

## 排障

| 现象 | 怎么处理 |
| --- | --- |
| `plan` 退出码 2 并报「子目录下没有 openspec/config.yaml」 | 子目录选错了。回第 1 步重看 worktree，或问用户 openspec 根到底在哪一层。**不要**在块里补 `openspec init` |
| 报「工作流 xxx 已装」为 ✗ | 该工作流没装进 `.codebuddy/commands/opsx/`。让用户在目标目录跑 `openspec config profile`（把该工作流纳入档位）再 `openspec update` |
| 用户说「随便挑个 worktree」 | 那就把 `worktrees` 的输出列给他选，仍然不要替他挑 |
| 用户没说子目录、仓库根就是 openspec 根 | 省略 `--subdir`（等价 `.`），不要自己编一个 |

## 配套

* 契约的唯一事实来源：`/storage/Users/currentUser/.workbuddy/scripts/opsx_fusion.py`（`--help` 看全部参数）。
* 本技能的文案由 `/storage/Users/currentUser/.workbuddy/scripts/opsx_skills_gen.py` 生成——12 份技能的前置/执行/输出契约/红旗四段必须逐字一致，**要改就改生成器再重跑**，不要只手改一份。
* 用户没提是哪个工作流、只说「用 openspec 做点事」→ 先问清楚要哪一步，再进对应的 `opsx-*` 技能。

## 关于这套技能

12 个技能与 openspec 的 12 个工作流一一对应：核心 6（`propose` `explore` `apply` `update` `sync` `archive`）+ 扩展 6（`new` `continue` `ff` `verify` `bulk-archive` `onboard`）。
它们**只负责产出「粘给融合开发环境里 CodeBuddy CLI 的命令」**——不执行、不建目录、不改文件。执行与结果由用户在人机之间往返确认。


# 技能格式与联动技能（SKILL.md「技能格式与联动技能」小节的展开）

## 1. 技能格式与通用性

本技能是标准的 Agent Skills 布局（`SKILL.md` + `references/` + `scripts/`），**不绑定任何特定编程智能体**：

- 支持技能机制的 Agent：把 `skills/fountain-developer/` 放进它的技能目录即可（如 CodeBuddy 的 `~/.codebuddy/skills/`、Claude Code 的 `~/.claude/skills/`，或项目内的技能目录）；
- 不支持技能机制的 Agent：直接让它阅读 `SKILL.md` 并按流程执行，效果相同；
- `scripts/` 下的 `fountain_lookup.py`、`install_skill.py`（纯 Python 3 标准库）与 `install_fboot.sh`（bash）可独立运行，与 Agent 平台无关。

「加载技能」（如 `cangjie-coding` / `cangjie-doc-lookup`）一律指：按当前 Agent 的能力加载——支持技能机制的按其机制加载，不支持的直接读该技能目录下的 `SKILL.md`。

## 2. 联动技能的加载与自动安装

`cangjie-coding`（仓颉知识库 / 构建测试规范）与 `cangjie-doc-lookup`（本地官方文档查阅）**加载失败（技能没装）时不要中断任务、也不要停下来问用户**：直接用下面的脚本从权威来源装进当前 Agent 的技能目录，然后按正常方式加载。

```bash
python <skill-root>/scripts/install_skill.py list                # 先看两个技能装没装、来源在哪
python <skill-root>/scripts/install_skill.py cangjie-doc-lookup  # 从已克隆的 fountain 项目 skills/ 子目录装
python <skill-root>/scripts/install_skill.py cangjie-coding      # 从 CangjieSkills 仓装
python <skill-root>/scripts/install_skill.py all                 # 两个都装
```

| 加载失败的是 | 安装来源 | 说明 |
| --- | --- | --- |
| `cangjie-doc-lookup` | **已克隆的 fountain 项目**的 `<fountain-root>/skills/cangjie-doc-lookup` | fountain 仓库根按 `fountain_lookup.py` 同一套规则定位（`--root` > `$FOUNTAIN_ROOT` > 当前目录上溯 > 技能相对位置 > 技能目录下的克隆副本；都没有会先克隆文档副本）。若那份源码停在还没有该技能的旧版本，脚本会给出提示：切到较新的版本（文档副本用 `python <skill-root>/scripts/fountain_lookup.py switch latest`）或 `--fountain-root` 指到含它的源码 |
| `cangjie-coding` | `https://gitcode.com/Cangjie-SIG/CangjieSkills.git` | 默认**稀疏克隆**到 `~/.cangjie-skills/CangjieSkills`（只取 `.agents/skills`，`--repo-dir` 可改；已存在则 `git pull --ff-only`），再从 `.agents/skills/cangjie-coding` 复制进技能目录 |

- 安装目标目录默认自动探测：优先**当前放着 `fountain-developer` 的那个技能目录**（`~/.codebuddy/skills`、`~/.claude/skills`、`~/.agents/skills` 等），也可 `--skills-root DIR` 指定；已装过的技能默认不覆盖，要升级加 `--force`。
- 装完**复验**：`install_skill.py list` 两个都显示 `[已装]`。装好 `cangjie-doc-lookup` 后**必须**再跑它自己的执行前检查（`python <skills>/cangjie-doc-lookup/scripts/skill_paths.py check`），文档源路径对不上时按它 SKILL.md「执行前检查」的四选一处理。
- 不支持的技能机制的 Agent 不需要「安装」这一步：直接按上面的来源读该技能的 `SKILL.md` 即可（脚本也能用，只是把文件放到一个目录）。

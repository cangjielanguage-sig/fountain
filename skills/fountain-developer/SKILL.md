---
name: fountain-developer
description: 当用户要求用 fountain 框架（仓颉）从零开发服务器应用、安装 fboot、初始化 fountain workspace 或模块、为项目添加 fountain 模块的中心仓依赖、按需求文档开发服务端功能，或把其他语言（Python/Java/Go/Node/TS 等）项目转换/迁移为仓颉项目时使用本技能。技能以 fountain 仓库的代码与 README 为 API 依据，并联动 cangjie-doc-lookup 与 cangjie-coding 技能。
---

# fountain-developer

fountain 是仓颉语言的服务器应用框架：应用**没有 main 函数**，每个模块编译为动态链接库，由 `fboot` 加载启动。本技能以 fountain 仓库自身的代码与 README 为唯一事实来源，完成九类任务：

| 任务 | 工作流 |
| --- | --- |
| 安装 fboot | A |
| 初始化 workspace | B |
| 在 workspace 下初始化模块 | C |
| 添加 fountain 模块的中心仓依赖 | D |
| 回答 fountain 配置与 API 用法问题 | E |
| 按需求文档开发服务器应用 | F（依赖 A→B→C→D） |
| 其他语言项目 → 仓颉项目 | G（依赖 A→B→C→D） |
| 非 fountain 的仓颉项目 → fountain 风格 | H（依赖 A→B→C→D，细节见 `references/cangjie-to-fountain.md`） |
| 为现有项目添加 / 修改模块配置 | I |

**工作流 F / G / H / I 覆盖完整交付流程**：初始化 → 配置（依赖随功能演进补充）→ 严格 TDD（Red-Green-Refactor + 回归测试 + 冒烟测试）→ 提交 → 建 tag，统一见 `references/delivery-workflow.md`。

## 技能格式与通用性

本技能是标准的 Agent Skills 布局（`SKILL.md` + `references/` + `scripts/`），**不绑定任何特定编程智能体**：

- 支持技能机制的 Agent：把 `skills/fountain-developer/` 放进它的技能目录即可（如 CodeBuddy 的 `~/.codebuddy/skills/`、Claude Code 的 `~/.claude/skills/`，或项目内的技能目录）；
- 不支持技能机制的 Agent：直接让它阅读本文件（`SKILL.md`）并按流程执行，效果相同；
- `scripts/` 下的 `fountain_lookup.py`、`install_skill.py`（纯 Python 3 标准库）与 `install_fboot.sh`（bash）可独立运行，与 Agent 平台无关。

下文提到「加载技能」（如 `cangjie-coding` / `cangjie-doc-lookup`）时一律指：按当前 Agent 的能力加载——支持技能机制的按其机制加载，不支持的直接读该技能目录下的 `SKILL.md`。

## 联动技能的加载与自动安装

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

## 必须遵守

- **联动两个技能（自动执行，无需询问用户）**：进入开发/转换任务（工作流 F、G）先加载 `cangjie-coding` 技能（仓颉知识库与构建/测试规范）；遇到语法、关键字、编译器行为、std/stdx API 问题即加载 `cangjie-doc-lookup` 查本地官方文档（加载方式按「技能格式与通用性」小节的约定）。**加载失败（技能没装）时不要中断任务、也不要问用户**：先按「联动技能的加载与自动安装」用 `scripts/install_skill.py` 装上再加载。不凭记忆猜 API 与语法。
- **API 以 fountain 仓库为准**：模块能力、签名、配置项都要在仓库的 README 与 `src/` 里核对；fountain 没有的能力不许硬编，走缺口处理（工作流 F 第 3 步）。
- **查询按「在用版本」**：查 fountain 能力 / API / 配置前先定版本——用户指定（`--version`）优先，其次当前项目 cjpm.toml 的 `"fountain::f_*"` 依赖版本；`fountain_lookup.py` 会先把技能目录下的文档副本切到该版本再检索。回答时以输出头部标注的版本为准；输出里出现 `⚠ 版本不一致` 时必须先说明，或按提示切到目标版本重查。
- **workspace 与模块一律用 fboot 创建**（`fboot workspace` / `fboot module`）：不得用 `cjpm init` 或手工写 cjpm.toml 代替；fboot 不可用时先按工作流 A 安装。
- **不写 main 函数**：入口是 `fboot run` 加载动态库；业务代码只写 `@Controller` / `@Bean` / `Initializer` 这类结构。
- **`fboot run` 是永久阻塞进程**：不要在当前工具调用里前台跑（会挂住）；后台跑并轮询日志，或把运行命令与判据交给用户执行。构建、测试（`fboot build` / `fboot test`）可以代跑。
- **严格 TDD，测试三件套齐全**：E / F / H 的功能开发按 Red-Green-Refactor 推进（先写失败测试 → 最小实现 → 重构）；每批完成后跑**回归测试**（全量，不只新用例），每个交付节点额外做**冒烟测试**（起服务 + 关键路径 + 日志检查）；`fboot build` + 测试全绿后才提交；提交与建 tag 按 `references/delivery-workflow.md`（tag 前提交必须已推送，tag 命名以用户项目规范为准）。
- **只动目标目录**：转换任务不修改原项目仓库；新项目建在用户指定位置。

## 定位 fountain 仓库与查询版本（自动读取代码与 README）

`scripts/fountain_lookup.py` 按 `--root` > `$FOUNTAIN_ROOT` > 当前目录向上搜索 > 技能相对位置（技能放在 fountain 仓库内时上溯两级）> 技能目录下的克隆副本 `<skill-root>/fountain` 依次定位仓库根。**都找不到时会自动克隆（仅用于查询文档）**：

```bash
git clone --depth 1 https://gitcode.com/Cangjie-SIG/fountain.git <skill-root>/fountain
```

该克隆副本只作 README / 源码的 API 参考（查询结果里会标注），**不要用它做构建 / 安装**——构建与安装用用户自己的 fountain 源码或中心仓。`--no-clone` 可禁用自动克隆与一切网络操作，`--repo-url` 可换镜像地址。

### 按「在用版本」查询（默认行为，不用手工切）

每次查询先定**目标版本**，优先级：`--version X.Y.Z`（也可直接给 tag 名）> `$FOUNTAIN_VERSION` > **当前项目**根 cjpm.toml 里 `"fountain::f_*"` 的依赖版本（从当前目录向上找最近的）。定了版本后，脚本会先把**技能目录下的文档副本**切到对应 tag（`git fetch --depth 1 origin tag <tag>` + `checkout --detach`，只取该版本快照，约 30MB / 几秒；命中本地已有 tag 时不再联网），再执行检索：

- 项目在用 1.3.9 时查询即为 1.3.9：`python <skill-root>/scripts/fountain_lookup.py search "orm_databasePoolMaxSize" --module f_orm`；
- 查别的版本：加 `--version 1.3.9`（用项目依赖那种数字版本号即可，脚本按 tag 名里的数字版本号定位，不用管后缀；也可直接给 tag 名 `release-1.3.9.alpha`）；
- 只切副本不查询：`python <skill-root>/scripts/fountain_lookup.py switch 1.3.9`（`switch latest` 回默认分支最新）；看当前状态：`python <skill-root>/scripts/fountain_lookup.py version`；
- **切版本只动技能目录下的副本**：`--root` / `$FOUNTAIN_ROOT` 指定的源码目录只读不改（版本不符时输出警告）；自动发现的源码目录版本不符时，脚本会自动改用文档副本并在 stderr 说明；
- **输出头部标注实际版本**（`fountain 仓库: <路径>（版本 x.y.z，tag ...）`）。看到 `⚠ 版本不一致` 先按提示切版本再回答，别把 master（或副本现状态）的结论当作在用版本的行为。

```bash
python <skill-root>/scripts/fountain_lookup.py root              # 打印仓库根（附版本标注）
python <skill-root>/scripts/fountain_lookup.py modules           # 全部模块 + 描述 + README 路径
python <skill-root>/scripts/fountain_lookup.py search "定时任务"  # 在 README 与源码中检索能力
python <skill-root>/scripts/fountain_lookup.py search "GetMapping" --in code
python <skill-root>/scripts/fountain_lookup.py api f_mvc         # 某模块公开声明清单
python <skill-root>/scripts/fountain_lookup.py version           # 查询版本与文档副本状态
python <skill-root>/scripts/fountain_lookup.py switch 1.3.9      # 只把副本切到某版本（latest = 默认分支最新）
```

Windows 用 `python`，WSL/Linux 用 `python3`。`search` 只做定位，命中后必须 `read_file` 读原文核对。

信息地图：

| 需要什么 | 读哪里 |
| --- | --- |
| 模块清单 / 一句话介绍 | 根 `README.md`「各模块详细文档」章节（或 `modules` 子命令） |
| 某版本的 API / 配置 | 先按在用版本切副本（默认已自动切；换版本用 `--version` 或 `switch`），再按下表读 |
| 某模块的用法、配置、API | `<模块>/README.md`（英文镜像 `<模块>/README_en.md`）；细节进 `<模块>/src/`。内容取自**查询版本**，输出头部有版本标注 |
| fboot 全部子命令与行为 | `f_app/README.md` 第 3 节（简版 `fboot/README.md`） |
| 服务器应用全链路范式 | `fdemo/`（`boot` 初始化 + `user` 业务两模块）、`docs/快速开始/000.get-start.md` |
| fboot 版本（依赖版本与它相同，也是默认的查询版本） | `fboot version` 直接返回；环境未配置时用 `install_fboot.sh version`（见「查看 fboot 版本」小节） |
| 哪些模块会发布到中心仓 | 根 `.modules`（`[include]` 发布 / `[detention]` 不发布） |
| 项目结构 / cjpm.toml 样例 | `fdemo/cjpm.toml`、`fdemo/user/cjpm.toml` |

## 查看 fboot 版本

```bash
fboot version                                                      # 返回 fboot 的版本，形如 fountain(x.y.z)
bash <skill-root>/scripts/install_fboot.sh version [--root DIR]   # 环境未配置时的查法：一次列出 PATH / 安装目录 / 源码三处
```

- **`fboot version` 返回的就是 fboot 的版本**（`fountain(x.y.z)`）；这个 `x.y.z` 也正是 `fboot workspace` 写进 workspace 根 cjpm.toml
  `[dependencies]` 的 `"fountain::f_base"` / `"fountain::f_version"` 版本号（fboot 的版本与其内置的 fountain 版本一致），工作流 D 加其它模块也用这个号。
- fboot 不在 PATH（环境未配置，直接跑会报 `libf_app@fountain.so: cannot open shared object file`）时用脚本的 `version` 子命令：
  它会自动 source 仓颉环境、从 fboot 位置推断安装目录，并用同级 `libs/fboot` 重试，不需要手工配 PATH / LD_LIBRARY_PATH。
- 已安装的 fboot 版本可能比当前源码版本旧（两者不一致是常态）⇒ **应用依赖版本以 fboot 版本为准**；中心仓没有该版本时按 `references/project-setup.md` 改用 path 依赖或重装 fboot。
- 这个版本号同时也是**查询版本**：查 API / 配置时 `fountain_lookup.py` 默认按项目依赖里的这个号切文档副本（见「定位 fountain 仓库与查询版本」）。查完若发现文档副本版本与本机 fboot 版本不一致，先按提示切版本再回答。
- **不要误用带参数形式**：`fboot version x.y.z [msg] [tag ...]` 是升版 / 打 tag 的管理命令，不是查询。

## 工作流 A — 安装 fboot

1. 检测：`fboot version` 能跑就跳过（记录版本号，后续依赖版本要与之相同；查不到就用上面的 `install_fboot.sh version`）。
2. 检查环境：`bash <skill-root>/scripts/install_fboot.sh check`（探测 cjc / cjpm / stdx / fountain 源码）。
3. 安装（二选一）：
   - **有 fountain 源码（推荐）**：`bash <skill-root>/scripts/install_fboot.sh install [--root DIR]`；等价于 `cd <fountain>/fboot && cjpm install --root DIR`。
   - **只有中心仓**：`cjpm install fountain::fboot-<版本> --root DIR`（如 `cjpm install fountain::fboot-1.3.14 --root ~/.cjpm`；省略 `--root` 时装到 `~/.cjpm`）。
4. 配置环境变量（每个新 shell 都要）：

   ```bash
   export PATH=$PATH:<DIR>/bin
   export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:<DIR>/libs/fboot
   export CANGJIE_STDX_DYNAMIC_PATH=<stdx 动态库所在目录>
   ```

5. 验收：`fboot version` 与 `fboot help` 均正常输出。

平台细节与已知坑（WSL 下 source cangjie 环境、库搜索顺序、Windows 变量错位）见 `references/environment.md`。

## 工作流 B — 初始化 workspace

**只能用 `fboot workspace` 创建**（先完成工作流 A）。不得用 `cjpm init --workspace` 或手工写 cjpm.toml 代替：
`cjpm init` 的产物缺 fboot 注入的 `[dependencies]`（f_base / f_version）、编译选项与各平台 `[target]` 段，手工补极易漏项。

```bash
fboot workspace <name>    # 在当前目录创建 <name>/ 并初始化为 workspace
fboot workspace           # 把当前目录初始化为 workspace（该目录必须为空）
cd <name>
```

fboot 在 `cjpm init --workspace` 之后自动改写 `cjpm.toml`：

- `[workspace] version = "1.0.0"`、`compile-option = "--dy-std -Woff all"`
- `[dependencies]` 注入 `"fountain::f_base"` 与 `"fountain::f_version"`，**版本 = 当前 fboot 的版本**
- 补齐各平台 `[target.*]` 与 `${CANGJIE_STDX_DYNAMIC_PATH}` / `${CANGJIE_STDX_PATH}` path-option

验收：`cjpm.toml` 中含上述 `[dependencies]` 与 `[target]` 段（完整产物样例见 `references/project-setup.md`）。Windows 下不要传 `D:\...` 绝对路径（只识别 `/` 开头的绝对路径）：先 `cd` 到目标父目录再 `fboot workspace <name>`。

## 工作流 C — 在 workspace 下初始化模块

**只能用 `fboot module` 创建**。不得用 `cjpm init --type=dynamic` 或手工建目录代替：fboot 在初始化模块的同时会把
`./<module_name>` 追加进上层 cjpm.toml 的 `members`；手工建目录不做这一步，模块不会被编译，也不会被 `fboot run` 加载。

```bash
cd <workspace>
fboot module <module_name>    # 创建 <module_name>/（cjpm init --type=dynamic）并加进 workspace 的 members
```

fboot 自动完成：生成模块 `cjpm.toml`（`output-type = "dynamic"`）、把 `./<module_name>` 追加进上层 `cjpm.toml` 的 `members`、写入占位 `src/<module_name>.cj`（内容 `package <module_name>`）。约定：

- 每个模块都必须是**动态链接库**，不需要 main 函数。
- `src/` 下按包分层（如 `controller/`、`service/impl/`、`dao/`、`model/`），包名与目录一致；包名由源码的 `package` 声明决定（fboot 生成的占位是 `package <module_name>`），模块之间与引用 fountain 库时都用**包名** import。
- 模块自己的 cjpm.toml 保持 cjpm 生成内容，不要手写；依赖统一声明在 workspace 根 cjpm.toml。

## 工作流 D — 添加 fountain 模块的中心仓依赖

1. 定清单：按需求选**直接使用**的模块（索引与选型见 `references/module-index.md`；不确定用 `fountain_lookup.py search <能力关键词>` 核对）。传递依赖由 cjpm 自动解析，不手动加。
2. 取版本号：`fboot version` 返回的 fboot 版本号（fboot 不在 PATH 时用 `install_fboot.sh version`；源码读法见「查看 fboot 版本」）。写进 `[dependencies]` 后，这个号也成了后续 `fountain_lookup.py` 查询时自动采用的版本（按项目依赖识别）。
3. 编辑 **workspace 根** cjpm.toml 的 `[dependencies]`：

   ```toml
   [dependencies]
     "fountain::f_base" = "1.3.14"
     "fountain::f_mvc" = "1.3.14"
   ```

4. 核对是否发布：`.modules` 的 `[detention]` 段列出的模块（当前为 `f_llm`、`fleet`）不发布中心仓，不能用版本依赖——需要时改 path/git 依赖，或与用户确认替代方案。
5. 验证：`fboot build`（或 `cjpm update`）能解析依赖。失败先查网络/镜像与版本号，再考虑换 path 依赖。

三种依赖形态（版本 / path / git）的写法与限制见 `references/project-setup.md`。

## 工作流 E — 回答 fountain 配置与 API 用法的问题

纯问答，不改代码。按下面的链路查证后再回答：

1. **定查询版本**：用户指定 `--version` > `$FOUNTAIN_VERSION` > 当前项目 cjpm.toml 的 fountain 依赖版本；脚本会先把文档副本切到该版本（见「定位 fountain 仓库与查询版本」）。用户没指定、项目也没定版本时，问一句按哪个版本回答，或明确说明用的是副本现状态（输出头部有版本标注）。
2. **拆问题**：定位「模块 + 关键词」——配置项名（如 `mvc_port`、`orm_databasePoolMaxSize`、`logger_appender_*`）或 API 名（如 `lookup`、`RootDAO`）。
3. **查证（命中即停，逐步深入）**：`fountain_lookup.py search "<关键词>"` → 模块 README（配置表、「其他公开 API」小节）→ `fountain_lookup.py api <模块>` 列公开声明 → read_file 到 `<模块>/src/` 核对签名。语法 / std / stdx 问题按「必须遵守」加载 `cangjie-doc-lookup` 与 `cangjie-coding`。
4. **回答要求**：
   - 先说明版本：结论来自哪个 fountain 版本（输出头部的版本标注），版本不一致警告照实转达；
   - 配置类：给出配置项名、取值 / 默认值、生效方式（环境变量 / `fboot build --key=value` 编译期 / 运行期优先于编译期）以及该写在哪里（启动脚本 `exports()` 或 build 参数）；
   - API 类：给出包名 + 签名 + 最小示例，示例优先取自 `fdemo` / `frpcdemo` 的真实用法，并注明出处（`<模块>/README.md`、`<模块>/src/xxx.cj:行号`）。
5. **查不到就说不确定**：仓库里没有的，明确回答「仓库中没有找到」并给出下一步（读哪个文件 / 问用户），**不许猜 API 与配置项**。用户顺势要求改动时转入工作流 I。

## 工作流 F — 按需求文档开发服务器应用

1. **读需求**：拆出功能点清单（接口、数据、认证、定时任务、外部调用、缓存等）。需求缺失关键信息时向用户要，不臆造。
2. **能力映射**：逐条把功能点映射到 fountain 模块（映射表见 `references/server-development.md`），用 `fountain_lookup.py search` 与模块 README 核对具体 API（按项目在用版本查，见「定位 fountain 仓库与查询版本」）。
3. **缺口处理（硬性门禁）**：任何功能点映射不到 fountain 能力时，**停下来问用户**，给出选项：a) 用更简单的方式继续实现；b) 用户提供第三方依赖（包名或源码路径）；c) 缩减范围/不实现；d) 在项目内自行实现完整功能和要求的基础设施代码、工具代码，然后完成需求功能。不得把缺失能力硬编成假实现，不得自行引入未经验证的第三方库。
4. **搭骨架（初始化 + 配置）**：按工作流 A→B→C 安装 fboot、建 workspace、按分层建模块（业务模块 + 可选 boot 初始化模块），按工作流 D 加依赖；**生成三平台启动脚本** `boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh`（Web 型参考 `fdemo`，含 RPC 时结合 `frpcdemo`，模板选用与合并规则见 `references/launch-scripts.md`）。
5. **TDD 逐层实现（严格 Red-Green-Refactor）**：数据模型/DAO → service → controller；每个功能点先写测试并确认**失败**（Red）→ 最小实现转绿（Green）→ 重构后再跑（Refactor），循环细则见 `references/delivery-workflow.md` 第 3 节。写法与注解见 `references/server-development.md`，测试规范加载 cangjie-coding；实现中发现需要新的 fountain 模块，按工作流 D 随时补根 cjpm.toml 依赖（依赖随功能演进同步，见 delivery-workflow 第 2 节）。
6. **构建 + 回归测试**：`fboot build` 通过；跑**全量回归**（不只新用例，`cjpm test` / `fboot test`），回归失败先修再往下（delivery-workflow 第 4 节）；编译错误按 cangjie-coding 的流程定位（先最小可编译切片，再逐步补全）。
7. **冒烟 + 验收**：用启动脚本拉起应用（`./boot.sh build` → `./boot.sh run`，`--dylibPattern` 覆盖 controller、service.impl、初始化、cron 所在库），先做**冒烟**（关键路径 curl / RPC 调用 + 日志无异常堆栈），再按需求逐条验收接口；长驻进程交给用户跑或后台跑；判据见 delivery-workflow 第 5 节。
8. **交付**：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前测试全绿；tag 前提交已推送；tag 命名以用户项目规范为准）。

## 工作流 G — 其他语言项目 → 仓颉项目

输入为本地路径或 git 链接；产出为**独立的新 fountain 项目**，不改原仓库。

1. **取源码**：git 链接 clone 到新目录；本地路径只读分析。
2. **侦察与映射**：读原项目结构与关键文件，产出「原功能 → fountain 模块」映射表与缺口清单（侦察清单与映射表见 `references/porting-guide.md`）。
3. **缺口处理**：同工作流 F 第 3 步。
4. **搭骨架**：工作流 A→B→C→D 建新项目，模块划分对齐原项目分层；生成三平台启动脚本（同工作流 F 第 4 步，见 `references/launch-scripts.md`）。
5. **分批转换（严格 TDD）**：按「数据模型 → 数据访问 → 业务逻辑 → 接口层 → 定时/异步任务」顺序逐批转换；每批按 Red-Green-Refactor 补测试（先失败测试再实现），批次末跑**全量回归** + `fboot build`；发现需要新模块时按工作流 D 补依赖。
6. **冒烟 + 验收**：启动做**冒烟**（关键路径）后，对照原项目行为逐项验证；输出转换报告（对应关系、缺口、未实现项），见 `references/porting-guide.md`。
7. **交付**：按 `references/delivery-workflow.md` 完成提交与建 tag。

## 工作流 H — 非 fountain 的仓颉项目 → fountain 风格项目

输入：用户当前的仓颉项目（cjpm 项目、不依赖 fountain，可能带 `main()` / executable）。
先判断：改造目标是服务端应用才适合 fountain 风格；纯 CLI / 库项目先与用户确认必要性。
与工作流 F / G / I 一样，本工作流覆盖**完整交付流程**（初始化 → 配置 → 严格 TDD → 回归 + 冒烟 → 提交 → 建 tag），通用门禁见 `references/delivery-workflow.md`。

1. **评估现状（只读）**：cjpm.toml（`output-type`、dependencies）、src 布局、`main()` 入口、现有能力（HTTP / DB / 日志 / 配置 / 定时）来自 stdx 还是手写。
2. **映射与缺口**：原能力 → fountain 模块（`references/module-index.md` 速查，映射参考 `references/cangjie-to-fountain.md`）；缺口按工作流 F 第 3 步处理（a–d 选项）。
3. **初始化骨架**（合规前提：workspace 与模块只能用 fboot 创建）：`fboot workspace <新目录>` + `fboot module <模块名>` 建骨架，把原源码用 `git mv`（保留历史）或拷贝进对应模块 `src/`；不删用户原文件，原目录处理与用户确认。
4. **配置**：按工作流 D 加依赖（fountain 模块版本 = fboot 版本），运行期 / 编译期配置落到三平台启动脚本；**依赖随功能演进同步**（delivery-workflow 第 2 节）。
5. **拆 `main()`**：初始化逻辑搬进 `boot` 模块（包级静态初始化 / Initializer），业务代码按包分层进各模块，去掉 executable 入口。
6. **能力替换（严格 TDD）**：HTTP → `f_mvc` 注解式 Controller；手写 SQL / 连接池 → `f_orm`（配置迁到 `orm_*`）；日志 → `f_log`；配置 → `f_config` / 环境变量；定时 → `f_ticktock`。逐类按 Red-Green-Refactor 推进（先失败测试 → 最小实现 → 重构）。
7. **回归 + 冒烟**：批次末跑**全量回归**（`cjpm test` / `fboot test`）；启动冒烟（关键路径 + 日志检查，delivery-workflow 第 5 节）；对照原项目行为逐项验证，输出改造报告（映射、缺口、未实现、启动方式）。
8. **交付**：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前单元测试 / 回归 / 冒烟全绿；tag 前提交已推送；tag 命名以用户项目规范为准）。

## 工作流 I — 为现有 fountain 项目添加 / 修改模块配置

1. **定位项目与版本**：确认目标目录是 fountain workspace（根 cjpm.toml 有 `[workspace]` 与 `"fountain::f_*"` 依赖），记录 fboot 版本（`install_fboot.sh version`）——依赖版本必须与它一致。
2. **先判类别再动手**（三类载体，改法不同）：
   - **模块依赖（含功能演进）**：根 cjpm.toml `[dependencies]` 增删 `"fountain::f_xxx" = "<fboot 版本>"`；代码里新用到的模块要随时补齐（规则同工作流 D 与 `references/project-setup.md`，演进规则见 `references/delivery-workflow.md` 第 2 节）。
   - **运行期配置**：配置项以对应模块 README 为准；改启动脚本（`boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh` **三个同步改**，Windows 版写成 `--key=value`，见 `references/launch-scripts.md`）；临时验证可用 shell 环境变量。
   - **编译期配置**：`fboot build` 的 `--key=value`（嵌入产物）；改启动脚本的 `build()` 或直接给命令。
3. **改前先读现状**：保持原有依赖格式与注释，不覆盖用户已有配置；改动同名配置项时说明影响；不在模块自己的 cjpm.toml 里加依赖。
4. **验证（回归 + 冒烟）**：`fboot build` 通过 + **全量回归**绿（`cjpm test` / `fboot test`）；涉及运行期行为时做**冒烟**（起服务 + 关键路径 + 日志检查）；长驻进程交给用户 / 后台。改动记录进项目 README 或脚本注释。
5. **交付**：按 `references/delivery-workflow.md` 完成提交与建 tag（一次提交只做一类改动）。

## 常见坑（摘要）

- 安装目录（`<install>/libs/fboot`）里的框架动态库若排在应用自身产物目录**之前**，命中的会是旧副本 ⇒ 表现为「新符号 undefined symbol」；排查先 `readelf -d` / `nm -D` 确认实际加载的库。
- WSL 里 `bash -lc` 不读 `~/.bashrc`，`cjpm` / `fboot` 会 command not found；脚本必须显式 source cangjie 环境，且不能 `set -u`。
- `fboot workspace` 只在目录为空时有意义；目标目录已存在内容时用 `fboot workspace <name>` 建子目录。
- 手工 `cjpm init` 建的 workspace 缺 fboot 注入的依赖与 `[target]` 段，手工建的模块不在 `members` 里 ⇒ 构建/加载会莫名失败；创建一律走 fboot。
- 依赖版本必须与 fboot 自身版本一致，否则可能拉到不兼容的旧模块。
- 需求缺口不得私自「造 API」；`[detention]` 模块不能用中心仓版本依赖。
- 查询前先看输出头部的**版本标注**：默认按当前项目依赖版本切文档副本；在项目目录外查、或项目还没写 `[dependencies]` 时，副本会停在上次的版本上（可能是 master），别把 master 的内容当成在用版本。`--version` 可显式指定。
- 文档副本会随切换累积多个版本的快照（约 30MB/版本，浅克隆）；副本损坏、或想清干净时直接删 `<skill-root>/fountain` 重新克隆即可。
- 切版本只对**技能目录下的副本**生效（`--root` / `$FOUNTAIN_ROOT` 指定的源码目录不会被改动，只会警告）；别指望它把用户项目里的源码切到某版本。

## 参考文档

- `references/environment.md` — 环境准备、fboot 安装、平台差异与已知坑；文档副本的克隆与按版本切换（工作流 A / 查询前置）
- `references/project-setup.md` — workspace / 模块 / 依赖的产物样例与校验（工作流 B / C / D）
- `references/module-index.md` — fountain 模块索引与选型（工作流 F / G / H / I 的能力映射）
- `references/server-development.md` — 服务器应用开发指南（工作流 F 展开：MVC / ORM / Bean / AOP / 认证 / 配置 / 运行）
- `references/launch-scripts.md` — 启动脚本（boot.sh / boot-macos.sh / boot-win-gitbash.sh）的模板选用与合并（工作流 F / G / H 搭骨架时）
- `references/delivery-workflow.md` — 交付全流程（工作流 F / G / H / I 共用：初始化 / 配置演进 / TDD / 提交 / 建 tag）
- `references/porting-guide.md` — 跨语言项目转换流程（工作流 G 展开）
- `references/cangjie-to-fountain.md` — 非 fountain 的仓颉项目改造为 fountain 风格（工作流 H 展开）
- `scripts/install_fboot.sh` — fboot 环境检查与安装
- `scripts/fountain_lookup.py` — fountain 仓库检索（按在用版本切文档副本：`root` / `modules` / `search` / `api` / `version` / `switch`）
- `scripts/install_skill.py` — 联动技能（cangjie-coding / cangjie-doc-lookup）加载失败时的自动安装（`list` / 技能名 / `all`）

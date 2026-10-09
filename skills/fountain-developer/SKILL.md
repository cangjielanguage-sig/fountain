---
name: fountain-developer
description: 当用户要求用 fountain 框架（仓颉）从零开发服务器应用、安装 fboot、初始化 fountain workspace 或模块、为项目添加 fountain 模块的中心仓依赖、按需求文档开发服务端功能，或把其他语言（Python/Java/Go/Node/TS 等）项目转换/迁移为仓颉项目时使用本技能。技能以 fountain 仓库的代码与 README 为 API 依据，并联动 cangjie-doc-lookup 与 cangjie-coding 技能。
---

# fountain-developer

fountain 是仓颉语言的服务器应用框架：应用**没有 main 函数**，每个模块编译为动态链接库，由 `fboot` 加载启动。本技能以 fountain 仓库自身的代码与 README 为唯一事实来源，完成六类任务：

| 任务 | 工作流 |
| --- | --- |
| 安装 fboot | A |
| 初始化 workspace | B |
| 在 workspace 下初始化模块 | C |
| 添加 fountain 模块的中心仓依赖 | D |
| 按需求文档开发服务器应用 | E（依赖 A→B→C→D） |
| 其他语言项目 → 仓颉项目 | F（依赖 A→B→C→D） |

## 技能格式与通用性

本技能是标准的 Agent Skills 布局（`SKILL.md` + `references/` + `scripts/`），**不绑定任何特定编程智能体**：

- 支持技能机制的 Agent：把 `skills/fountain-developer/` 放进它的技能目录即可（如 CodeBuddy 的 `~/.codebuddy/skills/`、Claude Code 的 `~/.claude/skills/`，或项目内的技能目录）；
- 不支持技能机制的 Agent：直接让它阅读本文件（`SKILL.md`）并按流程执行，效果相同；
- `scripts/` 下的 `fountain_lookup.py`（纯 Python 3 标准库）与 `install_fboot.sh`（bash）可独立运行，与 Agent 平台无关。

下文提到「加载技能」（如 `cangjie-coding` / `cangjie-doc-lookup`）时一律指：按当前 Agent 的能力加载——支持技能机制的按其机制加载，不支持的直接读该技能目录下的 `SKILL.md`。

## 必须遵守

- **联动两个技能（自动执行，无需询问用户）**：进入开发/转换任务（工作流 E、F）先加载 `cangjie-coding` 技能（仓颉知识库与构建/测试规范）；遇到语法、关键字、编译器行为、std/stdx API 问题即加载 `cangjie-doc-lookup` 查本地官方文档（加载方式按「技能格式与通用性」小节的约定）。不凭记忆猜 API 与语法。
- **API 以 fountain 仓库为准**：模块能力、签名、配置项都要在仓库的 README 与 `src/` 里核对；fountain 没有的能力不许硬编，走缺口处理（工作流 E 第 3 步）。
- **workspace 与模块一律用 fboot 创建**（`fboot workspace` / `fboot module`）：不得用 `cjpm init` 或手工写 cjpm.toml 代替；fboot 不可用时先按工作流 A 安装。
- **不写 main 函数**：入口是 `fboot run` 加载动态库；业务代码只写 `@Controller` / `@Bean` / `Initializer` 这类结构。
- **`fboot run` 是永久阻塞进程**：不要在当前工具调用里前台跑（会挂住）；后台跑并轮询日志，或把运行命令与判据交给用户执行。构建、测试（`fboot build` / `fboot test`）可以代跑。
- **只动目标目录**：转换任务不修改原项目仓库；新项目建在用户指定位置。

## 定位 fountain 仓库（自动读取代码与 README）

`scripts/fountain_lookup.py` 按 `--root` > `$FOUNTAIN_ROOT` > 当前目录向上搜索 > 技能相对位置（技能放在 fountain 仓库内时上溯两级）> 技能目录下的克隆副本 `<skill-root>/fountain` 依次定位仓库根。**都找不到时会自动克隆（仅用于查询文档）**：

```bash
git clone --depth 1 https://gitcode.com/Cangjie-SIG/fountain.git <skill-root>/fountain
```

该克隆副本只作 README / 源码的 API 参考（查询结果里会标注），**不要用它做构建 / 安装**——构建与安装用用户自己的 fountain 源码或中心仓。`--no-clone` 可禁用自动克隆，`--repo-url` 可换镜像地址。

```bash
python <skill-root>/scripts/fountain_lookup.py root              # 打印仓库根
python <skill-root>/scripts/fountain_lookup.py modules           # 全部模块 + 描述 + README 路径
python <skill-root>/scripts/fountain_lookup.py search "定时任务"  # 在 README 与源码中检索能力
python <skill-root>/scripts/fountain_lookup.py search "GetMapping" --in code
python <skill-root>/scripts/fountain_lookup.py api f_mvc         # 某模块公开声明清单
```

Windows 用 `python`，WSL/Linux 用 `python3`。`search` 只做定位，命中后必须 `read_file` 读原文核对。

信息地图：

| 需要什么 | 读哪里 |
| --- | --- |
| 模块清单 / 一句话介绍 | 根 `README.md`「各模块详细文档」章节（或 `modules` 子命令） |
| 某模块的用法、配置、API | `<模块>/README.md`（英文镜像 `<模块>/README_en.md`）；细节进 `<模块>/src/` |
| fboot 全部子命令与行为 | `f_app/README.md` 第 3 节（简版 `fboot/README.md`） |
| 服务器应用全链路范式 | `fdemo/`（`boot` 初始化 + `user` 业务两模块）、`docs/快速开始/000.get-start.md` |
| fboot 版本（依赖版本与它相同） | `fboot version` 直接返回；环境未配置时用 `install_fboot.sh version`（见「查看 fboot 版本」小节） |
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
2. 取版本号：`fboot version` 返回的 fboot 版本号（fboot 不在 PATH 时用 `install_fboot.sh version`；源码读法见「查看 fboot 版本」）。
3. 编辑 **workspace 根** cjpm.toml 的 `[dependencies]`：

   ```toml
   [dependencies]
     "fountain::f_base" = "1.3.14"
     "fountain::f_mvc" = "1.3.14"
   ```

4. 核对是否发布：`.modules` 的 `[detention]` 段列出的模块（当前为 `f_llm`、`fleet`）不发布中心仓，不能用版本依赖——需要时改 path/git 依赖，或与用户确认替代方案。
5. 验证：`fboot build`（或 `cjpm update`）能解析依赖。失败先查网络/镜像与版本号，再考虑换 path 依赖。

三种依赖形态（版本 / path / git）的写法与限制见 `references/project-setup.md`。

## 工作流 E — 按需求文档开发服务器应用

1. **读需求**：拆出功能点清单（接口、数据、认证、定时任务、外部调用、缓存等）。需求缺失关键信息时向用户要，不臆造。
2. **能力映射**：逐条把功能点映射到 fountain 模块（映射表见 `references/server-development.md`），用 `fountain_lookup.py search` 与模块 README 核对具体 API。
3. **缺口处理（硬性门禁）**：任何功能点映射不到 fountain 能力时，**停下来问用户**，给出选项：a) 用更简单的方式继续实现；b) 用户提供第三方依赖（包名或源码路径）；c) 缩减范围/不实现；d) 在项目内自行实现完整功能和要求的基础设施代码、工具代码，然后完成需求功能。不得把缺失能力硬编成假实现，不得自行引入未经验证的第三方库。
4. **搭骨架**：按工作流 A→B→C 安装 fboot、建 workspace、按分层建模块（业务模块 + 可选 boot 初始化模块），按工作流 D 加依赖；**生成三平台启动脚本** `boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh`（Web 型参考 `fdemo`，含 RPC 时结合 `frpcdemo`，模板选用与合并规则见 `references/launch-scripts.md`）。
5. **逐层实现**：数据模型/DAO → service → controller；每批 `fboot build` 验证。写法与注解见 `references/server-development.md`；优先在 `fdemo` 里找同型示例对照。
6. **构建**：`fboot build`；编译错误按 cangjie-coding 的流程定位（先最小可编译切片，再逐步补全）。
7. **运行与验收**：用生成的启动脚本运行（`./boot.sh build` → `./boot.sh run`，`--dylibPattern` 要覆盖 controller、service.impl、初始化、cron 所在库）并给出访问判据；长驻进程交给用户跑或后台跑。按需求逐条验证接口（curl / 单元测试）。

## 工作流 F — 其他语言项目 → 仓颉项目

输入为本地路径或 git 链接；产出为**独立的新 fountain 项目**，不改原仓库。

1. **取源码**：git 链接 clone 到新目录；本地路径只读分析。
2. **侦察与映射**：读原项目结构与关键文件，产出「原功能 → fountain 模块」映射表与缺口清单（侦察清单与映射表见 `references/porting-guide.md`）。
3. **缺口处理**：同工作流 E 第 3 步。
4. **搭骨架**：工作流 A→B→C→D 建新项目，模块划分对齐原项目分层；生成三平台启动脚本（同工作流 E 第 4 步，见 `references/launch-scripts.md`）。
5. **分批转换**：按「数据模型 → 数据访问 → 业务逻辑 → 接口层 → 定时/异步任务」顺序逐批转换，每批 `fboot build` 验证。
6. **验收**：启动并对照原项目行为逐项验证；输出转换报告（对应关系、缺口、未实现项），见 `references/porting-guide.md`。

## 常见坑（摘要）

- 安装目录（`<install>/libs/fboot`）里的框架动态库若排在应用自身产物目录**之前**，命中的会是旧副本 ⇒ 表现为「新符号 undefined symbol」；排查先 `readelf -d` / `nm -D` 确认实际加载的库。
- WSL 里 `bash -lc` 不读 `~/.bashrc`，`cjpm` / `fboot` 会 command not found；脚本必须显式 source cangjie 环境，且不能 `set -u`。
- `fboot workspace` 只在目录为空时有意义；目标目录已存在内容时用 `fboot workspace <name>` 建子目录。
- 手工 `cjpm init` 建的 workspace 缺 fboot 注入的依赖与 `[target]` 段，手工建的模块不在 `members` 里 ⇒ 构建/加载会莫名失败；创建一律走 fboot。
- 依赖版本必须与 fboot 自身版本一致，否则可能拉到不兼容的旧模块。
- 需求缺口不得私自「造 API」；`[detention]` 模块不能用中心仓版本依赖。

## 参考文档

- `references/environment.md` — 环境准备、fboot 安装、平台差异与已知坑
- `references/project-setup.md` — workspace / 模块 / 依赖的产物样例与校验
- `references/module-index.md` — fountain 模块索引与选型
- `references/server-development.md` — 服务器应用开发指南（MVC / ORM / Bean / AOP / 认证 / 配置 / 运行）
- `references/launch-scripts.md` — 启动脚本（boot.sh / boot-macos.sh / boot-win-gitbash.sh）的模板选用与合并
- `references/porting-guide.md` — 跨语言项目转换流程
- `scripts/install_fboot.sh` — fboot 环境检查与安装
- `scripts/fountain_lookup.py` — fountain 仓库检索

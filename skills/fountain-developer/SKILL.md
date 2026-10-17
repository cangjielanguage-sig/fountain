---
name: fountain-developer
description: 当用户要求用 fountain 框架（仓颉）从零开发服务器应用、安装 fboot、初始化 fountain workspace 或模块、为项目添加 fountain 模块的中心仓依赖、按需求文档开发服务端功能、把其他语言（Python/Java/Go/Node/TS 等）项目转换/迁移为仓颉项目，把使用旧版 SDK 1.0.x / fountain 1.0.x 的既有项目升级到与当前 fboot 同版 fountain，或在 fountain 仓库内开发框架自身（修改 `f_*` 模块、加功能、修缺陷、新建模块）时使用本技能；工作流 F / G / H / I / J 一律自动执行 OpenSpec 六步规格驱动流程，产物落盘 `doc/spec/`（fountain 放相应模块 doc、其他项目放项目根 doc），在鸿蒙 PC 上由 12 个 `opsx-*` 技能执行（本机没装就从 fountain 仓库自动安装）；fboot 或应用起不来、报 `cannot open shared object file` / `undefined symbol` / `liburing.so.2`、`fboot build` 失败时同样适用。
---

# fountain-developer

fountain 是仓颉语言的服务器应用框架：应用**没有 main 函数**，每个模块编译为动态链接库，由 `fboot` 加载启动。本技能以 fountain 仓库自身的代码与 README 为唯一事实来源，完成十一类任务：

| 任务 | 工作流 |
| --- | --- |
| 安装 fboot | A |
| 初始化 workspace | B |
| 在 workspace 下初始化模块 | C |
| 添加 fountain 模块的中心仓依赖 | D |
| 回答 fountain 配置与 API 用法问题 | E |
| 按需求文档开发服务器应用 | F（依赖 A→B→C→D；**全程走 OpenSpec 六步**） |
| 其他语言项目 → 仓颉项目 | G（依赖 A→B→C→D；**全程走 OpenSpec 六步**） |
| 非 fountain 的仓颉项目 → fountain 风格 | H（依赖 A→B→C→D，细节见 `references/cangjie-to-fountain.md`；**全程走 OpenSpec 六步**） |
| 旧版本项目升级（SDK 1.0.x + fountain 1.0.x → 与当前 fboot 同版） | I（细节见 `references/legacy-upgrade.md`；**全程走 OpenSpec 六步**） |
| 在 fountain 仓库内开发（框架自身：加功能 / 修缺陷 / 新建模块） | J（**全程走 OpenSpec 六步**） |
| 为现有项目添加 / 修改模块配置 | K |

**工作流 F / G / H / I 覆盖完整交付流程**：初始化 → 配置（依赖随功能演进补充）→ 严格 TDD（Red-Green-Refactor + 回归测试 + 冒烟测试）→ 提交 → 建 tag，统一见 `references/delivery-workflow.md`；**工作流 J**（在 fountain 仓库内开发）复用其中的 TDD / 回归 / 冒烟 / 提交 / 建 tag 门禁；**工作流 K** 只改配置（依赖 / 运行期 / 编译期），无功能代码，走构建 + 回归 + 冒烟即可。

**TDD 是 F / G / H / I / J 的开工前置与全程纪律（不是建议）**：进入任务后**第一件事加载 `test-driven-development` 技能**，在 OpenSpec 六步的**步骤 4（`opsx:apply`）里逐任务执行 Red → Green → Refactor**——先写失败用例并亲眼看到它失败，再写最小实现，跑绿后才勾任务；**没有失败测试就不写实现代码，不因「改动小 / 时间紧 / 只是迁移照搬 / 老代码没测试」而例外**。TDD 的循环细节与反合理化清单以该技能为准，仓颉 / fountain 的落法见 `references/delivery-workflow.md` 第 3 节。

**工作流 F / G / H / I / J 全程自动叠加 OpenSpec 六步规格驱动流程，无需用户额外要求**：步骤 1 环境与刷新 → 步骤 2 `opsx:propose` → 步骤 3 用户评审（门禁）→ 步骤 4 `opsx:apply`（逐任务 TDD）→ 步骤 5 `opsx:verify` → 步骤 6 `opsx:archive`。产物按约定落盘到 `doc/spec/<变更名>/`：**fountain 仓库放相应模块的 `doc/`，其他项目放项目根的 `doc/`**（四件套全存；propose 后落一次、archive 后用最终版更新）。完整展开见 `references/openspec-workflow.md`。

## 技能格式与联动技能（安装与参数细节见 `references/skill-infra.md`）

本技能是标准 Agent Skills 布局（`SKILL.md` + `references/` + `scripts/`），**不绑定任何编程智能体**：支持技能机制的直接放进技能目录；不支持的 Agent 直接读本文件（`SKILL.md`）按流程执行，效果相同；`scripts/` 下的脚本可独立运行。
下文提到「加载技能」（如 `cangjie-coding` / `cangjie-doc-lookup`）时一律指：按当前 Agent 的能力加载（有技能机制按其机制加载，没有就直接读该技能目录下的 `SKILL.md`）。

`cangjie-coding`（仓颉知识库 / 构建测试规范）、`cangjie-doc-lookup`（本地官方文档查阅）与 **12 个 `opsx-*` 技能**（鸿蒙 PC 上执行 OpenSpec 的通道）**加载失败（技能没装）时不要中断任务、也不要停下来问用户**：用 `python <skill-root>/scripts/install_skill.py all` 装进当前 Agent 的技能目录再加载（只补其中一组时用 `install_skill.py opsx` / `cangjie-coding` / `cangjie-doc-lookup`）；装完用 `install_skill.py list` 复验（`opsx-*` 那组应显示 `12/12 已装`）；`cangjie-doc-lookup` 装好后**必须**再跑它自己的执行前检查（`python <skills>/cangjie-doc-lookup/scripts/skill_paths.py check`，路径对不上时按它 SKILL.md「执行前检查」处理）。

另外两类联动技能（加载时机见「必须遵守」）：

| 技能 | 何时加载 | 加载失败（没装）怎么办 |
| --- | --- | --- |
| `test-driven-development` | **工作流 F / G / H / I / J 一开始**，写任何实现代码之前 | 来源与安装见 `references/skill-infra.md` 第 3 节；本机确实找不到时按本文「严格 TDD」与 `references/delivery-workflow.md` 第 3 节的 Red-Green-Refactor 循环执行，并在交付说明里写明「未加载 TDD 技能」 |
| **12 个 `opsx-*` 技能**（`opsx-propose` / `opsx-apply` / `opsx-verify` / `opsx-archive` 等，鸿蒙 PC 上执行 OpenSpec 的通道） | **工作流 F / G / H / I / J 全程**，六步的每一步 | 加载失败 = 本机没装这批技能：`python <skill-root>/scripts/install_skill.py opsx`（来源是 fountain 仓库的 `skills/opsx-*`），装完 `list` 复验 `12/12 已装`。**不要手工 clone + 拷贝、不要改用手写规格代替**；展开见 `references/openspec-workflow.md` 第 9 节 |

上表只管「技能装没装」。OpenSpec **项目侧**的就绪（CLI、`openspec init`、`config.yaml` 的中文 context）是另一回事，见 `references/openspec-workflow.md` 第 1–2 节与「必须遵守」的 OpenSpec 条目。

## 必须遵守

- **联动技能（自动执行，无需询问用户）**：进入开发 / 转换 / 升级任务（工作流 F、G、H、I、J）先加载 `cangjie-coding` 技能（仓颉知识库与构建/测试规范）；遇到语法、关键字、编译器行为、std/stdx API 问题即加载 `cangjie-doc-lookup` 查本地官方文档（加载方式见「技能格式与联动技能」小节）。**加载失败（技能没装）时不要中断任务、也不要问用户**：先按该小节用 `scripts/install_skill.py` 装上再加载。不凭记忆猜 API 与语法。
- **TDD 技能（REQUIRED SUB-SKILL，工作流 F / G / H / I / J 一律）**：开工**先加载 `test-driven-development` 技能**，并按其规则推进（**先写失败测试 → 最小实现 → 重构**）——它定义的「没看着测试失败过就不算测试」是本技能所有 TDD 门禁的判据；技能没装时按「技能格式与联动技能」小节的表格处理。写实现代码之前加载，不是写完再补。
- **API 以 fountain 仓库为准**：模块能力、签名、配置项都要在仓库的 README 与 `src/` 里核对；fountain 没有的能力不许硬编，走缺口处理（工作流 F 步骤 2）。
- **查询按「在用版本」**：查 fountain 能力 / API / 配置前先定版本——用户指定（`--version`）优先，其次当前项目 cjpm.toml 的 `"fountain::f_*"` 依赖版本；`fountain_lookup.py` 会先把技能目录下的文档副本切到该版本再检索。回答时以输出头部标注的版本为准；输出里出现 `⚠ 版本不一致` 时必须先说明，或按提示切到目标版本重查。
- **workspace 与模块一律用 fboot 创建**（`fboot workspace` / `fboot module`）：不得用 `cjpm init` 或手工写 cjpm.toml 代替；fboot 不可用时先按工作流 A 安装。
- **不写 main 函数**：入口是 `fboot run` 加载动态库；业务代码只写 `@Controller` / `@Bean` / `Initializer` 这类结构。
- **`fboot run` 是永久阻塞进程**：不要在当前工具调用里前台跑（会挂住）；后台跑并轮询日志，或把运行命令与判据交给用户执行。构建、测试（`fboot build` / `fboot test`）可以代跑。
- **严格 TDD，测试三件套齐全（工作流 F / G / H / I / J 一律）**：开工先加载 `test-driven-development` 技能，功能开发、转换与升级适配全部按 Red-Green-Refactor 推进——**先写失败测试并确认它真的失败（Red）→ 最小实现（Green）→ 重构（Refactor）**；测试的失败原因必须是「功能未实现 / 断言不满足」，不是编译错误或测试本身写错。每批完成后跑**回归测试**（全量，不只新用例），每个交付节点额外做**冒烟测试**（起服务 + 关键路径 + 日志检查）；`fboot build` + 测试全绿后才提交；提交与建 tag 按 `references/delivery-workflow.md`（tag 前提交必须已推送，tag 命名以用户项目规范为准）。
- **OpenSpec 环境（工作流 F / G / H / I / J 全程，自动执行）**：每次开工先确保环境就绪——没装 openspec 就装（`npm install -g @fission-ai/openspec@latest`），项目没初始化就 `openspec init --tools <tool>`（**`<tool>` 必须问用户**用哪个开发工具，不替他选；转换 / 升级类工作流在**产出项目根**初始化，不是原项目），`openspec/config.yaml` 的 `context` 里必须有「所有产出物用简体中文撰写」（缺了追加，不覆盖既有内容）；随后 `openspec update` 刷新一次指令文件，再 `openspec list --json` 看在途变更。
- **OpenSpec 六步（工作流 F / G / H / I / J 全程，自动执行，无需用户要求）**：**步骤 1 环境与刷新**（`openspec update` + `openspec list --json`）→ **步骤 2 `opsx:propose`**（生成 `openspec/changes/<变更名>/` 五件套）→ **步骤 3 用户评审（门禁）**（逐条确认 `design.md` / `tasks.md`；反馈用 `opsx:update`）→ **步骤 4 `opsx:apply`**（按 tasks 逐任务 TDD，严格跟随 design）→ **步骤 5 `opsx:verify`**（前置：`fboot build` / 全量回归 / 冒烟全绿；CRITICAL 清零）→ **步骤 6 `opsx:archive` + 产物落盘**（沉淀规范、归档变更、更新 doc 副本）。**propose 只写规划产物、不改项目代码**；**用户明确确认 design / tasks 前不得进入 apply**；verify 不在 core 档、需先启用（启用与回退见 openspec-workflow 第 6 节）。OpenSpec 的产物与归档**不替代**本技能的 TDD / 全量回归 / 冒烟 / 提交 / 建 tag 门禁。
- **规格产物落盘 `doc/spec/`（六步的一部分，propose 后 + archive 后各一次）**：把四件套（`proposal.md` / `spec.md`（规格 delta，多 capability 时为 `specs/<capability-path>/spec.md`）/ `design.md` / `tasks.md`）同步到 **`doc/spec/<变更名>/`**——**fountain 仓库放相应模块的 `doc/spec/<变更名>/`**（跨多个模块时，各模块放与其 capability 相关的 `spec.md`，`proposal.md` / `design.md` / `tasks.md` 放主模块），**其他项目放项目根的 `doc/spec/<变更名>/`**。propose 完成后新建副本（评审与入库可见），archive 完成后用 OpenSpec 最终版覆盖更新（以最终版为准）。`openspec/` 可能被 `.gitignore` 忽略——`doc/spec/` 才是随代码入库、可回溯的规格副本，不得省略。
- **鸿蒙 PC 上的 OpenSpec 执行通道（工作流 F / G / H / I / J 全程）**：六步的每一步都经对应的 `opsx-*` 技能执行——技能先 `ssh-check` 探测融合开发引擎的 ssh 连接（首次访问问用户 IP / 用户名 / 密码并固化，IP 失效重问），再用 `opsx_fusion.py` 生成 ssh 命令、用 Bash 工具代跑到融合侧 CodeBuddy CLI 并回收结果；对应关系与安装见 `references/openspec-workflow.md` 第 9 节，本机没装先 `install_skill.py opsx`。**不要自己把 `codebuddy` 拉起来跑、不要让用户自己拼命令**；`openspec init` / `update` / `list` / `config` / `validate` 这类环境与查询命令仍由你在鸿蒙侧直接跑（两者分工见第 9.3 节）。
- **等待 OpenSpec 任务期间按协议周期报告进度（工作流 F / G / H / I / J 全程）**：opsx 任务在后台运行期间，**每 5 分钟**输出一次进度报告——【项目/模块】+ 六阶段状态（① 环境与刷新 / ② propose / ③ 用户评审 / ④ apply / ⑤ verify / ⑥ archive + 落盘），**「进行中」的阶段必须给客观详情**（tasks 勾选 x/y、当前任务、近 10 分钟改动文件、后台输出尾部）；快照一律用 `python3 <skill-root>/scripts/opsx_progress.py --repo <仓库> --change <变更名> --stage <当前步骤> --log <后台输出文件>` 采集，不凭印象编。**连续 3 轮（约 15 分钟）无进展即暂停周期报告、转入停滞诊断**：先说明卡点与证据 → 给出解决方案 → 实际尝试（ssh 连通 → 远程进程 → CodeBuddy 日志 → 重扫输出；已死则重跑）→ **问题解决后先更新并报告进度（`--reset` + 新快照），再回到 OpenSpec 六步当前步骤继续——apply 内按 `test-driven-development` 继续逐任务 TDD 验证（测试绿才勾任务），build / 全量回归 / 冒烟门禁不变——随后恢复周期报告**；无解则带证据交还用户，不空转。完整协议（报告模板、诊断步骤、恢复动作、示例、红旗）见 `references/opsx-waiting.md`。
- **只动目标目录**：转换任务不修改原项目仓库；新项目建在用户指定位置。

## Red flags（命中就停下）

以下信号说明你正准备绕开「必须遵守」或某个工作流的门禁——**停下，回到对应流程，不要先动手**：

| 你正想说 / 快要做 | 现实 |
| --- | --- |
| 「fountain 没有这个能力，先写个临时实现，以后替换」 | 假实现会长成事实标准；走缺口处理——停下给建议、问用户（工作流 F 步骤 2、工作流 J 步骤 2） |
| 「不用查了，直接写」 | 先复用再实现：`fountain_lookup.py search` 查一轮远便宜于重复造轮子（工作流 J 步骤 1） |
| 「先用 `cjpm init` / 手工 cjpm.toml 建着，回头再对齐 fboot」 | 手工骨架缺依赖注入、`[target]` 段与 `members`，后面全是隐性故障；一律 `fboot workspace` / `fboot module` |
| 「改动小 / 时间紧，测试回头补（或『跑跑现成的就够了』）」 | 先把改动钉成失败用例（Red）再实现；「回头补」等于不补 |
| 「测试写好了也跑绿了，只是先写的实现」 | 顺序反了就是没走 TDD：先写实现再补的测试没经过「看着它失败」，无法证明测的是需求；删掉实现，从 Red 重来 |
| 「转换 / 升级是照搬代码，不用先写测试」 | 照搬更要先用失败用例（characterization test）钉住原行为再改；没有基线，改坏了看不出来 |
| 「TDD 技能没装，先按记忆写」 | 按 `references/skill-infra.md` 第 3 节在本机找一份装上再开工；本机确实没有时按 delivery-workflow 第 3 节循环执行，并在交付说明写明「未加载 TDD 技能」 |
| 「出问题我负责 / 别管规范，先做出来」 | 免责承诺不改变缺陷的实际代价（隐性故障、回归风险照旧）；按流程做并把风险讲清楚 |
| 「版本号先随便写一个，build 时再改」 | 依赖版本必须等于当前 fboot 版本；拉到不兼容版本会以符号错误的形式爆出来 |
| 「按印象写 API，差不多就对」 | API 与配置一律在仓库 README / `src/` 里核对（按在用版本查），不凭记忆猜 |
| 「先把功能写出来，OpenSpec 文档回头补」 | propose 是前置：五件套没出来就不进 apply，也不写实现代码（工作流 F / G / H / I / J 步骤 2） |
| 「design 我自己看着行，直接 apply」 | 架构与边界场景必须**用户评审确认**；跳过评审等于替用户拍板设计（六步的步骤 3，F / G / H / I / J 通用） |
| 「G / H / I 是转换 / 升级，不是新功能，OpenSpec 可以不走」 | F / G / H / I / J **五个工作流一律六步全程**，无例外；转换 / 升级同样先 propose（能力映射与缺口结论写进 proposal / design） |
| 「doc/spec 回头再拷，openspec 本地有就够了」 | 六步的一部分：propose 后与 archive 后各落盘一次（fountain 放相应模块 `doc/spec/<变更名>/`、其他项目放项目根 `doc/spec/<变更名>/`）；`openspec/` 可能被 `.gitignore` 忽略，doc 副本才是入库 / 回溯的凭据 |
| 「tasks 先勾掉，测试后面统一加」 | apply 里每个任务仍走 Red-Green-Refactor；先勾任务再补测试 = 假进度，交付时无法自证 |
| 「`opsx:verify` 没装 / 跑不了，跳过算了」 | 按 `references/openspec-workflow.md` 第 6 节把 profile 设为 custom 并启用该工作流；不能启用时走步骤 5 的回退（`openspec validate --strict` + 三对齐），不静默跳过 |
| 「OpenSpec 这步自己拼命令更快，不用走技能」 | 鸿蒙 PC 上 propose→评审→apply→verify→archive **一律经对应的 `opsx-*` 技能**（ssh 探测 → `plan` 生成命令 → 代跑 → 汇报）；自己拼会漏掉 `/mnt/linux_share` 前缀、目标子目录与预检（openspec-workflow 第 9 节） |
| 「`opsx-*` 技能没装，我 `git clone` 下来拷一份（或让用户自己拷）」 | 用 `scripts/install_skill.py opsx`——它按同一套仓库定位规则取源、装到当前 Agent 的技能目录并复验；手工拷会漏掉目标目录判定与 frontmatter 校验 |
| 「技能没装就先跳过，五件套我自己手写」 | 先装再走。手写的产物不经 `/opsx:propose`，后续 apply / verify / archive 与 `openspec instructions` 全部对不上 |
| 「openspec 归档完了，交付就结束了」 | `opsx:archive` 只沉淀规范；`fboot build` / 全量回归 / 冒烟 / 提交 / 建 tag 一个都不能少 |
| 「`--tools all` 反正都能用，省得问」 | `<tool>` 必须问用户（写进仓库的指令文件因工具而异）；擅自选等于替用户决定技术栈 |
| 「任务在后台跑，我安静等结果就好」 | 用户看不到任何进度；每 5 分钟一轮报告（六阶段 + 进行中客观详情），见 `references/opsx-waiting.md` |
| 「报告一句『还在跑』就够了」 | 缺阶段状态与客观证据等于没报：tasks 勾选 / 当前任务 / 改动文件 / 日志尾部必须给 |
| 「卡住了，先问用户怎么办」 | 先按协议诊断并尝试（ssh 连通 → 远程进程 → 日志 → 重扫输出）；带证据和方案再找用户 |
| 「停滞了，继续按 5 分钟报流水账」 | 停滞即暂停周期报告、转诊断块；每轮诊断必须有新动作或新信息，没有就交还用户 |
| 「停滞问题解决了，直接继续下一轮报告」 | 先更新并报告进度（`--reset` + 新快照）→ 回到六步当前步骤 → apply 里继续 TDD 验证（测试绿才勾任务）；跳过任一步等于把未验证的修复带进交付 |

命中任何一条 → 回到「必须遵守」与对应工作流重走一遍，别先动手。

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
| OpenSpec 流程 / 产物 / CLI 对照（工作流 F、J） | `references/openspec-workflow.md`；在途变更用 `openspec list`（产物在仓库根的 `openspec/`） |

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
   - **只有中心仓**：`cjpm install fountain::fboot-<版本> --root DIR`（如 `cjpm install fountain::fboot-1.3.16 --root ~/.cjpm`；省略 `--root` 时装到 `~/.cjpm`）。
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
     "fountain::f_base" = "1.3.16"
     "fountain::f_mvc" = "1.3.16"
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
5. **查不到就说不确定**：仓库里没有的，明确回答「仓库中没有找到」并给出下一步（读哪个文件 / 问用户），**不许猜 API 与配置项**。用户顺势要求改动时转入工作流 K。

## 工作流 F — 按需求文档开发服务器应用

**全程走 OpenSpec 六步**（步骤 1 环境与刷新 → 步骤 2 propose → 步骤 3 用户评审 → 步骤 4 apply → 步骤 5 verify → 步骤 6 archive + 落盘；展开与 CLI 对照见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**。六步里本工作流的专属动作：

1. **步骤 1 — 环境与刷新 + 读需求**：先确保 OpenSpec 环境就绪——没装 CLI 就装、项目没初始化就 `openspec init --tools <tool>`（**`<tool>` 问用户**）、`config.yaml` 的 `context` 含「所有产出物用简体中文撰写」（细节见 openspec-workflow 第 1–2 节）→ **`openspec update`（每次开工都要先更新一次）** → `openspec list --json` 看有没有在途变更。然后拆功能点清单（接口、数据、认证、定时任务、外部调用、缓存等）；需求缺失关键信息时向用户要，不臆造。
2. **步骤 2 — 能力映射、缺口处理与 propose**：逐条把功能点映射到 fountain 模块（映射表见 `references/server-development.md`），用 `fountain_lookup.py search` 与模块 README 核对具体 API（按项目在用版本查，见「定位 fountain 仓库与查询版本」）。任何功能点映射不到 fountain 能力时**停下来问用户**，给出选项：a) 用更简单的方式继续实现；b) 用户提供第三方依赖（包名或源码路径）；c) 缩减范围/不实现；d) 在项目内自行实现完整功能和要求的基础设施代码、工具代码，然后完成需求功能。不得把缺失能力硬编成假实现，不得自行引入未经验证的第三方库。结论写进 proposal / design 后执行 `opsx:propose 实现 XX 功能`（**加载 `opsx-propose` 技能**，由它生成 ssh 命令并代跑到融合开发引擎执行；本工作流后续 `opsx:*` 步骤同理，见 openspec-workflow 第 9 节）：生成 `openspec/changes/<变更名>/` 下**五件套** —— `proposal.md`、`specs/<capability>/spec.md`（规格 delta）、`design.md`、`tasks.md`、`.openspec.yaml`。**本步只产出规划产物，不改项目代码**；完成后先按约定落盘 `doc/spec/<变更名>/`，再停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` 与 `tasks.md` 交用户逐条评审，重点确认**模块边界 / 依赖方向 / 数据模型与迁移 / 异常与错误码 / 边界场景（空值、超限、并发、重启）/ 验收判据**；按反馈用 `opsx:update`（`opsx-update` 技能）折回产物并保持一致。**用户明确确认前不进入 apply。**
4. **步骤 4 — 搭骨架 + `opsx:apply`**：先按工作流 A→B→C 安装 fboot、建 workspace、按分层建模块（业务模块 + 可选 boot 初始化模块），按工作流 D 加依赖；**生成三平台启动脚本** `boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh`（Web 型参考 `fdemo`，含 RPC 时结合 `frpcdemo`，模板选用与合并规则见 `references/launch-scripts.md`）。然后 `opsx:apply`（`opsx-apply` 技能）**逐任务 TDD 实现**：**严格跟随 `design.md` 与 `tasks.md`**，按数据模型/DAO → service → controller 推进；每个任务先写失败测试再写最小实现（Red-Green-Refactor，**REQUIRED SUB-SKILL:** `test-driven-development`），跑绿之后才勾掉任务——不允许出现「任务已勾选但没有对应测试」的进度。写法与注解见 `references/server-development.md`；实现中发现需要新的 fountain 模块，按工作流 D 随时补根 cjpm.toml 依赖。**实现与 design 冲突时不要自行改设计**——回步骤 3 问用户。
5. **步骤 5 — 构建 / 回归 / 冒烟 + `opsx:verify`**：`fboot build` 通过；跑**全量回归**（不只新用例，`cjpm test` / `fboot test`），回归失败先修再往下（delivery-workflow 第 4 节）；用启动脚本拉起应用（`./boot.sh build` → `./boot.sh run`，`--dylibPattern` 覆盖 controller、service.impl、初始化、cron 所在库）做**冒烟**（关键路径 curl / RPC 调用 + 日志无异常堆栈），按 specs / design 逐条验收接口；最后 `opsx:verify`（`opsx-verify` 技能）校验代码与规范一致（Completeness / Correctness / Coherence），**CRITICAL 未清零不往下走**；verify 不在 core 档、需先启用（启用与回退见 openspec-workflow 第 6 节）。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前测试全绿；tag 前提交已推送；tag 命名以用户项目规范为准）；执行 `opsx:archive`（`opsx-archive` 技能）沉淀规范、归档变更；最后用 OpenSpec 最终版**覆盖更新项目根的 `doc/spec/<变更名>/`**（四件套全量）。archive 放最后，万一还要补代码可以继续 apply。

## 工作流 G — 其他语言项目 → 仓颉项目

输入为本地路径或 git 链接；产出为**独立的新 fountain 项目**，不改原仓库。

**全程走 OpenSpec 六步**（在**产出项目根**初始化 OpenSpec 并执行；展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**），全程按 Red-Green-Refactor 推进。

1. **步骤 1 — 环境与刷新 + 取源码与侦察**：`openspec update` + `openspec list --json`；git 链接 clone 到新目录（本地路径只读分析）；读原项目结构与关键文件，产出「原功能 → fountain 模块」映射表与缺口清单（侦察清单与映射表见 `references/porting-guide.md`）。
2. **步骤 2 — 缺口处理与 propose**：缺口按工作流 F 步骤 2 的 a–d 选项处理；映射、缺口与分期转换计划写进 proposal / design，执行 `opsx:propose 把 XX 项目转换为仓颉 fountain 项目` 生成五件套（**只写规划产物**），完成后落盘 `doc/spec/<变更名>/`，停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户评审，重点确认**模块划分与原项目分层的对应、缺口方案（a–d）、分期计划、验收判据（对照原项目行为）**；反馈用 `opsx:update` 折回。**未确认不进 apply。**
4. **步骤 4 — 搭骨架 + `opsx:apply` 分批转换**：工作流 A→B→C→D 建新项目，模块划分对齐原项目分层；生成三平台启动脚本（同工作流 F 步骤 4，见 `references/launch-scripts.md`）；按「数据模型 → 数据访问 → 业务逻辑 → 接口层 → 定时/异步任务」顺序逐批转换——每批按 Red-Green-Refactor 补测试（先失败测试再实现），批次末跑**全量回归** + `fboot build`，跑绿才勾任务；发现需要新模块时按工作流 D 补依赖。
5. **步骤 5 — 冒烟 + 回归 + `opsx:verify`**：启动做**冒烟**（关键路径）后，对照原项目行为逐项验证；`opsx:verify` 校验代码与规范一致，**CRITICAL 未清零不往下走**；输出转换报告（对应关系、缺口、未实现项），见 `references/porting-guide.md`。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 完成提交与建 tag；执行 `opsx:archive` 归档；最后覆盖更新**产出项目根**的 `doc/spec/<变更名>/`（四件套全量）。

## 工作流 H — 非 fountain 的仓颉项目 → fountain 风格项目

输入：用户当前的仓颉项目（cjpm 项目、不依赖 fountain，可能带 `main()` / executable）。
先判断：改造目标是服务端应用才适合 fountain 风格；纯 CLI / 库项目先与用户确认必要性。

**全程走 OpenSpec 六步**（展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**），能力替换逐类按 Red-Green-Refactor 推进。与工作流 F / G / I / K 一样，本工作流覆盖**完整交付流程**（初始化 → 配置 → 严格 TDD → 回归 + 冒烟 → 提交 → 建 tag），通用门禁见 `references/delivery-workflow.md`。

1. **步骤 1 — 环境与刷新 + 评估现状（只读）**：`openspec update` + `openspec list --json`；看 cjpm.toml（`output-type`、dependencies）、src 布局、`main()` 入口、现有能力（HTTP / DB / 日志 / 配置 / 定时）来自 stdx 还是手写。
2. **步骤 2 — 映射、缺口与 propose**：原能力 → fountain 模块（`references/module-index.md` 速查，映射参考 `references/cangjie-to-fountain.md`）；缺口按工作流 F 步骤 2 的 a–d 处理；映射与改造计划写进 proposal / design，执行 `opsx:propose` 生成五件套（**只写规划产物**），完成后落盘 `doc/spec/<变更名>/`，停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户评审，重点确认**模块拆分、`main()` 拆解方案、能力替换顺序与兼容性、验收判据**；反馈用 `opsx:update` 折回。**未确认不进 apply。**
4. **步骤 4 — 骨架 + `opsx:apply` 能力替换**：`fboot workspace <新目录>` + `fboot module <模块名>` 建骨架（合规前提：workspace 与模块只能用 fboot 创建），把原源码用 `git mv`（保留历史）或拷贝进对应模块 `src/`（不删用户原文件，原目录处理与用户确认）；按工作流 D 加依赖；拆 `main()`（初始化搬进 boot 模块，业务按包分层，去掉 executable 入口）；逐类替换能力：HTTP → `f_mvc` 注解式 Controller；手写 SQL / 连接池 → `f_orm`（配置迁到 `orm_*`）；日志 → `f_log`；配置 → `f_config` / 环境变量；定时 → `f_ticktock`——每类 Red-Green-Refactor（先失败测试 → 最小实现 → 重构），跑绿才勾任务。
5. **步骤 5 — 回归 + 冒烟 + `opsx:verify`**：批次末跑**全量回归**（`cjpm test` / `fboot test`）；启动冒烟（关键路径 + 日志检查，delivery-workflow 第 5 节）；对照原项目行为逐项验证，输出改造报告（映射、缺口、未实现、启动方式）；`opsx:verify` CRITICAL 清零。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前单元测试 / 回归 / 冒烟全绿；tag 前提交已推送）；执行 `opsx:archive` 归档；最后覆盖更新项目根的 `doc/spec/<变更名>/`（四件套全量）。

## 工作流 I — 旧版本项目升级（SDK 1.0.x + fountain 1.0.x → 与当前 fboot 同版）

输入是已跑起来的**老项目**（SDK 1.0.x + fountain 1.0.x：模块 `cjc-version = "1.0.4"`，源码里是聚合根
`import fountain.mvc.*` 或扁平 `import f_mvc.*`）。产出默认是**同一项目就地升级**（保留 git 历史）到
「fountain 依赖版本 = 当前 fboot 版本」；不改技术栈、不重写业务。完整展开见 `references/legacy-upgrade.md`。

**全程走 OpenSpec 六步**（展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**）；升级属高风险改动，API 适配与行为修复都先落失败用例再改代码。

1. **步骤 1 — 环境对齐与刷新（先做）**：工作流 A 安装 / 配置当前 fboot——`fboot version` 定目标版本号（它就是待写入的依赖版本）；把 SDK / stdx 换到与 fboot 匹配的版本（老项目 `cjc-version = "1.0.4"` 对不上当前 fountain 的 `"1.2.0"`），不换的话后面全是假错误；`openspec update` + `openspec list --json`；**现状评估（只读）**：依赖形态（聚合根 path / git）、各模块 `cjc-version`、`import fountain.*` / `import f_*` 去重出的模块清单（= 升级后要声明的 `fountain::f_*`）、`boot.sh` 的配置项清单、第三方依赖写法（legacy-upgrade 第 2 节表）。
2. **步骤 2 — 缺口处理与 propose**：升级范围、硬差异清单（见 legacy-upgrade 第 4.3 节）与适配 / 测试计划写进 proposal / design；执行 `opsx:propose 升级 XX 项目到 fountain <版本>` 生成五件套（**只写规划产物**），完成后落盘 `doc/spec/<变更名>/`，停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户评审，重点确认**升级范围、兼容性影响（公开 API / 行为变化）、分批适配顺序、验收判据（对照老行为）**；反馈用 `opsx:update` 折回。**未确认不进 apply。**
4. **步骤 4 — `opsx:apply`：依赖与代码适配**：默认**就地升级**——把聚合根依赖换成按模块版本依赖 `"fountain::f_xxx" = "<fboot 版本>"`，`[target]` 段补齐 `${CANGJIE_STDX_PATH}`，模块 `cjc-version` 同步；用 `fboot workspace` 在临时目录生成一份新产物逐段对照（产物样例见 `references/project-setup.md`）。先 `python <skill-root>/scripts/migrate_fountain_imports.py <项目根>`（预演确认后 `--apply`）把包名 import 机械改掉（**单独一个提交**）；再 `fboot build` 逐条修 API，每个点用 `fountain_lookup.py --version <老项目在用版本>` 与目标版本**两版对照**查证（老版本号读老项目依赖的 fountain 源码 `f_version/src/FountainVersion.cj`；1.0.x 的 tag 名与版本标记不总相等，见 legacy-upgrade 第 4.2 节）。已知硬差异见 legacy-upgrade 第 4.3 节：AOP `InvocationFuncInfo` class→struct、连接池迁到 `fountain::f_dbpool.DatabasePool`（`init(driver, ds)` 已删）、第三方依赖新写法、新增模块可换用、fboot 子命令变化。每类适配先写失败用例再改代码。
5. **步骤 5 — 配置 / 启动脚本 + 回归 + 冒烟 + `opsx:verify`**：按 `references/launch-scripts.md` 补齐 / 对齐三平台脚本——老脚本是**库路径后插**（`undefined symbol` 的根因）、通常只有 Linux 版、编译期配置靠环境变量；老 `export` 清单里的配置项逐个用**目标版本**的模块 README 核对。版本升级属**高风险改动**（`references/delivery-workflow.md` 第 4 节）——针对性回归 + 全量回归 + 冒烟（起服务 + 关键路径 + 日志）；最后 `opsx:verify`，**CRITICAL 未清零不往下走**。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：提交按「依赖 / 机械 import / API 适配」分粒度；按 delivery-workflow 第 6 / 7 节提交与建 tag；交付升级报告（旧 → 新对照表 + 行为变化 + 未适配项）；执行 `opsx:archive` 归档；最后覆盖更新项目根的 `doc/spec/<变更名>/`（四件套全量）。

## 工作流 J — 在 fountain 仓库内开发（框架自身）

**适用**：当前正在开发的项目就是 fountain 仓库——根 cjpm.toml 的包名是 `fountain`、`fountain::f_*` 依赖全是 `{path = "./f_xxx"}` 形态，仓库里有 `.modules` 与各 `f_*` 模块目录；此时被开发的对象就是框架自身（加功能 / 修缺陷 / 新建模块），产出是框架源码的改动。**仓库内查询不加 `--version` 即读工作区源码**（path 依赖没有版本号、脚本不需要切文档副本；输出头部标注源码版本与分支 / tag）。

**全程走 OpenSpec 六步**（新建模块、加功能、修缺陷一律；纯内部修复可在 `.openspec.yaml` 里用 `skip_specs: true` 跳过规格文件，但六步流程照走；展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**）。

1. **步骤 1 — 环境与刷新 + 先复用再实现**：`openspec update` + `openspec list --json`。动手写代码前，把要用到的能力逐条在仓库里查证有没有现成实现，命中即用：
   - 查证链路：`fountain_lookup.py modules` → `search "<能力关键词>"` → 模块 README → `api <模块>` → 读 `src/` 核对签名；
   - 现有模块能满足的**不重复造轮子**（异常体系、日志、工具函数、集合扩展、时间换算、编解码等，先按 `references/module-index.md` 对号入座再现场核对，不按记忆猜）；
   - 新增代码遵守仓库既有约定：包与目录结构、可见性、测试布局都参照同层既有代码；README 中英成对同步。
2. **步骤 2 — 缺口处理与 propose**：fountain 现有 API 不能满足需求时**停下来问用户**，给出几个建议并询问接下来如何做，等用户拍板再动手——**不擅自新造公开 API、不硬编假实现、不悄悄引入第三方依赖**：
   - 每条建议写清代价与影响面（是否动公开 API、是否破坏兼容、影响哪些调用方、测试与文档成本）；公开 API 变更宁保守（能加参数 / 重载就不改既有签名）；
   - 典型候选：a) 扩展现有模块（哪个模块、加什么 API 的签名草案）；b) 新建模块（职责边界与发布登记；聚合根包与 `src/<模块>` shim 已冻结，新模块不登记进去）；c) 改用仓颉标准库 / stdx 的现成能力（不新增 fountain API）；d) 在目标模块内部实现（不公开，仅本次需求用）；e) 缩减范围或调整需求；
   - 未拍板前不写实现代码。
   - 拍板后执行 `opsx:propose`（新建模块：职责 + 对外 API 草案；加功能 / 修缺陷：行为变化与规格 delta），生成五件套（**只写规划产物**），完成后**落盘到相应模块的 `doc/spec/<变更名>/`**（跨多个模块时各模块放其 `spec.md`，`proposal.md` / `design.md` / `tasks.md` 放主模块），停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户逐条评审——**新建模块**重点：模块职责边界、公开 API 签名、与既有模块的依赖方向、`.modules` 发布登记、README 中英同步、边界场景与兼容性；**既有模块改动**重点：兼容性（是否动公开 API、破坏调用方）、测试与文档影响。反馈用 `opsx:update` 折回产物并保持一致。**用户明确确认前不进入 apply。**
4. **步骤 4 — `opsx:apply`（逐任务 TDD）**：严格跟随 design / tasks（新建模块的目录 / 包结构 / 测试布局以 design 为准，既有约束 `[detention]`、聚合根 shim 冻结不破）；先写失败用例（Red）→ 最小实现（Green）→ 重构（Refactor）；用例放语义所属的层 / 包；**跑绿才勾任务**——不许出现「任务已勾选但没有对应测试」的假进度；公开 API 变化同步该模块 README（中英成对）；实现与 design 冲突时回步骤 3 问用户，不自行改设计。
5. **步骤 5 — 回归 + `opsx:verify`**：受影响模块 + 全量 `cjpm test` 全绿再提交；涉及 fboot / 应用启动链的改动按 `references/delivery-workflow.md` 第 5 节做冒烟；最后 `opsx:verify`，**CRITICAL 未清零不往下走**（启用与回退见 openspec-workflow 第 6 节）。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：提交与建 tag 按 delivery-workflow 第 6 / 7 节；fountain 自身的升版（各 `cjpm.toml` + `f_version/src/FountainVersion.cj`）与发布文档同步按仓库既有发布流程；执行 `opsx:archive` 归档；最后用最终版**覆盖更新相应模块的 `doc/spec/<变更名>/`**（四件套全量）。仓库里可能有其他会话的并行工作线（`.worktrees/` 工作树与分支）——只操作自己的，不 prune、不删除任何工作树与分支。

## 工作流 K — 为现有 fountain 项目添加 / 修改模块配置

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
- WSL 里 `bash -lc` 不读 `~/.bashrc`（`cjpm` / `fboot` 会 command not found）、脚本不能 `set -u`；完整执行规范（含 PowerShell 传参、长任务写法）见 `references/environment.md` 第 4 节。
- `fboot workspace` 只在目录为空时有意义；目标目录已存在内容时用 `fboot workspace <name>` 建子目录。
- 手工 `cjpm init` 建的 workspace 缺 fboot 注入的依赖与 `[target]` 段，手工建的模块不在 `members` 里 ⇒ 构建/加载会莫名失败；创建一律走 fboot。
- 依赖版本必须与 fboot 自身版本一致，否则可能拉到不兼容的旧模块。
- 老项目（fountain 1.0.x）的 `import fountain.mvc.*`（聚合根）/ `import f_mvc.*`（扁平）都要改成 `fountain::f_mvc.*`，
  用 `scripts/migrate_fountain_imports.py` 重写、别手改；聚合根 shim 已冻结（没有 f_rpc / f_dbpool 等新模块），
  不作为新代码路线（工作流 I）。
- 需求缺口不得私自「造 API」；`[detention]` 模块不能用中心仓版本依赖。
- OpenSpec 是叠加在交付门禁之上的流程，不是替代：propose 阶段只写规划产物（改代码要等 apply）；`opsx:archive` 之后仍要过 `fboot build` / 全量回归 / 冒烟 / 提交 / 建 tag；`openspec validate` 只校验文件与规格格式，代码一致性靠 `opsx:verify`。工作流 F / G / H / I / J 一律六步全程，没有「转换 / 升级 / 小修可以不走」的例外。
- OpenSpec 产物必须按约定落盘 `doc/spec/<变更名>/`（fountain 放相应模块的 doc、其他项目放项目根 doc；四件套全存）：propose 后落一次、archive 后用最终版更新。fountain 仓库的 `openspec/` 在 `.gitignore` 里——doc 副本才是入库、评审与回溯的凭据。
- 在鸿蒙 PC 上，OpenSpec 的**工作流步骤**（propose / explore / apply / update / sync / archive / verify / new / continue / ff / bulk-archive / onboard）由 12 个 `opsx-*` 技能生成 ssh 命令、代跑到**融合开发引擎**执行；`openspec` CLI 只在鸿蒙侧做**环境与查询**（init / update / list / config / validate）。两者别混：混了会漏掉 `/mnt/linux_share` 前缀与预检，或误在融合侧重装 CLI（openspec-workflow 第 9 节）。
- 查询前先看输出头部的**版本标注**：默认按当前项目依赖版本切文档副本；在项目目录外查、或项目还没写 `[dependencies]` 时，副本会停在上次的版本上（可能是 master），别把 master 的内容当成在用版本。`--version` 可显式指定。
- 文档副本会随切换累积多个版本的快照（约 30MB/版本，浅克隆）；副本损坏、或想清干净时直接删 `<skill-root>/fountain` 重新克隆即可。
- 切版本只对**技能目录下的副本**生效（`--root` / `$FOUNTAIN_ROOT` 指定的源码目录不会被改动，只会警告）；别指望它把用户项目里的源码切到某版本。

## 参考文档

- `references/environment.md` — 环境准备、fboot 安装、平台差异与已知坑；文档副本的克隆与按版本切换（工作流 A / 查询前置）
- `references/project-setup.md` — workspace / 模块 / 依赖的产物样例与校验（工作流 B / C / D）
- `references/module-index.md` — fountain 模块索引与选型（工作流 F / G / H / I / J / K 的能力映射）
- `references/server-development.md` — 服务器应用开发指南（工作流 F 展开：MVC / ORM / Bean / AOP / 认证 / 配置 / 运行）
- `references/launch-scripts.md` — 启动脚本（boot.sh / boot-macos.sh / boot-win-gitbash.sh）的模板选用与合并（工作流 F / G / H 搭骨架、工作流 I 升级脚本时）
- `references/delivery-workflow.md` — 交付全流程（工作流 F / G / H / I 共用：初始化 / 配置演进 / TDD / 提交 / 建 tag；工作流 J 复用第 3–7 节，工作流 K 走第 4–7 节）
- `references/porting-guide.md` — 跨语言项目转换流程（工作流 G 展开）
- `references/openspec-workflow.md` — OpenSpec 规格驱动流程（工作流 F / G / H / I / J 全程：装 CLI / `openspec init --tools <tool>` / `config.yaml` 的 context / 每次开工 `openspec update` / **六步流程**（环境与刷新 → propose → 评审 → apply → verify → archive）与 CLI 对照 / **产物落盘 `doc/spec/<变更名>/`**（fountain 相应模块 doc、其他项目项目根 doc）/ core 之外工作流的档位启用与回退 / **第 9 节：鸿蒙 PC 上用 12 个 `opsx-*` 技能执行与自动安装**）
- `references/cangjie-to-fountain.md` — 非 fountain 的仓颉项目改造为 fountain 风格（工作流 H 展开）
- `references/legacy-upgrade.md` — 旧版本项目升级（工作流 I 展开：SDK 1.0.x + fountain 1.0.x → 与当前 fboot 同版）
- `references/skill-infra.md` — 技能格式与联动技能：跨 Agent 通用性，cangjie-coding / cangjie-doc-lookup / **12 个 `opsx-*` 技能**的安装来源与脚本参数（SKILL.md「技能格式与联动技能」的展开）
- `scripts/install_fboot.sh` — fboot 环境检查与安装
- `scripts/fountain_lookup.py` — fountain 仓库检索（按在用版本切文档副本：`root` / `modules` / `search` / `api` / `version` / `switch`）
- `scripts/install_skill.py` — 联动技能（cangjie-coding / cangjie-doc-lookup / 12 个 opsx-*）加载失败时的自动安装（`list` / 技能名 / `opsx` / `all`）
- `scripts/migrate_fountain_imports.py` — 旧包名 import 重写（工作流 I 第 4.1 步：`fountain.<seg>` / `f_<seg>` → `fountain::f_<seg>`；默认预演，`--apply` 落盘）

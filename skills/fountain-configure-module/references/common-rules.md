# fountain 通用规则（12 个工作流技能共享）

> 本文件由 fountain-developer 的工作流技能随包携带。独立使用某个工作流技能时，先读本文件；只执行与当前工作流相关的条目（A/B/C/D/E/K 不走 OpenSpec 六步与 TDD 门禁，F/G/H/I/J/L 必须走）。

## 工作流 ↔ 技能映射

| 工作流 | 独立技能 | 任务 |
| --- | --- | --- |
| A | `fountain-install-fboot` | 安装 fboot |
| B | `fountain-init-workspace` | 初始化 fountain workspace |
| C | `fountain-init-module` | 在 workspace 下初始化模块 |
| D | `fountain-add-dependency` | 添加 fountain 模块的中心仓依赖 |
| E | `fountain-api-lookup` | 回答 fountain 配置与 API 用法 |
| F | `fountain-build-server` | 按需求文档开发服务器应用 |
| G | `fountain-port-other-lang` | 其他语言项目 → 仓颉项目 |
| H | `fountain-adopt-cangjie` | 非 fountain 仓颉项目 → fountain 风格 |
| I | `fountain-upgrade-legacy` | 旧版本项目升级 |
| J | `fountain-develop-framework` | 在 fountain 仓库内开发 |
| K | `fountain-configure-module` | 为现有项目添加 / 修改模块配置 |
| L | `fountain-code-review-fix` | 代码审查 → OpenSpec 修复 |

## 工作流技能的安装

12 个独立技能由 `fountain-developer` 调度，也可以单独加载；缺任一用 `python <skill-root>/scripts/install_skill.py workflows` 一次装齐，`install_skill.py list` 复验 `12/12`。每个技能自带本文件与所需脚本，不依赖调度器是否安装。

## 技能格式与联动技能（安装与参数细节见 `references/skill-infra.md`）

本技能是标准 Agent Skills 布局（`SKILL.md` + `references/` + `scripts/`），**不绑定任何编程智能体**：支持技能机制的直接放进技能目录；不支持的 Agent 直接读本文件（`SKILL.md`）按流程执行，效果相同；`scripts/` 下的脚本可独立运行。
下文提到「加载技能」（如 `cangjie-coding` / `cangjie-doc-lookup`）时一律指：按当前 Agent 的能力加载（有技能机制按其机制加载，没有就直接读该技能目录下的 `SKILL.md`）。

`cangjie-coding`（仓颉知识库 / 构建测试规范）、`cangjie-doc-lookup`（本地官方文档查阅）与 **12 个 `opsx-*` 技能**（鸿蒙 PC 上执行 OpenSpec 的通道）**加载失败（技能没装）时不要中断任务、也不要停下来问用户**：用 `python <skill-root>/scripts/install_skill.py all` 装进当前 Agent 的技能目录再加载（只补其中一组时用 `install_skill.py opsx` / `cangjie-coding` / `cangjie-doc-lookup`）；**工作流 L 的审查技能用 `install_skill.py harness`，fountain 仓库的全部技能（含 opsx-*）用 `install_skill.py fountain`**。装完用 `install_skill.py list` 复验（`opsx-*` 那组应显示 `12/12 已装`）；`cangjie-doc-lookup` 装好后**必须**再跑它自己的执行前检查（`python <skills>/cangjie-doc-lookup/scripts/skill_paths.py check`，路径对不上时按它 SKILL.md「执行前检查」处理）。

另外几类联动技能（加载时机见「必须遵守」）：

| 技能 | 何时加载 | 加载失败（没装）怎么办 |
| --- | --- | --- |
| `test-driven-development` | **工作流 F / G / H / I / J / L 一开始**，写任何实现代码之前 | 来源与安装见 `references/skill-infra.md` 第 3 节；本机确实找不到时按本文「严格 TDD」与 `references/delivery-workflow.md` 第 3 节的 Red-Green-Refactor 循环执行，并在交付说明里写明「未加载 TDD 技能」 |
| **12 个 `opsx-*` 技能**（`opsx-propose` / `opsx-apply` / `opsx-verify` / `opsx-archive` 等，鸿蒙 PC 上执行 OpenSpec 的通道） | **工作流 F / G / H / I / J / L 全程**，六步的每一步 | 加载失败 = 本机没装这批技能：`python <skill-root>/scripts/install_skill.py opsx`（来源是 fountain 仓库的 `skills/opsx-*`），装完 `list` 复验 `12/12 已装`。**不要手工 clone + 拷贝、不要改用手写规格代替**；展开见 `references/openspec-workflow.md` 第 9 节 |
| `cangjie-code-review-harness` | **工作流 L 一开始**，进入审查之前 | 没装：`python <skill-root>/scripts/install_skill.py harness`——从 `https://gitcode.com/zhangyin_gitcode/cangjie_harness.git` 装全部审议式技能（代码审查 / 架构设计 / 需求设计等）；本机没有 git 时脚本自动借融合侧 git 或归档下载 |

上表只管「技能装没装」。OpenSpec **项目侧**的就绪（CLI、`openspec init`、`config.yaml` 的中文 context）是另一回事，见 `references/openspec-workflow.md` 第 1–2 节与「必须遵守」的 OpenSpec 条目。

## 必须遵守

- **联动技能（自动执行，无需询问用户）**：进入开发 / 转换 / 升级任务（工作流 F、G、H、I、J、L）先加载 `cangjie-coding` 技能（仓颉知识库与构建/测试规范）；遇到语法、关键字、编译器行为、std/stdx API 问题即加载 `cangjie-doc-lookup` 查本地官方文档（加载方式见「技能格式与联动技能」小节）。**加载失败（技能没装）时不要中断任务、也不要问用户**：先按该小节用 `scripts/install_skill.py` 装上再加载。不凭记忆猜 API 与语法。
- **TDD 技能（REQUIRED SUB-SKILL，工作流 F / G / H / I / J / L 一律）**：开工**先加载 `test-driven-development` 技能**，并按其规则推进（**先写失败测试 → 最小实现 → 重构**）——它定义的「没看着测试失败过就不算测试」是本技能所有 TDD 门禁的判据；技能没装时按「技能格式与联动技能」小节的表格处理。写实现代码之前加载，不是写完再补。
- **API 以 fountain 仓库为准**：模块能力、签名、配置项都要在仓库的 README 与 `src/` 里核对；fountain 没有的能力不许硬编，走缺口处理（工作流 F 步骤 2）。
- **查询按「在用版本」**：查 fountain 能力 / API / 配置前先定版本——用户指定（`--version`）优先，其次当前项目 cjpm.toml 的 `"fountain::f_*"` 依赖版本；`fountain_lookup.py` 会先把技能目录下的文档副本切到该版本再检索。回答时以输出头部标注的版本为准；输出里出现 `⚠ 版本不一致` 时必须先说明，或按提示切到目标版本重查。
- **workspace 与模块一律用 fboot 创建**（`fboot workspace` / `fboot module`）：不得用 `cjpm init` 或手工写 cjpm.toml 代替；fboot 不可用时先按工作流 A 安装。
- **不写 main 函数**：入口是 `fboot run` 加载动态库；业务代码只写 `@Controller` / `@Bean` / `Initializer` 这类结构。
- **`fboot run` 是永久阻塞进程**：不要在当前工具调用里前台跑（会挂住）；后台跑并轮询日志，或把运行命令与判据交给用户执行。构建、测试（`fboot build` / `fboot test`）可以代跑。
- **严格 TDD，测试三件套齐全（工作流 F / G / H / I / J / L 一律）**：开工先加载 `test-driven-development` 技能，功能开发、转换与升级适配全部按 Red-Green-Refactor 推进——**先写失败测试并确认它真的失败（Red）→ 最小实现（Green）→ 重构（Refactor）**；测试的失败原因必须是「功能未实现 / 断言不满足」，不是编译错误或测试本身写错。每批完成后跑**回归测试**（全量，不只新用例），每个交付节点额外做**冒烟测试**（起服务 + 关键路径 + 日志检查）；`fboot build` + 测试全绿后才提交；提交与建 tag 按 `references/delivery-workflow.md`（tag 前提交必须已推送，tag 命名以用户项目规范为准）。
- **OpenSpec 环境（工作流 F / G / H / I / J / L 全程，自动执行）**：每次开工先确保环境就绪——没装 openspec 就装（`npm install -g @fission-ai/openspec@latest`），项目没初始化就 `openspec init --tools <tool>`（**`<tool>` 必须问用户**用哪个开发工具，不替他选；转换 / 升级类工作流在**产出项目根**初始化，不是原项目），`openspec/config.yaml` 的 `context` 里必须有「所有产出物用简体中文撰写」（缺了追加，不覆盖既有内容）；随后 `openspec update` 刷新一次指令文件，再 `openspec list --json` 看在途变更。
- **OpenSpec 六步（工作流 F / G / H / I / J / L 全程，自动执行，无需用户要求）**：**步骤 1 环境与刷新**（`openspec update` + `openspec list --json`）→ **步骤 2 `opsx:propose`**（生成 `openspec/changes/<变更名>/` 五件套）→ **步骤 3 用户评审（门禁）**（逐条确认 `design.md` / `tasks.md`；反馈用 `opsx:update`）→ **步骤 4 `opsx:apply`**（按 tasks 逐任务 TDD，严格跟随 design）→ **步骤 5 `opsx:verify`**（前置：`fboot build` / 全量回归 / 冒烟全绿；CRITICAL 清零）→ **步骤 6 `opsx:archive` + 产物落盘**（沉淀规范、归档变更、更新 doc 副本）。**propose 只写规划产物、不改项目代码**；**用户明确确认 design / tasks 前不得进入 apply**；verify 不在 core 档、需先启用（启用与回退见 openspec-workflow 第 6 节）。OpenSpec 的产物与归档**不替代**本技能的 TDD / 全量回归 / 冒烟 / 提交 / 建 tag 门禁。
- **规格产物落盘 `doc/spec/`（六步的一部分，propose 后 + archive 后各一次）**：把四件套（`proposal.md` / `spec.md`（规格 delta，多 capability 时为 `specs/<capability-path>/spec.md`）/ `design.md` / `tasks.md`）同步到 **`doc/spec/<变更名>/`**——**fountain 仓库放相应模块的 `doc/spec/<变更名>/`**（跨多个模块时，各模块放与其 capability 相关的 `spec.md`，`proposal.md` / `design.md` / `tasks.md` 放主模块），**其他项目放项目根的 `doc/spec/<变更名>/`**。propose 完成后新建副本（评审与入库可见），archive 完成后用 OpenSpec 最终版覆盖更新（以最终版为准）。`openspec/` 可能被 `.gitignore` 忽略——`doc/spec/` 才是随代码入库、可回溯的规格副本，不得省略。
- **鸿蒙 PC 上的 OpenSpec 执行通道（工作流 F / G / H / I / J / L 全程）**：六步的每一步都经对应的 `opsx-*` 技能执行——技能先 `ssh-check` 探测融合开发引擎的 ssh 连接（首次访问问用户 IP / 用户名 / 密码并固化，IP 失效重问），再用 `opsx_fusion.py` 生成 ssh 命令、用 Bash 工具代跑到融合侧 CodeBuddy CLI 并回收结果；对应关系与安装见 `references/openspec-workflow.md` 第 9 节，本机没装先 `install_skill.py opsx`。**不要自己把 `codebuddy` 拉起来跑、不要让用户自己拼命令**；`openspec init` / `update` / `list` / `config` / `validate` 这类环境与查询命令仍由你在鸿蒙侧直接跑（两者分工见第 9.3 节）。
- **OpenSpec 流程与 cjpm/cjc 执行期间按协议周期报告（工作流 F / G / H / I / J / L 全程）**：**从进入 OpenSpec 六步（步骤 1 起）或执行任何 `cjpm` / `cjc` 命令开始，每 5 分钟输出一次报告**——不需要判断「是否在等任务结束」，也不需要单独判断「测试是否耗时太久」。报告 =【项目/模块】+ 六阶段状态（① 环境与刷新 / ② propose / ③ 用户评审 / ④ apply / ⑤ verify / ⑥ archive + 落盘）+ 「进行中」的客观详情（tasks 勾选 x/y、当前任务、近 10 分钟改动文件、后台输出尾部）+ **cjpm/cjc 执行状况**（在跑什么 / 进程 PID·时长·CPU·STAT / 输出文件大小与尾部；没在跑也要写「未在运行」），快照一律用 `python3 <skill-root>/scripts/opsx_progress.py --repo <仓库> [--change <变更名>] [--stage <当前步骤>] [--log <后台输出文件>]` 采集（脚本默认含 cjpm/cjc 状况），不凭印象编。**同一状态连续 3 轮（约 15 分钟）无变化即暂停周期报告、转入停滞诊断**：检查代码与进程是否存在死锁 / 活锁 / 长时间阻塞 / 死循环（可加临时探针 `// PROBE(...)` 定位，用后必须移除）→ 详细说明当前问题与证据 → 给出解决方案 → 实际尝试（ssh 连通 → 远程进程/线程 → CodeBuddy 日志 → 重扫输出；已死则重跑）→ **问题解决后先更新并报告进度（`--reset` + 新快照），再回到 OpenSpec 六步当前步骤继续——apply 内按 `test-driven-development` 继续逐任务 TDD 验证（测试绿才勾任务），build / 全量回归 / 冒烟门禁不变——随后恢复周期报告**；无解则带证据交还用户，不空转。完整协议（报告模板、cjpm/cjc 状况、停滞诊断与探针、恢复动作、示例、红旗）见 `references/opsx-waiting.md`。
- **遇到仓颉 SDK / STDX 的 BUG（工作流 F / G / H / I / J / L 全程）**：先按「查证」排除用法与环境问题（查文档 → 查既有用法 → 缩最小 → 排除环境），确认是 SDK/STDX 缺陷后再走协议——**先问用户最小复现用例的保存路径**，生成 ≤ 30 行的独立复现用例（单文件或最小 cjpm 项目，命名 `sdk-bug-<现象>-<yyyymmdd>`），**并立即显示其文件名 / 项目名与路径**；然后在不改变设计意图的前提下尝试绕过（换 API / 规避触发 / 适配层 shim 标记 `WORKAROUND(<repro 名>)` / 版本调整需用户同意）；确实绕不过就**报告 OpenSpec 流程进度（变更 / 步骤 / tasks）与 TDD 进度（当前任务、测试红绿）并暂停**，等用户决定，不跳步、不伪造进度。完整协议见 `references/sdk-bug-handling.md`。
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
| 「先把功能写出来，OpenSpec 文档回头补」 | propose 是前置：五件套没出来就不进 apply，也不写实现代码（工作流 F / G / H / I / J / L 步骤 2） |
| 「design 我自己看着行，直接 apply」 | 架构与边界场景必须**用户评审确认**；跳过评审等于替用户拍板设计（六步的步骤 3，F / G / H / I / J / L 通用） |
| 「G / H / I 是转换 / 升级，不是新功能，OpenSpec 可以不走」 | F / G / H / I / J / L **六个工作流一律六步全程**，无例外；转换 / 升级同样先 propose（能力映射与缺口结论写进 proposal / design） |
| 「doc/spec 回头再拷，openspec 本地有就够了」 | 六步的一部分：propose 后与 archive 后各落盘一次（fountain 放相应模块 `doc/spec/<变更名>/`、其他项目放项目根 `doc/spec/<变更名>/`）；`openspec/` 可能被 `.gitignore` 忽略，doc 副本才是入库 / 回溯的凭据 |
| 「tasks 先勾掉，测试后面统一加」 | apply 里每个任务仍走 Red-Green-Refactor；先勾任务再补测试 = 假进度，交付时无法自证 |
| 「`opsx:verify` 没装 / 跑不了，跳过算了」 | 按 `references/openspec-workflow.md` 第 6 节把 profile 设为 custom 并启用该工作流；不能启用时走步骤 5 的回退（`openspec validate --strict` + 三对齐），不静默跳过 |
| 「OpenSpec 这步自己拼命令更快，不用走技能」 | 鸿蒙 PC 上 propose→评审→apply→verify→archive **一律经对应的 `opsx-*` 技能**（ssh 探测 → `plan` 生成命令 → 代跑 → 汇报）；自己拼会漏掉 `/mnt/linux_share` 前缀、目标子目录与预检（openspec-workflow 第 9 节） |
| 「`opsx-*` 技能没装，我 `git clone` 下来拷一份（或让用户自己拷）」 | 用 `scripts/install_skill.py opsx`——它按同一套仓库定位规则取源、装到当前 Agent 的技能目录并复验；手工拷会漏掉目标目录判定与 frontmatter 校验 |
| 「技能没装就先跳过，五件套我自己手写」 | 先装再走。手写的产物不经 `/opsx:propose`，后续 apply / verify / archive 与 `openspec instructions` 全部对不上 |
| 「openspec 归档完了，交付就结束了」 | `opsx:archive` 只沉淀规范；`fboot build` / 全量回归 / 冒烟 / 提交 / 建 tag 一个都不能少 |
| 「`--tools all` 反正都能用，省得问」 | `<tool>` 必须问用户（写进仓库的指令文件因工具而异）；擅自选等于替用户决定技术栈 |
| 「这一步没在等任务 / 没在跑测试，不用报」 | 进入 OpenSpec 六步或执行任何 cjpm/cjc 就开始报（每 5 分钟），没有「不需要报」的阶段 |
| 「任务在后台跑，我安静等结果就好」 | 每 5 分钟一轮报告：六阶段 + 进行中客观详情 + cjpm/cjc 状况（`references/opsx-waiting.md`） |
| 「任务在跑 cjpm，但不报 cjpm 状况」 | 每轮必报；快照脚本默认采集，没在跑也要写「未在运行」 |
| 「测试 10 分钟没动静，再等等」 | 不单独判断测试耗时；同一状态连续 3 轮（约 15 分钟）无变化 → 停滞诊断（死锁 / 活锁 / 阻塞 / 死循环，可加探针） |
| 「才 2 轮没变化，再等一轮」 | 3 轮是阈值；到 3 轮必须暂停周期报告、转诊断块 |
| 「加了探针定位完不删」 | `// PROBE(...)` 必须移除，不得留在交付代码 |
| 「报告一句『还在跑』就够了」 | 缺阶段状态与客观证据等于没报：tasks 勾选 / 当前任务 / 改动文件 / 日志尾部必须给 |
| 「卡住了，先问用户怎么办」 | 先按协议诊断并尝试（ssh 连通 → 远程进程 → 日志 → 重扫输出）；带证据和方案再找用户 |
| 「停滞了，继续按 5 分钟报流水账」 | 停滞即暂停周期报告、转诊断块（死锁 / 活锁 / 长时间阻塞 / 死循环逐个排除，可加探针）；每轮诊断必须有新动作或新信息，没有就交还用户 |
| 「停滞问题解决了，直接继续下一轮报告」 | 先更新并报告进度（`--reset` + 新快照）→ 回到六步当前步骤 → apply 里继续 TDD 验证（测试绿才勾任务）；跳过任一步等于把未验证的修复带进交付 |
| 「报错就是 SDK bug，直接写复现用例」 | 先查文档 / 既有用法 / 缩到最小 / 排除环境；用法错就改自己代码（`references/sdk-bug-handling.md`） |
| 「绕过 SDK bug 不用留记录」 | 必须写 `WORKAROUND(<repro 名>)`；verify 与交付说明保留记录 |
| 「绕不过，先跳过这段往下做」 | 报告 OpenSpec + TDD 进度并暂停；静默跳过 = 伪造进度 |

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
- OpenSpec 是叠加在交付门禁之上的流程，不是替代：propose 阶段只写规划产物（改代码要等 apply）；`opsx:archive` 之后仍要过 `fboot build` / 全量回归 / 冒烟 / 提交 / 建 tag；`openspec validate` 只校验文件与规格格式，代码一致性靠 `opsx:verify`。工作流 F / G / H / I / J / L 一律六步全程，没有「转换 / 升级 / 小修可以不走」的例外。
- OpenSpec 产物必须按约定落盘 `doc/spec/<变更名>/`（fountain 放相应模块的 doc、其他项目放项目根 doc；四件套全存）：propose 后落一次、archive 后用最终版更新。fountain 仓库的 `openspec/` 在 `.gitignore` 里——doc 副本才是入库、评审与回溯的凭据。
- 在鸿蒙 PC 上，OpenSpec 的**工作流步骤**（propose / explore / apply / update / sync / archive / verify / new / continue / ff / bulk-archive / onboard）由 12 个 `opsx-*` 技能生成 ssh 命令、代跑到**融合开发引擎**执行；`openspec` CLI 只在鸿蒙侧做**环境与查询**（init / update / list / config / validate）。两者别混：混了会漏掉 `/mnt/linux_share` 前缀与预检，或误在融合侧重装 CLI（openspec-workflow 第 9 节）。
- 查询前先看输出头部的**版本标注**：默认按当前项目依赖版本切文档副本；在项目目录外查、或项目还没写 `[dependencies]` 时，副本会停在上次的版本上（可能是 master），别把 master 的内容当成在用版本。`--version` 可显式指定。
- 文档副本会随切换累积多个版本的快照（约 30MB/版本，浅克隆）；副本损坏、或想清干净时直接删 `<skill-root>/fountain` 重新克隆即可。
- 切版本只对**技能目录下的副本**生效（`--root` / `$FOUNTAIN_ROOT` 指定的源码目录不会被改动，只会警告）；别指望它把用户项目里的源码切到某版本。

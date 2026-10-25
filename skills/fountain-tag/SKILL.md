---
name: fountain-tag
description: Use when asked to create a new release tag and push it (打 tag、创建 tag、新建版本 tag、release tag、new tag), or when CHANGELOG must be updated from the previous tag to the latest master commit in reverse chronological order (newest first) before tagging.
---

# fountain-tag

## Overview

先做文档与技能同步（各模块 README 对照代码、依赖图按最新依赖重生成、`skills/fountain-developer` 的配置与 API 描述按最新代码同步、上一 tag 以来受影响文件与本轮改动文件的换行符统一为 LF），再升版本号并**提交推送**（这些提交都要落进 `master`）；随后按「上一个 tag → master 最新提交」汇总并**按时间倒序更新 `CHANGELOG`（越近越靠前）**，把 CHANGELOG 提交也合入 master；最后用同一区间汇总作为附注 tag 信息，创建并推送新 tag。

流水线：**Step 0 定名（`scripts/check_tag_name.py` 校验：数字版本 a.b.c 三段 / 全 tag 唯一 / 大于最新 tag）→ Step 1 同步文档（README / 依赖图 / fountain-developer / 换行符）→ Step 2 改版本号 → Step 3 提交并推送（含合入 master）→ Step 3.5 更新 CHANGELOG（BASE..origin/master，时间倒序）→ Step 4 定区间 → Step 5 汇总 → Step 6 建 tag → Step 7 推送**。版本号替换由 `scripts/bump_version.py` 完成（脚本只改文件；提交、推送、合并、打 tag 由本技能后续步骤做）。

五条硬约束：
1. **tag 名必须匹配 `^release-\d+(\.\d+){2}(\.(alpha|beta))?$`，且数字版本 `a.b.c` 在所有 tag 中唯一、大于当前最新 tag，并经用户确认** —— 这三条由 `scripts/check_tag_name.py` 一次判定，全过才能往下走（Step 0）。
2. **提交区间只能取自 master**。
3. **建 tag 前，本次要发布的提交（文档同步 + 升版 + CHANGELOG）必须已经在 `origin/master` 上**——顺序绝不能颠倒：先提交推送、合入 master、推 master，再打 tag。tag 打在 master 的旧 tip 上就会出现「tag 信息写着新版本号、代码树还是旧版本号」。
4. **建 tag 前，根 README（中英两份）的模块清单必须与代码里的库模块集合一致**：代码里有、README 没引用的追加进去；README 有、代码里已不存在的删掉（见 Step 1.1）。
5. **建 tag 前，`CHANGELOG` 必须已按 `BASE..origin/master` 更新、按时间倒序（最新日期在最上、同日内也最新在前），并已提交合入 `origin/master`**——只改文件不提交、或把新条目追加到末尾，都算没更新（见 Step 3.5）。

## 适用 / 不适用

- 适用：用户要求新建并推送版本 tag（如 `release-1.3.12.alpha`），tag 信息由提交汇总生成，且仓库内各模块版本号要同步升到新版本、README、依赖图与 `fountain-developer` 要跟着代码更新。
- 不适用：删除 / 移动 / 重打已有 tag；给 feature 分支打 tag；发布制品（那是 `fboot pub`）；只改版本号不建 tag（直接跑 `scripts/bump_version.py`）；只想同步文档不打 tag（按 Step 1 做完即可）。
- 会动这几处：各模块 README、依赖图产物、`skills/fountain-developer` 的配置与 API 描述、`CHANGELOG`、区间文件与本轮改动文件的换行符、当前开发分支（最多四个文档/工程提交 + 升版提交 + CHANGELOG 提交 + 推送）、`master`（`--no-ff` 合并 + 推送）、一个新 tag。开工前先 `git status` 确认工作区是否干净、当前分支是不是预期的开发分支。

## Step 0 — 门禁：确定 tag 名（会阻断）

合法 tag 名匹配 `^release-\d+(\.\d+){2}(\.(alpha|beta))?$`（大小写敏感；后缀只认小写 `.alpha` / `.beta`），且数字版本**必须正好是 `a.b.c` 三段**、必须**没被任何 tag 用过**、必须**大于当前最新 tag**。三条一起判，用校验脚本（只读：不建 tag、不 fetch、不改文件）：

```bash
python "<技能目录>/scripts/check_tag_name.py" <候选 tag 名>    # Windows PowerShell；WSL 里 python3
```

**数字版本只认三段，段数不对一律不合规**：`release-1`（单段）、`release-1.4`（两段）、`release-1.3.16.1`（四段）、`release-1.3.16.1.alpha`（四段带后缀）都不可用 —— 整仓库只有 `release-a.b.c` 与 `release-a.b.c.alpha` / `release-a.b.c.beta` 两种形态。段数不对时**不要自行补段或砍段**（把 `release-1.4` "补"成 `release-1.4.0`、把 `release-1.3.16.1` "砍"成 `release-1.3.16` 都是改用户给的名字），报给用户请其换名。

退出码 `0` = 三条全过；`1` = 违反规则（脚本直接打印违反哪条、撞了哪些 tag、最新 tag 是什么）；`2` = 环境错误（不是 git 仓库等）。脚本口径：「最新 tag」= `git tag --sort=-creatordate` 首行（与本文同一口径）；唯一性对**本地 + origin** 的 tag 全量比对（`git tag` + `git ls-remote --tags origin`，取不到 origin 时只警告并退回本地列表）；递增按 `a.b.c` 逐段数值比较（`1.3.10 > 1.3.9`，不是字典序）。

1. 用户指定了名字 → 先跑上面的校验：
   - 退出码 `0` → 记下这个名字，进入 Step 1；
   - 退出码 `1` → **停下**，把违反项（撞了哪个 tag、最新 tag 名与它的版本）报给用户并请其换名。**不要**自作主张改成别的名，也**不要**改用较低版本；
   - 报「无法判定递增」（最新 tag 解析不出 `a.b.c`，如 `v1.3.9`）→ 把最新 tag 名原样报给用户，请其确认该名确实大于它；确认后才继续。
2. 未指定或不合规 → 取当前最新 tag（`git tag --sort=-creatordate` 首行，只读、不 fetch），**第 3 位版本号 +1、其余原样**得候选名，用提问工具给出「同意该名」/「我自己指定」两个选项：
   - `release-1.3.9.alpha` → `release-1.3.10.alpha`
   - `release-1.3.9.beta` → `release-1.3.10.beta`
   - `release-1.3.9` → `release-1.3.10`

   同意 → 推导出来的名字也**先跑一次校验**，通过后进入 Step 1；不同意 → 请用户给名字，回到第 1 条。最新 tag 本身不匹配正则（如 `release-1.0.13.1`、`release-1.1.3.BETA`）时推导不出来，直接请用户指定。推导只依据 tag 名，不看版本文件（cjpm.toml / FountainVersion.cj）。
3. 三条都要卡的理由：正则 ⇒ 下游按正则解析 tag 的脚本能认出它；唯一 ⇒ 同一 `a.b.c` 出第二个 tag 后，「这个版本对应哪个 tag」就没法回答（`release-1.0.13` 与 `release-1.0.13.1` 就是这么撞上的）；递增 ⇒ 新 tag 不能往旧版本上打（Step 2 会把文件从 a.b.c 改成新名，倒退的版本号会一路带进 master）。名字定下后**绝不** `-f` 覆盖、**绝不** `tag -d` 删除、**绝不**移动已有 tag —— 撞名一律换名。
4. 第 2 条读到的最新 tag 就是本次的**BASE**：Step 1 用它算「本区间改过代码的模块」，Step 4 用它定区间。先把它的名字与短 sha 记下来。

## Step 1 — 同步 README、依赖图、fountain-developer 与换行符（会改文件 + 提交）

让 tag 落在「文档、技能与换行符都已跟上代码」的状态上：先把文档与 `skills/fountain-developer` 补到与代码一致、把区间文件与本轮改动文件的换行符统一为 LF，再升版本号。四类改动**各自成一个提交**，某一类没改动就跳过该提交。用户明确要求跳过本步时照做，并在最终汇报里写明「本轮未做文档 / fountain-developer 同步」。

先 `git fetch origin --tags`（只读），再取 BASE = Step 0 读到的最新 tag，区间以 BASE 为界。

### 1.1 模块清单对齐（追加缺失、删除已不存在）

**根 README 的模块清单必须与代码里的库模块集合一一对应，中英两份都要对上**——这是建 tag 前的硬检查，别只看「有没有新模块」。

- **权威清单** = 顶层带 `cjpm.toml` 的库模块（示例应用 `fdemo` / `fcoder` / `frpcdemo` 不入清单，与依赖图的 `EXCLUDE` 同口径；以 `git ls-files '*/cjpm.toml'` 为准，避免工作区里未跟踪的目录造成误报）；**根 README 的模块清单** = `README.md` 与 `README_en.md` 里的 `### fountain::<模块>` 条目。检查（PowerShell）：

  ```powershell
  $mods = git ls-files '*/cjpm.toml' | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique |
          Where-Object { $_ -notin @('fdemo','fcoder','frpcdemo') } | Sort-Object
  $zh = Select-String -Path README.md    -Pattern '^### `fountain::([^`]+)`' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object
  $en = Select-String -Path README_en.md -Pattern '^### `fountain::([^`]+)`' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object
  Compare-Object $mods $zh   # <= 只在代码里有（待追加）；=> 只在 README 里有（模块已不存在，待删除）
  Compare-Object $zh $en     # 中英清单必须完全一致
  ```

- **代码里有、README 里没有** → **追加**到「各模块详细文档」清单末尾（与既有新增模块的做法一致）：

  ```markdown
  ### `fountain::<模块>`
  <一句话描述>

  **详情请见：**<https://gitcode.com/Cangjie-TPC/fountain/blob/master/<模块>/README.md>
  ```

  英文版同位置追加，链接指向 `<模块>/README_en.md`、引导语用 `**See details:**`。描述**取自该模块自己 README 的首段**，不要自造；中英两条要对应。
- **README 里有、代码里已不存在**（模块目录 / `cjpm.toml` 被删或改名）→ **删除**该条目（标题 + 描述 + 链接行 + 随后的多余空行），两个 README 各删一次；再全文搜一遍模块名（`Select-String -Path README.md,README_en.md -Pattern '<模块>'`），别处（如「模块依赖关系」章节）的悬空提及一并清掉。
- 复查：上面两条 `Compare-Object` 都必须为空，且条目数三处一致（`$mods` == `$zh` == `$en` == 依赖图节点数）。
- 确有模块是**刻意不列**（实验性、未发布）→ 把这条例外写进 `docs/模块依赖图/README.md` 的说明里（依赖图侧同样排除），两处口径保持一致；别默不作声地漏掉。

### 1.2 各模块 README 对照代码（`README.md` / `README_en.md`）

每个模块目录（`f_*`、`fboot`、`fleet`、`fcoder`、`fdemo`、`frpcdemo`）都有一对 `README.md` / `README_en.md`：英文版是中文版的逐段翻译，**章节顺序、代码块、清单条目一一对应，代码块的差别只允许注释语言**。根目录还有 `README.md` / `README_en.md`（模块清单 + 依赖图章节 + fboot 用法）。

**判据**：README 里出现的 API 名必须能在该模块 `src/` 里找到对应声明（签名、默认值、注解参数不得比代码旧；行为与设计说明要仍然成立；示例里的宏名 / 函数名 / 导入路径要存在）。反过来，`src/` 里的 public 声明**未必要**全进 README——先按下面的口径筛，再把该进的补上。

**工具**（技能自带；`readme_gap.py` 只读报告，`append_api_section.py` 才会写文件）：

```bash
python3 <技能目录>/scripts/readme_gap.py --base BASE                    # 1) 缺口报告（强烈建议带 --base）
python3 <技能目录>/scripts/readme_gap.py --details --base BASE f_base   #    附源码位置、签名与上方注释
python3 <技能目录>/scripts/append_api_section.py --base BASE f_base f_util  # 2) 批量补齐（幂等追加）
```

补法：**手写优先**——异常、配置表、带参数表/示例的段落按模块既有体例写；量大的模块用 `append_api_section.py`
生成「其他公开 API」小节（源码签名 + 按模块级/类型分组，中英条目完全相同、标题与引导语各自语言），
再跑一次 `readme_gap.py` 复核该模块「待新增」清零。

统计口径：只看顶层带 `cjpm.toml` 的模块（示例应用 `fdemo` / `fcoder` / `frpcdemo` 除外）、跳过 `*_test.cj`；**宿主类型不是 `public` 的成员不算对外 API**；「README 提过」只在代码上下文里认（行内 `` `code span` ``，或围栏代码块里像声明 / 调用的行），不拿正文单词凑数。

**默认不进 README 的声明**（命中就跳过，别补）：

| 类别 | 说明 |
|---|---|
| 压测 | 名字或宿主含 `bench` |
| 极简迭代器 | 类型名含 `Iterator` 且 public 成员只有构造函数与 `next`（连同其成员） |
| FFI | `f_uring` 的 C 结构体字段与 `ioUring*` 等 FFI 函数；`f_uring` 只写核心 API，辅助性能的声明不进 |
| 类型转换 | `to*` / `tryTo*` / `from*` / `as*`；`f_data` 里 `Data` 开头与 `Data` 结尾的类型（连同其成员）；`f_orm` 里 `SqlArg` 结尾的类型 |
| 配置类 | 名字或宿主含 `Config` |
| 宏专用 | 仅仅给宏调用的公共声明（`f_macros` 模块、`f_xxx_*` 形式的内部函数、已知宏支撑函数） |
| 模块特例 | `f_store` 只写核心 API（如 `ByteArray.compare` 这类辅助项不进） |
| 冻结模块 | `f_llm` / `f_log` / `f_mvc` / `f_ticktock` / `f_rpc`：**除非本轮区间内该模块有代码改动**（带 `--base` 时工具自动解冻），否则整模块不改 README |
| 非对外 API | 宿主类型不是 `public` 的成员 |

报告里「一、待新增」就是该补的内容；「二、补中文 / 三、补英文」是中英不一致——**哪边漏了补哪边**，两份 README 必须保持一致（条数、章节、代码块一一对应）。

1. **BASE 以来改过代码的模块逐条深读**（本步的重点）：
   ```bash
   git log --oneline BASE..HEAD -- <模块>   # 或按模块聚合 git diff --stat BASE..HEAD
   ```
   逐项核对 README 与代码：签名 / 默认值 / 注解参数是否滞后；行为与设计说明（建链时机、作用域、并发约定、路由规则、平台支持等）是否仍然成立；示例代码里的宏名、函数名、导入路径是否存在。
2. **其余模块按上面的口径过滤后再补**：以工具的「一、待新增」为清单补 README（中英成对），补完再跑一次工具复核——同一个模块的待新增项应当清零或只剩按口径排除的项。
3. 只改文档、不改代码：代码与 README 冲突时以**代码**为准改 README；怀疑代码本身写错 → 停下问用户。判断不了某段差异该不该写进 README → 停下问用户，**别凭印象编 API 与签名**。

### 1.3 依赖关系图与矩阵图重生成

两张图的数据层：从各模块 `cjpm.toml` 的 `[dependencies]` 取 `fountain::*` 声明，再用 `src/` 里是否 `import` 了对方包筛出**真实依赖**（声明了但源码没引用的不画、间接可达关系也不画）；每条边再按「该模块对它的 API 调用次数」排序，**每个模块只把调用最多的前三名画成彩色实线 / 彩色格，其余依赖退成灰色虚线 / 浅灰格**（规则见 `extract_deps.top_edges`）。依赖变了必须重生成，**不要手改 SVG 成品**。脚本口径、跑法与同步规则详见 `scripts/deps/README.md`：

```bash
# 方式一（推荐）：技能自带副本，在仓库里执行即可 —— 根目录按 FOUNTAIN_ROOT > git 仓库根 > 当前目录推断，
# 产物写到 <仓库根>/.assets/README/ 下；抽到别的仓库/工作树时用 FOUNTAIN_ROOT=… 指定
python3 <技能目录>/scripts/deps/extract_deps.py     # 先看抽取结果：modules=N edges=M
python3 <技能目录>/scripts/deps/gen_layered_svg.py  # → .assets/README/module-dependencies.svg
python3 <技能目录>/scripts/deps/gen_matrix_svg.py   # → .assets/README/module-dependency-matrix.svg

# 方式二：仓库内的入库版本（docs/模块依赖图/ 是仓库产物，改脚本要走仓库提交）
cd docs/模块依赖图 && python3 extract_deps.py && python3 gen_layered_svg.py && python3 gen_matrix_svg.py
```

- 两处脚本**同源**：技能副本唯一的差别是「根目录与产物路径改为按 `FOUNTAIN_ROOT` / git 仓库根 / 当前目录推断」。
  改了生成逻辑（依赖判定、布局、配色、自检）**两处要同步**，仓库内 `docs/模块依赖图/README.md` 的约定也要一起改。
  同步与校验都用自带脚本（都是幂等的，可在仓库里执行）：
  `python3 <技能目录>/scripts/deps/sync_from_repo.py` 把仓库版同步到技能副本（自动补三处有意差异）；
  `python3 <技能目录>/scripts/deps/check_sync.py --run` 校验源码同源、且技能副本跑出来的两张 SVG 与仓库版产物 md5 一致（退出码 0 = 同源）。

- 两个生成器自带自检，必须全部干净再提交（改脚本或数据，**不改成品 SVG**）：
  - 连线图：`header overflow`（页眉文字越界）/ `node crossings`（线压到节点框，必须 `none`——避让路由失效就是这里报警）/ `overlaps`（节点重叠）/ `colors unique`（模块色相不重复），统计行给出 `nodes / edges / levels / canvas / crossings`；
  - 矩阵图：`header overflow` / `colors unique`。
  - 另外核对产物是**可复现**的：同一脚本连跑两次，两张 SVG 的 md5 应完全一致（生成器用固定随机种子）。
- `git diff --stat` 复核产物：本轮没有依赖变化时两张图应当**无 diff**；出现与本轮无关的大范围差异 = 生成器或环境不一致 → 停下查清，别把噪声当更新提交。
- 有依赖变化时，产物 diff 里的节点 / 边应与 `extract_deps.py --json` 的差集对得上（新增模块要出现在图里，颜色与分层沿用既有规则）。
- `docs/模块依赖图/README.md` 的约定（产物路径、排除名单、自检项）有变动时同步改；根 README 的「模块依赖关系」章节只在引用或说明变化时才动，重画本身不用改正文。

### 1.4 同步 fountain-developer 的配置与 API 描述

`skills/fountain-developer` 是「消费」本仓库 README 与代码的技能（安装 fboot、按需求开发、项目改造都靠它的描述当依据）。
**每次建 tag 前按最新代码同步一遍**，否则它会把旧版本的配置项与 API 教给下一次使用；只改 `skills/fountain-developer/` 下的文件，
不改模块代码与模块 README（那是 1.2 的事）。

`common-rules.md` / `module-index.md` / `porting-guide.md` / `server-development.md` / `fountain_lookup.py` 在每个独立技能目录
各有一份**内容必须相同的副本**（`fountain-api-lookup` 另带 `module-index.md`）。先改 `skills/fountain-developer/` 里的主副本，
再把主副本覆盖到所有同名副本，最后核对哈希只剩一个值：

```bash
# 例：把主副本分发到所有同名副本（其余文件同理）
find skills -name common-rules.md -exec cp skills/fountain-developer/references/common-rules.md {} \;
find skills -name common-rules.md -exec md5sum {} \; | awk '{print $1}' | sort -u   # 应只有一行
```

- **模块清单与选型**（`references/module-index.md`）：用技能自带工具现场取当前模块，再与文件里的表格对比：

  ```bash
  python3 skills/fountain-developer/scripts/fountain_lookup.py modules   # Windows 下用 python
  ```

  模块新增 / 删除 / 改名 / 职责变化 → 更新模块表与「需求 → 模块」选型速查；发布范围（如 `[detention]`）以根 `.modules` 为准。
- **API 与注解描述**（`references/server-development.md`、`references/porting-guide.md`）：BASE 以来改过代码的模块逐个核对
  （`git log --oneline BASE..HEAD -- <模块>`）：注解名与参数（`@Controller` / `@GetMapping` / `@Bean` / `@DAO` / `@ORMField` /
  `@AspectRoute` 等）、关键函数与用法示例是否仍能在该模块 README 或 `src/` 里对上；改过的符号用
  `python3 skills/fountain-developer/scripts/fountain_lookup.py search "<符号>" --in code` 复核；特性 / 限制 / 平台前提
  （如「机器码仅 Linux」「at-least-once」）用 `search "<关键词>" --in docs` 与各模块 `doc/` 对一遍。
- **配置项描述**（`references/launch-scripts.md`、`references/server-development.md`、`references/environment.md`）：
  `mvc_*` / `orm_*` / `logger_*` / `rpc*` 等环境变量组的名字与默认值以对应模块 README 为准；三平台启动脚本的差异描述与本仓库
  `fdemo` / `frpcdemo` 的三份 boot 脚本保持一致；版本号示例（fboot 版本等）用现场值更新。
- **流程与命令描述**（`SKILL.md` 与其余 references）：fboot 子命令、目录约定、被引用的文件路径若在本轮区间内有变化，同步修正。

判据：fountain-developer 里出现的每个配置项名与 API 名都能在本仓库对应模块的 README 或 `src/` 里对上；拿不准的差异
**停下问用户**，不凭印象改。改动后按 1.6 单独提交（它属于「文档同步」类，不混进 1.1–1.3 的提交）。

### 1.5 换行符统一为 LF

本仓库约定**文本文件在仓库与工作区都用 LF**（根 `.gitattributes` 的 `* text=auto eol=lf` 只保证仓库侧；工作区副本仍可能被编辑器 / 工具写成 CRLF）。建 tag 前把两类文件的换行符都校正成 LF：

1. **上一个 tag 以来 master 上改过的文件**（`BASE..origin/master` 区间文件，BASE = Step 0 记下的最新 tag）；
2. **本次工作区里所有待提交的改动**（1.1–1.4 改过的文档 / 技能文件；Step 2 之后还会加上升版文件）。

用技能自带脚本检查并修正（幂等；`--base` 同时覆盖两类；先 `--check` 看报告再实跑）：

```bash
python3 <技能目录>/scripts/normalize_newlines.py --base BASE --check   # 只报告（Windows PowerShell 里用 python）
python3 <技能目录>/scripts/normalize_newlines.py --base BASE           # 实修：CRLF -> LF
```

- 口径：只碰 git 判定为文本的文件（二进制与空文件跳过，已删除的路径跳过）；只把 `\r\n` 换成 `\n`，不动内容。`git ls-files --eol` 里 `w/crlf` / `w/mixed` 是工作区侧（修了就有值），`i/crlf` 是索引侧（必须修 + 提交）。
- 是否需要提交**以 `git diff --stat` 为准**（这才是内容层面的差异）：无输出 → 仓库侧本来就是 LF，只修了工作区副本，继续下一步；有输出（脚本也会列出「索引侧仍是 CRLF」的文件）→ 按 1.6 用 `git add` / `git commit -m "chore: 统一换行符为 LF"` 提交，随 Step 3 进 master。
- 刚改写过文件时 `git status --short` 可能一时把既有文件报成 ` M`（Windows 上的 stat/racy 伪报，此时 `git diff --stat` 为空）——跑一次 `git update-index --refresh` 或 `git add -u` 后复看，别为此建空提交。

### 1.6 提交

```bash
git status --short      # 只应出现上面几类文件
git add -u              # 不要用 git add -A；1.4 / 1.5 若新增了文件，再单独 git add <路径>（-u 不含未跟踪文件）
git commit -m "docs(README): 同步各模块 README（<要点：模块清单对齐 / 内容更新>）"  # 1.1、1.2 有改动时
git commit -m "docs(依赖图): 按最新模块依赖重生成依赖图与矩阵图"                    # 1.3 有改动时
git commit -m "docs(skills): 按最新代码同步 fountain-developer 的配置与 API 描述"   # 1.4 有改动时
git commit -m "chore: 统一换行符为 LF"                                             # 1.5 有入库改动时
```

- 出现别的改动或未跟踪文件 → 停下问用户，别顺手一起提交。
- **版本号改动不要混进这些提交**（Step 2 要复核「除版本号外没有别的改动」）；本步不 push，推送与合入 master 都在 Step 3。

## Step 2 — 改版本号（只改文件）

从新 tag 名取出数字版本 `x.y.z`（`release-1.3.10.alpha` → `1.3.10`），把仓库文件里的 `a.b.c` 改成 `x.y.z`；`a.b.c` = Step 0 所依据的最新 tag 的数字版本。

```bash
python "<技能目录>/scripts/bump_version.py" <x.y.z> --old <a.b.c> --root <仓库根>
```

`cjpm.toml` 分两种口径：默认按**值**匹配（只替换值正好等于 a.b.c 的节点）；`fdemo/`、`frpcdemo/` 子树下的 cjpm.toml **不论当前值一律同步**（它们跟随发布走）。替换只认行首的 version 节点，因此依赖表里的版本（如 fdemo 的 `postgres_driver = {version = "0.0.3"}`）不会被误改：

| 位置 | 替换 |
|---|---|
| 仓库内所有 `cjpm.toml` | `version = "a.b.c"` → `version = "x.y.z"` |
| `fdemo/`、`frpcdemo/` 下的 `cjpm.toml` | 不论当前值，行首 `version = "…"` → `version = "x.y.z"` |
| `f_version/src/FountainVersion.cj` | `"a.b.c"` → `"x.y.z"` |

- **根 README.md / README_en.md 不参与替换**：模块文档链接已是版本无关形态（`https://gitcode.com/Cangjie-TPC/fountain/blob/master/<模块>/README.md`），升版时别去改它们，也别做 `/a.b.c/ → /x.y.z/` 全局替换。
- 复核 `git diff --stat`：文件数应等于「参与发布的 cjpm.toml 总数（含 fdemo / frpcdemo 子树）+ `f_version/src/FountainVersion.cj`」，且除版本号外没有别的改动（Step 1 的文档改动此时已提交入库，不应再出现在 diff 里）。先 `--dry-run` 看一遍也可以。
- 脚本退出码 2 = 一处都没替换 → 先核对 `--old` 是否等于文件里当前的版本号。
- 本步只改文件，**不提交**；提交、推送、合入 master 都在 Step 3。

## Step 3 — 提交升版改动并推送，再合入 master（会动分支）

1. 记录开发分支 `DEV`（`git rev-parse --abbrev-ref HEAD`，本仓库通常是 `sts/1.3.x`），并确认工作区**只有**版本号这一组改动：`git status --short` 列出的应当就是 Step 2 报告的那些文件。出现别的改动或未跟踪文件 → 停下问用户，别顺手一起提交。
2. 暂存并复核，**不要用 `git add -A`**：
   ```bash
   git add -u                    # 只暂存已跟踪文件的改动，不捎带未跟踪文件
   git diff --cached --stat      # 文件数与替换处数须与 Step 2 的统计一致
   git diff --cached             # 抽查：只有版本号行在变
   ```
3. 提交（对齐本仓库 `a01c34cc` 的口径）：
   ```bash
   git commit -m "chore(release): 更新所有模块版本从 a.b.c 到 x.y.z"
   ```
4. 推送 `DEV` 并核对：
   ```bash
   git push origin <DEV>
   git rev-parse HEAD                       # == 下面的远端 sha
   git ls-remote origin refs/heads/<DEV>
   ```
   本次推送会把 Step 1 的文档提交一并推上去，属预期。
5. 合入 master：
   - `DEV` 就是 `master` → 跳过合并，直接进第 6 步（提交已在 master 上）。
   - 否则：
     ```bash
     git checkout master
     git merge --no-ff <DEV> -m "Merge branch '<DEV>'"
     git push origin master
     git checkout <DEV>          # 必须切回，别把工作区留在 master
     ```
   - 有冲突 → 停在冲突现场，把冲突文件列给用户，不自行取舍；`Already up to date` 也要在汇报里写明。
6. **门禁复核（不通过就别往下走）**：`git merge-base --is-ancestor <升版提交 sha> origin/master` 必须 exit 0。这里用升版提交的 sha（Step 3.3 的 `HEAD`），不是 `DEV` 的 tip；有 Step 1 的文档提交时，对它的 sha 也跑一遍同样的检查。
7. 复核 master 已推送：`git rev-list --count origin/master..master` 应为 0。

## Step 3.5 — 更新 CHANGELOG（建 tag 前，会改文件 + 提交 + 合入 master）

**位置**：Step 3 已把文档 + 升版提交推入 `origin/master` 之后、Step 4 定 tag 区间之前。`CHANGELOG` 必须覆盖 `BASE..origin/master`（BASE = Step 0 的最新 tag，目标 = 当前 `origin/master` 的 tip），并且它自己也要进入 master，才能被本次 tag 覆盖。

1. **取区间与日期**（只读）：

   ```bash
   git fetch origin --tags
   BASE=<Step 0 记录的最新 tag>        # 替换成 tag 名（占位符，不是 shell 变量语法）
   git rev-parse origin/master
   git show -s --format=%ad --date=short origin/master
   git log --format="%h|%ad|%s" --date=short BASE..origin/master   # 新→旧
   git rev-list --count --merges BASE..origin/master                 # 合并数
   git diff --stat BASE..origin/master
   ```

   - 先按每个提交的 `%ad` 取日期，同一天的提交合并到同一日期段；**不要把区间内所有条目都塞到目标提交日期**。目标提交日期（`git show -s --format=%ad --date=short origin/master`）用于本次升版条目与判断新段位置。
   - 区间为空 → 不更新 CHANGELOG，按 Step 4 的「无新提交」处理（不建 tag）。
   - 区间里应能看到 Step 2/3 的升版提交；看不到说明 master 还没推上去，回 Step 3。

2. **读现有 `CHANGELOG`**：从头读，记录已有日期段、已有条目与格式（日期行顶格、条目 4 空格缩进、`type(module): 摘要`、长行 6 空格续行）。已有条目视为「已记录」，不得重复添加；同一变更已有更宽的总结时，不拆成多条。

3. **归并条目**（按主题，不逐条抄提交）：
   - 先按提交日期分组，再按主题：新增与接口变化 / 修复 / 文档 / 工程；`refactor!` / 破坏性变更必须在摘要里标 `!` 或「不兼容」。
   - 每条写「模块：做了什么——动机/影响」，不写提交号；纯合并提交不单列。
   - 功能性 / 行为性描述必须回到 `git diff` 核对（与 Step 5 同一口径）；提交信息与 diff 冲突时以代码为准。
   - 工程段至少写本次升版：所有模块 `cjpm.toml`（含 fdemo / frpcdemo 工作区）与 `f_version/src/FountainVersion.cj` 由 a.b.c 升到 x.y.z；已有同版本条目则跳过。
   - 只把**缺失**的条目插入；已有条目保持原文，不重写、不删改（除非日期段乱序需要整段移动）。

4. **写入 `CHANGELOG`（时间倒序，越近越靠前）**：
   - 每个日期段按 `YYYY-MM-DD` **倒序插入到正确位置**：比它旧的段之前、比它新的段之后；已有该日期段时把新条目放在该段**最前面**，没有则新建。最新日期段自然在文件最顶部。
   - 本次升版条目放在目标提交日期段（没有就新建该日期段）。
   - 日期段发现乱序时，只移动整段，不改段内内容。
   - 格式对齐现有文件：UTF-8、LF、无尾随空格、条目 4 空格缩进、续行 6 空格。
   - 示例（只示意顺序）：

     ```
     2026-10-25
         feat(f_mcp): 新增 @Mcp 宏与三个元数据注解
         fix(f_mq): 死信阈值改重试次数语义
     2026-10-24
         新增 f_jsonrpc 模块（JSON-RPC 2.0）
     ```

   - 禁止把新条目追加到文件末尾、按正序排、或把旧日期段整体倒序重写。

5. **提交并合入 master**（与 Step 3 同一套推送 / 合并 / 门禁）：

   ```bash
   git status --short                 # 只应出现 CHANGELOG
   git add CHANGELOG
   git diff --cached --stat           # 只应有 CHANGELOG
   git commit -m "docs(CHANGELOG): 汇总 <BASE>..<target 短 sha> 的变更"
   git push origin <DEV>
   git rev-parse HEAD                 # 记为 CL_SHA
   ```

   - `DEV` 就是 `master` → 跳过合并；否则：
     ```bash
     git checkout master
     git merge --no-ff <DEV> -m "Merge branch '<DEV>'"
     git push origin master
     git checkout <DEV>
     ```
   - 门禁：`git merge-base --is-ancestor <CL_SHA> origin/master` 必须 exit 0；`git rev-list --count origin/master..master` 必须为 0。
   - 无新增条目（`git diff --stat` 为空）→ 不建空提交、不合并；在汇报里写明「CHANGELOG 已包含本区间全部变更」，`CL_SHA` 记为空。
   - `CHANGELOG` 改动**单独提交**，不要混进 Step 1 的文档提交或 Step 2 的升版提交。
   - 有冲突 → 停在冲突现场，把冲突文件列给用户，不自行取舍。

## Step 4 — 定位基线与目标提交

```bash
git fetch origin --tags                          # 失败说明本地 tag 可能过期：继续，但汇报里写明
git tag --sort=-creatordate                      # 首行 = 上一个 tag（记为 BASE）
git merge-base --is-ancestor BASE origin/master  # exit 0 才合法；非 0 则列出候选让用户选
git rev-parse origin/master                      # 目标提交：master 的 tip
git rev-list --count origin/master..master       # 应为 0；>0 = master 还有未推送提交
git log --oneline BASE..origin/master            # 本次要总结的提交集合（合并数另跑 --merges）
```

- 目标提交 = **`origin/master` 的 tip**。本地 `master` 上尚未推送的提交不进区间，也**不要**为它们询问用户。
- 区间里**必须能看到 Step 3 的升版提交**（以及 Step 1 的文档提交）；看不到说明 master 还没推上去 → 回 Step 3 第 6、7 步。
- 若 Step 3.5 产生了 CHANGELOG 提交，区间里**也必须能看到 `docs(CHANGELOG)` 提交**，且目标提交包含它；看不到说明 CHANGELOG 没合入 master → 回 Step 3.5 第 5 步。
- fetch 后最新 tag 与 Step 0 推导候选时所依据的不一致 → 回到 Step 0 重新推导并征求同意，再用新的 `a.b.c` 重做 Step 2（此时 `--old` 传文件里当前的版本号）；区间若因此扩大，Step 1.2 的「改过代码的模块」清单按新 BASE 重新核一遍。
- 区间为空 → 汇报「无新提交」，不建 tag。
- 禁止：拿 `HEAD`、当前分支或别的分支当目标提交；禁止用 `BASE..HEAD` 当范围——未合并到 master 的提交不得进入 tag 信息。
- 只读查看仓库状态；不动其它分支 / worktree，不 prune、不删分支与 tag。

## Step 5 — 汇总（结论必须回到 diff 核对）

1. `git log BASE..origin/master --format="%h|%ad|%s" --date=short`：提交清单与数量（合并数用 `--merges` 单独数）。
2. `git show --no-patch --format=%B <sha1> <sha2> <sha3>`：一次取多个正文，不要用 shell 循环。
3. `git diff --stat BASE..origin/master`，再对功能性提交按路径取关键 diff。**tag 信息里每条机制性描述都要在 diff 里核实过**——提交信息常滞后于代码，冲突时以代码为准。
4. 按主题分组，风格对齐本仓库既有 tag（可 `git cat-file tag <BASE>` 参考）：
   - 头部：`自 BASE（短 sha，YYYY-MM-DD）至本次提交（短 sha，YYYY-MM-DD），共 N 个提交（含 M 个合并）。` 下一行为 `以下按主题汇总。`
   - 分节：一、新增与接口变化；二、修复；三、文档；四、工程（空分节删掉）。
   - 每条一行：`- 模块：做了什么——动机/影响`；写模块与行为，不写提交号。
   - 「三、文档」要涵盖 Step 1 的 README、依赖图、fountain-developer 同步改动与 Step 3.5 的 CHANGELOG 更新（每条同样回到 diff 核对；CHANGELOG 条目与 tag 信息不能互相矛盾）。
   - 工程分节必须写到本次升版：全部模块 `cjpm.toml`（含 fdemo / frpcdemo 工作区）与 `f_version/src/FountainVersion.cj` 由 a.b.c 升到 x.y.z（根 README 的链接与版本无关，不在列）。

## Step 6 — 建附注 tag

0. 建 tag 前再确认一次：`git rev-parse origin/master` 与 Step 4 记录的目标 sha 相同，且 Step 3 第 6 步的门禁已通过（Step 1 的文档提交——含 1.4 的 fountain-developer 同步——与升版提交都在 master 上）；若 Step 3.5 产生了 CHANGELOG 提交，`git merge-base --is-ancestor <CL_SHA> origin/master` 也必须 exit 0，且目标 sha 已包含它。
1. 用编辑器工具把 tag 信息写到**仓库外**的临时文件（UTF-8 无 BOM）。禁用 PowerShell here-string / `Out-File -Encoding utf8`：引号会被吞、BOM 会写进 tag。
   - **写完先核对文件非空**再往下走：`(Get-Item <路径>).Length` 应 > 0，首行应是 tag 名。编辑器工具偶发写出 0 字节文件，而 `git tag -a -F` 对空文件照样 exit 0，会静默产出空消息的 tag。是 0 字节 → **换个文件名重写**（同名路径刚被删过时容易再写空），不要直接重试同名。
2. 文件内容格式（git 会剥掉首尾空行）：

```
<tag 名>

自 <BASE>（<短 sha>，<日期>）至本次提交（<短 sha>，<日期>），共 N 个提交（含 M 个合并）。
以下按主题汇总。

一、新增与接口变化
- 模块：…
```

3. 建 tag（必须 `-a`：本仓库 release tag 全是附注 tag，`git tag -l -n` 才显示消息）：

```bash
git tag -a <tag 名> <origin/master 完整 sha> -F "<临时文件路径>"
```

4. 落地校验 `git cat-file tag <tag 名>`：`object` 行 == 目标 sha，`tag` 行 == tag 名，正文中文无乱码、分节完整。正文为空（只有 object/type/tag/tagger 四行）说明消息文件是空的 → 这个 tag 是本步刚建、**尚未推送**的，可 `git tag -d <tag 名>` 后换文件名重建；已推送的 tag 一律不动、不 `-f` 覆盖。
5. 删掉临时文件。

## Step 7 — 推送并复核远端

```bash
git push origin refs/tags/<tag 名>              # 显式 refspec；不加 --force，不用 --tags
git --no-pager ls-remote --tags origin <tag 名> # 必须回显 tag 对象 sha
```

汇报：BASE tag、目标提交、升版提交 sha 与合并提交 sha（若有）、`DEV` 与 `master` 的推送结果、提交数、Step 0 的 tag 名校验结论（三条是否全过 / 最新 tag / 是否撞过名）、Step 1.1 的模块清单对齐结果（追加 / 删除了哪些条目，或「无差异，共 M 个模块」）、Step 1 的其余改动清单（改了哪些 README / 图 / fountain-developer 文件、换行符修正了几个文件、改了什么）、Step 2 的版本号替换统计（改了哪些文件、多少处）、Step 3.5 的 CHANGELOG 更新（新增 / 合并了哪些日期段与条目、按时间倒序是否满足、是否产生提交与合并、`CL_SHA`、或「已包含全部变更」）、tag 信息全文、推送结果（本地 tag 对象 sha 与远端 sha）。只推这一个 tag，其余推送只限 Step 3 / 3.5 的 `DEV` 与 `master`。

## Red Flags — 命中就停下重来

| 症状 | 现实 |
|---|---|
| tag 名没定（用户没给或给的名不合正则）就先改版本号 / 汇总提交 | 顺序错了：先定名（推导候选 + 征得同意）再动手 |
| 名字不合正则却照用（如 `release-1.3.10.Alpha`、`v1.3.9`、`release-1`、`release-1.4`、`release-1.3.16.1`） | 下游按正则解析 tag 的脚本会漏掉它；数字版本**只认 `a.b.c` 三段**，段数不对一律退回给用户，不许自行补段（`release-1.4`→`1.4.0`）或砍段（`release-1.3.16.1`→`1.3.16`） |
| 用户给的名字版本号已被别的 tag 用过却照用（最新是 `release-1.3.15.alpha`，还要建 `release-1.3.15` 或 `.beta`） | 同一 `a.b.c` 出第二个 tag 后，「这个版本对应哪个 tag」没法回答；Step 0 的唯一性校验必须跑，脚本会指出被哪个 tag 占用 |
| 用户给的名字版本号比当前最新 tag 小（最新 `1.3.15` 却要建 `release-1.3.9.alpha`） | 升版会从 1.3.15 倒退到 1.3.9 并一路进 master；Step 0 的递增校验必须跑，报给用户换名而不是照做 |
| 靠肉眼比版本号、跳过校验脚本 | 创建时间新 ≠ 版本号大；`git tag` 默认还是字典序（`1.3.9` 排在 `1.3.10` 之后），唯一性还得对全量 tag 看；跑一次脚本（正则 + 唯一 + 递增）比人眼快也更稳 |
| 升版改动没提交就建 tag | tag 停在 master 旧 tip：tag 信息写着新版本号、代码树仍是旧版本号（2026-10-07 `release-1.3.10.alpha` 首版即如此，只能删掉重打）。顺序永远是 Step 3 → Step 3.5 → Step 6 |
| 升版提交只推到开发分支、没合进 master | 区间取自 master，tag 里不会有升版提交；Step 3 第 6 步的门禁不能跳 |
| README 没对照代码就建 tag | 发出去的是旧说明；Step 1.2 的逐条核对不能跳，BASE 以来改过代码的模块尤其 |
| 没同步 fountain-developer 就建 tag | 它的配置 / API 描述停留在旧版本，下一次用它开发会按旧描述写出错代码；Step 1.4 不能跳（BASE 以来改过代码的模块尤其），`docs(skills)` 提交也要落进 master |
| 新模块没进根 README、模块已删却还留在根 README 就建 tag | Step 1.1 的清单对齐是硬检查：两条 `Compare-Object` 必须都为空，且中英两份成对改 |
| 只改中文 README、漏了 `README_en.md`（或反之） | 双语版会漂移：章节、代码块、清单条目必须一一对应 |
| README 里凭印象写 API / 签名 | 每个写进去的符号都要在该模块 `src/` 里对上；判断不了就问用户 |
| 手改 SVG 成品、或不跑生成器就提交依赖图 | 下次重生成即被覆盖，且与 `cjpm.toml` 脱节；只跑 `scripts/deps/`（技能副本）或 `docs/模块依赖图/`（仓库版）里的生成器 |
| 生成器自检有告警（页眉越界 / 线压节点 / 节点重叠 / 色相重复）仍提交 | 图本身有问题，先修脚本或数据，再重跑；`node crossings` 必须为 none |
| 依赖图出现与本轮无关的大范围 diff | 生成器或环境不一致；停下查清，别把噪声当更新提交 |
| 建 tag 前没更新 CHANGELOG | Step 3.5 是硬步骤：必须按 `BASE..origin/master` 汇总，否则 tag 与 CHANGELOG 脱节 |
| CHANGELOG 新条目追加在文件末尾 / 日期按正序排 | 必须时间倒序：最新日期段在最上、同日内最新条目在前；新条目追加到末尾算没更新 |
| CHANGELOG 改了但没提交 / 没合入 master | 只在工作区改文件不算更新；必须单独提交、推送 `DEV`、合入并推送 `master`，否则本次 tag 不包含它 |
| CHANGELOG 把已有条目重复一遍 / 直接抄提交信息 | 先读现有 CHANGELOG，已有条目（或更宽的总结）不重复；按主题归并，功能性描述回到 diff 核对 |
| CHANGELOG 改动混进升版提交 | 必须单独 `docs(CHANGELOG): …` 提交；混进升版提交会破坏 Step 2 的「只有版本号」复核 |
| CHANGELOG 日期段乱序 | 日期段按 `YYYY-MM-DD` 从新到旧；发现乱序时只移动整段，不改段内内容 |
| 文档改动与版本号改动混在一个提交 | Step 2 的「除版本号外没有别的改动」复核会失效；两类改动各自成提交 |
| 文档提交没进 master 就打 tag | 区间取自 master，未合并的文档不进 tag；同升版提交的约束 |
| 用 `git add -A` 暂存 | 会捎带未跟踪文件与无关改动；用 `git add -u`，并在 commit 前复核 `git diff --cached --stat` |
| 合并到 master 后没切回开发分支 | 后续改动会落在 master 上；`git checkout <DEV>` 收尾 |
| 合并有冲突却自行取舍 | 停下问用户，把冲突文件列出来 |
| 用 `HEAD` / 当前分支当目标提交 | 会把未合并到 master 的提交写进 tag 信息 |
| 提交信息直接抄成 tag 信息 | 提交信息常与代码不符，必须核对 diff |
| 手工全局替换 `version = "` | 会误伤依赖版本（如 fdemo 的 `postgres_driver` 0.0.3）与 fcoder；用 `bump_version.py`（只认行首 version 节点） |
| `git push --tags` 或 `-f` | 会捎带别的 tag / 覆盖已有 tag |
| 用 PowerShell here-string 写消息 | 引号与编码出错，中文或特殊字符被破坏 |
| 临时消息文件是 0 字节就建 tag | `git tag -a -F` 对空文件也 exit 0 → 静默生成空消息 tag；写完先看文件长度，空就换名重写 |
| 临时消息文件没删 | 留下垃圾，还可能被误提交 |
| 区间文件 / 待提交文件的换行符没校正就建 tag | 仓库约定全 LF：跑 `scripts/normalize_newlines.py --base BASE`（Step 1.5）；`i/crlf` 的文件要 `git add` 提交、随 Step 3 进 master，`w/crlf` 只影响工作区副本 |

## 平台注意（Windows + PowerShell）

- 没有 `head`/`tail`/`grep`：用 `Select-Object -First N`、`Select-String`。
- 命令里**不要出现 `%n`**：含 `%n` 的 `--format` 会让整条命令被平台吞掉（报「系统找不到指定的路径」，命令根本没执行）。要分隔符就用 `|`（`--format="%h|%ad|%s"`）；要正文另跑一条 `git show --no-patch --format=%B <sha1> <sha2>`（`%B`/`%s`/`%ad`/`--date=short`/`--date=format:...` 均实测可用）。
- **`^` 也别用在 rev 里**：`release-1.3.9.alpha^{commit}` 会被 PowerShell 当转义符吞掉（报 `ambiguous argument 'YwBvAG0AbQBpAHQA'`）。要解析附注 tag 指向的提交，用 `git show -s --format=%h <tag 名>` 或 `git merge-base --is-ancestor <tag 名> <分支>`。
- 写消息文件用编辑器工具，不要用 shell 重定向或 heredoc；并注意刚被 `Remove-Item` 删掉的同名路径再写容易得 0 字节文件，写完核对长度、必要就换文件名。
- 依赖图生成器只依赖 Python 3（纯标准库）：Windows PowerShell 里 `python3` 通常不存在，用 `python`；WSL 里用 `python3`。仓库内副本按脚本位置推断仓库根（`cd docs/模块依赖图` 直接跑即可）；技能副本（`scripts/deps/`）按 `FOUNTAIN_ROOT` > git 仓库根 > 当前目录推断，在仓库里直接跑即可，产物都写到 `<仓库根>/.assets/README/`。两处同源，漂移与否用 `scripts/deps/check_sync.py [--run]` 一条命令校验；脚本口径与常量说明见 `scripts/deps/README.md`。
- 换行符统一脚本 `normalize_newlines.py` 只用 Python 3 标准库：`--base` = 区间文件 + 待提交文件（Step 1.5 用），`--all` = 全仓体检，`--check` 只报告（存在待修正文件时退出码 1）；Windows 用 `python`、WSL 用 `python3`。

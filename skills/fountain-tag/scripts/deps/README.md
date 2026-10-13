# scripts/deps —— 依赖关系图 / 矩阵图生成脚本（技能自带副本）

三件套，纯 Python 3 标准库（无第三方依赖），跑完产物落在 `<仓库根>/.assets/README/`：

| 脚本 | 作用 |
|---|---|
| `extract_deps.py` | 数据层：抽各模块 `cjpm.toml` 的 `fountain::*` 声明、`src/` 里的 import（真实用到的）、以及每对模块的 API 引用量；被两个生成器 `import` |
| `gen_layered_svg.py` | 分层连线图 → `module-dependencies.svg` |
| `gen_matrix_svg.py` | 43×43 矩阵图 → `module-dependency-matrix.svg` |
| `check_sync.py` | 校验上面三份技能副本与仓库内 `docs/模块依赖图/` 的入库版本是否同源（`--run` 再跑一遍核对产物 md5） |
| `sync_from_repo.py` | 反向同步：把仓库内 `docs/模块依赖图/` 的入库版本覆盖到技能副本（自动补上三处有意差异），`--check` 只检查 |

## 跑法

在仓库里执行即可（根目录按 `FOUNTAIN_ROOT` > git 仓库根 > 当前目录推断）：

```bash
python3 <技能目录>/scripts/deps/extract_deps.py            # 统计 + 依赖表
python3 <技能目录>/scripts/deps/extract_deps.py --usage    # 每条边的 API 引用次数（降序）
python3 <技能目录>/scripts/deps/extract_deps.py --declared # 连「声明了但没引用」的边一起列（标 UNUSED）
python3 <技能目录>/scripts/deps/extract_deps.py --json     # 供别的工具消费
python3 <技能目录>/scripts/deps/gen_layered_svg.py
python3 <技能目录>/scripts/deps/gen_matrix_svg.py
```

抽到别的仓库 / 工作树时用 `FOUNTAIN_ROOT=/path/to/fountain python3 …`。

**同步自检**（改完脚本或怀疑两处漂移时跑，退出码 0 = 同源）：

```bash
python3 <技能目录>/scripts/deps/check_sync.py        # 只比源码
python3 <技能目录>/scripts/deps/check_sync.py --run  # 再跑技能副本，核对两张 SVG 与仓库版产物 md5 一致
```

## 口径（改逻辑前先读这段）

**数据层（`extract_deps.py`）**

- 一条边 = 「`cjpm.toml` 里声明了 `fountain::X`」**且**「本模块 `src/` 下的非 `_test.cj` 代码里 `import` 了 `fountain::X…`」（仓颉要用对方 API 必须声明直接依赖，所以这两条同时成立才算真实依赖）；
  - 声明了但源码里没引用的（18 条左右）**不画**；间接可达关系也不画；
  - import 允许 `public` / `protected` / `internal` / `private` 修饰。
- **API 引用量** `api_usage()`：A 的源码里出现 B 的**公开符号名**的次数——import 行、注释、字符串字面量都不计；同名符号若同时属于 A 依赖的多个模块，按候选数**均摊**；A 自己也声明了同名符号则不计（归属不明）。连线图用它决定边的深浅。
- **每模块前三** `top_edges(k=3)`：按上面的引用量给每个模块的依赖排序（次数相同时按依赖名定序，保证可复现），取前三——两张图用它决定「哪些边/格子画彩色」。
- 排除示例应用 `fdemo` / `fcoder` / `frpcdemo`。

**连线图（`gen_layered_svg.py`）**

- 分层：`level` = 到汇点的最长路径；节点宽度按最长模块名自适应（`NW`），`NH` / `NODE_FONT` / `HGAP` / `MAX_HGAP` / `VGAP` / 线宽都在文件顶部常量里。
- 行内布局：节点少的行把余量摊进间距（上限 `MAX_HGAP`），再叠加**行级横向错位**（`optimize_shifts` 逐行试偏移量取交叉最少者，夹在画布内）。
- 行内排序：多起点「重心法 + 相邻交换」局部搜索，目标函数 = **路径交叉数**（沿与最终 SVG 相同的路径每 `band` 像素取 x，统计相邻取样间顺序翻转数）；固定随机种子 ⇒ 重跑产物一致。
- **跨层长边避让路由**：`span > 1` 的边在中间每一层都必须落在「该层节点之间的空隙」或行两端外侧（净距 `CLR`），通道内竖直、行间用控制点在竖直中点的贝塞尔过渡 ⇒ **线不会压到任何节点框**（斜向交叉可以接受）。
- **边的两种画法**：该模块 API 调用次数**前三**的依赖 → 彩色实线（色相 = 来源模块色相、深浅 = 引用量）；其余依赖 → **灰色虚线**（照旧参与避让路由与交叉统计，只是退成背景）。每个模块的色相都**不重复**（黄金角散布），彩色线的深浅按 log 归一分 6 档。
- 自检（必须全部干净）：`header overflow` / `node crossings`（线压节点，必须 none）/ `overlaps` / `colors unique`；统计行给出 `nodes / edges / levels / canvas / crossings`。

**矩阵图（`gen_matrix_svg.py`）**：与连线图同一套色相、深浅与前三规则——每行前三的格子彩色、其余浅灰（`#e2e8f0`）；行 = 依赖方，列 = 被依赖方，两轴按层级升序 ⇒ 依赖只落在对角线右上侧；每个列名（竖排）下边紧贴一个数字 = 该模块被依赖次数；自检 `header overflow` / `colors unique`。

## 与仓库内入库版本的差别 / 同步

仓库内的入库版本在 `docs/模块依赖图/`（`extract_deps.py` / `gen_layered_svg.py` / `gen_matrix_svg.py`），与这里**同源**，技能副本只有两处故意差异：

1. **根目录推断**：技能副本按 `FOUNTAIN_ROOT` > `git rev-parse --show-toplevel` > 当前目录；仓库版按脚本位置（`docs/模块依赖图/` 上两级）。
2. **产物路径**：技能副本用 `extract_deps.ROOT` 拼 `.assets/README/…`；仓库版用脚本相对路径。

**改了生成逻辑（依赖判定、布局、配色、自检）两处都要同步**：

```bash
# 仓库版改完 → 同步到技能副本（自动补三处有意差异），再校验
python3 <技能目录>/scripts/deps/sync_from_repo.py
python3 <技能目录>/scripts/deps/check_sync.py --run     # 源码同源 + 两张 SVG md5 不变
```

并且：

- 仓库内 `docs/模块依赖图/README.md`（约定：产物路径、排除名单、自检项）要一起改；
- 根 `README.md` / `README_en.md` 的「模块依赖关系」章节只在**说明变了**的时候才动（重画本身不用改正文）；
- 同步后建议两边各跑一遍生成器，核对两张 SVG 的 md5 相同（技能副本与仓库版产出必须逐字节一致）。

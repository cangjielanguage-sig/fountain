# 模块依赖图生成脚本

根 `README.md` / `README_en.md` 里那两张图的生成器。数据分两层：各模块 `cjpm.toml` 的 `[dependencies]`
里 `fountain::*` 的**声明**，以及该模块 `src/` 下**是否真的 import 了对方包**——两条同时成立才算一条边
（仓颉里要用某个模块的 API 必须把它声明成直接依赖，所以声明了却没引用只是多余声明，不进图）。

| 产物 | 生成脚本 |
|---|---|
| `.assets/README/module-dependencies.svg`（分层连线图） | `gen_layered_svg.py` |
| `.assets/README/module-dependency-matrix.svg`（依赖矩阵） | `gen_matrix_svg.py` |
| 依赖表 / 统计（排查用） | `extract_deps.py`，另有 `--usage`（每条边的 API 引用次数）、`--declared`（连未引用的声明一起列）、`--json` |

重画（模块依赖变化后跑前两条即可；只要 Python 3，无第三方依赖）：

```bash
cd docs/模块依赖图
python3 extract_deps.py         # 先看抽取结果：modules=… declared=… used=… unused=…
python3 gen_layered_svg.py      # → ../../.assets/README/module-dependencies.svg
python3 gen_matrix_svg.py       # → ../../.assets/README/module-dependency-matrix.svg
```

约定（改脚本时保持一致）：

- **不写死路径**：仓库根按脚本位置推断（脚本在 `docs/模块依赖图/` 下，产物写 `../../.assets/README/`）；
- **什么算依赖**：`cjpm.toml` 声明了 `fountain::X` 且 `src/`（非 `_test.cj`）里 `import` 了 `fountain::X…`
  （import 可带 `public` / `protected` / `internal` / `private` 修饰）；声明了但源码未引用的不画，
  间接可达关系也不画；
- **API 引用量**（`extract_deps.api_usage`）：A 的源码里出现 B 的公开符号名的次数——import 行、注释、
  字符串字面量不计，同名符号属多个候选时按候选数均摊，A 自己声明的同名符号不计；
- **每模块前三**（`extract_deps.top_edges`）：按引用量给每个模块的依赖排序（并列时按依赖名定序，保证可复现），
  前三名画**彩色实线 / 彩色格**，其余画**灰色虚线 / 浅灰格**——两张图用同一条规则；
- **配色**：每个模块一个不重复的色相（黄金角散布），彩色边 / 格的深浅 = 该模块对该依赖的 API 引用量
  （log 归一分 6 档，越多越深）；两张图共用这套色，所以同一个模块在两张图里同色；
- **连线图布局**：节点宽度按最长模块名自适应；行内按画布宽度摊开（节点少的行间距更大）+ 行级横向错位；
  行内排序用多起点「重心法 + 相邻交换」搜索，目标函数 = 沿真实路径统计的交叉数；**跨层长边避让路由**——
  每条长边在中间各层只能落在「节点之间的空隙」或行外侧，所以线不会压到任何节点框；
- **矩阵图上的数字**：每个列名（竖排）下边紧贴一个数字 = 该模块被依赖次数（原先放在网格底行，已上移）；
- **产物可复现**：生成器用固定随机种子，同一脚本连跑两次两张图 md5 应一致；
- **自检**（必须全部干净）：连线图 `header overflow` / `node crossings`（线压节点，必须 `none`）/
  `overlaps` / `colors unique`，矩阵图 `header overflow` / `colors unique`；
- **示例应用不进图**：`fdemo`、`fcoder`、`frpcdemo` 列在 `extract_deps.py` 的 `EXCLUDE` 里；
- **与技能 fountain-tag 同源**：`fountain-tag/scripts/deps/` 是同一套脚本的技能副本（差别只有「仓库根按
  `FOUNTAIN_ROOT` > git 仓库根 > 当前目录推断」与产物路径），改完这里用
  `python3 <技能目录>/scripts/deps/sync_from_repo.py` 同步、`check_sync.py --run` 校验同源与产物一致。

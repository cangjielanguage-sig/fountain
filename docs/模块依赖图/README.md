# 模块依赖图生成脚本

根 `README.md` / `README_en.md` 里那两张图的生成器。数据源是各模块 `cjpm.toml` 的 `[dependencies]`，
只取 `fountain::*` 内部依赖。

| 产物 | 生成脚本 |
|---|---|
| `.assets/README/module-dependencies.svg`（分层连线图） | `gen_layered_svg.py` |
| `.assets/README/module-dependency-matrix.svg`（依赖矩阵） | `gen_matrix_svg.py` |
| 依赖表（排查用） | `extract_deps.py`，加 `--json` 输出 JSON |

重画（模块依赖变化后跑前两条即可；只要 Python 3，无第三方依赖）：

```bash
cd docs/模块依赖图
python3 gen_layered_svg.py      # → ../../.assets/README/module-dependencies.svg
python3 gen_matrix_svg.py       # → ../../.assets/README/module-dependency-matrix.svg
python3 extract_deps.py         # 只打印依赖表，确认抽取结果
```

约定（改脚本时保持一致）：

- **不写死路径**：仓库根按脚本位置推断（脚本在 `docs/模块依赖图/` 下，产物写 `../../.assets/README/`）；
- **两张图共用一份数据与一套颜色**：节点（连线图）/ 行（矩阵）的颜色按 `(依赖层级, 名字)` 排序后轮流取
  `PALETTE`，所以同一个模块在两张图里的颜色一致；
- **依赖分两类**：结构性依赖（无法由其它依赖间接到达）与冗余直达（可由其它依赖间接到达，但 `cjpm.toml`
  仍声明了它）——两张图的图注里都对读者写明了这条区分；
- **示例应用不进图**：`fdemo`、`fcoder`、`frpcdemo` 列在 `extract_deps.py` 的 `EXCLUDE` 里；
- 两个生成器都会自检并打印结果：**页眉文字是否超出画布**、节点是否重叠、是否存在依赖环。

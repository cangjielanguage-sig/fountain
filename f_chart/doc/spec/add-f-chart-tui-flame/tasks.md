## 1. 测试（Red）

- [x] 1.1 新增 `TuiFlameChart_test.cj`：基本渲染、标题/标签、真彩色序列
- [x] 1.2 覆盖 `bottom-up` / `top-down` 的根节点行位置
- [x] 1.3 覆盖 `colorBy = "value"` 热力色
- [x] 1.4 覆盖单根、未知父节点、重复 id、子节点超限、非正值、类型错误
- [x] 1.5 覆盖缺省 80×24、自定义尺寸与确定性

## 2. 实现（Green）

- [x] 2.1 在 `TuiColor.cj` 增加 `tuiContrastColor`
- [x] 2.2 新增 `TuiFlameChart.cj`：解析、校验、递归布局、真彩块与标签
- [x] 2.3 生成 `charts/M052-flame.tui.txt` 样例

## 3. 文档与交付

- [x] 3.1 更新 `f_chart/README.md` / `README_en.md` 的 TUI 类表与用法
- [x] 3.2 更新 `f_chart/doc/f_chart模块设计.md`
- [x] 3.3 `openspec validate add-f-chart-tui-flame --strict` 通过
- [x] 3.4 全量 `cjpm test` 回归
- [x] 3.5 归档并同步四件套到 `f_chart/doc/spec/add-f-chart-tui-flame/`

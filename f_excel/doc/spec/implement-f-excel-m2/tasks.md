# Tasks — implement-f-excel-m2

> 每个任务先写失败用例（Red）→ 最小实现（Green）→ 重构；跑绿才勾选。
> 分支：`feature/f_excel` 的后续工作线；不自动 merge / push。

## 0. 前置

- [ ] 0.1 R5–R8 实测（tint 公式、函数对照值来源、Duration 范围、样式池 64000 性能），结论回填 design §5
- [ ] 0.2 确认 `f_xml` DOM 能覆盖 styles.xml 的全部节点；不能则记录缺口并停下询问

## 1. M2-a 样式

- [ ] 1.1 失败用例 `Style_test`：`CellStyle` 值语义、`with*`、默认值、`Color` 三编码相等
- [ ] 1.2 失败用例 `StylePool_test`：深比较去重、四张子表编号、`maxCellStyles` 两种上限消息
- [ ] 1.3 失败用例 `Styles_test`（读）：20 种样式样本 → `Font/Fill/Border/Alignment/Protection` 全字段
- [ ] 1.4 失败用例（写）：20 种样式 → styles.xml 结构与索引；往返后逐字段相等
- [ ] 1.5 失败用例：`Cell.style` 与 `numberFormat` 并存时以 style 为准；M1 调用方不受影响
- [ ] 1.6 实现 `Style.cj` / `StylePool.cj` / `Styles.cj`，接入 `WorksheetParser` / `PackageWriter`
- [ ] 1.7 openpyxl 回读 20 种样式（字体/填充/边框/对齐）核对

## 2. M2-b 公式核心

- [ ] 2.1 失败用例 `FormulaLexer_test`：数字/字符串/布尔/错误/引用/区域/函数名/运算符/空白
- [ ] 2.2 失败用例 `FormulaParser_test`：优先级、括号、一元负号、比较、字符串连接、错误公式
- [ ] 2.3 失败用例 `Evaluator_test`：四则/比较/连接/引用取值/区域聚合
- [ ] 2.4 失败用例 `FunctionRegistry_test`：40 个函数逐一对 Excel 预期值
- [ ] 2.5 失败用例 `DependencyGraph_test`：跨格/跨表依赖、拓扑序、循环引用 `#CIRC!`
- [ ] 2.6 失败用例 `CalcEngine_test`：`recalculate` 全表/单表、`evaluate` 单格、默认不自动重算
- [ ] 2.7 失败用例：共享公式平移（`$` 不动、越界 `#REF!`）；数组公式左上角求值
- [ ] 2.8 实现词法/语法/AST/求值/注册表/依赖图/引擎

## 3. M2-c 扩展

- [ ] 3.1 失败用例：+100 函数逐一对 Excel 预期值
- [ ] 3.2 失败用例：易失函数一次 `recalculate` 内一致
- [ ] 3.3 失败用例：未知函数 `#NAME?` + `CalcIssue`
- [ ] 3.4 实现扩展函数并补注册表

## 4. M2-d 时长与富文本

- [ ] 4.1 失败用例 `TimeSpan_test`：`[h]:mm:ss` / `[hh]:mm` / 100h / 跨日
- [ ] 4.2 失败用例 `RichText_test`：`<r><rPr>` 分段、粗体/颜色、无 rPr 合并
- [ ] 4.3 实现 `CellValue.TimeSpan`、`RichText` 与 sharedStrings 解析
- [ ] 4.4 往返：TimeSpan 写回数字 + 格式；富文本写回平坦化文本

## 5. 收尾

- [ ] 5.1 `cjpm test` 全绿，记录用例数（目标 ≥ 290）
- [ ] 5.2 README 中英、设计文档、verification.md
- [ ] 5.3 `openspec validate` + verify（CRITICAL 清零）

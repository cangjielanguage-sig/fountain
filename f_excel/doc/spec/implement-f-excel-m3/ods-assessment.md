# ods 可行性评估（M3-e）

> 日期：2026-10-31 ｜ 结论：**暂不实现**，M3 只做评估；接口层留出未来接入点。

## 1. 格式对照

| 维度 | xlsx（OOXML） | ods（ODF 1.2/1.3） |
|---|---|---|
| 容器 | ZIP + `[Content_Types].xml` | ZIP + `mimetype`（必须首个且不压缩） |
| 表内容 | `xl/worksheets/sheetN.xml` | `content.xml` 的 `table:table` / `table:table-row` / `table:table-cell` |
| 字符串 | `sharedStrings.xml`（共享表） | 单元格内直接文本 / `text:p`，无共享表 |
| 值类型 | `t="s"/"n"/"b"/"e"/"str"` | `office:value-type` + `office:value` / `office:boolean-value` |
| 公式 | `<f>` + 缓存 `<v>` | `table:formula="of:=..."`（OpenFormula 语法） |
| 日期 | 序列号 + `numFmt` | `office:date-value` ISO 8601 字符串 |
| 样式 | `styles.xml` 的 fonts/fills/borders/cellXfs | `styles.xml` 的 `style:style` 家族，自动样式 `table:style-name` |
| 合并 | `<mergeCells>` | `table:number-columns-spanned` / `table:number-rows-spanned` |
| 图片 | `xl/media` + DrawingML | `Pictures/` + `draw:frame` |
| 条件格式 | `<conditionalFormatting>` | `calcext:conditional-formats`（扩展命名空间） |

## 2. 可复用部分

| 模块 | 复用度 | 说明 |
|---|---|---|
| `f_zip` | 100% | 只需处理 `mimetype` 首条目与 Stored 压缩 |
| `f_xml` | 100% | 事件流 + DOM 都直接可用 |
| `CellValue` / `CellRef` / `RowData` | 100% | 值模型与坐标模型与格式无关 |
| `DateFormat` / `DateSerial` | 80% | 日期字符串 ↔ `DateTime` 需另写 ISO 解析 |
| `Worksheet` / `ExcelDocument` | 70% | 作为统一内存模型；需要格式探测与分派层 |
| 公式引擎 | 30% | OpenFormula 与 Excel 语法差异大（前缀 `of:=`、函数名相同但引用语法 `[.A1]`） |
| 样式模型 | 40% | 概念可映射，字段名与继承规则不同 |

## 3. 主要差异与风险

1. **公式语法**：OpenFormula 用 `[.A1]`、`[Sheet.A1]`，函数命名空间 `ORG.OPENOFFICE.*`；直接复用现有解析器会大面积误判。
2. **样式继承**：ods 的 `style:family` + `style:parent-style-name` 是继承链，与 xlsx 的扁平索引模型不同。
3. **日期/时长**：ods 用 ISO 字符串，不依赖序列号；写回需要双向转换。
4. **mimetype**：必须第一个条目且 `Stored`，现有 `ZipWriter` 支持但需专门分支。
5. **条件格式**：属于 `calcext` 扩展，非标准 ODF，跨工具兼容性差。

## 4. 工作量估算

| 子项 | 估算 |
|---|---|
| 格式探测 + 统一入口（`ExcelDocument.open` 自动分派） | 3–5 人日 |
| ods 读取（content/styles/meta，含值类型与合并） | 10–15 人日 |
| ods 写出（含 mimetype、样式、图片） | 10–15 人日 |
| 公式语法适配（只做常用函数子集） | 8–12 人日 |
| 测试与真实 LibreOffice 对照 | 8–10 人日 |
| **合计** | **40–60 人日** |

## 5. 结论

- **M3 不实现 ods 读写**；`ExcelDocument` 对 `.ods` 继续抛"不是有效的 xlsx 文件"。
- 触发条件：出现真实业务需求，且允许只支持"值 + 基本样式 + 合并"的子集（不含公式求值）。
- 若要做，先做**格式探测与只读**，再评估写出；不建议一次性做全量。

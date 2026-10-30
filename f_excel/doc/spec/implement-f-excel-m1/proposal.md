# Proposal: 实现 f_excel M1（xlsx 读写核心 + 流式读 + 流式写）

> **唯一入库副本**：`f_excel/doc/spec/implement-f-excel-m1/`。`openspec/` 已被根 `.gitignore` 忽略，
> 本地工作副本（`openspec/changes/implement-f-excel-m1/`）由 `openspec new change` 生成后用
> `rsync -a --delete f_excel/doc/spec/implement-f-excel-m1/ openspec/changes/implement-f-excel-m1/`
> 同步；校验 `diff -ru` 无输出（tasks 12.7）。
> **本目录是本变更的全部规划产物**，规格口径以本目录为准。

## Why

1. **`f_excel` 目前只有骨架**：`f_excel/src/f_excel.cj` 只导出一个 `F_EXCEL_VERSION` 常量，
   `cjpm.toml` 与中英 README 已就位，零实现、零用例。
   设计文档 `f_excel/doc/f_excel模块设计.md`（v0.8）已把决策全部落定——§13.1 共 32 条已定项、
   §13.2「仍需确认：暂无」，可以进入实施。
2. **前置模块已经就位，不再是风险**：设计 §12 的 P-1（先做 `f_xml` 与 `f_zip`）已完成——
   `f_zip` 有完整的 `ZipReader`（流 / 路径两种）与 `ZipWriter`（`add` / `addFileStream`），
   `f_xml` M1 已验收（303 用例全绿，含 `XmlPullParser` 事件流、DOM、`XmlWriter`）。
   本变更不需要改动这两者中的任何一行（实测清单见 `baseline.md`）。
3. **知识库 / 导入场景要的是"一行进来、处理完、丢掉"**，不是"整表进内存"。设计 §2.7 已论证
   `eager = false`（M3）解决不了这个问题：它只推迟"解析哪个 sheet"，单张 100 万行的表依旧
   要 30~50 MB 模型。流式读必须和核心取值逻辑一起落地——它复用同一套 `t` 类型表与
   sharedStrings，晚做等于把取值逻辑写两遍。
4. **流式写与流式读是同一闭环**：设计 §2.7.2 让读侧 `RowData`/`Cell` 直接喂给
   `ExcelWriter.writeSheet`，"读写同构、不需要中间转换"。两者分开做会先造一个中间类型再拆掉。
5. **M1 的出口必须可验证**：`P3`（生成一个 Excel 认可的文件）是设计 §12 里最关键的一步——
   在此之前所有工作都只是"自己读自己"。因此本变更的验收不是"能跑通"，而是
   **往返一致 + 真实 Excel 能打开**（`f-excel-roundtrip`）。

## What Changes

本变更覆盖**设计 M1（P0–P6）+ M2-e（流式写）+ M2-f（流式读）**三块，一次性把
"核心读写 + 两端常量内存"打通。**不含** M2-a~d（样式完整读写、公式引擎、`TimeSpan`、富文本）。

- **`CellRef` 与列号**：值类型 struct（`row`/`col` 1 起、`rowAbs`/`colAbs`）；`parse` / `parseRange` /
  `toString` / `toA1` / `==` / `<`；列字母 ↔ 列号双向转换（`A→1 … XFD→16384`）；
  超上限一律 `None`（2.4.2 全表）。**这是设计 §11.6 点名"最容易写错"的函数，先做、先测。**
- **`CellValue` 模型**：`Empty` / `Number(Float64)` / `Text(String)` / `Boolean(Bool)` /
  `Error(String)` / `Date(DateTime)` / `Formula(String, Option<CellValue>)`。
  `TimeSpan` 与富文本不在本变更（M2），`[h]:mm:ss` 按 `Date` 返回并记 warning（设计 5.3.1）。
- **`RowData` / `Cell`**：读写共用的行模型（`index` / `cells` / `height`），
  `cells` 按 `col` 升序、只含实际出现的单元格（稀疏行天然表达）。
- **包结构解析**：`[Content_Types].xml`、`_rels/.rels`、`xl/workbook.xml`、
  `xl/_rels/workbook.xml.rels` 的读取与生成；`r:id → 目标路径` 映射；
  `workbookPr.date1904` 判定。对外只有 `sheetNames()` / `sheet(name)`，不泄漏 rels 细节。
- **`sharedStrings`**：事件流解析 `<si>`（多段 `<r><t>` 拼接、`xml:space="preserve"`、
  跳过 `<rPh>` 注音）；`count`/`uniqueCount` 不做校验；索引越界 → `Empty` + warning。
- **worksheet 解析（整文档）**：按 `r` 属性定位行列（**不按出现顺序推断**）；
  `t` 九种取值（缺省/`n`/`s`/`inlineStr`/`str`/`b`/`e`/`d` + 未知值降级）；
  缺 `r` 时按"前一个 +1"推断并记 warning；`<row>` 无 `r` 同理；
  `mergeCells` 记录合并区域；`dimension` 只在存在时采用。
- **日期识别（默认开）**：内置格式 `14`–`22`/`45`–`47` 的 `numFmtId` 集合；
  自定义 `formatCode` 走"净化 → 是否日期"启发式（5.3.2），`m` 的月/分钟歧义按"紧邻 h 或 s"
  判定；1900 闰年 bug（serial 59/60/61 三分支，60 按 `Number` 保留 + warning）；
  1904 基准；`autoDetectDate=false` 时一律 `Number`；`loadStyles=false` 时自动降级 + warning。
- **生成最小可用包（`ExcelDocument.write`）**：`[Content_Types].xml` → `_rels/.rels` →
  `xl/workbook.xml` → `xl/_rels/workbook.xml.rels` → `sheetN.xml` → `xl/styles.xml`；
  文本走 `inlineStr`（默认，设计 2.6.6）；数字按**最短往返**十进制；`Float64` 整数值写
  `"1"` 而不是 `"1.0"`；日期值自动绑内置日期 `numFmtId`；合并单元格 `<mergeCells>`；
  多 sheet。
- **最小 `styles.xml`**：`fonts` 至少 1 条（只写 `<sz val="11"/>`）、
  `fills` 前两项必须是 `none` / `gray125`、`borders`/`cellStyleXfs`/`cellXfs`/`cellStyles`
  各至少一项（`builtinId="0"` 的 Normal）。M1 不做样式池、不做用户样式（见差异 3/4）。
- **`ExcelSheetStream`（流式读）**：`open(path)` / `open(input)`；`sheetNames()`；
  `rows(sheet)` / `rowsAt(index)` 返回 `RowReader <: Iterator<RowData>`；
  `Path` 输入走 `ZipReader(path)` 真流式；`InputStream` 输入默认落临时文件（`spool = true`）
  后同路径，`spool = false` 退化为全量缓冲并记 warning；逐行产出语义见 2.7.5
  （稀疏行不补空行、乱序照原样 + warning、`<row r="5"/>` 产出空 cells 行）；
  `mergedRanges()` 在流结束后才有值（2.7.6）；`close()` 幂等、删除临时文件。
- **`ExcelWriter`（流式写）**：`init(output, sheetNames)`（sheet 清单必须一次给全，2.6.2）；
  `writeSheet(name, rows: Iterator<RowData>)`；`finish()`。
  文本默认 `InlineStr`；行号必须**严格递增**（乱序抛 `ExcelException`，不静默排序）；
  单格文本 > 32767、行 > 1048576、列 > 16384 抛 `ExcelException`（不截断）；
  失败即残缺（`Failed` 状态后续调用一律抛，产物由调用方丢弃）；
  flush 粒度按 2.6.7（8 KB 文本缓冲满/行结束；**不**每行 flush `OutputStream`）。
- **`WorksheetXmlWriter`**：f_excel 自带的流式 XML 文本发射器（设计 2.6.7 已定），
  8 KB 缓冲、逐行拼 `<row>`/`<c>`；转义表见 4.4；**非法控制字符剔除 + warning**（不抛，
  与 `f_xml` 的 `Throw` 策略不同，理由见 `design.md` §6.8）。
- **往返测试**：`xlsx → 解析 → 模型 → 生成 → xlsx → 解析 → 模型` 逐单元格比对
  （值 + 类型），以及**流式 ↔ 整文档等价**（同一 fixture 两条通道逐行比对 `index`/`cells`）。
  生成侧另有一组结构断言（openpyxl 可读 / 部件齐全 / 条目顺序），
  以及"真实 Excel 打开不报修复"的人工验收清单。

## Impact

- **新增代码**：`f_excel/src/*.cj` 约 21 个文件，单包 `fountain::f_excel`。
- **新增测试**：`f_excel/src/*_test.cj`（与实现同目录，遵循仓库约定）。
- **依赖**：**不改**。`f_excel/cjpm.toml` 已声明 `f_base` / `f_log` / `f_util` / `f_xml` / `f_zip`；
  本变更实际使用 `f_base`（`BaseException`、`StringGenerator`）、`f_xml`、`f_zip`，
  `f_log` 与 `f_util` 保持"已声明但本变更不引用"（避免无谓改动）。
- **对外 API**：从「1 个常量」变为「约 25 个公开类型 / 6 个 `ExcelDocument` 构造重载 /
  3 个 `Worksheet` 单元格访问重载组」。无既有调用方，不存在破坏性变更。
- **不改动的模块**：`f_zip` / `f_xml` / `f_base` 在本变更内**不再改动**；它们的前置补强
  （`f_zip.openEntry`、`f_xml.XmlWriter` 增量接口）已于 2026-10-30 完成并合入 `sts/1.3.x`
  （`00ca5ed9` / `9066e1cd`，分别 145 / 389 用例全绿），本变更只消费它们。
- **文档**：`f_excel/README.md` / `README_en.md` 的能力表与用法章节按 M1 实况重写
  （当前写的是"骨架已建立"）；`f_excel/doc/f_excel模块设计.md` 按 `design.md` §8 的差异表
  回填（版本升到 v0.9）；新增 `f_excel/doc/build-warnings.md` 记录 `cjpm build` 的告警处置
  （沿用 `f_xml` 的做法）。
- **磁盘**：`ExcelSheetStream.open(input)` 在 `spool = true` 时产生一份与包等大的临时文件，
  `close()` 删除；异常路径 `try-finally` 保证清理。
- **性能**：不在本变更设门禁。验收只要求"内存与行数无关"（流式两端）与
  "1 万行 × 10 列往返 < 5 s"这一条粗粒度可观测指标（设计 §9.3 的 100~300 ms 量级留 20 倍余量）。

## 与设计文档的差异登记

设计文档有 9 处无法字面落地，或与仓库现状冲突。本变更按下列方式实施（逐条理由见
`design.md` §8）：

| # | 设计原文 | 问题 | 本变更的处理 |
|---|---|---|---|
| 1 | §2.1.4 `ZipReader(path: Path)` | `f_zip` 实测只有 `ZipReader(path: String)` 与 `ZipReader(input: InputStream)` | `ExcelDocument.init(path: Path)` 内部转 `path.toString()` 传给 `f_zip`；`f_excel` 对外仍收 `Path` |
| 2 | §2.5 `ExcelReadOptions` 含 `eager` 与 `loadTheme` | `eager=false` 是 M3（按需解析）；`loadTheme` 依赖 M2 的 theme 解析 | M1 不含这两个字段——不做"声明了但无声失效"的选项 |
| 3 | §2.6 `Cell(col, value, style!: ?CellStyle)` | `CellStyle`/`Font`/`Fill` 的完整模型是 M2-a；M1 兑现不了字体/填充，提前暴露会**静默丢样式** | M1 用 `Cell(col, value, numberFormat!: ?NumberFormat)`；M2-a 改为 `?CellStyle`（此时才第一次有调用方） |
| 4 | §2.6.4 样式池 + `styles.xml` 后写 | 样式池存在的理由是"第 100 万行才出现新样式"；M1 没有用户样式，池里最多 4 条固定项 | M1 写**固定最小样式表**，`s` 索引是编译期常量；样式池随 M2-a 引入，届时再改为后写 |
| 5 | §8.1 XML 一律交给 `f_xml` | 原计划里 `XmlWriter` 只有整树写，worksheet 需自写发射器；该前置已补齐（f_xml v1.2 增量接口） | worksheet 直接使用 `f_xml.XmlWriter` 增量接口；f_excel 只保留控制字符剔除、数字格式化与 Excel 上限校验 |
| 6 | §2.6 `SheetWriteOptions` 五项 | `columns`/`freezePane` 属 M2（行高列宽/视图）；`maxCellStyles`/`styleBytesWarnThreshold` 依赖样式池 | M1 只有 `dimension`；其余随 M2-a/M2-e2 引入 |
| 7 | §2.7.2 `RowReader` 无 `mergedRanges`，§2.7.6 写 `ExcelSheetStream.mergedRanges()` | 两处口径需消歧：合并区域属于"哪张表" | 挂在 **`RowReader.mergedRanges()`**（流结束后有值，流中为空数组）+ `ExcelSheetStream.lastMergedRanges(sheet)` 便捷读；同一流上两个 reader 顺序交替时以各自 reader 为准 |
| 8 | §2.2 `ExcelDocument.properties: DocumentProperties` | M1 无任何字段可填，且 `docProps/core.xml` 是可选的（§4.1 第 7 步） | M1 不含 `DocumentProperties`，M2 随样式/公式补，届时向后兼容 |
| 9 | §2.6.6 `StringWriteMode`（`InlineStr` / `SharedStrings`） | `SharedStrings` 要全量去重表，与"两端常量内存"是两套取舍，属 M2-e 收尾 | M1 不提供该枚举，只实现 `inlineStr`；M2-e 加回时是新增而非改动 |

## Out of Scope

- **M2-a 样式完整读写**：`Font`/`Fill`/`Border`/`Alignment`/`Protection`/`Color`/theme/tint/
  `dxfs` 的存取与 `styleOf`/`setStyle`/`stylePool*` 一律不写。
- **M2-b/c 公式引擎**：不求值、不建依赖图、不实现任何函数；`Formula` 只保留原文 + 缓存值。
- **M2-d `TimeSpan` 与 `RichText`**：`[h]:mm:ss` 按 `Date` + warning；富文本只平坦化成
  `Text(String)`，不提供 `richText()`。
- **M2-e 完整形态**：样式池、`SheetWriteOptions` 的列宽/冻结/上限、`SharedStrings` 写出模式
  （M1 只实现 `InlineStr`；`StringWriteMode.SharedStrings` 留到 M2-e 收尾时再做，
  因为它需要全量去重表，与"两端常量内存"是两套取舍）。
- **M3**：`eager = false` 按需解析、`sharedStrings` 磁盘索引、紧凑单元格结构、ods。
- **M4**：条件格式的语义求值不做；**`<conditionalFormatting>` 也不保留**——设计 §6.6.2 的
  "整块原样保留"策略需要 `Worksheet` 上挂一份原始规则模型，M1 不建这个模型。
  后果：含条件格式的文件往返后该块丢失，这只影响显示，不影响单元格值。
  这条必须写进 README 的"已知缺口"。
- **不做**：图表 / 图片 / 数据透视表 / 批注 / 表格（`<table>`）/ 数据验证。
- **性能门禁**：只记录实测，不设阈值（设计 §9 的预估留给 M3 优化时对照）。

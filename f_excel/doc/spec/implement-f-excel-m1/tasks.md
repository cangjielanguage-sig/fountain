# Tasks — implement-f-excel-m1

> **唯一入库副本**：`f_excel/doc/spec/implement-f-excel-m1/`。本地工作副本
> `openspec/changes/implement-f-excel-m1/` 由 `openspec new change` 生成后
> `rsync -a --delete f_excel/doc/spec/implement-f-excel-m1/ openspec/changes/implement-f-excel-m1/`
> 同步，`diff -ru` 必须无输出（12.7）。
>
> **TDD**：每个任务先写失败用例，再写实现。每个任务完成即独立提交（仓库约定
> 「有单元测试后再提交」）。
> **分支**：在本 worktree 的当前分支开发（开工前 `git branch --show-current` 确认、`git pull`）；
> **不新建**分支、**不自动 merge**、**不自动 push**——验收通过后由用户确认再按仓库流程
> `git merge --no-ff` 合回主干。
> **边界**：只改 `f_excel/`；不动 `f_base` / `f_xml` / `f_zip` / `f_log` / `f_util`；不新增依赖。
> **范围**：只做 M1 + M2-e + M2-f。任何样式池、公式求值、`TimeSpan`、`RichText`、`eager` 的代码
> 都不写（包括"先留个空壳"）。

## 0. 前置

- [x] 0.1 记录基线：`f_excel` 的 `cjpm build` / `cjpm test` 现状（预期：build 通过、0 用例）；
  `git branch --show-current` 记录当前分支。
- [x] 0.2 建包骨架：`f_excel/src/f_excel.cj` 保留 `F_EXCEL_VERSION` 并补包文档；
  确认 `f_excel/cjpm.toml` 的 5 项依赖可直接 import（`f_base` / `f_xml` / `f_zip`），
  并确认 `f_zip.ZipWriter.openEntry` 与 `f_xml.XmlWriter.startElement` 可编译（前置已合入 sts），
  `cjpm build` 通过。
- [x] 0.3 **R1 实测**（`Float64.toString()`）：打印 `1.0` / `0.1` / `1e20` / `1.0/3.0` /
  `-0.0`，`Float64.parse` 回比；结论回填 `design.md` §10.1，决定 `formatNumber` 是否需要
  自实现（§6.8）。
- [x] 0.4 **R2 实测**（`DateTime` ↔ 天数）：查 `std.time` 可用 API，验证同一日期在不同
  `TZ` 下换算结果相同；结论回填 §10.1。
- [ ] 0.5 **R3 + R4 实测**（临时文件 API、`cjpm test` 工作目录）：结论回填 §10.1，
  决定 `spool` 与 `testdata/` 的路径解析。
- [x] 0.6 建立 `f_excel/testdata/` 与 `f_excel/src/fixtures.cj`（内部夹具工厂：用
  `f_zip.ZipWriter` 拼最小包）。**先写**工厂的 3 个用例（最小表 / 带前缀表 / 空 sheet）
  证明工厂可用，再往下走。

## 1. P0 小函数（设计 §11.6 点名）

- [x] 1.1 **先写测试** `src/CellRef_test.cj`：列号互转 8 组边界
  （`A→1, Z→26, AA→27, AZ→52, BA→53, ZZ→702, AAA→703, XFD→16384`）+ 反向；
  `columnLetters(16385)` 抛 `ExcelException`；`columnIndex("1")` 返回 `None`。
  → 实现 `src/CellRef.cj` 的 `columnIndex` / `columnLetters`。
- [x] 1.2 **先写测试**：`CellRef.parse` 全表 12 行（`A1` / `a1` / `$A$1` / `$A1` / `A$1` /
  `A01` / `A` / `1` / `A1B` / `XFE1` / `A1048577` / `A0` / `""`）。
  → 实现 `parse`（§6.2 的线性扫描状态机）。
- [x] 1.3 **先写测试**：`parseRange`（正常 / 单格 / 倒置 / 多冒号 / 一侧非法）；
  `toString` / `toA1` 的四种 `$` 组合；`==` 与 `<`（先行后列）。
- [x] 1.4 **先写测试** `src/CellValue_test.cj`：七个分支的构造与 `toString`；
  `Formula` 原文不带 `=`；`TimeSpan` **不存在**（编译期保证，用注释说明）。
  → 实现 `src/CellValue.cj` 的 `CellValue` + `NumberFormat`（含显式 `==`）。
- [x] 1.5 **先写测试** `src/RowData_test.cj`：`RowData` / `Cell` 的值语义（拷贝不改原件）、
  `numberFormat` 默认 `None`。→ 实现 `src/RowData.cj`。
- [x] 1.6 **先写测试** `src/ExcelException_test.cj`：`ExcelException <: BaseException`
  可被 `catch (e: Exception)` 捕获、`message` 可读、`caused` 链保留；
  `ExcelWarningKind` 的 `==` 显式实现（`Equatable`）。→ 实现 `src/ExcelException.cj`。

## 2. P1 包结构与 workbook

- [x] 2.1 **先写测试** `src/PackageReader_test.cj`：最小包 → `sheetNames()` 正确；
  带前缀（`<x:workbook>`）等价；缺 `workbook.xml` 抛「缺少 workbook.xml」；
  缺 rels 时 sheet 被跳过 + `SheetSkipped`；rels 指向不存在部件 + `SheetEntryMissing`。
  → 实现 `src/PackageReader.cj`。
- [x] 2.2 **先写测试** `src/Worksheet_test.cj`：三组 `cell`/`setCell`/`clearCell` 重载一致；
  越界写抛、越界读 `None`；`rowCount`/`colCount`/`dimension`；`rowValues` 稀疏；
  `range` 对齐与空位填充；`addSheet` 的四种非法名。→ 实现 `src/Worksheet.cj`。
- [x] 2.3 **先写测试** `src/ExcelDocument_test.cj`：`init()` 的默认态（1 个 `Sheet1`、
  不发 I/O）；`sheet`/`sheetAt`/`sheetCount`/`addSheet`/`removeSheet`/`renameSheet`；
  零字节输入抛「不是有效的 xlsx 文件」。→ 实现 `src/ExcelDocument.cj` 的构造与 sheet 管理。

## 3. P2 sharedStrings 与类型表

- [ ] 3.1 **先写测试** `src/SharedStringTable_test.cj`：单 `<t>`；多段 `<r><t>` 拼接；
  `xml:space="preserve"` 保留首尾空白；**无该属性时也保留**；`<rPh>` 与其内部 `<t>` 跳过；
  `count`/`uniqueCount` 不参与校验（乱填照样读）。
  → 实现 `src/SharedStringTable.cj`。
- [ ] 3.2 **先写测试** `src/WorksheetParser_test.cj`（前半）：类型表全 8 行
  （缺省/`n`/`s`/`inlineStr`/`str`/`b`/`e`/`d`）+ 未知 `t` 降级；
  `t="s"` 越界 → `Empty` + warning；`<v>1,5</v>` → `Text` + warning；
  `t="str"` 按 `Text` 而不是 `Number`。→ 实现 `src/WorksheetParser.cj` +
  `src/SheetRowSink.cj` 的取值部分。
- [ ] 3.3 **先写测试**（后半）：稀疏性（`<row r="100"><c r="Z100">` 只落一格）；
  `<c>` 缺 `r` 按前一列 +1 + `MissingCellRef`；`<c r>` 非法同理；
  `<row>` 缺 `r` 按上一行 +1 + `MissingRowIndex`；`loadSharedStrings=false` 时 `t="s"` → `Empty`。
- [ ] 3.4 **先写测试**：`Some(Empty)` 与 `None` 的区分（`<c r="A1" s="3"/>`）。

## 4. P3 写最小可用包（**本变更最关键**）

- [ ] 4.1 **先写测试** `src/PackageWriter_test.cj`：`[Content_Types].xml` 是第一个条目；
  每个 worksheet 有 Override；`r:id` 带前缀且根声明了 `xmlns:r`；
  生成物能被 `f_xml.XmlParser` 逐份解析。→ 实现 `src/PackageWriter.cj` 的前四个部件。
- [ ] 4.2 **先写测试** `src/SheetXmlWriter_test.cj`（事件与语义）：控制字符剔除 +
  `ControlCharStripped`（一格多个字符只记一条）；文本上限 32767（rune）与公式上限 8192；
  生成的 XML 能被 `f_xml.XmlParser` 解析且单元格值正确；特殊字符只出现 `f_xml` 标准转义。
  → 实现 `src/SheetXmlWriter.cj`（调用 `f_xml.XmlWriter` 增量接口，不自带转义表）。
- [ ] 4.3 **先写测试**（数字）：`1.0 → "1"`、`0.1 → "0.1"`、`1e20`、`-3.141592653589793`、
  `NaN`/`±Inf` 抛。→ 实现 `formatNumber`（按 0.3 的实测结论定策略）。
- [ ] 4.4 **先写测试**（值）：`Empty`/`Boolean`/`Error`/`Text`/`Formula` 的 XML 形态；
  非法错误码（`#FOO!`）抛；`<t xml:space="preserve">` 只在首尾有空白时出现；
  文本上限 32767（rune）与公式上限 8192。→ 补齐 `SheetXmlWriter`。
- [ ] 4.5 **先写测试** `src/ExcelDocument_write_test.cj`：`write(output)` 不关调用方的流；
  `write(path)` 后能重新打开；含 `dimension` / 不含 `dimension` 两种形态；
  空 sheet 也写 `<sheetData/>`。→ 实现 `ExcelDocument.write`。
- [ ] 4.6 **人工验收（P3 出口）**：生成的文件用 Excel / WPS / LibreOffice 打开不报"需要修复"，
  中文与数字正常。结论记入 `verification.md`；不通过则回到 4.1–4.5。

## 5. P4 日期

- [ ] 5.1 **先写测试** `src/DateFormat_test.cj`：内置集合 `14..22`/`45..47`；
  自定义净化（去 `[...]`/`"..."`/`\x`/`_x`/`*x`）；
  §5.3.3 的 8 个"非日期"样本全部判 `Number`；
  `m` 歧义（`yyyy-mm-dd` vs `h:mm`）；
  `[h]` 判定表 10 行（`[h]:mm:ss` / `[hh]:mm` / `[Red][h]:mm` / `[Blue][mm]:ss` /
  `[Red]0.00` / `[$-409]h:mm` / `[$-409][h]:mm` / `[>=100]0.00` / `[h:ss]` / `[Color10]`）。
  → 实现 `src/DateFormat.cj` + `src/StylesLite.cj`（只读 `cellXfs[i].numFmtId`）。
- [ ] 5.2 **先写测试** `src/DateSerial_test.cj`：1900 基准 serial `1→1900-01-01`、`59→1900-02-28`、
  `60→Number` + `DateSerial60`、`61→1900-03-01`；1904 基准 `0→1904-01-01`；
  带时间（`45231.5`）；反向（`DateTime → serial`）逐项还原；`TZ` 变化不影响结果（按 0.4 结论）。
  → 实现 `src/DateSerial.cj`。
- [ ] 5.3 **先写测试**：`autoDetectDate=false` → `Number`；`loadStyles=false` 且
  `autoDetectDate=true` → 自动降级 + `AutoDetectDateDisabled`；`date1904` 选项与
  `workbookPr` 相反 → 以选项为准 + `DateBaseMismatch`；`numFmtId=46` → `Date` +
  `UnsupportedTimeFormat`。
- [ ] 5.4 **先写测试**（写侧）：`Date` 三档（`14` / `22` / `20`）的 `s` 与 `<v>`；
  调用方给非日期格式时不覆盖 + `NumberFormatNotSupportedInM1`。

## 6. P5 合并单元格与多 sheet

- [ ] 6.1 **先写测试** `src/Merge_test.cj`：`<mergeCells>` 解析进 `Worksheet`；
  `mergedRangeAt` 跨行列（`A1:C3`）；`mergedValue` 对区域外返回自身值；
  `merge` 重叠抛；`unmerge` 找不到返回 `false`。
- [ ] 6.2 **先写测试**：写出侧 `<mergeCells>` 在 `</sheetData>` 之后、`count` 正确、
  区域内只写左上角值。
- [ ] 6.3 **先写测试**：2 个 sheet 的 `workbook.xml` 顺序与 `sheetId`/`r:id` 对应；
  `date1904` 只在为真时写。

## 7. P6 流式读

- [ ] 7.1 **先写测试** `src/ExcelSheetStream_test.cj`（入口）：`open(path)` / `open(input)`
  的 `sheetNames()` 一致；`rows` 名字不存在 → `None`；`rowsAt` 越界 → `None`；
  不是 ZIP / 缺 workbook 两种异常；`spool=false` 记 `SpoolDisabled`；
  `spoolDir` 不可写抛且消息含两个出路。
  → 实现 `src/ExcelSheetStream.cj` 的打开与装载。
- [ ] 7.2 **先写测试**（行语义）：稀疏行；`<row r="5"/>` 空 cells；缺行不补；
  乱序照原样 + `RowOrderViolation`；`maxRows`/`maxCols` 截断；
  `loadRowHeight=false` 时 `height` 为 `None`。→ 实现 `RowReader.next()`。
- [ ] 7.3 **先写测试**（生命周期）：`next()` 幂等（`None` 之后仍 `None`）；`close()` 后
  `next()` 抛「流已关闭」；提前 `close()` 后能重新 `rows(sheet)` 从第 1 行开始；
  `close()` 幂等；`close()` 删除 spool 临时文件；坏 sheet 抛异常后仍能读下一个 sheet。
- [ ] 7.4 **先写测试**（合并时序）：流中 `mergedRanges()` 为空 + `MergedRangesUnavailable`；
  读到 `None` 后有值；提前 `close()` 仍为空；`lastMergedRanges(sheet)` 同上。

## 8. P7 流式写

- [ ] 8.1 **先写测试** `src/ExcelWriter_test.cj`（构造）：空清单 / 重名 / 非法名抛；
  构造后已写出 4 个元数据条目（用 `ZipReader` 读中途字节会被 `ZipException` 挡住——
  改为检查底层计数流的字节前缀含 `[Content_Types].xml`）。
  → 实现 `src/ExcelWriter.cj` 的构造。
- [ ] 8.2 **先写测试**（写入）：名字顺序不一致抛；迭代器消费次数 = 行数 + 1；
  行号非严格递增抛（含重复）；`col` 越界 / 非升序抛；`rowsWritten` 每 sheet 归零。
  → 实现 `writeSheet`。
- [ ] 8.3 **先写测试**（输出一致）：同一组 `RowData` 经 `ExcelWriter` 与
  `ExcelDocument.write`，两个 `sheet1.xml` 解压内容**逐字节相同**。
- [ ] 8.4 **先写测试**（状态机）：`finish()` 前读字节 → `ZipException`；
  中途异常后 `writeSheet`/`finish` 都抛且消息含原始原因；`finish()` 后不可再用；
  `finish()` 写出的包能读回全部行。
- [ ] 8.5 **先写测试**（flush 粒度 + 直连）：1 万行经计数 `OutputStream`，`write` 次数远小于
  1 万；`RowReader` 直接喂 `writeSheet` 的"大表复制"用例。

## 9. P8 往返与结构

- [ ] 9.1 **先写测试** `src/RoundTrip_test.cj`：七种值各 2 格往返逐格相等；
  中文/emoji/`& < > " '`/首尾空格/`\r\n` 往返逐字符相等；数字精度 5 组；
  日期两种基准；2 sheet + 2 合并区域。
- [ ] 9.2 **先写测试** `src/ChannelParity_test.cj`：5 份 fixture 分别走整文档与流式通道，
  逐行逐格比对；日期/公式在两条通道一致；`autoDetectDate=false` 在两条通道一致。
- [ ] 9.3 **先写测试** `src/PackageStructure_test.cj`：六类必需部件齐全；
  每个 xml/rels 能被 `f_xml` 解析；`[Content_Types].xml` 覆盖完整（无遗漏无多余）；
  无悬空 `r:id`；`fills[0]=none` / `fills[1]=gray125` / `cellXfs[0].numFmtId=0` /
  `cellStyles` 含 `builtinId="0"`；所有 `s` 索引 `< cellXfs.count`。
- [ ] 9.4 **先写测试**（外部工具）：`testdata/` 的 4 份真实样本能被读出预期值；
  openpyxl 回读（`python3` 可用时执行；不可用时 **fail 并提示安装命令**，不 skip）。

## 10. 收尾

- [ ] 10.1 `cjpm build` 的 WARNING 逐条处理：能改的改，改不了的记录到
  `f_excel/doc/build-warnings.md`（沿用 `f_xml` 的做法）。
- [ ] 10.2 `f_excel/README.md` / `README_en.md` 按 M1 实况重写：能力表、用法（读 / 写 /
  流式读 / 流式写 / 大表复制）、三条已知缺口（合并区域时序、`[h]` 在 M1 是 `Date`、
  无样式）。
- [ ] 10.3 `f_excel/doc/f_excel模块设计.md` 按 `design.md` §8 的 9 项差异回填，版本升到 v0.9，
  章末留一条变更记录（"v0.9：M1 落地时与文档不符之处"）。
- [ ] 10.4 把 `design.md` §10 的 R1–R4 实测结论回填到 §10.1。

## 11. 验收

- [ ] 11.1 `cjpm clean` 后 `cjpm build` + `cjpm test` 全绿，记录用例总数。
- [ ] 11.2 生成 `verification.md`：结果总览、P3 与最终两轮人工 Excel 验收结论
  （含 Excel 版本）、遗留项（应为空或明确移交 M2/M3）。
- [ ] 11.3 把 `verification.md` 的结论逐条对照 `proposal.md` 的 What Changes，
  确认没有"写了没做"的条目。

## 12. 产物一致性

- [ ] 12.1 `openspec new change implement-f-excel-m1` 生成本地副本（需 OpenSpec CLI）。
- [ ] 12.2 `rsync -a --delete f_excel/doc/spec/implement-f-excel-m1/ openspec/changes/implement-f-excel-m1/`
- [ ] 12.3 `diff -ru f_excel/doc/spec/implement-f-excel-m1 openspec/changes/implement-f-excel-m1`
  无输出。
- [ ] 12.4 六份 spec 的 capability 目录名与 `design.md` §2 的范围表一一对应，无孤儿文件。
- [ ] 12.5 `proposal.md` 的差异表（9 项）与 `design.md` §8（9 项）逐条同号同结论。
- [ ] 12.6 `tasks.md` 里每个 `→ 实现` 都指向 `design.md` §4 的文件清单中存在的文件名。
- [ ] 12.7 提交前再跑一次 12.3；`openspec validate implement-f-excel-m1` 通过（有 CLI 时）。

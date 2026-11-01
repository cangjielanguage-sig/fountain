# Verification — implement-f-excel-m1

> 验证时间：2026-10-30 ｜ 分支 `feature/f_excel` ｜ 构建环境：融合开发引擎（aarch64 Linux）+
> 兼容 SDK `1.3.0-alpha.20261016001051`（鸿蒙本机 20261023 nightly 与 sts/1.3.x 的 `Exception` API 不兼容）。
> 自动化与外部工具验收均在此环境完成。

## 1. 自动化结果

| 项 | 结果 |
|---|---|
| `cjpm build` | 通过（f_excel 源码 0 warning；依赖模块既有 warning 未改动） |
| `cjpm test`（f_excel） | **86 通过 / 0 失败 / 0 错误** |
| `cjpm test`（f_zip） | 145 通过（含新增 `openEntry` 10 条） |
| `cjpm test`（f_xml） | 390 通过（含增量写入 14 条） |
| `openspec validate implement-f-excel-m1` | 通过（仅「需求正文 > 500 字」格式建议，见 4） |

用例分布：`CellRef` 7、`CellValue/RowData/异常` 6、`PackageReader` 5、`Worksheet` 5、
`ExcelDocument` 4、`SharedStringTable` 5、`WorksheetParser` 10、`Writer` 10、`Date` 11、
`StreamRead` 8、`ExcelWriter` 7、`RoundTrip/PackageStructure` 8。

## 2. 外部工具验收（openpyxl 3.1.5）

用模块自身写出一份样本（2 sheet、文本/数字/日期/布尔/错误/公式、合并区域、中文与 emoji），
再用 openpyxl 回读：

```
sheets ['Sheet1', '二']
A1 名称  B1 0.1  C1 2024-02-29 00:00:00  D1 True  E1 #N/A  F1 =B1*2
merged ['A2:C2']
A2 合并  sheet2 中文😀
```

结论：部件结构、值、日期类型、合并区域、公式原文、中文/emoji 全部正确。

## 3. 人工验收（待用户执行）

以下两项需要 Windows / macOS 上的真实 Excel（或 WPS / LibreOffice），本环境无法自动完成：

- [ ] 用 Excel 打开 `write()` 生成的文件，不出现「需要修复」
- [ ] 日期显示为日期（不是 5 位整数）、合并单元格显示正确、中文不乱码

样本生成方法：任一 `ExcelDocument` / `ExcelWriter` 产物（结构已由 openpyxl 验证）。

## 4. 已知告警与遗留

| 项 | 说明 |
|---|---|
| `openspec validate --strict` | 7 条「Requirement 正文 > 500 字」的格式建议；内容与场景完整，未拆条 |
| 真实 Excel 人工验收 | 见第 3 节，未执行 |
| M2-a 样式 | 只写日期 `numFmtId` 与最小 `styles.xml`；字体/填充/边框未实现 |
| M2-b/c 公式 | 只保留原文 + 缓存，不求值 |
| M2-d 时长/富文本 | `[h]` 按 `Date` + 告警；富文本平坦化 |
| M3 按需解析 / 磁盘索引 | 未实现（流式读已覆盖大表场景） |
| M4 条件格式 | 不保留 |
| `sharedStrings` 写出 | 只写 `inlineStr` |

## 5. 与 proposal 的逐条对照

| proposal「What Changes」 | 落点 |
|---|---|
| `CellRef` / 列号 / 七种值 | `CellRef.cj` / `CellValue.cj`，用例 `CellRef_test` / `CellValue_test` |
| 包结构解析 | `PackageReader.cj`，用例 `PackageReader_test` |
| sharedStrings | `SharedStringTable.cj`，用例 `SharedStringTable_test` |
| worksheet 解析（整文档） | `WorksheetParser.cj`，用例 `WorksheetParser_test` |
| 日期识别 | `StylesLite.cj` / `DateFormat.cj` / `DateSerial.cj`，用例 `Date_test` |
| 最小可用包生成 | `PackageWriter.cj` / `SheetXmlWriter.cj` / `ExcelDocument.write`，用例 `Writer_test` |
| 最小 `styles.xml` | `PackageWriter.stylesXml`，用例 `Writer_test.packageLayout` / `PackageStructure_test` |
| 流式读 | `ExcelSheetStream.cj`，用例 `StreamRead_test` |
| 流式写 | `ExcelWriter.cj`，用例 `ExcelWriter_test` |
| 往返 / 通道等价 / 结构 | `RoundTrip_test` / `StreamRead_test.channelParityWithDocument` / `PackageStructure_test` |

没有「写了没做」的条目。

# Spec Delta — f-excel-roundtrip

## ADDED Requirements

### Requirement: 模型往返一致

```
xlsx → 解析 → 模型 → 生成 → xlsx → 解析 → 模型
```

两次解析得到的模型 SHALL 在**每个单元格的值与类型**上完全一致
（`Number` 逐位相等，`Text` 逐字符相等，`Date` 到秒相等，`Boolean`/`Error` 相等，
`Formula` 原文与缓存值相等）。允许的差异只有：本变更明确不支持的特性
（样式、富文本、`TimeSpan`、`sharedStrings` 复用、`docProps`）。

#### Scenario: 覆盖七种值

- **WHEN** 造一个含 `Empty`/`Number`/`Text`/`Boolean`/`Error`/`Date`/`Formula` 各至少 2 格的表，走完整往返
- **THEN** 两次模型逐格相等

#### Scenario: 中文与 emoji

- **WHEN** 文本含中文、emoji、`& < > " '`、首尾空格、`\r\n`
- **THEN** 往返后文本逐字符相等

#### Scenario: 数字精度

- **WHEN** 写入 `0.1`、`1.0`、`1e20`、`-3.141592653589793`、`1/3`
- **THEN** 往返后与写入值逐位相等（`1.0` 不变成 `Number(1.0)` 之外的东西，也不变成 `Text`）

#### Scenario: 日期两种基准

- **WHEN** 分别用 `date1904 = false` / `true` 造表并往返
- **THEN** 两次都是 `Date`，且日期到秒相等

#### Scenario: 多 sheet 与合并

- **WHEN** 2 个 sheet、其中一个有 2 个合并区域
- **THEN** 往返后 sheet 名、顺序、合并区域列表都一致

### Requirement: 流式与整文档必须等价

同一文件分别用 `ExcelDocument` 与 `ExcelSheetStream` 读，逐行比对 `RowData.index` 与
`RowData.cells`（列号 + 值 + 类型）SHALL 完全一致。允许的差异只有流式通道拿不到的语义
（`mergedRanges()` 的可用时机，`f-excel-stream-read` 已单列）。

#### Scenario: 同一 fixture 两条通道逐行一致

- **WHEN** 对 5 份 fixture 分别走两条通道，逐行比对
- **THEN** 行数、行号、每格列号与值全部相等

#### Scenario: 日期与公式在两条通道一致

- **WHEN** fixture 含日期单元格与带缓存的公式
- **THEN** 两条通道得到的 `Date` 与 `Formula` 完全相同

#### Scenario: 读取选项在两条通道语义一致

- **WHEN** `autoDetectDate = false` 分别用在两条通道
- **THEN** 两条通道都把日期格返回为 `Number`

### Requirement: 生成物的结构合法性

生成物 SHALL 满足：

1. `f_zip.ZipReader` 能打开，条目名与 `f-excel-writer` 的清单一致；
2. 每个 `.xml` / `.rels` 部件都能被 `f_xml.XmlParser` 解析（良构）；
3. `[Content_Types].xml` 覆盖所有部件（无遗漏、无多余 Override）；
4. 每个 `<sheet r:id>` 都能在 `xl/_rels/workbook.xml.rels` 里解析到存在的部件；
5. `styles.xml` 的 `fills[0]=none`、`fills[1]=gray125`、`cellXfs[0].numFmtId=0`、
   `cellStyles` 含 `builtinId="0"`；
6. 每个单元格的 `s` 索引 `< cellXfs` 长度。

#### Scenario: 部件齐全

- **WHEN** 生成含 1 个 sheet 的文档
- **THEN** 6 类必需部件都存在，且能被 `f_xml` 逐份解析成功

#### Scenario: 无悬空 r:id

- **WHEN** 遍历 `workbook.xml` 的 `<sheet r:id>`
- **THEN** 每个 id 在 rels 里有且仅有一条目标，目标部件存在

#### Scenario: s 索引不越界

- **WHEN** 遍历所有 worksheet 的 `s` 属性
- **THEN** 每个值都 `< cellXfs.count`

### Requirement: 外部工具可读

生成物 SHALL 能被 **openpyxl** 打开并把值读回来（自动化，CI 可用时执行；缺失时 fail 并提示
安装命令，不 skip），也 SHALL 能被 **LibreOffice headless** 转成 CSV 而不报错（人工/可选）。

#### Scenario: openpyxl 回读

- **WHEN** 用 openpyxl 打开生成物，遍历 `sheet.cell(row, col).value`
- **THEN** 值与类型与模型一致（中文不乱码、日期是 `datetime`）

### Requirement: 真实 Excel 的人工验收

以下四条 SHALL 在发布前由人工完成并记录在 `verification.md`：

| # | 验收 | 判据 |
|---|---|---|
| 1 | Excel 打开不报"需要修复" | 无任何修复提示 |
| 2 | 中文显示 | 中文不乱码、不变成 `?` |
| 3 | 日期显示 | 显示为日期，不是 5 位数字 |
| 4 | 合并单元格 | 跨列/跨行区域显示正确 |

#### Scenario: 记录留档

- **WHEN** 人工验收完成
- **THEN** `verification.md` 里有四条结论与所用 Excel 版本

### Requirement: 夹具与样本策略

| 类别 | 来源 | 是否入库 |
|---|---|---|
| 现场构造的最小包 | 测试内用 `f_zip.ZipWriter` 拼字符串部件 | 不入库（代码即夹具） |
| 真实生成器样本（Excel / LibreOffice / WPS / openpyxl 各 1） | 手工制作 | 入库，单份 ≤ 20 KB，放 `f_excel/testdata/` |
| 超大表（10 万行以上） | 测试内生成 | 不入库 |

现场构造的夹具 SHALL 覆盖：命名空间前缀差异（`<x:row>`）、缺 `r`、乱序行、稀疏行、
`inlineStr` 与 `t="s"` 混用、`<mergeCells>`、1904 基准、`[h]:mm:ss`、带缓存的公式。

#### Scenario: 前缀夹具

- **WHEN** 夹具用 `<x:worksheet xmlns:x="…"><x:sheetData><x:row …>`
- **THEN** 解析结果与无前缀版本完全相同

#### Scenario: 样本目录按需跳过

- **WHEN** `f_excel/testdata/` 不存在（例如精简检出）
- **THEN** 依赖它的用例 fail 并提示重新检出，不静默 skip；现场构造的用例照常跑

# Baseline — implement-f-excel-m1 的起点与依赖实测

> 记录时间：2026-10-30（本 worktree `f_excel`）。全部结论来自**读源码**，不是查文档；
> 每条都带 `文件:行`，实施时若发现不符，直接回填本文并记一条修正。
>
> 用途：设计文档 §2 对 `f_zip` / `f_xml` 的假设必须逐条成立才敢开工。设计 §12 的 P-1
> （「先完成 `f_xml` 与 `f_zip`」）已完成，本文把"能用的部分"和"形状不一样的部分"钉住。

## 1. 被实施模块的现状

| 项 | 实测 |
|---|---|
| 源码 | `f_excel/src/f_excel.cj` 只有 `public let F_EXCEL_VERSION = "0.1.0"`，无其他声明 |
| 用例 | **0 条**（无 `*_test.cj`） |
| 依赖声明 | `f_base` / `f_log` / `f_util` / `f_xml` / `f_zip` 五项已就位（`f_excel/cjpm.toml:1-6`），本变更**不改**该文件 |
| 工作区 | 根 `cjpm.toml:16` 已把 `f_excel` 作为 workspace member |
| 文档 | `README.md` / `README_en.md` 描述的是目标能力，标着"骨架已建立" |
| 版本 | `cjpm.toml:19` `version = "1.3.17"`，`F_EXCEL_VERSION = "0.1.0"` —— 两者不一致，本变更不动（属版本策略问题，不是本变更范围） |

## 2. `f_zip` 可用面（写读 OOXML 容器）

| 能力 | 实测签名 / 行为 | f_excel 用法 |
|---|---|---|
| 构造（流） | `ZipReader(input: InputStream, limits!)`：**整个流读进内存**（`ZipReader.cj:52`） | 整文档读走这条；流式读仅当 `spool = false` |
| 构造（路径） | `ZipReader(path: String, limits!)`：尾部窗口 + 中央目录，条目按需读（`ZipReader.cj:61`） | 整文档读与流式读的**真流式**入口。**只收 `String`，不收 `Path`**（差异 1） |
| 列条目 | `entries(): ArrayList<ZipEntry>`、`contains(name)`、`read(name): ?Array<Byte>` | `contains` 判部件存在 |
| 条目流 | `open(name): ?InputStream`：每次另开独立游标，**可重复解压、可并发**；读到 EOF 才校验 CRC 与大小（`ZipReader.cj:113`、`ZipEntryInputStream.cj:291`） | `XmlPullParser(input)` 的输入；`rows(sheet)` 每次重开 = 可重复读 |
| 关闭 | `close()` 幂等（`ZipReader.cj:141`） | `ExcelSheetStream.close()` 转调 |
| 写（内存） | `add(name, data): String`，超过 `memoryEntryThreshold` 自动改走流式路径（`ZipWriter.cj:83`） | 小部件（ContentTypes/rels/workbook/styles）用它 |
| 写（流式） | `addFileStream(name, input): InputStream`，24 字节 data descriptor，长度未知也安全（`ZipWriter.cj:139`） | worksheet / sharedStrings 用它，**这是流式写的落点** |
| 进度 | `position`（已写出字节数）、`spilling`（是否在落临时文件，仅供展示）（`ZipWriter.cj:61,71`） | `ExcelWriter` 暴露为诊断 |
| 失败语义 | 中途抛异常后 writer 进入**脏状态**，后续 `add*`/`close()` 全抛（`ZipWriter.cj:42-43` 类注释） | 与设计 2.6.7「失败即残缺」同构，f_excel 不再自建回滚 |
| 写完 | `close()` 才写中央目录 + EOCD（`ZipWriter.cj:280`） | 对应 `ExcelWriter.finish()` |
| 压缩方法 | `ZipWriterOptions.method`，默认 `Deflate` | 保持默认 |

**结论**：`ZipWriter` **没有** `openEntry(name): OutputStream`（推模式入口），所以设计 2.6.1
「不做 `appendRow()` 推模式」的结论仍然成立——流式写只能是「f_zip 拉、f_excel 供」。

## 3. `f_xml` 可用面（解析 / DOM / 生成）

| 能力 | 实测签名 | 备注 |
|---|---|---|
| 拉模式事件 | `XmlPullParser(input: InputStream, options!)`、`nextEvent(): ?XmlEvent`、`skipElement()`、`close()`、`warnings(): Array<String>`（`XmlPullParser.cj:30-63`） | **不建树**，流式读的唯一内核 |
| 事件分支 | `StartDocument` / `XmlDeclaration` / `DocType` / `StartElement(QName, Array<XmlAttribute>, Bool)` / `EndElement` / `Text` / `CData` / `Comment` / `ProcessingInstruction` / `EndDocument`（`XmlEvent.cj:27-37`） | 共 10 分支，`match` 可穷尽 |
| DOM | `XmlDocument`（`root` / `declaration` / `doctype` / `prolog` / `epilog`）、`XmlElement`（`name` / `attributes` / `children` 均 public、`setAttr` / `appendChild` / `withText` / `attr` / `child` / `childrenOf` / `text`）、`XmlNode`（6 分支）（`XmlNode.cj:148-287`） | `child`/`attr` 按 **local name** 匹配，正好适配 OOXML 前缀差异 |
| 命名空间 | `QName(local, prefix!, uri!)`，`==` 按 `uri + local`（`QName.cj:43-70`） | 匹配一律用 `name.local` |
| 生成器 | `XmlWriter(output, options!)`：`write(doc)` / `write(element)` / `flush()` / `close()`（`XmlWriter.cj:45-141`） | **只能写完整元素或完整文档**，无 `startElement`/`text`/`endElement` 增量 API |
| 生成器缓冲 | 16 KB `StringGenerator` 阈值，UTF-8 走 `unsafeBytes()` 直写（`XmlWriter.cj:43,168-180`） | 小部件写足够 |
| 解析选项 | `XmlParserOptions(bufSize=8192, trimWhitespaceOnly=false, entityLimits, onInvalidByte=Strict, maxElementDepth=4096, maxAttributeValueLength=1MiB)`（`XmlOptions.cj:122-156`） | `trimWhitespaceOnly` 必须保持 `false`：`<t xml:space="preserve">` 的空白是数据 |

**两条必须记住的形状约束：**

1. **`XmlWriter` 没有增量接口** → worksheet 的逐行输出无法用它。设计 2.6.7 已经写明字节路径是
   `调用方 Iterator → WorksheetXmlWriter → addFileStream → deflate → output`，即 **f_excel 自带
   worksheet 发射器**。这是本变更差异 5 的直接依据。
2. **`Escaper` 不是 public**（`Escaper.cj:27/45/65` 都是包内 `static func`）→ f_excel 无法复用
   `f_xml` 的转义实现。因此 `WorksheetXmlWriter` 自带转义，并用「合法字符输出与 `f_xml` 逐字节
   一致」的用例兜住漂移（`f-excel-writer` 的 Scenario「转义与 f_xml 一致」）。

**写带前缀的属性要注意**：`XmlElement.setAttr(name: String, value)` 只构造无前缀的 `QName`
（`XmlNode.cj:169`），所以 `r:id` 不能靠它写。正确做法是把
`XmlAttribute(QName(local: "id", prefix!: Some("r"), uri!: Some(R_NS)), "...")` 直接
`push` 进 `element.attributes`——`XmlWriter.declareNamespaces` 会在该元素上补
`xmlns:r="…"`（`XmlWriter.cj:402-445`）。

## 4. `f_base` 可用面

| 能力 | 实测 | 用途 |
|---|---|---|
| `BaseException` | `public open class BaseException <: Exception`，`init(message)` / `init(message, caused)` / `addSuppressed` / `printStackTrace`（`BaseException.cj:44-55`） | `ExcelException <: BaseException`（与 `f_zip`/`f_xml`/`f_egraph` 一致） |
| `StringGenerator` | `f_xml`/`f_zip` 已在用；`append<T>` / `append(Rune)` / `size`（**字节数**）/ `unsafeBytes()`（零拷贝）/ `toString()` | `WorksheetXmlWriter` 的文本缓冲 |

## 5. 其它平台事实

| 项 | 实测 / 约定 |
|---|---|
| `@When` 平台分支 | 仓库只用 `os == "Linux" && env == "gnu"` 与取反两支（`ZipWriterOptions.cj:36,42`，注释明确「鸿蒙的 os 也是 Linux」）。M1 不需要平台分支（无 `maxCellStyles`），M2 引入时照此写 |
| 临时目录 | `f_zip` 的 `TempSpill` 是四级探测（选项 → `TMPDIR` → 系统临时目录 → `./.fountain_tmp`）；设计 2.7.4 要求 `ExcelSheetStream` 也这么做，**但各模块私有约 20 行，不入公用模块**（设计 §5.4.2 口径） |
| `cjpm test` 工作目录 | `f_xml` 实测为模块根（`implement-f-xml-m1/design.md` §10.1 R6）→ f_excel 的测试夹具路径按「工作目录 = 模块根」解析 |

## 6. 本变更必须补测的三条外部行为

设计文档没给结论、而 M1 一定要用到的三件事（详见 `design.md` §10）：

| # | 项 | 为什么必须实测 |
|---|---|---|
| R1 | `Float64.toString()` 是否给出最短往返串，整数是否带 `.0` | 设计 4.3 要求「最短往返」；若默认实现会截断或补 `.0`，`formatNumber` 必须自己实现 |
| R2 | `DateTime` 与「自 1899-12-30/31 起的天数」互转的可用 API（`toUnixTimeStamp` / `DateTime.ofEpoch` 之类） | 日期读写的核心换算，猜 API 会写出错一个时区的结果 |
| R3 | `File.createTemp(directory)` 与 `env` 临时目录 API 的实际签名 | `spool` 落地依赖它；签名不对就要换路径策略 |

这三条在 `tasks.md` 0.3–0.5 里先做，结论回填 `design.md` §10。

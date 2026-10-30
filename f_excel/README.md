# f_excel

Excel（xlsx / OOXML）读写模块：**流式解析、流式生成**、样式与公式。

- 包名：`fountain::f_excel`
- 依赖：`f_base`、`f_log`、`f_util`、`f_xml`（XML 事件解析 / DOM）、`f_zip`（OOXML 容器）
- 设计文档：[`doc/f_excel模块设计.md`](doc/f_excel模块设计.md)

## 当前状态

模块骨架已建立，能力按设计文档的里程碑推进（M1 → M4），代码与单元测试同步落地。

| 里程碑 | 内容 |
|---|---|
| M1 | 读取 worksheet / sharedStrings / 合并单元格、最小可用生成、日期识别 |
| M2 | 样式完整读写、公式引擎、`TimeSpan`、流式生成 |
| M3 | 按需解析、数组公式、完整函数库 |
| M4 | 条件格式语义求值 |

## 设计要点

- **流式解析**：按行拉取（`ExcelSheetStream` 迭代器），内存与行数无关；`Path` 输入走
  `f_zip` 的 `seek` 窗口读，非可定位输入落临时文件后同样真流式。
- **流式生成**：`ExcelWriter` 吃行迭代器，`f_zip.addFileStream` 边生成 XML 边压缩写出，
  内存峰值 = 单行 + 压缩缓冲。
- **XML 交给 `f_xml`**：命名空间前缀用 `QName.local` 匹配，不自写标签扫描器。

## 用法

见设计文档第 2 章；README 的用法章节在 M1 落地后补齐。

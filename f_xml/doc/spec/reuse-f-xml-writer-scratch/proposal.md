# 复用 XML 写入器的字节暂存与编码缓冲

## Why

`docs/LocalMode.md` 2.5 表把 `XmlWriter.flush` 的 16 KB 编码数组列为优化点。实测否定了这一判断：UTF-8 路径的 `StringGenerator.unsafeBytes()` 只产生一个数组视图，64 次刷写总分配约 20 KB（313 B/次），无可复用空间。

真正的热点在**非 ASCII 文本与属性转义**：`StringGenerator.append(r: Rune)` 每遇到一个非 ASCII 字符就新建 `[0, 0, 0, 0]` 暂存数组。实测写入 20000 个汉字：**68 B/rune**；改用复用 4 B 暂存后为 **2 B/rune**（34×）。

中文 XML 写入是 `f_xml` 的常见场景，该分配随字符数线性增长。

## What Changes

- **`XmlWriter` 的输出缓冲从 `StringGenerator` 换成包内 `ByteScratch`**：后者已有复用的 4 B 编码暂存与 `putCp`，且 `reset()` 只置长度、容量留用。
- **`Escaper` 的三个写入方法改为接收 `ByteScratch`**：文本/属性/CDATA 的非 ASCII 字符走 `putCp`，不再每字符新建暂存数组。
- **`ByteScratch` 增加批量追加**：`append(text: String)` 用 `Array.copyTo` 整块搬入；容量增长的逐字节拷贝也改为 `copyTo`。
- **刷写路径不变**：UTF-8 仍直接 `output.write(buffer[0..size])`；非 UTF 仍经 `toString()` + `encodeChecked`（往返校验与 `?` 兜底保留）。
- **测试**：新增 `f_xml/src/XmlWriterScratch_test.cj`——多段刷写的 UTF-8/UTF-16LE 输出逐字节不变、非 ASCII 转义与 CDATA 不变、env-gated 分配基准（≤ 8 B/rune，且比 `StringGenerator` 基线低一个数量级以上）。

**公开 API 不变**：`XmlWriter` / `Escaper` / `ByteScratch` 的公开签名与可见性不变（后两者本就是包内类型）。

## Capabilities

### New Capabilities

- `xml-writer-output`：XML 写入器的输出不变性与非 ASCII 追加的低分配约束。

### Modified Capabilities

无。

## Impact

- 代码：`f_xml/src/XmlWriter.cj`、`f_xml/src/Escaper.cj`、`f_xml/src/ByteScratch.cj`。
- 测试：新增 `f_xml/src/XmlWriterScratch_test.cj`；既有 `XmlWriter_test` / `XmlWriterIncremental_test` / `WriterEncoding_test` / `FormatSamples_test` 作为回归网。
- 行为：输出字节、转义、编码、异常类型均不变；仅去掉非 ASCII 追加的每字符暂存分配。
- 依赖：不新增依赖，不改 `f_base`。

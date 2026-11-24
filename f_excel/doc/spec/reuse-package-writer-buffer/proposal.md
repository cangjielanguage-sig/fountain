# 复用 OPC 包生成的 XML 部件缓冲

## Why

`f_excel` 每写一份 xlsx，`PackageWriter` 会为 7 个 XML 部件各新建一个 `ByteBuffer`，`StylesWriter` 再新建一个：

| 部件 | 现初始容量 | 位置 |
| --- | --- | --- |
| `[Content_Types].xml` | 256 KiB | `PackageWriter.cj:130` |
| `_rels/.rels` | 64 KiB | `PackageWriter.cj:220` |
| `xl/workbook.xml` | 128 KiB | `PackageWriter.cj:238` |
| `xl/_rels/workbook.xml.rels` | 128 KiB | `PackageWriter.cj:266` |
| `xl/drawings/drawingN.xml` | 256 KiB（每个带图 sheet） | `PackageWriter.cj:294` |
| `xl/drawings/_rels/drawingN.xml.rels` | 64 KiB（每个带图 sheet） | `PackageWriter.cj:355` |
| `xl/worksheets/_rels/sheetN.xml.rels` | 64 KiB（每个带图 sheet） | `PackageWriter.cj:375` |
| `xl/styles.xml` | 256 KiB | `StylePool.cj:126` |

`f_excel` 用的是 **`std.io.ByteBuffer`**（不是 `f_io.ByteBuffer`）。`ByteBuffer(initialCapacity)` 的构造体是 `Array<Byte>(initialCapacity, repeat: 0)`，也就是每次分配都先零填充：

- 无图文档一次写出零填充 **832 KiB**，其中 `_rels/.rels` 实际内容约 300 字节、`xl/workbook.xml` 约 300 字节、`xl/workbook.xml.rels` 约 400 字节。
- 每个带图 sheet 再多 **384 KiB**；`drawingN.xml.rels` / `sheetN.xml.rels` 通常不到 500 字节。

这些缓冲互不重叠、生命周期都落在同一次 `PackageWriter.write` 内，且 `ZipWriter.add` 在返回前完成 CRC 与压缩、不保留 `data` 引用；因此可以复用同一个底层 buffer，逐部件各一份并不必要。

## What Changes

- **`PackageWriter`**：单次包写出只建一个 `ByteBuffer`（初值 256 KiB），7 处 XML 部件依次复用它；超出容量时依赖 `ByteBuffer` 既有增长策略扩容。
- **生成器重载**：
  - 4 个既有内部生成器 `contentTypes` / `rootRels` / `workbookXmlFromNames` / `workbookRels` 保留原签名（内部新建缓冲后委托），新增接收 `buffer` 的重载。
  - 3 个私有生成器 `drawingXml` / `drawingRels` / `sheetRels` 提升为 `internal` 并直接接收 `buffer`（否则新增测试无法直接覆盖绘图部件）。
- **`StylesWriter`**：新增 `write(pool, buffer)` 复用重载；`write(pool)` 保留并委托，避免调用方改动。
- **`ExcelWriter`**：构造时（4 个前置部件）与 `finish()` 时（styles）各用一个**局部** buffer，不在实例上长期持有 256 KiB。
- **测试**：部件字节等价（复用 vs 新建）、重复复用无串扰（含大→小交替、缓冲预置残留）、字节视图在复用前消费、超限部件按需增长、两次写出同名部件一致。
- **基准**：新增 `Package_bench.cj`，用 `@Bench` 对照"复用缓冲"与"每部件新建缓冲"两条路径。

**明确不做**：

- 不改任何公开 API（`PackageWriter` / `StylesWriter` 均为 `internal`，本次只增不改公开面）。
- 不把 sheet 部件改成内存缓冲 — sheet 仍走 `zip.openEntry` 流式写，内存边界不动。
- 不改 XML 生成逻辑（元素顺序、属性顺序、转义）——只改缓冲来源。

## Impact

- 代码：`f_excel/src/PackageWriter.cj`、`f_excel/src/StylePool.cj`、`f_excel/src/ExcelWriter.cj`；新增 `f_excel/src/PackageBuffer_test.cj`、`f_excel/src/Package_bench.cj`。
- 规格：新增 capability `excel-opc-package` 的增量（`specs/excel-opc-package/spec.md`）。
- 兼容性：公开 API 零变更；产物中每个 XML 部件逐字节不变（ZIP 容器本身含 `DateTime.now()` 时间戳，跨次运行本来就不逐字节相等）。
- 性能：单次写出少 4 次容量级数组分配（每个带图 sheet 再多省 3 次）；`clear()` 仍按上一部件长度擦零，收益以分配与容量复用为主，不承诺减少擦零总量。
- 风险：`ByteBuffer.bytes()` 返回底层数组**视图**，延迟消费会读到后续内容；生产路径依赖 `zip.add` 同步 CRC/压缩、不保留引用，测试在复用前复制/序列化。

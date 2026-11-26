# 设计：OPC 包生成的 XML 部件缓冲复用

## 背景（现状）

`PackageWriter.write`（`f_excel/src/PackageWriter.cj:48`）按固定顺序向 `ZipWriter` 添加条目。除 sheet 走 `zip.openEntry` 流式写外，其余 7 个 XML 部件都是「建 `ByteBuffer` → `XmlWriter` 逐事件写 → `flush()` → `bytes()`」：

```cangjie
zip.add("[Content_Types].xml", contentTypes(count, sheetDrawing: sheetDrawing, formats: usedFormats))
zip.add("_rels/.rels", rootRels())
zip.add("xl/workbook.xml", workbookXmlFromNames(names.toArray(), date1904))
zip.add("xl/_rels/workbook.xml.rels", workbookRels(count))
...
zip.add("xl/drawings/drawing${drawing}.xml", drawingXml(images))
zip.add("xl/drawings/_rels/drawing${drawing}.xml.rels", drawingRels(media))
zip.add("xl/worksheets/_rels/sheet${i + 1}.xml.rels", sheetRels(drawing))
...
zip.add("xl/styles.xml", StylesWriter.write(styles))
```

`PackageWriter.cj:121` 已有 `newWriter(buffer)` 这个薄封装，本次不动。

`ExcelWriter`（`f_excel/src/ExcelWriter.cj:71-77`）在构造函数据里也调同一批生成器，`finish()`（`ExcelWriter.cj:153`）调 `StylesWriter.write(styles)`。**两条路径都要改**，否则只优化了 `ExcelDocument.write`。

### 关键前提：`std.io.ByteBuffer` 的行为

`f_excel` 用的是 **`std.io.ByteBuffer`**（`PackageWriter.cj` 的 `import std.io.{ByteBuffer, OutputStream}`），不是 `f_io.ByteBuffer`。std 实现（`stdlib/libs/std/io/byte_buffer.cj`）：

- `ByteBuffer(capacity)` → `Array<Byte>(capacity, repeat: 0)`，分配即零填充，这就是本次要省掉的开销。
- `bytes(): Array<Byte>` → `myData.slice(start, _length)`，即 `Array(rawptr, this.start + start, len)`，返回**共享底层存储的视图**，不是拷贝；后续写入/清空会改变已返回的视图。
- `clear()` → 把 `[0, start + _length)` 逐字节置 0，再把 `start` / `_length` 归零；容量保留。
- `write(buf)` 空间不足时自动扩容。

`ZipWriter.add`（`f_zip/src/ZipWriter.cj:86`）在返回前完成 `crc32(data)` 与 `compressData(data)`，并把压缩结果写入输出流；它不保留 `data` 引用。因此生产路径「生成 → 立即 `zip.add` → 复用」是安全的，但**任何延迟消费都会读到后续内容**。

## 目标

1. 单次包写出中，7 个 XML 部件 + `styles.xml` 复用**一个** `ByteBuffer`，初值 256 KiB，按需增长。
2. 每个 XML 部件的输出字节与改造前逐字节一致。
3. 复用不引入任何跨部件串扰。
4. 公开 API 零变更；既有内部调用方式不破坏。
5. 收益可用 `cjpm bench` 度量。

## 非目标

- 不把 sheet 部件改成缓冲（流式写的内存边界保持不变）。
- 不引入跨 `write` 调用的缓冲池/线程本地缓存（生命周期与并发复杂度不值这点收益）。
- 不改 `ZipWriter`、`XmlWriter`、`ByteBuffer` 的任何实现。

## 决策

### D1 一个包写出一个缓冲，而不是每部件一个

7 个部件的写出在 `PackageWriter.write` 内严格串行，且 `zip.add` 会**立即**算 CRC、压缩并写入输出流（`f_zip/src/ZipWriter.cj:86-133`），不持有 `data` 引用。因此"上一部件写完后缓冲即可复用"在顺序上是成立的。

在 `write()` 里建一个 `ByteBuffer`，逐个部件传下去：

```cangjie
let parts = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)   // 256 KiB，本次唯一
zip.add("[Content_Types].xml", contentTypes(count, sheetDrawing: sheetDrawing, formats: usedFormats, buffer: parts))
zip.add("_rels/.rels", rootRels(parts))
zip.add("xl/workbook.xml", workbookXmlFromNames(names.toArray(), date1904, parts))
zip.add("xl/_rels/workbook.xml.rels", workbookRels(count, parts))
...
zip.add("xl/styles.xml", StylesWriter.write(styles, parts))
```

### D2 生成器契约：进入清空，返回快照

每个接收 `buffer` 的生成器统一遵守：

```
进入 → buffer.clear()（丢弃前序内容并擦零，容量保留）
写入 → XmlWriter(buffer) 逐事件写，末尾 flush()
退出 → buffer.bytes()（底层数组视图；调用方 MUST 在下一次复用前消费，生产路径由 zip.add 同步消费）
```

清空放在**被调用方**而不是调用方，好处是任何调用顺序、任何异常的残留都不会影响下一次生成 —— 串扰在结构上被消除，而不是靠调用方自觉。

### D3 用重载而不是改签名

`ExcelWriter` 与既有测试都在用这四个生成器的老签名，改签名等于扩大改动面。采用重载：

```cangjie
// 保留：内部新建缓冲后委托
internal static func contentTypes(
    sheetCount: Int64,
    sheetDrawing!: ArrayList<Int64> = ArrayList<Int64>(),
    formats!: ArrayList<ImageFormat> = ArrayList<ImageFormat>()
): Array<Byte> {
    contentTypes(
        sheetCount,
        sheetDrawing: sheetDrawing,
        formats: formats,
        buffer: ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
    )
}

// 新增：复用重载。buffer 为必填且排在第二位，避免与上面 1..3 参调用产生重载歧义。
internal static func contentTypes(
    sheetCount: Int64,
    buffer!: ByteBuffer,
    sheetDrawing!: ArrayList<Int64> = ArrayList<Int64>(),
    formats!: ArrayList<ImageFormat> = ArrayList<ImageFormat>()
): Array<Byte> {
    buffer.clear()
    let xml = newWriter(buffer)
    ... 原有函数体，一字不改 ...
    xml.flush()
    buffer.bytes()
}
```

> 为什么 `buffer` 必须放在第二位且不给默认值：若复用重载把 `buffer` 放到末尾并给前面参数默认值，`contentTypes(count)` 会同时匹配两个重载。把 `buffer` 设为必填、位置靠前，则「1..3 参调用」只匹配老签名，「带 `buffer:` 命名实参」只匹配新重载，解析唯一。

其余三个同理：

```cangjie
internal static func rootRels(buffer: ByteBuffer): Array<Byte>
internal static func workbookXmlFromNames(sheets: Array<String>, date1904: Bool, buffer: ByteBuffer): Array<Byte>
internal static func workbookRels(sheetCount: Int64, buffer: ByteBuffer): Array<Byte>
```

### D4 三个私有绘图生成器升为 `internal` 并直接收 buffer

`drawingXml` / `drawingRels` / `sheetRels` 只在 `PackageWriter.write` 内部调用，没有外部调用方，因此**不加老签名包装**，直接改成：

```cangjie
internal static func drawingXml(images: ArrayList<SheetImage>, buffer: ByteBuffer): Array<Byte>
internal static func drawingRels(media: ArrayList<String>, buffer: ByteBuffer): Array<Byte>
internal static func sheetRels(drawing: Int64, buffer: ByteBuffer): Array<Byte>
```

`private` → `internal` 的唯一目的是让新增测试能直接对比「复用缓冲 vs 新建缓冲」的绘图部件字节。它们仍不进入公开 API。（备选：用带图片的文档走端到端断言，但那样就没有独立的"新建缓冲"基线可对比，验证力更弱。）

### D5 `StylesWriter` 加复用重载

```cangjie
static func write(pool: StylePool): Array<Byte> {
    write(pool, ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY))
}

static func write(pool: StylePool, buffer: ByteBuffer): Array<Byte> {
    buffer.clear()
    let xml = XmlWriter(buffer)
    ... 原有函数体 ...
    xml.flush()
    buffer.bytes()
}
```

`StylePool.cj` 与 `PackageWriter.cj` 同属 `fountain::f_excel`，常量统一定义在 `PackageWriter.cj` 顶层，避免两处硬编码 256 KiB：

```cangjie
/** 单次包写出复用的 XML 部件缓冲初始容量。 */
internal let OPC_PART_BUFFER_INITIAL_CAPACITY: Int64 = 256 * 1024
```

### D6 `ExcelWriter` 用两段局部缓冲，不挂字段

`ExcelWriter` 的两批部件在时间上相隔整个 sheet 流式写出过程：

- 构造：`[Content_Types].xml`、`_rels/.rels`、`xl/workbook.xml`、`xl/_rels/workbook.xml.rels`
- `finish()`：`xl/styles.xml`

若把 buffer 挂成字段，256 KiB 会随 writer 常驻（大文档可能常驻很久）。改为各自用局部变量，出作用域即回收：

```cangjie
// init 内
let parts = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
zip.add("[Content_Types].xml", PackageWriter.contentTypes(Int64(sheetNames.size), buffer: parts))
zip.add("_rels/.rels", PackageWriter.rootRels(parts))
zip.add("xl/workbook.xml", PackageWriter.workbookXmlFromNames(sheetNames, options.date1904 ?? false, parts))
zip.add("xl/_rels/workbook.xml.rels", PackageWriter.workbookRels(Int64(sheetNames.size), parts))

// finish() 内
let parts = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
zip.add("xl/styles.xml", StylesWriter.write(styles, parts))
```

代价是两次 256 KiB 分配；收益是不改变 writer 的常驻内存特征。

### D7 容量策略：256 KiB 起、只增不减、无上限

- 初始 256 KiB：覆盖绝大多数文档的 `[Content_Types].xml` / `workbook.xml` / `styles.xml`（旧代码这三处的初值就是 256 KiB / 128 KiB / 256 KiB）。
- 增长交给 `ByteBuffer` 既有策略（`capacity/2 + 本次写入`），`XmlWriter.flush()` 是成块写出，不会退化成逐字节增长。
- 不缩容：高水位只在单次 `write` 内存在，函数返回即释放；加缩容逻辑反而多一次拷贝。

## 数据流

```
write()/init()
   └─ ByteBuffer(256 KiB)  ── parts
        ├─ contentTypes  : clear → 写 → bytes()拷贝 → zip.add(立即压缩落盘)
        ├─ rootRels      : clear → 写 → bytes()拷贝 → zip.add
        ├─ workbook      : clear → 写 → bytes()拷贝 → zip.add
        ├─ workbookRels  : clear → 写 → bytes()拷贝 → zip.add
        ├─ drawingN      : clear → 写 → bytes()拷贝 → zip.add   （每带图 sheet 一次）
        ├─ drawingN.rels : clear → 写 → bytes()拷贝 → zip.add
        ├─ sheetN.rels   : clear → 写 → bytes()拷贝 → zip.add
        └─ styles        : clear → 写 → bytes()拷贝 → zip.add
```

## 字节等价如何被证明

1. **函数体不动**：每个生成器只增加 `buffer.clear()`，把 `let buffer = ByteBuffer(x)` 换成形参，末尾仍是 `flush()` + `bytes()`。XML 内容由同一套 `XmlWriter` 事件序列产生；`bytes()` 是视图，调用方必须在下一次复用前消费。
2. **T1 逐字节对比**：7 类部件 + styles，复用重载 vs 新建缓冲，断言等长且逐字节相等；**每次取到视图后先复制/序列化为 `Array<Byte>` 或 `String`，再复用缓冲**。
3. **T2 端到端**：同一文档连写两次，解包后同名部件逐字节相等；并保留现有 `RoundTrip_test` / `Writer_test` / `Style_test` 全绿。
4. **T4 基线固定**：改造前抓取固定夹具的 4 个小部件字节固化为字符串常量（`styles.xml` 较长，用"长度 + 关键片段 + 解析结构"断言），改造后必须不变。

## 测试设计（新增 `f_excel/src/PackageBuffer_test.cj`）

固定夹具：1 张 sheet、少量单元格（含数字/文本/样式），无图片；另备一个 2048 sheet 的生成器夹具和一个带图片文档夹具。

| 用例 | 内容 |
| --- | --- |
| T1 `reusedPartsEqualFreshParts` | 7 类部件 + styles：同一输入，`copy(f(args, shared))` 与 `copy(f(args, fresh))` 等长且逐字节相等；调用下一生成器前必须先复制/序列化上一次视图；再加一条反向断言（不同输入必须不同） |
| T2 `twoPackageWritesProduceSameParts` | `ExcelDocument.write` 连写两次，解包逐部件比对 |
| T3 `bytesViewMustBeConsumedBeforeReuse` | 先取视图、再在同一 buffer 写新内容，断言旧视图**随底层数组变化**（钉死 std 视图语义）；同时断言生产路径必须在复用前消费 |
| T4 `partsMatchPinnedBaseline` | 改造前抓取的 4 个小部件字节常量 + styles 的结构断言（比较前先复制/转字符串） |
| T5 `alternatingReuseHasNoCrosstalk` | 同一 buffer：大部件（2048 sheet 的 `contentTypes`，>256 KiB）→ 小部件（`rootRels`）→ 再大部件；每一步取到视图后先复制/序列化，再与全新缓冲结果逐字节相等 |
| T6 `garbageInBufferIsCleared` | 先往 buffer 灌垃圾字节，再调用生成器，结果仍等于全新缓冲（比较前复制/序列化） |
| T7 `bufferGrowsForLargePart` | 2048 sheet 的 `contentTypes`：`capacity > 256 KiB`、输出长度等于内容长度、`XmlParser` 可解析；随后写小部件，长度不受高水位影响 |
| T8 `drawingPartsUseSharedBuffer` | 带图片文档：`drawingXml` / `drawingRels` / `sheetRels` 复用 vs 新建逐字节相等（比较前复制/序列化） |

断言风格沿用仓库现状：`@Assert(actual, expected)`，测试类 `@Test public class Xxx_test`。

## 基准设计（新增 `f_excel/src/Package_bench.cj`）

形态对齐 `f_cache/src/HeapCache_bench.cj`、`f_store/src/Store_bench.cj`：`@Test public class Xxx_bench` + `@Bench` 方法，`cjpm bench` 跑。

| 用例 | 度量对象 |
| --- | --- |
| `benchPackageWrite` | 固定文档（2 sheet × 200 行 × 8 列，含样式）走 `ExcelDocument.write` 到预分配输出缓冲 |
| `benchSevenPartsReused` | 7 个部件串在**一个** buffer 上生成 |
| `benchSevenPartsFresh` | 同样 7 个部件，每次新建 buffer（保留老路径作为对照） |
| `benchStylesReused` / `benchStylesFresh` | `StylesWriter` 两条路径 |
| `benchPartsWithDrawingsReused` / `benchPartsWithDrawingsFresh` | 4 个带图 sheet 的绘图部件 |

要点：

- 输出 sink 预先分配并每轮 `clear()`，避免把 `ByteBuffer` 扩容算进被测时间。
- 每轮把 `bytes().size` 累加到实例字段，防止结果被优化掉。
- 夹具在 `init()` 里构建一次，基准方法里只做生成，避免构造文档的时间污染。

## 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| `ByteBuffer.bytes()` 返回视图而非拷贝 | 延迟消费会读到后续内容，产物损坏 | 生产路径生成后立即 `zip.add`（同步 CRC/压缩，不保留引用）；测试在复用前复制/序列化；T3 钉死视图语义 |
| 大部件触发增长时的拷贝 | 单次写出多一次 O(n) 拷贝 | 增长发生在容量级、`XmlWriter` 成块 flush；T7 验证不失控 |
| 高水位滞留 | 单次 `write` 内多占内存（如 2 MiB） | 生命周期止于 `write` 返回；不缩容是有意取舍 |
| `clear()` 会擦零已用前缀 | 大部件后接小部件时有一次 O(n) 擦零 | 只省分配与容量复用，不承诺省擦零；T5/T7 观察；不缩容 |
| 只改 `PackageWriter` 漏掉 `ExcelWriter` | 流式路径无收益，且两路径行为可能漂移 | 任务里单列 `ExcelWriter` 步骤 + 两条路径都用例覆盖 |
| 基准噪声 | 结论不可信 | 固定夹具、预分配 sink、同进程对照两路径 |

## 备选方案（不选的理由）

1. **7 个部件直接 `zip.openEntry` 流式写**：省掉 `bytes()` 快照，但会把 ZIP 容器从「mem header + 真实大小」变成「descriptor 流式」，小部件还多一次 `ZipEntryOutputStream` 开销，且容器字节变化会波及既有 ZIP 层测试 —— 收益不确定、风险更大。
2. **7 个字段级缓冲常驻**：内存常驻、状态更多，收益与单缓冲完全相同，纯增复杂度。
3. **跨 `write` 的缓冲池 / `ThreadLocal`**：能省掉每次 256 KiB 零填充，但引入生命周期与并发语义，收益是常数级，不做。

## 验收口径

- `cd f_excel && cjpm test` 全绿（现 184 条 + 新增用例），无 warning 新增。
- `cd f_excel && cjpm bench` 可跑，输出复用 / 新建两条路径的参考数据（不作 CI 性能判定）。
- `git diff` 中 XML 生成逻辑无内容改动（只有缓冲来源与 `clear()`）。
- 公开 API 签名零变更（`git diff` 中不含 `public` 声明变更）。

/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_excel

import std.collection.ArrayList
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_zip.ZipReader
import fountain::f_xml.XmlParser

/** 改造前固定夹具的 `[Content_Types].xml`（679 字节）。 */
private let GOLDEN_CONTENT_TYPES: String =
    "3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d3822207374616e64616c6f6e653d22796573223f3e3c547970657320786d6c6e733d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f7061636b6167652f323030362f636f6e74656e742d7479706573223e3c44656661756c7420457874656e73696f6e3d2272656c732220436f6e74656e74547970653d226170706c69636174696f6e2f766e642e6f70656e786d6c666f726d6174732d7061636b6167652e72656c6174696f6e73686970732b786d6c222f3e3c44656661756c7420457874656e73696f6e3d22786d6c2220436f6e74656e74547970653d226170706c69636174696f6e2f786d6c222f3e3c4f7665727269646520506172744e616d653d222f786c2f776f726b626f6f6b2e786d6c2220436f6e74656e74547970653d226170706c69636174696f6e2f766e642e6f70656e786d6c666f726d6174732d6f6666696365646f63756d656e742e73707265616473686565746d6c2e73686565742e6d61696e2b786d6c222f3e3c4f7665727269646520506172744e616d653d222f786c2f776f726b7368656574732f7368656574312e786d6c2220436f6e74656e74547970653d226170706c69636174696f6e2f766e642e6f70656e786d6c666f726d6174732d6f6666696365646f63756d656e742e73707265616473686565746d6c2e776f726b73686565742b786d6c222f3e3c4f7665727269646520506172744e616d653d222f786c2f7374796c65732e786d6c2220436f6e74656e74547970653d226170706c69636174696f6e2f766e642e6f70656e786d6c666f726d6174732d6f6666696365646f63756d656e742e73707265616473686565746d6c2e7374796c65732b786d6c222f3e3c2f54797065733e"

/** 改造前固定夹具的 `_rels/.rels`（295 字节）。 */
private let GOLDEN_ROOT_RELS: String =
    "3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d3822207374616e64616c6f6e653d22796573223f3e3c52656c6174696f6e736869707320786d6c6e733d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f7061636b6167652f323030362f72656c6174696f6e7368697073223e3c52656c6174696f6e736869702049643d22724964312220547970653d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f6f6666696365446f63756d656e742f323030362f72656c6174696f6e73686970732f6f6666696365446f63756d656e7422205461726765743d22786c2f776f726b626f6f6b2e786d6c222f3e3c2f52656c6174696f6e73686970733e"

/** 改造前固定夹具的 `xl/workbook.xml`（283 字节）。 */
private let GOLDEN_WORKBOOK: String =
    "3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d3822207374616e64616c6f6e653d22796573223f3e3c776f726b626f6f6b20786d6c6e733d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f73707265616473686565746d6c2f323030362f6d61696e2220786d6c6e733a723d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f6f6666696365446f63756d656e742f323030362f72656c6174696f6e7368697073223e3c7368656574733e3c7368656574206e616d653d225368656574312220736865657449643d22312220723a69643d2272496431222f3e3c2f7368656574733e3c2f776f726b626f6f6b3e"

/** 改造前固定夹具的 `xl/_rels/workbook.xml.rels`（423 字节）。 */
private let GOLDEN_WORKBOOK_RELS: String =
    "3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d3822207374616e64616c6f6e653d22796573223f3e3c52656c6174696f6e736869707320786d6c6e733d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f7061636b6167652f323030362f72656c6174696f6e7368697073223e3c52656c6174696f6e736869702049643d22724964312220547970653d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f6f6666696365446f63756d656e742f323030362f72656c6174696f6e73686970732f776f726b736865657422205461726765743d22776f726b7368656574732f7368656574312e786d6c222f3e3c52656c6174696f6e736869702049643d22724964322220547970653d22687474703a2f2f736368656d61732e6f70656e786d6c666f726d6174732e6f72672f6f6666696365446f63756d656e742f323030362f72656c6174696f6e73686970732f7374796c657322205461726765743d227374796c65732e786d6c222f3e3c2f52656c6174696f6e73686970733e"

/** 改造前固定夹具的 `xl/styles.xml` 长度。 */
private let GOLDEN_STYLES_SIZE: Int64 = 1069

@Test
public class PackageBuffer_test {
    /** 固定夹具：1 sheet、数字/文本/布尔/样式单元格各一，无图片。 */
    internal static func fixtureDoc(): ExcelDocument {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Text("hello"))
        sheet.setCell("B1", CellValue.Number(42.5))
        sheet.setCell("C1", CellValue.Boolean(true))
        sheet.setCell("A2", CellValue.Text("样式"))
        sheet.setCell("B2", CellValue.Number(-3.25))
        sheet.setStyle(
            2,
            2,
            CellStyle(
                numberFormat: NumberFormat.Custom("0.00_);[Red](0.00)"),
                font: Font(bold: true, color: Some(Color.Rgb("FF0000FF"))),
                fill: Fill.solid(Color.Rgb("FFFFFF00"))
            )
        )
        doc
    }

    /** 带图片夹具：1 sheet + 1 张 1x1 PNG。 */
    internal static func withImageDoc(): ExcelDocument {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Text("img"))
        sheet.addImage(Image_test.tinyPng(), ImageFormat.Png, "A1", "B2")
        doc
    }

    /** 名字清单夹具：`count` 个 sheet 名字。 */
    internal static func manySheets(count: Int64): Array<String> {
        let names = ArrayList<String>()
        for (i in 1..=count) {
            names.add("S${i}")
        }
        names.toArray()
    }

    private static func writeDoc(doc: ExcelDocument): Array<Byte> {
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        buffer.bytes()
    }

    private static func partOf(bytes: Array<Byte>, name: String): Array<Byte> {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            reader.read(name).getOrThrow()
        } finally {
            reader.close()
        }
    }

    private static func entryNames(bytes: Array<Byte>): Array<String> {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            let out = ArrayList<String>()
            for (entry in reader.entries()) {
                out.add(entry.name)
            }
            out.toArray()
        } finally {
            reader.close()
        }
    }

    /** 十六进制串还原为字节，用于 golden 常量对比。 */
    private static func unhex(hex: String): Array<Byte> {
        let chars = hex.toArray()
        let out = ArrayList<Byte>()
        var i = 0
        while (i + 1 < chars.size) {
            out.add(Byte((nibble(chars[i]) << 4) | nibble(chars[i + 1])))
            i += 2
        }
        out.toArray()
    }

    private static func nibble(c: UInt8): Int64 {
        if (c >= 48u8 && c <= 57u8) {
            return Int64(c) - 48
        }
        if (c >= 97u8 && c <= 102u8) {
            return Int64(c) - 87
        }
        throw ExcelException("非法十六进制字节：${c}")
    }

    /** 首个不同字节的下标；全等返回 -1。长度不等也视为不同。 */
    private static func firstDiff(actual: Array<Byte>, expected: Array<Byte>): Int64 {
        let n = if (actual.size < expected.size) {
            actual.size
        } else {
            expected.size
        }
        for (i in 0..n) {
            if (actual[i] != expected[i]) {
                return i
            }
        }
        if (actual.size != expected.size) {
            return n
        }
        -1
    }

    @TestCase
    public func twoPackageWritesProduceSameParts(): Unit {
        let doc = fixtureDoc()
        let first = writeDoc(doc)
        let second = writeDoc(doc)
        let names = entryNames(first)
        @Assert(names.size, entryNames(second).size)
        for (name in names) {
            let a = partOf(first, name)
            let b = partOf(second, name)
            @Assert(firstDiff(a, b), -1)
        }
    }

    @TestCase
    public func bytesViewMustBeConsumedBeforeReuse(): Unit {
        let buffer = ByteBuffer(16)
        buffer.write(Array<Byte>(8, repeat: 65))
        let view = buffer.bytes()
        @Assert(view.size, 8)
        @Assert(view[0], 65u8)
        buffer.clear()
        buffer.write(Array<Byte>(3, repeat: 66))
        // 视图共享底层存储：清空并写入新内容后，旧视图看到的是新内容。
        @Assert(view.size, 8)
        @Assert(view[0], 66u8)
        @Assert(view[3], 0u8)
        // 生产路径必须在下一次复用前消费视图：先复制再复用，副本不受影响。
        let copied = view.clone()
        buffer.clear()
        buffer.write(Array<Byte>(2, repeat: 67))
        @Assert(copied[0], 66u8)
        @Assert(view[0], 67u8)
    }

    @TestCase
    public func partsMatchPinnedBaseline(): Unit {
        let bytes = writeDoc(fixtureDoc())
        @Assert(firstDiff(partOf(bytes, "[Content_Types].xml"), unhex(GOLDEN_CONTENT_TYPES)), -1)
        @Assert(firstDiff(partOf(bytes, "_rels/.rels"), unhex(GOLDEN_ROOT_RELS)), -1)
        @Assert(firstDiff(partOf(bytes, "xl/workbook.xml"), unhex(GOLDEN_WORKBOOK)), -1)
        @Assert(firstDiff(partOf(bytes, "xl/_rels/workbook.xml.rels"), unhex(GOLDEN_WORKBOOK_RELS)), -1)
        let styles = partOf(bytes, "xl/styles.xml")
        @Assert(styles.size, GOLDEN_STYLES_SIZE)
        let text = String.fromUtf8(styles)
        @Assert(text.contains("<numFmt numFmtId=\"164\" formatCode=\"0.00_);[Red](0.00)\"/>"), true)
        @Assert(text.contains("<fonts count=\"2\">"), true)
        @Assert(text.contains("<fills count=\"3\">"), true)
        @Assert(text.contains("<cellXfs count=\"2\">"), true)
        @Assert(text.contains("applyNumberFormat=\"1\" applyFill=\"1\" applyFont=\"1\""), true)
        @Assert(text.endsWith("</styleSheet>"), true)
    }

    /** 复用重载与新建缓冲对同一输入必须逐字节一致；不同输入必须不同。 */
    @TestCase
    public func reusedPartsEqualFreshParts(): Unit {
        let shared = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
        let sheetDrawing = ArrayList<Int64>([1, 0])
        let formats = ArrayList<ImageFormat>([ImageFormat.Png])

        let typesReused = PackageWriter.contentTypes(2, buffer: shared, sheetDrawing: sheetDrawing, formats: formats).clone()
        let typesFresh = PackageWriter.contentTypes(2, sheetDrawing: sheetDrawing, formats: formats).clone()
        @Assert(firstDiff(typesReused, typesFresh), -1)

        let relsReused = PackageWriter.rootRels(shared).clone()
        let relsFresh = PackageWriter.rootRels().clone()
        @Assert(firstDiff(relsReused, relsFresh), -1)

        let names = manySheets(3)
        let workbookReused = PackageWriter.workbookXmlFromNames(names, true, shared).clone()
        let workbookFresh = PackageWriter.workbookXmlFromNames(names, true).clone()
        @Assert(firstDiff(workbookReused, workbookFresh), -1)

        let workbookRelsReused = PackageWriter.workbookRels(3, shared).clone()
        let workbookRelsFresh = PackageWriter.workbookRels(3).clone()
        @Assert(firstDiff(workbookRelsReused, workbookRelsFresh), -1)

        let pool = StylePool()
        pool.getOrAdd(
            CellStyle(
                numberFormat: NumberFormat.Custom("0.00"),
                font: Font(bold: true),
                fill: Fill.solid(Color.Rgb("FF00FF00"))
            ),
            64000
        )
        let stylesReused = StylesWriter.write(pool, shared).clone()
        let stylesFresh = StylesWriter.write(pool).clone()
        @Assert(firstDiff(stylesReused, stylesFresh), -1)

        // 反向断言：输入不同，字节必须不同，避免两侧都为空导致假绿。
        @Assert(firstDiff(PackageWriter.contentTypes(2, sheetDrawing: sheetDrawing, formats: formats),
            PackageWriter.contentTypes(3, sheetDrawing: sheetDrawing, formats: formats)) != -1, true)
        @Assert(firstDiff(PackageWriter.rootRels(), PackageWriter.workbookRels(1)) != -1, true)
        @Assert(firstDiff(PackageWriter.workbookXmlFromNames(manySheets(1), false),
            PackageWriter.workbookXmlFromNames(manySheets(2), false)) != -1, true)
    }

    /** 大部件 → 小部件 → 大部件，交替复用不得串扰。 */
    @TestCase
    public func alternatingReuseHasNoCrosstalk(): Unit {
        let shared = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
        let big1 = PackageWriter.contentTypes(2048, buffer: shared).clone()
        @Assert(big1.size > OPC_PART_BUFFER_INITIAL_CAPACITY, true)

        let small = PackageWriter.rootRels(shared).clone()
        @Assert(firstDiff(small, PackageWriter.rootRels()), -1)

        let big2 = PackageWriter.contentTypes(2048, buffer: shared).clone()
        @Assert(firstDiff(big2, big1), -1)
        @Assert(firstDiff(big2, PackageWriter.contentTypes(2048)), -1)
    }

    /** 缓冲里残留垃圾字节也必须被生成器进入时清空。 */
    @TestCase
    public func garbageInBufferIsCleared(): Unit {
        let shared = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
        shared.write(Array<Byte>(4096, repeat: 120))
        let rels = PackageWriter.rootRels(shared).clone()
        @Assert(firstDiff(rels, PackageWriter.rootRels()), -1)
        shared.write(Array<Byte>(8192, repeat: 121))
        let workbook = PackageWriter.workbookXmlFromNames(manySheets(1), false, shared).clone()
        @Assert(firstDiff(workbook, PackageWriter.workbookXmlFromNames(manySheets(1), false)), -1)
    }

    /** 超限部件按需增长，小部件长度不被高水位带偏。 */
    @TestCase
    public func bufferGrowsForLargePart(): Unit {
        let shared = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
        let big = PackageWriter.contentTypes(2048, buffer: shared).clone()
        @Assert(shared.capacity > OPC_PART_BUFFER_INITIAL_CAPACITY, true)
        @Assert(big.size, PackageWriter.contentTypes(2048).size)
        let doc = XmlParser.parse(big)
        @Assert(doc.root.getOrThrow().name.toString().contains("Types"), true)

        let small = PackageWriter.rootRels(shared).clone()
        @Assert(small.size, PackageWriter.rootRels().size)
        @Assert(firstDiff(small, PackageWriter.rootRels()), -1)
    }

    /** 绘图三个部件同样走共享缓冲且字节一致。 */
    @TestCase
    public func drawingPartsUseSharedBuffer(): Unit {
        let doc = withImageDoc()
        let images = doc.sheet("Sheet1").getOrThrow().sheetImages()
        let media = ArrayList<String>(["image1.png"])
        let shared = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)

        let drawing = PackageWriter.drawingXml(images, shared).clone()
        @Assert(firstDiff(drawing, PackageWriter.drawingXml(images, ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY))), -1)

        let drawingRels = PackageWriter.drawingRels(media, shared).clone()
        @Assert(firstDiff(drawingRels, PackageWriter.drawingRels(media, ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY))), -1)

        let sheetRels = PackageWriter.sheetRels(1, shared).clone()
        @Assert(firstDiff(sheetRels, PackageWriter.sheetRels(1, ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY))), -1)
    }
}

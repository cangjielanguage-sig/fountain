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

/**
 * `f_excel` OPC 包生成基准（`cjpm bench`）。对照「复用缓冲」与「每部件新建缓冲」两条路径：
 * - `benchPackageWrite`：固定文档走 `ExcelDocument.write` 到预分配输出缓冲
 * - `benchSevenPartsReused` / `benchSevenPartsFresh`：7 个 XML 部件串在一个 / 每次新建缓冲
 * - `benchStylesReused` / `benchStylesFresh`：`StylesWriter` 两条路径
 * - `benchPartsWithDrawingsReused` / `benchPartsWithDrawingsFresh`：带图 sheet 的绘图部件
 *
 * 输出 sink 预算分配并每轮 `clear()`，不把扩容计入被测时间；每轮把 `bytes().size`
 * 累加到字段，防止结果被优化掉。夹具在 `init()` 构建一次。
 */
@Test
public class Package_bench {
    private let doc: ExcelDocument
    private let pool = StylePool()
    private let names: Array<String>
    private let sheetDrawing: ArrayList<Int64>
    private let formats: ArrayList<ImageFormat>
    private let media: ArrayList<String>
    private let images: ArrayList<SheetImage>
    private let sink = ByteBuffer(8 * 1024 * 1024)
    private let shared = ByteBuffer(OPC_PART_BUFFER_INITIAL_CAPACITY)
    private var checksum = 0

    public init() {
        let built = ExcelDocument()
        for (s in 1..=2) {
            let sheet = built.addSheet("S${s}")
            for (row in 1..=200) {
                for (col in 1..=8) {
                    if ((row + col) % 4 == 0) {
                        sheet.setCell(row, col, CellValue.Text("cell-${row}-${col}"))
                    } else {
                        sheet.setCell(row, col, CellValue.Number(Float64(row * col) / 4.0))
                    }
                }
                sheet.setStyle(row, 1, CellStyle(font: Font(bold: row % 3 == 0)))
            }
        }
        this.doc = built

        let withImage = ExcelDocument()
        let drawing = ArrayList<Int64>()
        let usedFormats = ArrayList<ImageFormat>()
        for (s in 1..=4) {
            let sheet = withImage.addSheet("D${s}")
            sheet.addImage(tinyPng(), ImageFormat.Png, "A1", "B2")
            sheet.setCell("C3", CellValue.Text("drawing-${s}"))
            drawing.add(Int64(s))
            usedFormats.add(ImageFormat.Png)
        }
        this.sheetDrawing = drawing
        this.formats = usedFormats
        this.media = ArrayList<String>(["image1.png"])
        this.images = withImage.sheet("D1").getOrThrow().sheetImages()
        this.names = ArrayList<String>(["Alpha", "Beta"]).toArray()
        pool.getOrAdd(CellStyle(numberFormat: NumberFormat.Custom("0.00"), font: Font(bold: true)), 64000)
        pool.getOrAdd(CellStyle(fill: Fill.solid(Color.Rgb("FF00FF00"))), 64000)
    }

    /** 1x1 透明 PNG（与本模块图片用例同一份夹具）。 */
    private static func tinyPng(): Array<Byte> {
        [
            0x89u8, 0x50u8, 0x4Eu8, 0x47u8, 0x0Du8, 0x0Au8, 0x1Au8, 0x0Au8,
            0x00u8, 0x00u8, 0x00u8, 0x0Du8, 0x49u8, 0x48u8, 0x44u8, 0x52u8,
            0x00u8, 0x00u8, 0x00u8, 0x01u8, 0x00u8, 0x00u8, 0x00u8, 0x01u8,
            0x08u8, 0x06u8, 0x00u8, 0x00u8, 0x00u8, 0x1Fu8, 0x15u8, 0xC4u8,
            0x89u8, 0x00u8, 0x00u8, 0x00u8, 0x0Au8, 0x49u8, 0x44u8, 0x41u8,
            0x54u8, 0x78u8, 0x9Cu8, 0x63u8, 0x00u8, 0x01u8, 0x00u8, 0x00u8,
            0x05u8, 0x00u8, 0x01u8, 0x0Du8, 0x0Au8, 0x2Du8, 0xB4u8, 0x00u8,
            0x00u8, 0x00u8, 0x00u8, 0x49u8, 0x45u8, 0x4Eu8, 0x44u8, 0xAEu8,
            0x42u8, 0x60u8, 0x82u8
        ]
    }

    @Bench
    public func benchPackageWrite(): Unit {
        sink.clear()
        doc.write(sink)
        checksum += sink.bytes().size
    }

    @Bench
    public func benchSevenPartsReused(): Unit {
        let count = Int64(doc.sheetCount())
        checksum += PackageWriter.contentTypes(count, buffer: shared, sheetDrawing: sheetDrawing).size
        checksum += PackageWriter.rootRels(shared).size
        checksum += PackageWriter.workbookXmlFromNames(names, false, shared).size
        checksum += PackageWriter.workbookRels(count, shared).size
        checksum += PackageWriter.drawingXml(images, shared).size
        checksum += PackageWriter.drawingRels(media, shared).size
        checksum += PackageWriter.sheetRels(1, shared).size
    }

    @Bench
    public func benchSevenPartsFresh(): Unit {
        let count = Int64(doc.sheetCount())
        let fresh = OPC_PART_BUFFER_INITIAL_CAPACITY
        checksum += PackageWriter.contentTypes(count, sheetDrawing: sheetDrawing).size
        checksum += PackageWriter.rootRels().size
        checksum += PackageWriter.workbookXmlFromNames(names, false).size
        checksum += PackageWriter.workbookRels(count).size
        checksum += PackageWriter.drawingXml(images, ByteBuffer(fresh)).size
        checksum += PackageWriter.drawingRels(media, ByteBuffer(fresh)).size
        checksum += PackageWriter.sheetRels(1, ByteBuffer(fresh)).size
    }

    @Bench
    public func benchStylesReused(): Unit {
        checksum += StylesWriter.write(pool, shared).size
    }

    @Bench
    public func benchStylesFresh(): Unit {
        checksum += StylesWriter.write(pool).size
    }

    @Bench
    public func benchPartsWithDrawingsReused(): Unit {
        for (i in 0..sheetDrawing.size) {
            checksum += PackageWriter.drawingXml(images, shared).size
            checksum += PackageWriter.drawingRels(media, shared).size
            checksum += PackageWriter.sheetRels(sheetDrawing[i], shared).size
        }
    }

    @Bench
    public func benchPartsWithDrawingsFresh(): Unit {
        let fresh = OPC_PART_BUFFER_INITIAL_CAPACITY
        for (i in 0..sheetDrawing.size) {
            checksum += PackageWriter.drawingXml(images, ByteBuffer(fresh)).size
            checksum += PackageWriter.drawingRels(media, ByteBuffer(fresh)).size
            checksum += PackageWriter.sheetRels(sheetDrawing[i], ByteBuffer(fresh)).size
        }
    }
}

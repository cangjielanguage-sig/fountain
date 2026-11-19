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

@Test
public class Image_test {
    /** 1x1 透明 PNG。 */
    internal static func tinyPng(): Array<Byte> {
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

    private static func build(): Array<Byte> {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().addImage(tinyPng(), ImageFormat.Png, "A1", "B2")
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        buffer.bytes()
    }

    private static func textOf(bytes: Array<Byte>, name: String): String {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            String.fromUtf8(reader.read(name).getOrThrow())
        } finally {
            reader.close()
        }
    }

    @TestCase
    public func imagePartsAreWritten(): Unit {
        let bytes = build()
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            let names = ArrayList<String>()
            for (entry in reader.entries()) {
                names.add(entry.name)
            }
            for (required in [
                "xl/media/image1.png",
                "xl/drawings/drawing1.xml",
                "xl/drawings/_rels/drawing1.xml.rels",
                "xl/worksheets/_rels/sheet1.xml.rels"
            ]) {
                @Assert(names.contains(required), true)
            }
        } finally {
            reader.close()
        }
        let sheet = textOf(bytes, "xl/worksheets/sheet1.xml")
        @Assert(sheet.contains("<drawing r:id=\"rId1\"/>"), true)
        let types = textOf(bytes, "[Content_Types].xml")
        @Assert(types.contains("image/png"), true)
        @Assert(types.contains("/xl/drawings/drawing1.xml"), true)
        let drawing = textOf(bytes, "xl/drawings/drawing1.xml")
        @Assert(drawing.contains("<xdr:col>0</xdr:col>"), true)
        @Assert(drawing.contains("<xdr:row>0</xdr:row>"), true)
        @Assert(drawing.contains("<xdr:col>1</xdr:col>"), true)
        @Assert(drawing.contains("<xdr:row>1</xdr:row>"), true)
        @Assert(drawing.contains("r:embed=\"rId1\""), true)
    }

    @TestCase
    public func multipleImagesGetDistinctParts(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.addImage(tinyPng(), ImageFormat.Png, "A1", "B2")
        sheet.addImage(tinyPng(), ImageFormat.Png, "C3", "D4")
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let bytes = buffer.bytes()
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            let names = ArrayList<String>()
            for (entry in reader.entries()) {
                names.add(entry.name)
            }
            @Assert(names.contains("xl/media/image1.png"), true)
            @Assert(names.contains("xl/media/image2.png"), true)
        } finally {
            reader.close()
        }
        let drawing = textOf(bytes, "xl/drawings/drawing1.xml")
        @Assert(drawing.contains("r:embed=\"rId2\""), true)
    }

    @TestCase
    public func invalidInputsRejected(): Unit {
        let sheet = Worksheet("S")
        var inverted = false
        try {
            sheet.addImage(tinyPng(), ImageFormat.Png, "B2", "A1")
        } catch (_: ExcelException) {
            inverted = true
        }
        @Assert(inverted, true)
        var empty = false
        try {
            sheet.addImage(Array<Byte>(), ImageFormat.Png, "A1", "B2")
        } catch (_: ExcelException) {
            empty = true
        }
        @Assert(empty, true)
    }

    @TestCase
    public func readBackIgnoresImageButKeepsValues(): Unit {
        let bytes = build()
        let doc = ExcelDocument(ByteBuffer(bytes))
        @Assert(doc.sheet("Sheet1").getOrThrow().imageCount(), 0)
        @Assert(doc.sheet("Sheet1").getOrThrow().mergedRanges().size, 0)
    }
}

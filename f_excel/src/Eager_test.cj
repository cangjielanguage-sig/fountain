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

import std.env
import std.fs.Path
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Eager_test {
    private static func lazyOptions(): ExcelReadOptions {
        let options = ExcelReadOptions()
        options.eager = false
        options
    }

    @TestCase
    public func lazyOpensWithoutParsingBrokenSheet(): Unit {
        let bad = "<?xml version=\"1.0\"?><worksheet><sheetData><row"
        let good = worksheetXml("<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>")
        let bytes = buildXlsx([bad, good], names: ["Bad", "Good"])
        var eagerThrew = false
        try {
            ExcelDocument(ByteBuffer(bytes))
        } catch (_: Exception) {
            eagerThrew = true
        }
        @Assert(eagerThrew, true)

        let doc = ExcelDocument(ByteBuffer(bytes), options: lazyOptions())
        @Assert(doc.sheetCount(), 2)
        let goodSheet = doc.sheet("Good").getOrThrow()
        @Assert(match (goodSheet.cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 1.0)
        var lazyThrew = false
        try {
            doc.sheet("Bad").getOrThrow().cell("A1")
        } catch (_: Exception) {
            lazyThrew = true
        }
        @Assert(lazyThrew, true)
    }

    @TestCase
    public func lazyPathLoadsOnFirstAccessAndKeepsDataOnWrite(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("B1", CellValue.Number(2.0))
        let source = Path("${env.getTempDirectory()}/f_excel_lazy_src.xlsx")
        let target = Path("${env.getTempDirectory()}/f_excel_lazy_dst.xlsx")
        doc.write(source)

        let lazy = ExcelDocument(source, options: lazyOptions())
        let lazySheet = lazy.sheet("Sheet1").getOrThrow()
        lazySheet.setCell("B1", CellValue.Number(5.0))
        lazy.write(target)

        let back = ExcelDocument(target).sheet("Sheet1").getOrThrow()
        @Assert(match (back.cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 1.0)
        @Assert(match (back.cell("B1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 5.0)
    }

    @TestCase
    public func lazyInputStreamSpools(): Unit {
        let sheetXml = worksheetXml("<row r=\"1\"><c r=\"A1\"><v>7</v></c></row>")
        let bytes = buildXlsx([sheetXml])
        let doc = ExcelDocument(ByteBuffer(bytes), options: lazyOptions())
        let sheet = doc.sheet("Sheet1").getOrThrow()
        @Assert(match (sheet.cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 7.0)
    }

    @TestCase
    public func lazySkipSheetsDoesNotParse(): Unit {
        let bad = "<?xml version=\"1.0\"?><worksheet><sheetData><row"
        let good = worksheetXml("<row r=\"1\"><c r=\"A1\"><v>2</v></c></row>")
        let bytes = buildXlsx([bad, good], names: ["Bad", "Good"])
        let options = lazyOptions()
        options.skipSheets = ["Bad"]
        let doc = ExcelDocument(ByteBuffer(bytes), options: options)
        @Assert(doc.sheetCount(), 1)
        @Assert(match (doc.sheet("Good").getOrThrow().cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 2.0)
    }
}

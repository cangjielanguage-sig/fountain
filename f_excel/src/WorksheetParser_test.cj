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
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SharedStringTable_test {
    private static func sst(xml: String): SharedStringTable {
        SharedStringTable.load(
            ("<?xml version=\"1.0\"?><sst xmlns=\"${NS_MAIN}\" count=\"9\" uniqueCount=\"9\">" +
                xml + "</sst>").toArray()
        )
    }

    @TestCase
    public func singleText(): Unit {
        let table = sst("<si><t>Hello</t></si>")
        @Assert(table.size, 1)
        @Assert(table.get(0).getOrThrow(), "Hello")
        @Assert(table.get(1).isNone(), true)
    }

    @TestCase
    public func richTextSegmentsAreJoined(): Unit {
        let table = sst("<si><r><t>Rich</t></r><r><t> text</t></r></si>")
        @Assert(table.get(0).getOrThrow(), "Rich text")
    }

    @TestCase
    public func phoneticRunsAreSkipped(): Unit {
        let table = sst("<si><t>漢字</t><rPh sb=\"0\" eb=\"2\"><t>かんじ</t></rPh></si>")
        @Assert(table.get(0).getOrThrow(), "漢字")
    }

    @TestCase
    public func whitespaceIsPreserved(): Unit {
        let table = sst("<si><t xml:space=\"preserve\">  a  </t></si>")
        @Assert(table.get(0).getOrThrow(), "  a  ")
    }

    @TestCase
    public func countsAreNotValidated(): Unit {
        let table = sst("<si><t>x</t></si>")
        @Assert(table.size, 1)
    }
}

@Test
public class WorksheetParser_test {
    private static func parse(rows: String, options!: ExcelReadOptions = ExcelReadOptions()): ParsedSheet {
        WorksheetParser.parseSheet(worksheetXml(rows).toArray(), options, SharedStringTable.empty(), "S")
    }

    @TestCase
    public func inlineAndScalarTypes(): Unit {
        let parsed = parse(
            "<row r=\"1\">" +
                "<c r=\"A1\" t=\"inlineStr\"><is><t>文本</t></is></c>" +
                "<c r=\"B1\" t=\"b\"><v>1</v></c>" +
                "<c r=\"C1\" t=\"e\"><v>#DIV/0!</v></c>" +
                "<c r=\"D1\" t=\"str\"><v>公式结果</v></c>" +
                "<c r=\"E1\"><v>42</v></c>" +
                "</row>"
        )
        @Assert(parsed.rows.size, 1)
        let cells = parsed.rows[0].cells
        @Assert(cells.size, 5)
        @Assert(cells[0].value.toString(), "文本")
        @Assert(cells[1].value.toString(), "TRUE")
        @Assert(cells[2].value.toString(), "#DIV/0!")
        @Assert(cells[3].value.toString(), "公式结果")
        @Assert(match (cells[4].value) {
            case Number(v) => v
            case _ => 0.0
        }, 42.0)
    }

    @TestCase
    public func sharedStringLookup(): Unit {
        let table = SharedStringTable.load(
            ("<sst xmlns=\"${NS_MAIN}\"><si><t>hi</t></si><si><t>there</t></si></sst>").toArray()
        )
        let parsed = WorksheetParser.parseSheet(
            worksheetXml("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>1</v></c><c r=\"B1\" t=\"s\"><v>7</v></c></row>").toArray(),
            ExcelReadOptions(),
            table,
            "S"
        )
        let cells = parsed.rows[0].cells
        @Assert(cells[0].value.toString(), "there")
        // 越界：Empty + warning
        @Assert(match (cells[1].value) {
            case Empty => true
            case _ => false
        }, true)
        @Assert(parsed.warnings.size, 1)
        @Assert(parsed.warnings[0].kind, ExcelWarningKind.SharedStringIndexOutOfRange)
    }

    @TestCase
    public func sparseRowKeepsOnlyPresentCells(): Unit {
        let parsed = parse("<row r=\"5\"><c r=\"C5\"><v>1</v></c></row>")
        @Assert(parsed.rows[0].index, 5)
        @Assert(parsed.rows[0].cells.size, 1)
        @Assert(parsed.rows[0].cells[0].col, 3)
    }

    @TestCase
    public func missingRefsAreInferredWithWarnings(): Unit {
        let parsed = parse("<row><c><v>1</v></c><c><v>2</v></c></row>")
        @Assert(parsed.rows[0].index, 1)
        @Assert(parsed.rows[0].cells[0].col, 1)
        @Assert(parsed.rows[0].cells[1].col, 2)
        @Assert(parsed.warnings.size, 3)
        @Assert(parsed.warnings[0].kind, ExcelWarningKind.MissingRowIndex)
    }

    @TestCase
    public func styleOnlyCellIsEmptyNotAbsent(): Unit {
        let parsed = parse("<row r=\"1\"><c r=\"A1\" s=\"3\"/></row>")
        @Assert(match (parsed.rows[0].cells[0].value) {
            case Empty => true
            case _ => false
        }, true)
    }

    @TestCase
    public func unknownTypeFallsBackToText(): Unit {
        let parsed = parse("<row r=\"1\"><c r=\"A1\" t=\"z\"><v>raw</v></c></row>")
        @Assert(parsed.rows[0].cells[0].value.toString(), "raw")
        @Assert(parsed.warnings[0].kind, ExcelWarningKind.UnknownCellType)
    }

    @TestCase
    public func badNumberBecomesText(): Unit {
        let parsed = parse("<row r=\"1\"><c r=\"A1\"><v>1,5</v></c></row>")
        @Assert(parsed.rows[0].cells[0].value.toString(), "1,5")
        @Assert(parsed.warnings[0].kind, ExcelWarningKind.NumberParseFailed)
    }

    @TestCase
    public func formulaKeepsSourceAndCache(): Unit {
        let parsed = parse("<row r=\"1\"><c r=\"B1\"><f>SUM(A1:A10)</f><v>55</v></c></row>")
        let value = match (parsed.rows[0].cells[0].value) {
            case Formula(src, cached) => "${src}|${cached.getOrThrow().toString()}"
            case _ => "?"
        }
        @Assert(value, "SUM(A1:A10)|55.000000")
    }

    @TestCase
    public func mergesAndDimension(): Unit {
        let xml =
            "<?xml version=\"1.0\"?><worksheet xmlns=\"${NS_MAIN}\">" +
                "<dimension ref=\"A1:B2\"/><sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>" +
                "<mergeCells count=\"1\"><mergeCell ref=\"A1:B2\"/></mergeCells></worksheet>"
        let parsed = WorksheetParser.parseSheet(xml.toArray(), ExcelReadOptions(), SharedStringTable.empty(), "S")
        @Assert(parsed.dimension.getOrThrow(), "A1:B2")
        @Assert(parsed.merges.size, 1)
        @Assert(parsed.merges[0], "A1:B2")
    }

    @TestCase
    public func maxRowsTruncates(): Unit {
        let options = ExcelReadOptions()
        options.maxRows = 1
        let parsed = parse("<row r=\"1\"><c r=\"A1\"><v>1</v></c></row><row r=\"2\"><c r=\"A2\"><v>2</v></c></row>", options: options)
        @Assert(parsed.rows.size, 1)
        @Assert(parsed.warnings[0].kind, ExcelWarningKind.MaxRowsTruncated)
    }
}

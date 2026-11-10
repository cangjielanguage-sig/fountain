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
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class M4_test {
    private static let STYLES: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
        "<styleSheet xmlns=\"${NS_MAIN}\">" +
        "<fonts count=\"1\"><font><sz val=\"11\"/></font></fonts>" +
        "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill>" +
        "<fill><patternFill patternType=\"gray125\"/></fill></fills>" +
        "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
        "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>" +
        "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>" +
        "<dxfs count=\"1\"><dxf><font><color rgb=\"FF9C0006\"/></font>" +
        "<fill><patternFill><bgColor rgb=\"FFFFC7CE\"/></patternFill></fill></dxf></dxfs>" +
        "</styleSheet>"

    private static func sheetWithRules(): String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"${NS_MAIN}\"><sheetData>" +
            "<row r=\"1\"><c r=\"A1\"><v>5</v></c><c r=\"B1\"><v>25</v></c></row>" +
            "<row r=\"2\"><c r=\"A2\"><v>50</v></c><c r=\"B2\"><v>75</v></c></row>" +
            "<row r=\"3\"><c r=\"A3\"><v>100</v></c><c r=\"B3\"><v>100</v></c></row>" +
            "</sheetData>" +
            "<conditionalFormatting sqref=\"A1:A3\">" +
            "<cfRule type=\"cellIs\" dxfId=\"0\" priority=\"1\" operator=\"greaterThan\"><formula>50</formula></cfRule>" +
            "<cfRule type=\"colorScale\" priority=\"2\"><colorScale>" +
            "<cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>" +
            "<color rgb=\"FFF8696B\"/><color rgb=\"FFFFEB84\"/><color rgb=\"FF63BE7B\"/>" +
            "</colorScale></cfRule>" +
            "</conditionalFormatting>" +
            "<conditionalFormatting sqref=\"B1:B3\">" +
            "<cfRule type=\"dataBar\" priority=\"1\"><dataBar><cfvo type=\"min\"/><cfvo type=\"max\"/>" +
            "<color rgb=\"FF638EC6\"/></dataBar></cfRule>" +
            "</conditionalFormatting>" +
            "</worksheet>"
    }

    private static func docWithRules(): ExcelDocument {
        ExcelDocument(
            ByteBuffer(
                buildXlsx(
                    [sheetWithRules()],
                    parts: [("xl/styles.xml", STYLES)]
                )
            )
        )
    }

    @TestCase
    public func parseAndMatchCellIs(): Unit {
        let doc = docWithRules()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        @Assert(sheet.conditionalFormats().size, 2)
        let low = sheet.matchedRules(1, 1)
        @Assert(low.size, 1) // 只有 colorScale 命中
        @Assert(low[0].rule.ruleType, CfRuleType.ColorScale)
        let high = sheet.matchedRules(3, 1)
        @Assert(high.size, 2)
        @Assert(high[0].rule.ruleType, CfRuleType.CellIs)
        @Assert(high[0].format.fill.getOrThrow(), "FFFFC7CE")
        @Assert(high[0].format.fontColor.getOrThrow(), "FF9C0006")
    }

    @TestCase
    public func colorScaleInterpolates(): Unit {
        let doc = docWithRules()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        let min = sheet.matchedRules(1, 1)
        @Assert(min[0].format.fill.getOrThrow(), "FFF8696B")
        let max = sheet.matchedRules(3, 1)
        @Assert(max[1].format.fill.getOrThrow(), "FF63BE7B")
        let mid = sheet.matchedRules(2, 1)
        @Assert(mid.size, 1)
        @Assert(mid[0].rule.ruleType, CfRuleType.ColorScale)
        @Assert(mid[0].format.fill.isSome(), true)
    }

    @TestCase
    public func dataBarLength(): Unit {
        let doc = docWithRules()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        let low = sheet.matchedRules(1, 2)
        @Assert(low.size, 1)
        @Assert(low[0].format.dataBarLength.getOrThrow(), 0.0)
        let high = sheet.matchedRules(3, 2)
        @Assert(high[0].format.dataBarLength.getOrThrow(), 1.0)
        let mid = sheet.matchedRules(2, 2)
        @Assert(abs(mid[0].format.dataBarLength.getOrThrow() - 0.6666666666666666) < 1e-9, true)
    }

    @TestCase
    public func stopIfTrueStopsLaterRules(): Unit {
        let sheetXml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"${NS_MAIN}\"><sheetData>" +
            "<row r=\"1\"><c r=\"A1\"><v>5</v></c></row></sheetData>" +
            "<conditionalFormatting sqref=\"A1\">" +
            "<cfRule type=\"cellIs\" priority=\"1\" operator=\"greaterThan\" stopIfTrue=\"1\"><formula>0</formula></cfRule>" +
            "<cfRule type=\"cellIs\" priority=\"2\" operator=\"greaterThan\"><formula>0</formula></cfRule>" +
            "</conditionalFormatting></worksheet>"
        let doc = ExcelDocument(ByteBuffer(buildXlsx([sheetXml])))
        let matches = doc.sheet("Sheet1").getOrThrow().matchedRules(1, 1)
        @Assert(matches.size, 1)
        @Assert(matches[0].rule.priority, 1)
    }

    @TestCase
    public func expressionRuleViaEngine(): Unit {
        let sheetXml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"${NS_MAIN}\"><sheetData>" +
            "<row r=\"1\"><c r=\"A1\"><v>5</v></c></row>" +
            "<row r=\"2\"><c r=\"A2\"><v>50</v></c></row>" +
            "<row r=\"3\"><c r=\"A3\"><v>100</v></c></row></sheetData>" +
            "<conditionalFormatting sqref=\"A1:A3\">" +
            "<cfRule type=\"expression\" priority=\"1\"><formula>A1&gt;10</formula></cfRule>" +
            "</conditionalFormatting></worksheet>"
        let doc = ExcelDocument(ByteBuffer(buildXlsx([sheetXml])))
        let engine = CalcEngine(doc)
        @Assert(engine.matchedRules("Sheet1", 1, 1).size, 0)
        @Assert(engine.matchedRules("Sheet1", 2, 1).size, 1)
        @Assert(engine.matchedRules("Sheet1", 3, 1).size, 1)
    }

    @TestCase
    public func roundTripPreservesRules(): Unit {
        let doc = docWithRules()
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let back = ExcelDocument(ByteBuffer(buffer.bytes()))
        // 重新写出的包能被再次解析，且规则类型/公式/dxf 保留
        let sheet = back.sheet("Sheet1").getOrThrow()
        @Assert(sheet.conditionalFormats().size, 2)
        let first = sheet.conditionalFormats()[0]
        @Assert(first.range, "A1:A3")
        @Assert(first.rules.size, 2)
        @Assert(first.rules[0].ruleType, CfRuleType.CellIs)
        @Assert(first.rules[0].formulas[0], "50")
        @Assert(first.rules[0].format.isSome(), true)
        @Assert(first.rules[1].ruleType, CfRuleType.ColorScale)
        @Assert(sheet.matchedRules(3, 1).size, 2)
    }

    @TestCase
    public func addProgrammaticRule(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(5.0))
        let formulas = ArrayList<String>()
        formulas.add("3")
        sheet.addConditionalFormat(
            "A1:A3",
            CfRule(
                CfRuleType.CellIs,
                priority: 1,
                comparison: CfOperator.GreaterThan,
                formulas: formulas,
                format: CfFormat(fill: Some("FFFF0000"))
            )
        )
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let back = ExcelDocument(ByteBuffer(buffer.bytes())).sheet("Sheet1").getOrThrow()
        @Assert(back.conditionalFormats().size, 1)
        let matched = back.matchedRules(1, 1)
        @Assert(matched.size, 1)
        @Assert(matched[0].format.fill.getOrThrow(), "FFFF0000")
    }
}

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

import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Formula_test {
    private static func num(value: CalcValue): Float64 {
        match (value) {
            case Number(v) => v
            case _ => -999999.0
        }
    }

    private static func boolOf(value: CalcValue): Bool {
        match (value) {
            case Boolean(v) => v
            case _ => false
        }
    }

    private static func textOf(value: CalcValue): String {
        calcToText(value)
    }

    private static func calc(doc: ExcelDocument, engine: CalcEngine, formula: String): CalcValue {
        doc.sheet("Sheet1").getOrThrow().setCell("Z1", CellValue.Formula(formula, None))
        engine.evaluate("Sheet1", "Z1")
    }

    private static func sample(): (ExcelDocument, CalcEngine) {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("A2", CellValue.Number(2.0))
        sheet.setCell("A3", CellValue.Number(3.0))
        sheet.setCell("B1", CellValue.Number(10.0))
        sheet.setCell("B2", CellValue.Number(20.0))
        sheet.setCell("B3", CellValue.Number(30.0))
        (doc, CalcEngine(doc))
    }

    // ---------------------------------------------------------------- 词法 / 语法

    @TestCase
    public func lexerTokens(): Unit {
        let tokens = tokenizeFormula("SUM(A1:B2, \"a\"\"b\", 1.5E2)")
        @Assert(tokens[0].kind, FTokKind.Ident)
        @Assert(tokens[0].text, "SUM")
        @Assert(tokens[1].kind, FTokKind.LParen)
        @Assert(tokens[2].text, "A1")
        @Assert(tokens[3].kind, FTokKind.Colon)
        @Assert(tokens[5].kind, FTokKind.Comma)
        @Assert(tokens[6].kind, FTokKind.Str)
        @Assert(tokens[6].text, "a\"b")
        @Assert(tokens[8].kind, FTokKind.Num)
        @Assert(tokens[8].number, 150.0)
    }

    @TestCase
    public func precedenceMatchesExcel(): Unit {
        let (doc, engine) = sample()
        // 一元负号高于 ^：(-2)^2 = 4
        @Assert(num(calc(doc, engine, "=-2^2")), 4.0)
        // ^ 左结合：(2^3)^2 = 64
        @Assert(num(calc(doc, engine, "=2^3^2")), 64.0)
        // 乘法优先于加法
        @Assert(num(calc(doc, engine, "=1+2*3^2")), 19.0)
        // 后缀百分号
        @Assert(num(calc(doc, engine, "=50%")), 0.5)
        // 比较返回布尔
        @Assert(boolOf(calc(doc, engine, "=1<2")), true)
        // 文本比较不区分大小写
        @Assert(boolOf(calc(doc, engine, "=\"A\"=\"a\"")), true)
        // 连接
        @Assert(textOf(calc(doc, engine, "=\"a\"&1")), "a1")
    }

    @TestCase
    public func parserRejectsBadFormula(): Unit {
        @Assert(FormulaParser.parse("SUM(").isNone(), true)
        @Assert(FormulaParser.parse("1+").isNone(), true)
        @Assert(FormulaParser.parse("\"abc").isNone(), true)
        @Assert(FormulaParser.parse("A1:").isNone(), true)
    }

    @TestCase
    public func rangesAndSheetRefs(): Unit {
        let (doc, engine) = sample()
        @Assert(num(calc(doc, engine, "=SUM(A1:A3)")), 6.0)
        @Assert(num(calc(doc, engine, "=SUM($A$1:$A$3)")), 6.0)
        @Assert(num(calc(doc, engine, "='Sheet1'!A1+'Sheet1'!B1")), 11.0)

        // 整列 / 整行：公式放在区域之外，避免自引用
        let doc2 = ExcelDocument()
        let sheet = doc2.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("B1", CellValue.Number(10.0))
        sheet.setCell("B5", CellValue.Formula("SUM(A:A)", None))
        sheet.setCell("C6", CellValue.Formula("SUM(1:1)", None))
        let engine2 = CalcEngine(doc2)
        @Assert(num(engine2.evaluate("Sheet1", "B5")), 1.0)
        @Assert(num(engine2.evaluate("Sheet1", "C6")), 11.0)
    }

    @TestCase
    public func errorPropagationTakesFirst(): Unit {
        let (doc, engine) = sample()
        match (calc(doc, engine, "=1/0")) {
            case Error(e) => @Assert(e, CalcError.DivZero)
            case _ => @Assert(false, true)
        }
        match (calc(doc, engine, "=1+#DIV/0!+#VALUE!")) {
            case Error(e) => @Assert(e, CalcError.DivZero)
            case _ => @Assert(false, true)
        }
        match (calc(doc, engine, "=1+\"abc\"")) {
            case Error(e) => @Assert(e, CalcError.Value)
            case _ => @Assert(false, true)
        }
        match (calc(doc, engine, "=FOO(1)")) {
            case Error(e) => @Assert(e, CalcError.Name)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func ifIsLazy(): Unit {
        let (doc, engine) = sample()
        @Assert(num(calc(doc, engine, "=IF(TRUE,1,1/0)")), 1.0)
        @Assert(num(calc(doc, engine, "=IF(FALSE,1/0,2)")), 2.0)
    }

    @TestCase
    public func dependencyChainAndRecalculate(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("A2", CellValue.Formula("A1+1", None))
        sheet.setCell("A3", CellValue.Formula("A2*2", None))
        let engine = CalcEngine(doc)
        @Assert(num(engine.evaluate("Sheet1", "A3")), 4.0)
        let report = engine.recalculate()
        @Assert(report.recalculated, 2)
        @Assert(report.errors, 0)
    }

    @TestCase
    public func cycleIsReported(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Formula("B1", None))
        sheet.setCell("B1", CellValue.Formula("A1", None))
        let engine = CalcEngine(doc)
        match (engine.evaluate("Sheet1", "A1")) {
            case Error(e) => @Assert(e, CalcError.Circular)
            case _ => @Assert(false, true)
        }
        let report = engine.recalculate()
        @Assert(report.cycles.size >= 1, true)
    }

    @TestCase
    public func recalculateWriteBack(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(2.0))
        sheet.setCell("A2", CellValue.Formula("A1*3", Some(CellValue.Number(1.0))))
        let engine = CalcEngine(doc)
        engine.recalculate(writeBack: true)
        match (sheet.cell("A2").getOrThrow()) {
            case Formula(source, cached) =>
                @Assert(source, "A1*3")
                match (cached) {
                    case Some(Number(v)) => @Assert(v, 6.0)
                    case _ => @Assert(false, true)
                }
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func sharedFormulaShifts(): Unit {
        let sheetXml = worksheetXml(
            "<row r=\"2\"><c r=\"A2\"><v>1</v></c><c r=\"B2\"><f t=\"shared\" ref=\"B2:B3\" si=\"0\">A2*2</f><v>2</v></c></row>" +
                "<row r=\"3\"><c r=\"A3\"><v>2</v></c><c r=\"B3\"><f t=\"shared\" si=\"0\"/><v>4</v></c></row>"
        )
        let doc = ExcelDocument(ByteBuffer(buildXlsx([sheetXml])))
        let sheet = doc.sheet("Sheet1").getOrThrow()
        match (sheet.cell("B3").getOrThrow()) {
            case Formula(source, cached) =>
                @Assert(source, "A3*2")
                match (cached) {
                    case Some(Number(v)) => @Assert(v, 4.0)
                    case _ => @Assert(false, true)
                }
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func shiftRespectsAbsoluteRefs(): Unit {
        @Assert(shiftFormula("A1+$A$1+$A1+A$1", 1, 1), "B2+$A$1+$A2+B$1")
        @Assert(shiftFormula("A1", -1, 0), "#REF!")
        @Assert(shiftFormula("\"A1\"&A1", 1, 0), "\"A1\"&A2")
        @Assert(shiftFormula("LOG10(A1)", 1, 0), "LOG10(A2)")
    }

    @TestCase
    public func arrayFormulaKeepsCachedValue(): Unit {
        let sheetXml = worksheetXml(
            "<row r=\"1\"><c r=\"A1\"><f t=\"array\" ref=\"A1:A2\">B1:B2*2</f><v>8</v></c></row>" +
                "<row r=\"2\"><c r=\"A2\"><f t=\"array\" ref=\"A1:A2\"/><v>16</v></c></row>"
        )
        let doc = ExcelDocument(ByteBuffer(buildXlsx([sheetXml])))
        let sheet = doc.sheet("Sheet1").getOrThrow()
        match (sheet.cell("A1").getOrThrow()) {
            case Formula(source, _) => @Assert(source, "B1:B2*2")
            case _ => @Assert(false, true)
        }
        @Assert(doc.warnings().size >= 1, true)
    }
}

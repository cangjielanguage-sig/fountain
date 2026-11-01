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
package fountain::f_rule.table

import std.collection.ArrayList
import std.env
import std.fs.Path
import std.time.{DateTime, Month}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_excel.{CellValue, ExcelDocument, Worksheet}
import fountain::f_jit.Compiler
import fountain::f_rule.condition.{Operand, Operator}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.FieldType
import fountain::f_rule.rule.RuleSet

/**
 * XLSX 载体解析（`doc/07-decision-table.md` §6，用例 T-12~T-14）。
 *
 * 夹具一律在临时目录用 `f_excel` 现场生成，不依赖外部脚本；
 * `pricing.xlsx` 等真实夹具由 `doc/tools/gen_fixtures.py` 生成，用于 T-12 等价性。
 */
@Test
class XlsxTableParser_test {
    private func tempPath(name: String): Path {
        Path("${env.getTempDirectory()}/f_rule_xlsx_${name}.xlsx")
    }

    /** 新建工作簿，并去掉默认的 `Sheet1`，让 sheet 顺序与用例一致。 */
    private func newBook(name: String): ExcelDocument {
        let doc = ExcelDocument()
        let first = doc.addSheet(name)
        let _ = first
        let _ = doc.removeSheet("Sheet1")
        doc
    }

    private func putRow(sheet: Worksheet, index: Int64, cells: Array<CellValue>): Unit {
        var col: Int64 = 1
        for (value in cells) {
            sheet.setCell(index, col, value)
            col += 1
        }
    }

    private func text(value: String): CellValue {
        CellValue.Text(value)
    }

    private func number(value: Float64): CellValue {
        CellValue.Number(value)
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        try {
            action()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** 表头与数据行：列种类、绑定期望、规则 id 与物理行号。 */
    @TestCase
    public func parsesHeaderAndRows(): Unit {
        let path = tempPath("header")
        let doc = newBook("pricing")
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("name"), text("when.order.level"),
            text("when.order.amount"), text("then.discount"), text("then.event")])
        putRow(sheet, 2, [text("R1"), text("VIP 大额"), text(">=3"), text(">200"),
            number(0.85), text("order.discounted")])
        putRow(sheet, 3, [text("R2"), text("兜底"), text(""), text(""), number(1.0),
            text("order.discounted")])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        @Assert(table.id, "pricing")
        @Assert(table.columns.size, 6)
        @Expect(table.columns[0].kind, ColumnKind.Metadata)
        @Expect(table.columns[2].kind, ColumnKind.When)
        @Assert(table.columns[2].binding, "order")
        @Assert(table.columns[2].field, "level")
        @Expect(table.columns[4].kind, ColumnKind.Then)
        @Assert(table.rows.size, 2)
        @Assert(table.rows[0].ruleId, "R1")
        @Assert(table.rows[0].line, 2)
        @Assert(table.rows[0].values[2].getOrThrow(), ">=3")
        @Assert(table.rows[0].values[4].getOrThrow(), "0.85")
        @Assert(table.rows[1].ruleId, "R2")
        @Assert(table.rows[1].line, 3)
        @Expect(table.rows[1].values[2].isNone(), true)
    }

    /** `_meta` sheet：key/value 两列承载表属性。 */
    @TestCase
    public func readsMetaSheet(): Unit {
        let path = tempPath("meta")
        let doc = newBook("pricing")
        let meta = doc.addSheet("_meta")
        putRow(meta, 1, [text("key"), text("value")])
        putRow(meta, 2, [text("id"), text("pricing")])
        putRow(meta, 3, [text("name"), text("订单折扣")])
        putRow(meta, 4, [text("version"), text("v2")])
        putRow(meta, 5, [text("factSpace"), text("orders")])
        putRow(meta, 6, [text("hitPolicy"), text("Collect")])
        putRow(meta, 7, [text("salience"), text("100")])
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), text(">=3"), number(0.85)])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        @Assert(table.id, "pricing")
        @Assert(table.name, "订单折扣")
        @Assert(table.version, "v2")
        @Assert(table.factSpace, "orders")
        @Expect(table.hitPolicy, HitPolicy.Collect)
        @Expect(table.salience, 100)
        @Assert(table.rows.size, 1)
    }

    /** 类型行：覆盖按单元格推断，且数据行从第 3 行开始。 */
    @TestCase
    public func typeRowOverridesInference(): Unit {
        let path = tempPath("typerow")
        let doc = newBook("pricing")
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("name"), text("when.order.level"),
            text("when.order.amount"), text("when.order.at"), text("then.extra")])
        putRow(sheet, 2, [text("text"), text("text"), text("number"), text("number"),
            text("time"), CellValue.Empty])
        putRow(sheet, 3, [text("R1"), text("大额"), text("3"), number(500.0),
            text("2026-01-01 00:00:00"), number(7.0)])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        @Assert(table.rows.size, 1)
        @Assert(table.rows[0].line, 3)
        @Expect(table.columnTypeAt(0).getOrThrow(), FieldType.Text)
        @Expect(table.columnTypeAt(2).getOrThrow(), FieldType.Number)
        @Expect(table.columnTypeAt(3).getOrThrow(), FieldType.Number)
        @Expect(table.columnTypeAt(4).getOrThrow(), FieldType.Time)
        // 类型行没写的列仍然按单元格推断
        @Expect(table.columnTypeAt(5).getOrThrow(), FieldType.Number)
        // 类型行只影响列类型，不改写单元格文本
        @Assert(table.rows[0].values[2].getOrThrow(), "3")
    }

    /** 无类型行时第 2 行就是数据行；列类型按单元格推断。 */
    @TestCase
    public func treatsSecondRowAsDataWithoutTypeRow(): Unit {
        let path = tempPath("notyperow")
        let doc = newBook("pricing")
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), number(3.0), number(0.85)])
        putRow(sheet, 3, [text("R2"), number(1.0), number(0.9)])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        @Assert(table.rows.size, 2)
        @Assert(table.rows[0].line, 2)
        @Expect(table.columnTypeAt(0).getOrThrow(), FieldType.Text)
        @Expect(table.columnTypeAt(1).getOrThrow(), FieldType.Number)
        @Expect(table.columnTypeAt(2).getOrThrow(), FieldType.Number)
        @Assert(table.rows[0].values[1].getOrThrow(), "3")
    }

    /** sheet 名是表 id：没有 `_meta` 时直接取 sheet 名。 */
    @TestCase
    public func usesSheetNameAsTableId(): Unit {
        let path = tempPath("sheetid")
        let doc = newBook("discounts")
        let sheet = doc.sheet("discounts").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), text(">=1"), number(1.0)])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "discounts")
        @Assert(table.id, "discounts")
        // 缺省表属性
        @Assert(table.factSpace, "default")
        @Expect(table.hitPolicy, HitPolicy.First)
        @Expect(table.salience, 0)
    }

    /** `CellValue` 八变体 → 文本与载体类型。 */
    @TestCase
    public func mapsAllCellVariants(): Unit {
        let path = tempPath("variants")
        let doc = newBook("variants")
        let sheet = doc.sheet("variants").getOrThrow()
        putRow(sheet, 1, [text("id"), text("then.num"), text("then.text"), text("then.bool"),
            text("then.date"), text("then.span"), text("then.formula"), text("then.blank")])
        putRow(sheet, 2, [text("R1"), number(3.5), text("VIP 大额"), CellValue.Boolean(true),
            CellValue.Date(DateTime.of(year: 2026, month: Month.of(3), dayOfMonth: 5,
                hour: 8, minute: 30, second: 0)),
            CellValue.TimeSpan(Duration.minute * 90),
            CellValue.Formula("1+1", Some(CellValue.Number(2.0))), CellValue.Empty])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "variants")
        let values = table.rows[0].values
        @Assert(values[1].getOrThrow(), "3.5")
        @Assert(values[2].getOrThrow(), "VIP 大额")
        @Assert(values[3].getOrThrow(), "true")
        @Assert(values[4].getOrThrow(), "2026-03-05 08:30:00")
        @Assert(values[5].getOrThrow(), "5400")
        @Assert(values[6].getOrThrow(), "2")
        @Expect(values[7].isNone(), true)
        @Expect(table.columnTypeAt(3).getOrThrow(), FieldType.`Bool`)
        @Expect(table.columnTypeAt(4).getOrThrow(), FieldType.Time)
        @Expect(table.columnTypeAt(5).getOrThrow(), FieldType.Number)
    }

    /** 错误单元格是坏数据，抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsErrorCell(): Unit {
        let path = tempPath("errorcell")
        let doc = newBook("broken")
        let sheet = doc.sheet("broken").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), CellValue.Error("#DIV/0!"), number(0.85)])
        doc.write(path)

        let code = codeOf({ => XlsxTableParser.parse(path, "broken") })
        @Expect(code, RuleErrorCode.TABLE_INVALID)
    }

    /** 公式没有缓存值无法在构建期定值，抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsFormulaWithoutCachedValue(): Unit {
        let path = tempPath("formula")
        let doc = newBook("broken")
        let sheet = doc.sheet("broken").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), CellValue.Formula("A9+1", None), number(0.85)])
        doc.write(path)

        let code = codeOf({ => XlsxTableParser.parse(path, "broken") })
        @Expect(code, RuleErrorCode.TABLE_INVALID)
    }

    private func couponRuleSet(): RuleSet {
        tableRuleSet("coupons") { space =>
            space.register(tableCouponSchema())
        }
    }

    /** 数字单元格 + 文本字段声明：冲突时以字段声明为准并 WARN。 */
    @TestCase
    public func fieldDeclarationWinsOverCellType(): Unit {
        let path = tempPath("conflict")
        let doc = newBook("codes")
        let meta = doc.addSheet("_meta")
        putRow(meta, 1, [text("key"), text("value")])
        putRow(meta, 2, [text("factSpace"), text("coupons")])
        let sheet = doc.sheet("codes").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.coupon.code"), text("then.flag")])
        putRow(sheet, 2, [text("R1"), number(42.0), text("hit")])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "codes")
        @Expect(table.columnTypeAt(1).getOrThrow(), FieldType.Number)
        let ruleSet = couponRuleSet()
        let compiler = Compiler()
        compiler.registerType<TableCoupon>()
        let compiled = TableCompiler(table, ruleSet.registry, compiler).compile()

        @Assert(compiled.warnings.size, 1)
        @Assert(compiled.warnings[0].contains("coupon.code"), true)
        @Assert(compiled.warnings[0].contains("以字段声明为准"), true)
        // 字段是 Text，因此取到的常量是字符串 "42"
        let condition = compiled.rows[0].conditions[0]
        @Expect(condition.constraint.getOrThrow().op, Operator.Eq)
        match (condition.constraint.getOrThrow().right) {
            case Operand.Const(value) => @Expect(value as String, "42")
            case _ => @Fail("常量右值期望是 String")
        }
    }

    /** 单元格类型与字段声明一致时不产生 WARN。 */
    @TestCase
    public func noWarningWhenCellTypeMatchesField(): Unit {
        let path = tempPath("nocontlict")
        let doc = newBook("pricing")
        let meta = doc.addSheet("_meta")
        putRow(meta, 1, [text("key"), text("value")])
        putRow(meta, 2, [text("factSpace"), text("orders")])
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), number(3.0), number(0.85)])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        let ruleSet = tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
        let compiler = Compiler()
        compiler.registerType<TableOrder>()
        let compiled = TableCompiler(table, ruleSet.registry, compiler).compile()
        @Expect(compiled.warnings.size, 0)
        match (compiled.rows[0].conditions[0].constraint.getOrThrow().right) {
            case Operand.Const(value) => @Expect(value as Int64, 3)
            case _ => @Fail("常量右值期望是 Int64")
        }
    }

    /** T-13：`A3:C3` 合并，左上角 `>=3`，该行三列都取 `>=3`。 */
    @TestCase
    public func mergedCellTakesTopLeftValue(): Unit {
        let path = tempPath("merged")
        let doc = newBook("pricing")
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("when.order.amount"),
            text("then.discount")])
        putRow(sheet, 2, [text("text"), text("number"), text("number"), text("number")])
        putRow(sheet, 3, [text(">=3"), CellValue.Empty, CellValue.Empty, number(0.85)])
        sheet.merge("A3:C3")
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        let values = table.rows[0].values
        @Assert(values.size, 4)
        @Assert(values[0].getOrThrow(), ">=3")
        @Assert(values[1].getOrThrow(), ">=3")
        @Assert(values[2].getOrThrow(), ">=3")
        @Assert(values[3].getOrThrow(), "0.85")
    }

    /** 合并区域覆盖的每个单元格都与 `Worksheet.mergedValue` 一致（含纵向合并）。 */
    @TestCase
    public func mergedCellsAgreeWithMergedValue(): Unit {
        let path = tempPath("mergedvalue")
        let doc = newBook("pricing")
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("name"), text("when.order.level"), text("then.discount")])
        putRow(sheet, 2, [text("R1"), text("大额"), text(">=3"), number(0.85)])
        putRow(sheet, 3, [text("R2"), text("普通"), text(">=1"), number(0.9)])
        // A2:A3 纵向合并 + B2:C2 横向合并
        sheet.merge("A2:A3")
        sheet.merge("B2:C2")
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        let reread = ExcelDocument(path).sheet("pricing").getOrThrow()
        // A3 被 A2:A3 覆盖 → 取 A2 的值
        @Assert(table.rows[1].values[0].getOrThrow(), table.rows[0].values[0].getOrThrow())
        @Assert(table.rows[0].values[0].getOrThrow(), "R1")
        // B2:C2 覆盖后，row2 的 level 列取 B2 的 "大额"
        @Assert(table.rows[0].values[2].getOrThrow(), "大额")
        for (pair in [(2, 1), (3, 1), (2, 2), (2, 3)]) {
            let covered = reread.mergedValue(pair[0], pair[1])
            @Expect(covered.isSome(), true)
        }
        // 未被合并覆盖的单元格照常取自身值
        @Assert(table.rows[1].values[2].getOrThrow(), ">=1")
    }

    /** 一个工作簿多张表：`parse(path)` 按工作簿顺序返回全部决策表。 */
    @TestCase
    public func parsesAllSheets(): Unit {
        let path = tempPath("multi")
        let doc = newBook("pricing")
        let meta = doc.addSheet("_meta")
        putRow(meta, 1, [text("key"), text("value")])
        putRow(meta, 2, [text("version"), text("v3")])
        let pricing = doc.sheet("pricing").getOrThrow()
        putRow(pricing, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(pricing, 2, [text("R1"), number(3.0), number(0.85)])
        putRow(pricing, 3, [text("R2"), number(1.0), number(0.9)])
        let users = doc.addSheet("users")
        putRow(users, 1, [text("id"), text("when.user.level"), text("then.vip")])
        putRow(users, 2, [text("U1"), number(2.0), CellValue.Boolean(true)])
        doc.write(path)

        let tables = XlsxTableParser.parse(path)
        @Assert(tables.size, 2)
        @Assert(tables[0].id, "pricing")
        @Assert(tables[0].version, "v3")
        @Assert(tables[0].rows.size, 2)
        @Assert(tables[1].id, "users")
        @Assert(tables[1].rows.size, 1)
    }

    /** 指定 sheet 取单表；sheet 不存在抛 `TABLE_INVALID`。 */
    @TestCase
    public func parsesSingleSheet(): Unit {
        let path = tempPath("single")
        let doc = newBook("pricing")
        let users = doc.addSheet("users")
        putRow(users, 1, [text("id"), text("when.user.level"), text("then.vip")])
        putRow(users, 2, [text("U1"), number(2.0), CellValue.Boolean(true)])
        let pricing = doc.sheet("pricing").getOrThrow()
        putRow(pricing, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(pricing, 2, [text("R1"), number(3.0), number(0.85)])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "users")
        @Assert(table.id, "users")
        @Assert(table.rows.size, 1)
        @Expect(codeOf({ => XlsxTableParser.parse(path, "missing") }), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf({ => XlsxTableParser.parse(path, "_meta") }), RuleErrorCode.TABLE_INVALID)
    }

    /** 流式路径：逐表迭代，数据行按需读取、不回写 `rows`（T-14 的体积不变式）。 */
    @TestCase
    public func streamsTablesLazily(): Unit {
        let path = tempPath("stream")
        let doc = newBook("pricing")
        let meta = doc.addSheet("_meta")
        putRow(meta, 1, [text("key"), text("value")])
        putRow(meta, 2, [text("factSpace"), text("orders")])
        let pricing = doc.sheet("pricing").getOrThrow()
        putRow(pricing, 1, [text("id"), text("when.order.level"), text("then.discount")])
        putRow(pricing, 2, [text("text"), text("number"), text("number")])
        putRow(pricing, 3, [text("R1"), number(3.0), number(0.85)])
        putRow(pricing, 4, [text("R2"), number(1.0), number(0.9)])
        let users = doc.addSheet("users")
        putRow(users, 1, [text("id"), text("then.note")])
        putRow(users, 2, [text("U1"), text("only")])
        doc.write(path)

        let ids = ArrayList<String>()
        var first: ?DecisionTable = None
        for (table in XlsxTableParser.stream(path)) {
            ids.add(table.id)
            if (first.isNone()) {
                first = Some(table)
            }
        }
        @Assert(ids.size, 2)
        @Assert(ids[0], "pricing")
        @Assert(ids[1], "users")

        let table = first.getOrThrow()
        @Expect(table.rows.isEmpty(), true)
        @Expect(table.streaming, true)
        @Expect(table.columnTypeAt(1).getOrThrow(), FieldType.Number)
        let rows = ArrayList<TableRow>()
        for (row in table.rowIterator()) {
            rows.add(row)
        }
        @Assert(rows.size, 2)
        @Assert(rows[0].ruleId, "R1")
        @Assert(rows[0].line, 3)
        @Assert(rows[0].values[1].getOrThrow(), "3")
        @Assert(rows[1].ruleId, "R2")

        // 惰性表可以直接编译：编译器消费行来源而不是 rows
        let ruleSet = tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
        let compiler = Compiler()
        compiler.registerType<TableOrder>()
        let compiled = TableCompiler(table, ruleSet.registry, compiler).compile()
        @Expect(compiled.rules.size, 2)
        @Assert(compiled.rules[0].id, "pricing/R1")
    }

    private func ordersRuleSet(): RuleSet {
        tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
    }
    private func orderCompiler(): Compiler {
        let compiler = Compiler()
        compiler.registerType<TableOrder>()
        compiler
    }

    /** 把字面量归一成可比较文本：数字统一按数值比对（`1` 与 `1.0` 等价）。 */
    private func literalKey(value: Any): String {
        match (value) {
            case integral: Int64 => "n:${Float64(integral)}"
            case real: Float64 => "n:${real}"
            case text: String => "s:${text}"
            case flag: Bool => "b:${flag}"
            case moment: DateTime => "t:${moment}"
            case _ => "?"
        }
    }

    private func operandKey(value: Operand): String {
        match (value) {
            case Operand.Const(constant) => "C:${literalKey(constant)}"
            case Operand.Field(name) => "F:${name}"
            case Operand.Bind(binding, field) => "B:${binding}.${field}"
        }
    }

    private func sourceKey(cell: OutputCell): String {
        match (cell.source) {
            case OutputSource.Literal(value) => "L:${literalKey(value)}"
            case OutputSource.FieldRef(binding, field) => "F:${binding}.${field}"
            case OutputSource.BindingRef(binding) => "B:${binding}"
        }
    }

    /** 一行编译结果的可比对快照：规则身份、模式约束、脚本与输出逐项展开。 */
    private func canonicalRow(compiled: CompiledTable, index: Int64): String {
        let row = compiled.rows[index]
        let rule = row.rule
        var out = "${rule.id}|${rule.salience}|${rule.factSpace}|${rule.explicitSpace}|" +
            "${row.salience}|"
        out += match (rule.activationGroup) {
            case Some(group) => group
            case None => "-"
        }
        out += "|"
        for (pattern in rule.patterns) {
            out += "${pattern.typeTag}/${pattern.binding}("
            for (constraint in pattern.constraints) {
                out += "${constraint.field}${constraint.op}${operandKey(constraint.right)};"
            }
            out += ")"
        }
        out += "|"
        for (script in rule.scripts) {
            out += "${script};"
        }
        out += "|"
        for (output in row.outputs) {
            out += "${output.name}=${sourceKey(output.cell)};"
        }
        out
    }

    /** T-12：`pricing.xlsx` 与 `pricing.csv` 编译出的规则逐字段相同。 */
    @TestCase
    public func pricingXlsxMatchesPricingCsv(): Unit {
        let xlsx = XlsxTableParser.parse(Path("src/fixtures/pricing.xlsx"), "pricing")
        let csv = CsvTableParser.parseFile(Path("src/fixtures/pricing.csv"))

        @Assert(xlsx.id, csv.id)
        @Assert(xlsx.name, csv.name)
        @Assert(xlsx.version, csv.version)
        @Assert(xlsx.factSpace, csv.factSpace)
        @Expect(xlsx.hitPolicy, csv.hitPolicy)
        @Expect(xlsx.salience, csv.salience)
        @Assert(xlsx.columns.size, csv.columns.size)
        @Assert(xlsx.rows.size, csv.rows.size)
        var index: Int64 = 0
        while (index < Int64(csv.columns.size)) {
            @Assert(xlsx.columns[index].name, csv.columns[index].name)
            @Expect(xlsx.columns[index].kind, csv.columns[index].kind)
            index += 1
        }

        let ruleSet = ordersRuleSet()
        let compiler = orderCompiler()
        let fromXlsx = TableCompiler(xlsx, ruleSet.registry, compiler).compile()
        let fromCsv = TableCompiler(csv, ruleSet.registry, compiler).compile()
        @Assert(fromXlsx.rules.size, fromCsv.rules.size)
        @Assert(fromXlsx.rules.size, 3)
        @Expect(fromXlsx.warnings.size, 0)
        index = 0
        while (index < Int64(fromCsv.rows.size)) {
            @Assert(canonicalRow(fromXlsx, index), canonicalRow(fromCsv, index))
            index += 1
        }
    }

    /** T-15：只有表头没有数据行的 XLSX 表，编译期抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsEmptyTable(): Unit {
        let path = tempPath("empty")
        let doc = newBook("pricing")
        let meta = doc.addSheet("_meta")
        putRow(meta, 1, [text("key"), text("value")])
        putRow(meta, 2, [text("factSpace"), text("orders")])
        let sheet = doc.sheet("pricing").getOrThrow()
        putRow(sheet, 1, [text("id"), text("when.order.level"), text("then.discount")])
        doc.write(path)

        let table = XlsxTableParser.parse(path, "pricing")
        @Expect(table.rows.isEmpty(), true)
        let ruleSet = ordersRuleSet()
        let code = codeOf({ =>
            let _ = TableCompiler(table, ruleSet.registry, orderCompiler()).compile()
        })
        @Expect(code, RuleErrorCode.TABLE_INVALID)
    }

    /** T-14：10 万行工作簿走流式路径，行不材料化、逐行可读。 */
    @TestCase
    public func streamsLargeWorkbookWithoutMaterializingRows(): Unit {
        let path = Path("src/fixtures/pricing_large.xlsx")
        var found: ?DecisionTable = None
        for (table in XlsxTableParser.stream(path)) {
            if (found.isNone()) {
                found = Some(table)
            }
        }
        let table = found.getOrThrow()
        @Assert(table.id, "pricing_large")
        @Assert(table.factSpace, "orders")
        // 不回写 rows：10 万行也没有任何一行留在表模型里
        @Expect(table.rows.isEmpty(), true)
        @Expect(table.streaming, true)

        var count: Int64 = 0
        var firstRuleId = ""
        var lastRuleId = ""
        for (row in table.rowIterator()) {
            if (count == 0) {
                firstRuleId = row.ruleId
            }
            lastRuleId = row.ruleId
            count += 1
        }
        @Expect(count, 100_000)
        @Assert(firstRuleId, "L1")
        @Assert(lastRuleId, "L100000")
    }
}

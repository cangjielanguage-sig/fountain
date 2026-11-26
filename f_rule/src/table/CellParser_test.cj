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

import std.time.{DateTime, Month}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.Operator
import fountain::f_rule.exception.*
import fountain::f_rule.fact.FieldType

/**
 * 条件单元格解析（`doc/07-decision-table.md` §4.1，用例 T-05）。
 *
 * 覆盖 13 种条件写法、`-`/空单元格等价、各 `FieldType` 的值解析与非法值报错。
 */
@Test
class CellParser_test {
    private func parse(cell: String, fieldType: FieldType): ConditionCell {
        CellParser.parseCondition(Some(cell), fieldType).getOrThrow()
    }

    private func codeOf(cell: String, fieldType: FieldType): RuleErrorCode {
        try {
            let _ = CellParser.parseCondition(Some(cell), fieldType).getOrThrow()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** 空单元格与 `-` 都表示不约束。 */
    @TestCase
    public func emptyAndDashAreUnconstrained(): Unit {
        @Expect(CellParser.parseCondition(None, FieldType.Number).isNone(), true)
        @Expect(CellParser.parseCondition(Some(""), FieldType.Number).isNone(), true)
        @Expect(CellParser.parseCondition(Some("  "), FieldType.Number).isNone(), true)
        @Expect(CellParser.parseCondition(Some("-"), FieldType.Number).isNone(), true)
        @Expect(CellParser.parseCondition(Some(" - "), FieldType.Text).isNone(), true)
    }

    /** 比较类算子：`== /= != > >= < <=`。 */
    @TestCase
    public func parsesComparisonOperators(): Unit {
        @Expect(parse("== 3", FieldType.Number).op, Operator.Eq)
        @Expect(parse("= 3", FieldType.Number).op, Operator.Eq)
        @Expect(parse("!= 3", FieldType.Number).op, Operator.Ne)
        @Expect(parse("> 200", FieldType.Number).op, Operator.Gt)
        @Expect(parse(">= 200", FieldType.Number).op, Operator.Ge)
        @Expect(parse("< 200", FieldType.Number).op, Operator.Lt)
        @Expect(parse("<= 200", FieldType.Number).op, Operator.Le)
        @Assert(parse(">=200", FieldType.Number).value.getOrThrow() as Int64, 200)
    }

    /** 集合类算子：`in` / `not in` / `between`。 */
    @TestCase
    public func parsesSetOperators(): Unit {
        let inCell = parse("in [1, 2, 3]", FieldType.Number)
        @Expect(inCell.op, Operator.In)
        let values = ((inCell.value.getOrThrow() as Array<Any>).getOrThrow())
        @Expect(values.size, 3)
        @Assert(values[1] as Int64, 2)

        let notIn = parse("not in ['A', 'B']", FieldType.Text)
        @Expect(notIn.op, Operator.NotIn)
        let texts = ((notIn.value.getOrThrow() as Array<Any>).getOrThrow())
        @Assert(texts[0] as String, "A")
        @Assert(texts[1] as String, "B")

        let between = parse("between [1, 100]", FieldType.Number)
        @Expect(between.op, Operator.Between)
        let range = ((between.value.getOrThrow() as Array<Any>).getOrThrow())
        @Expect(range.size, 2)
        @Assert(range[0] as Int64, 1)
        @Assert(range[1] as Int64, 100)
    }

    /** 文本类算子。 */
    @TestCase
    public func parsesTextOperators(): Unit {
        @Expect(parse("contains foo", FieldType.Text).op, Operator.Contains)
        @Assert(parse("contains foo", FieldType.Text).value.getOrThrow() as String, "foo")
        @Expect(parse("startsWith ABC", FieldType.Text).op, Operator.StartsWith)
        @Expect(parse("endsWith XYZ", FieldType.Text).op, Operator.EndsWith)
        @Expect(parse("matches ^[A-Z]+$", FieldType.Text).op, Operator.Matches)
        @Assert(parse("matches ^[A-Z]+$", FieldType.Text).value.getOrThrow() as String, "^[A-Z]+$")
    }

    /** `null` / `not null`。 */
    @TestCase
    public func parsesNullOperators(): Unit {
        @Expect(parse("null", FieldType.Text).op, Operator.IsNull)
        @Expect(parse("NULL", FieldType.Text).op, Operator.IsNull)
        @Expect(parse("not null", FieldType.Text).op, Operator.NotNull)
        @Expect(parse("not null", FieldType.Text).value.isNone(), true)
    }

    /** 裸值等价于 `==`，按字段类型解析。 */
    @TestCase
    public func bareValueIsEquality(): Unit {
        let number = parse("3", FieldType.Number)
        @Expect(number.op, Operator.Eq)
        @Assert(number.value.getOrThrow() as Int64, 3)
        let text = parse("abc", FieldType.Text)
        @Expect(text.op, Operator.Eq)
        @Assert(text.value.getOrThrow() as String, "abc")
    }

    /** 以算子符号开头但不是合法算子时抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsIllegalOperator(): Unit {
        @Expect(codeOf(">> 3", FieldType.Number), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf("=! 3", FieldType.Number), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf("in 1, 2", FieldType.Number), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf("between [1]", FieldType.Number), RuleErrorCode.TABLE_INVALID)
    }

    /** Number：整数优先，含 `.`/`e` 转浮点。 */
    @TestCase
    public func parsesNumbers(): Unit {
        @Assert(CellParser.parseValue("3", FieldType.Number) as Int64, 3)
        @Assert(CellParser.parseValue("-3", FieldType.Number) as Int64, -3)
        @Assert(CellParser.parseValue("3.5", FieldType.Number) as Float64, 3.5)
        @Assert(CellParser.parseValue("1e3", FieldType.Number) as Float64, 1000.0)
    }

    /** Text：去掉包裹的单/双引号。 */
    @TestCase
    public func parsesText(): Unit {
        @Assert(CellParser.parseValue("\"abc\"", FieldType.Text) as String, "abc")
        @Assert(CellParser.parseValue("'abc'", FieldType.Text) as String, "abc")
        @Assert(CellParser.parseValue("abc", FieldType.Text) as String, "abc")
    }

    /** Bool：大小写不敏感。 */
    @TestCase
    public func parsesBool(): Unit {
        @Assert(CellParser.parseValue("true", FieldType.`Bool`) as Bool, true)
        @Assert(CellParser.parseValue("TRUE", FieldType.`Bool`) as Bool, true)
        @Assert(CellParser.parseValue("False", FieldType.`Bool`) as Bool, false)
    }

    /** Time：ISO-8601 日期与日期时间。 */
    @TestCase
    public func parsesTime(): Unit {
        let date = ((CellParser.parseValue("2026-10-31", FieldType.Time) as DateTime).getOrThrow())
        let expectedDate = DateTime.of(year: 2026, month: Month.of(10), dayOfMonth: 31,
            hour: 0, minute: 0, second: 0)
        @Expect(date, expectedDate)

        let moment = ((CellParser.parseValue("2026-10-31 12:30:45", FieldType.Time) as DateTime).getOrThrow())
        let expectedMoment = DateTime.of(year: 2026, month: Month.of(10), dayOfMonth: 31,
            hour: 12, minute: 30, second: 45)
        @Expect(moment, expectedMoment)
    }

    /** List：`[a, b, c]`。 */
    @TestCase
    public func parsesList(): Unit {
        let list = ((CellParser.parseValue("[a, b, c]", FieldType.List) as Array<Any>).getOrThrow())
        @Expect(list.size, 3)
        @Assert(list[1] as String, "b")
    }

    /** Any：数字 → 布尔 → 时间 → 字符串。 */
    @TestCase
    public func infersAnyLiterals(): Unit {
        @Assert(CellParser.parseValue("3", FieldType.`Any`) as Int64, 3)
        @Assert(CellParser.parseValue("3.5", FieldType.`Any`) as Float64, 3.5)
        @Assert(CellParser.parseValue("true", FieldType.`Any`) as Bool, true)
        @Assert(CellParser.parseValue("abc", FieldType.`Any`) as String, "abc")
        let time = ((CellParser.parseValue("2026-10-31", FieldType.`Any`) as DateTime).getOrThrow())
        @Expect(time.year, 2026)
    }

    /** 值无法解析为声明类型时抛 `TYPE_MISMATCH`。 */
    @TestCase
    public func rejectsInvalidValues(): Unit {
        @Expect(codeOf("abc", FieldType.Number), RuleErrorCode.TYPE_MISMATCH)
        @Expect(codeOf("yes", FieldType.`Bool`), RuleErrorCode.TYPE_MISMATCH)
        @Expect(codeOf("2026/10/31", FieldType.Time), RuleErrorCode.TYPE_MISMATCH)
        @Expect(codeOf("2026-13-01", FieldType.Time), RuleErrorCode.TYPE_MISMATCH)
    }
}

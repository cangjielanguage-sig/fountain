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

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.{Fact, TypedFact}

/**
 * 输出单元格解析（`doc/07-decision-table.md` §4.2，用例 T-06）。
 *
 * 字面量、`${binding.field}`、`${binding}` 三种形态；`${}` 在编译期解析，
 * 引用未在该行条件中出现的绑定抛 `UNKNOWN_BINDING`。
 */
@Test
class OutputCell_test {
    private func parse(cell: String): OutputCell {
        OutputCell.parse(Some(cell), ["o"]).getOrThrow()
    }

    private func codeOf(cell: String): RuleErrorCode {
        try {
            let _ = OutputCell.parse(Some(cell), ["o"]).getOrThrow()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** 空单元格表示该行不产生这个输出。 */
    @TestCase
    public func emptyCellMeansNoOutput(): Unit {
        @Expect(OutputCell.parse(None, ["o"]).isNone(), true)
        @Expect(OutputCell.parse(Some(""), ["o"]).isNone(), true)
        @Expect(OutputCell.parse(Some("  "), ["o"]).isNone(), true)
    }

    /** 字面量按 Any 推断。 */
    @TestCase
    public func parsesLiterals(): Unit {
        match (parse("0.85").source) {
            case Literal(value) => @Assert(value as Float64, 0.85)
            case _ => @Expect("literal", "other")
        }
        match (parse("true").source) {
            case Literal(value) => @Assert(value as Bool, true)
            case _ => @Expect("literal", "other")
        }
        match (parse("order.discounted").source) {
            case Literal(value) => @Assert(value as String, "order.discounted")
            case _ => @Expect("literal", "other")
        }
    }

    /** `${binding.field}` → 字段引用。 */
    @TestCase
    public func parsesFieldReference(): Unit {
        match (parse("\${o.level}").source) {
            case FieldRef(binding, field) =>
                @Assert(binding, "o")
                @Assert(field, "level")
            case _ => @Expect("field ref", "other")
        }
    }

    /** `${binding}` → 整个事实。 */
    @TestCase
    public func parsesBindingReference(): Unit {
        match (parse("\${o}").source) {
            case BindingRef(binding) => @Assert(binding, "o")
            case _ => @Expect("binding ref", "other")
        }
    }

    /** 引用未在条件中出现的绑定抛 `UNKNOWN_BINDING`。 */
    @TestCase
    public func rejectsUnknownBinding(): Unit {
        @Expect(codeOf("\${u.name}"), RuleErrorCode.UNKNOWN_BINDING)
        @Expect(codeOf("\${u}"), RuleErrorCode.UNKNOWN_BINDING)
    }

    /** `${}` 未闭合或为空抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsMalformedReference(): Unit {
        @Expect(codeOf("\${o.level"), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf("\${}"), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf("\${o.}"), RuleErrorCode.TABLE_INVALID)
        @Expect(codeOf("\${o.a.b}"), RuleErrorCode.TABLE_INVALID)
    }

    /** 运行期解析：字面量原样、字段引用取事实字段、整事实返回引用。 */
    @TestCase
    public func resolvesValues(): Unit {
        let fact = TypedFact(TableOrder("1", 3, 500), tableOrderSchema())
        let bindings = HashMap<String, Fact>()
        bindings["o"] = fact

        match (parse("0.85").resolve(bindings)) {
            case Some(value) => @Assert(value as Float64, 0.85)
            case None => @Expect("literal resolved", "None")
        }
        match (parse("\${o.level}").resolve(bindings)) {
            case Some(value) => @Assert(value as Int64, 3)
            case None => @Expect("field resolved", "None")
        }
        match (parse("\${o}").resolve(bindings)) {
            case Some(value) => @Expect(refEq((value as Object).getOrThrow(), (fact as Object).getOrThrow()), true)
            case None => @Expect("binding resolved", "None")
        }
    }
}

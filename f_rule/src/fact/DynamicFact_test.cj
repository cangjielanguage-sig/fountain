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
package fountain::f_rule.fact

import std.collection.*
import std.math.numeric.Decimal
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * `DynamicFact` 的契约（`doc/02-fact-model.md` §4，用例 F-02/F-03）。
 *
 * 动态事实是"配置驱动的数据"入口：允许 8 种标量/列表类型，进入网络后必须冻结，
 * 非法类型在写入时就报 `TYPE_MISMATCH`，而不是等到算子求值。
 */
@Test
class DynamicFact_test {
    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** F-02：缺失字段 `get` 返回 None、`has` 返回 false。 */
    @TestCase
    public func missingFieldIsAbsent(): Unit {
        let fact = DynamicFact("Order")
        @Assert(fact.typeTag, "Order")
        @Expect(fact.get("amount").isNone(), true)
        @Expect(fact.has("amount"), false)
    }

    /** 基本读写与删除；删除后 `has` 变 false。 */
    @TestCase
    public func setAndRemoveFields(): Unit {
        let fact = DynamicFact("Order")
        fact.set("amount", 200)
        fact.set("code", "AB12")
        @Expect(fact.has("amount"), true)
        match (fact.get("code")) {
            case Some(v) =>
                match (v) {
                    case text: String => @Assert(text, "AB12")
                    case _ => @Expect("code type", "String")
                }
            case None => @Expect("code present", "Some")
        }
        fact.remove("amount")
        @Expect(fact.has("amount"), false)
        @Expect(fact.get("amount").isNone(), true)
    }

    /** 构造时批量写入并逐项校验。 */
    @TestCase
    public func constructsFromMap(): Unit {
        let values = HashMap<String, Any>()
        values["amount"] = 500
        values["level"] = 3
        let fact = DynamicFact("Order", values)
        @Expect(fact.has("amount"), true)
        @Expect(fact.has("level"), true)
        @Expect(fact.frozen, false)
    }

    /** 白名单内的 8 种类型全部接受。 */
    @TestCase
    public func acceptsWhitelistedTypes(): Unit {
        let fact = DynamicFact("Types")
        fact.set("text", "x")
        fact.set("int", 1)
        fact.set("real", 1.5)
        fact.set("flag", true)
        fact.set("time", DateTime.now())
        fact.set("money", Decimal.parse("1.25"))
        let list: Array<Any> = [1, "a", true]
        fact.set("list", list)
        @Expect(fact.has("list"), true)
    }

    /** F-03：冻结后 `set` / `remove` 抛 `ILLEGAL_STATE`。 */
    @TestCase
    public func frozenRejectsMutation(): Unit {
        let fact = DynamicFact("Order")
        fact.set("amount", 200)
        fact.freeze()
        @Expect(fact.frozen, true)
        @Expect(codeOf({ => fact.set("amount", 300) }), RuleErrorCode.ILLEGAL_STATE)
        @Expect(codeOf({ => fact.remove("amount") }), RuleErrorCode.ILLEGAL_STATE)
        // 冻结不清空已有值
        @Expect(fact.has("amount"), true)
        // 重复冻结是幂等的
        fact.freeze()
        @Expect(fact.frozen, true)
    }

    /** 非法值类型（嵌套 Fact / 任意对象）在写入时抛 `TYPE_MISMATCH`。 */
    @TestCase
    public func rejectsUnsupportedValueType(): Unit {
        let fact = DynamicFact("Order")
        @Expect(codeOf({ => fact.set("nested", DynamicFact("Inner")) }), RuleErrorCode.TYPE_MISMATCH)
        @Expect(codeOf({ => fact.set("object", ValueKey.of(1)) }), RuleErrorCode.TYPE_MISMATCH)
        // 列表内的非法元素同样拒绝
        let bad: Array<Any> = [1, ValueKey.of(1)]
        @Expect(codeOf({ => fact.set("badList", bad) }), RuleErrorCode.TYPE_MISMATCH)
    }
}

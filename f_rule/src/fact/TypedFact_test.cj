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
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `TypedFact` 与 `FactHandle` 的契约（`doc/02-fact-model.md` §2~§3，用例 F-01）。
 *
 * `TypedFact` 不做字段拷贝，`get` 每次调用注册的 getter；`FactHandle` 的相等性只看
 * `(space, id)`，`typeTag` 只用于调试与桶定位。
 */
@Test
class TypedFact_test {
    private func schema(): FactSchema<SchemaOrder> {
        FactSchema<SchemaOrder>("Order")
            .field("id", { o => o.id })
            .field("amount", FieldType.Number, { o => o.amount })
    }

    /** F-01：`get` 返回 getter 的当前值，字段缺失返回 None。 */
    @TestCase
    public func readsFieldsThroughGetter(): Unit {
        let fact = TypedFact(SchemaOrder("A", 500, 3), schema())

        @Assert(fact.typeTag, "Order")
        match (fact.get("amount")) {
            case Some(v) =>
                match (v) {
                    case amount: Int64 => @Assert(amount, 500)
                    case _ => @Expect("amount type", "Int64")
                }
            case None => @Expect("amount present", "Some")
        }
        match (fact.get("id")) {
            case Some(v) =>
                match (v) {
                    case id: String => @Assert(id, "A")
                    case _ => @Expect("id type", "String")
                }
            case None => @Expect("id present", "Some")
        }
        @Expect(fact.get("missing").isNone(), true)
    }

    /** `has` 与 `get` 区分：字段存在与值为 None 是两件事。 */
    @TestCase
    public func hasDistinguishesDeclaredField(): Unit {
        let fact = TypedFact(SchemaOrder("A", 500, 3), schema())
        @Expect(fact.has("amount"), true)
        @Expect(fact.has("missing"), false)
        @Expect(fact.get("missing").isNone(), true)
    }

    /** `value` 返回注册时的同一引用，不做拷贝。 */
    @TestCase
    public func keepsOriginalReference(): Unit {
        let order = SchemaOrder("A", 500, 3)
        let fact = TypedFact(order, schema())
        @Expect(refEq(fact.value, order), true)
        order.amount = 900
        match (fact.get("amount")) {
            case Some(v) =>
                match (v) {
                    case amount: Int64 => @Assert(amount, 900)
                    case _ => @Expect("amount type", "Int64")
                }
            case None => @Expect("amount present", "Some")
        }
    }

    /** 句柄相等性只看 `(space, id)`；`typeTag` 不参与。 */
    @TestCase
    public func handleIdentityIsSpaceAndId(): Unit {
        let handle = FactHandle("orders", 7, "Order")
        @Expect(handle, FactHandle("orders", 7, "Order"))
        @Expect(handle == FactHandle("orders", 7, "OtherType"), true)
        @Expect(handle == FactHandle("users", 7, "Order"), false)
        @Expect(handle == FactHandle("orders", 8, "Order"), false)
        @Assert(handle.hashCode(), FactHandle("orders", 7, "OtherType").hashCode())
        // 可直接作为 HashMap 键
        let map = HashMap<FactHandle, String>()
        map.add(handle, "x")
        @Assert(map.get(FactHandle("orders", 7, "Order")).getOrThrow(), "x")
    }
}

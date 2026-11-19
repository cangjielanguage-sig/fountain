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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * `FactBase` 的存储契约（`doc/02-fact-model.md` §6.3，用例 F-04/F-05/F-06）。
 *
 * 三个容易分裂的点：
 * 1. 同一**实例**重复 assert 抛错，但字段相同的另一个实例可以共存（D2 冲突裁决）；
 * 2. `update` 保留 id，语义是 retract + assert；
 * 3. `retract` 不存在时静默返回 false，不抛错。
 */
@Test
class FactBase_test {
    static func orderSchema(): FactSchema<SchemaOrder> {
        FactSchema<SchemaOrder>("Order")
            .field("id", FieldType.Text, { o => o.id })
            .field("amount", FieldType.Number, { o => o.amount })
    }

    private func base(): FactBase {
        let space = FactSpace("orders").register(FactBase_test.orderSchema())
        FactBase(space, "s1")
    }

    private static func same(left: Fact, right: Fact): Bool {
        match ((left as Object, right as Object)) {
            case (Some(a), Some(b)) => refEq(a, b)
            case _ => false
        }
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** assert 返回句柄；get/scan/size 能取回同一实例。 */
    @TestCase
    public func assertReturnsHandle(): Unit {
        let db = base()
        let fact = TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema())
        let handle = db.assert(fact)

        @Assert(handle.space, "orders")
        @Assert(handle.typeTag, "Order")
        @Assert(handle.id, 1)
        @Assert(db.size(), 1)
        @Expect(FactBase_test.same(db.get(handle).getOrThrow(), fact), true)
        @Assert(db.scan("Order").size, 1)
        @Expect(db.scan("Order")[0], handle)
        @Assert(db.scan("Other").size, 0)
    }

    /** F-04：同一对象重复 assert 抛 `DUPLICATE_FACT`；不同实例可以共存。 */
    @TestCase
    public func duplicateInstanceRejected(): Unit {
        let db = base()
        let fact = TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema())
        let _ = db.assert(fact)

        @Expect(codeOf({ => db.assert(fact) }), RuleErrorCode.DUPLICATE_FACT)
        @Assert(db.size(), 1)

        // 字段相同但不是同一实例：允许
        let same = TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema())
        let _ = db.assert(same)
        @Assert(db.size(), 2)
    }

    /** F-05：update 保留句柄 id，取回新值，size 不变。 */
    @TestCase
    public func updateKeepsHandle(): Unit {
        let db = base()
        let handle = db.assert(TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema()))
        let oldId = handle.id

        let updated = TypedFact(SchemaOrder("A", 900, 3), FactBase_test.orderSchema())
        @Expect(db.update(handle, updated), true)
        @Assert(handle.id, oldId)
        @Assert(db.size(), 1)
        @Expect(FactBase_test.same(db.get(handle).getOrThrow(), updated), true)

        // update 之后旧实例已从库中撤销，可以重新 assert
        let reloaded = TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema())
        let _ = db.assert(reloaded)
        @Assert(db.size(), 2)
    }

    /** F-06：retract 不存在或已撤销的句柄返回 false，不抛错。 */
    @TestCase
    public func retractMissingReturnsFalse(): Unit {
        let db = base()
        @Expect(db.retract(FactHandle("orders", 999, "Order")), false)
        // 其他空间的句柄也不存在
        @Expect(db.retract(FactHandle("users", 1, "Order")), false)

        let handle = db.assert(TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema()))
        @Expect(db.retract(handle), true)
        @Expect(db.retract(handle), false)
        @Assert(db.size(), 0)
        @Expect(db.get(handle).isNone(), true)
    }

    /** clear 清空全部类型桶。 */
    @TestCase
    public func clearRemovesEverything(): Unit {
        let db = base()
        let _ = db.assert(TypedFact(SchemaOrder("A", 500, 3), FactBase_test.orderSchema()))
        let _ = db.assert(TypedFact(SchemaOrder("B", 100, 1), FactBase_test.orderSchema()))
        @Assert(db.size(), 2)
        db.clear()
        @Assert(db.size(), 0)
        @Assert(db.scan("Order").size, 0)
    }

    /** 未在该空间注册的类型拒绝插入。 */
    @TestCase
    public func unknownTypeRejected(): Unit {
        let db = base()
        let space = FactSpace("dynamic").registerDynamic("Row", [("amount", FieldType.Number)])
        let other = FactBase(space, "s1")
        let _ = other.assert(DynamicFact("Row"))

        @Expect(codeOf({ => db.assert(DynamicFact("Row")) }), RuleErrorCode.UNKNOWN_TYPE)
    }

    /** `DynamicFact` 进入事实库时自动冻结。 */
    @TestCase
    public func dynamicFactIsFrozenOnAssert(): Unit {
        let space = FactSpace("dynamic").registerDynamic("Row", [("amount", FieldType.Number)])
        let db = FactBase(space, "s1")
        let fact = DynamicFact("Row")
        fact.set("amount", 1)
        let _ = db.assert(fact)

        @Expect(fact.frozen, true)
        @Expect(codeOf({ => fact.set("amount", 2) }), RuleErrorCode.ILLEGAL_STATE)
    }

    /** `assertCopy` 快照字段，之后修改原对象不影响库内事实。 */
    @TestCase
    public func assertCopySnapshotsFields(): Unit {
        let db = base()
        let order = SchemaOrder("A", 500, 3)
        let handle = db.assertCopy(TypedFact(order, FactBase_test.orderSchema()))

        order.amount = 900
        let stored = db.get(handle).getOrThrow()
        match (stored.get("amount")) {
            case Some(v) =>
                match (v) {
                    case amount: Int64 => @Assert(amount, 500)
                    case _ => @Expect("amount type", "Int64")
                }
            case None => @Expect("amount present", "Some")
        }
        @Assert(stored.typeTag, "Order")
    }
}

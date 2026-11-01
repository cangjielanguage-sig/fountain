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
import fountain::f_rule.exception.*

/**
 * `FactSpace` 与 `FactSpaceRegistry` 的契约（`doc/02-fact-model.md` §6.2、§8，用例 F-16）。
 *
 * 空间是规则集内的命名空间：类型描述只登记一次，冻结后运行期只读。
 */
@Test
class FactSpace_test {
    private func schema(amountType: FieldType): FactSchema<SchemaOrder> {
        FactSchema<SchemaOrder>("Order")
            .field("id", FieldType.Text, { o => o.id })
            .field("amount", amountType, { o => o.amount })
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

    /** 类型注册后可查询字段名、字段类型、类型集合。 */
    @TestCase
    public func registersTypedSchema(): Unit {
        let space = FactSpace("orders").register(schema(FieldType.Number))

        @Assert(space.id, "orders")
        @Expect(space.hasType("Order"), true)
        @Expect(space.hasType("Missing"), false)
        @Assert(space.typeTags(), ["Order"])
        @Assert(space.fieldNames("Order"), ["id", "amount"])
        @Expect(space.fieldType("Order", "amount"), FieldType.Number)
        @Expect(space.fieldType("Order", "missing").isNone(), true)
        @Expect(space.fieldTypes("Order").get("id").getOrThrow(), FieldType.Text)
    }

    /** 动态类型只登记字段名与类型。 */
    @TestCase
    public func registersDynamicType(): Unit {
        let space = FactSpace("dynamic")
            .registerDynamic("Row", [("amount", FieldType.Number), ("code", FieldType.Text)])

        @Expect(space.hasType("Row"), true)
        @Assert(space.fieldNames("Row"), ["amount", "code"])
        @Expect(space.fieldType("Row", "code"), FieldType.Text)
        @Expect(space.descriptor("Row").getOrThrow().hostTypeName, "")
    }

    /** F-16：同一 typeTag 用**不一致**的 schema 重复注册抛 `DUPLICATE_TYPE`。 */
    @TestCase
    public func inconsistentReregistrationRejected(): Unit {
        let space = FactSpace("orders").register(schema(FieldType.Number))

        @Expect(codeOf({ => space.register(schema(FieldType.Text)) }), RuleErrorCode.DUPLICATE_TYPE)
        // 改成动态类型也算不一致
        @Expect(codeOf({ => space.registerDynamic("Order", [("id", FieldType.Text)]) }),
            RuleErrorCode.DUPLICATE_TYPE)
    }

    /** 完全一致的重复注册是幂等的（便于多处装配同一 schema）。 */
    @TestCase
    public func identicalReregistrationIsIdempotent(): Unit {
        let space = FactSpace("orders")
            .register(schema(FieldType.Number))
            .register(schema(FieldType.Number))

        @Assert(space.typeTags().size, 1)
        @Assert(space.fieldNames("Order").size, 2)
    }

    /** 冻结后注册抛 `NETWORK_FROZEN`；查询仍可用。 */
    @TestCase
    public func frozenSpaceRejectsRegistration(): Unit {
        let space = FactSpace("orders").register(schema(FieldType.Number))
        space.freeze()

        @Expect(space.frozen, true)
        @Expect(codeOf({ => space.registerDynamic("Other", [("x", FieldType.`Any`)]) }),
            RuleErrorCode.NETWORK_FROZEN)
        @Expect(space.hasType("Order"), true)
    }

}

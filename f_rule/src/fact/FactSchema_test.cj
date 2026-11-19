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

import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*

/** 测试宿主类：只看字段，不实现 `Fact`（`doc/02-fact-model.md` §3）。 */
public class SchemaOrder {
    public var id: String
    public var amount: Int64
    public var level: Int64

    public init(id: String, amount: Int64, level: Int64) {
        this.id = id
        this.amount = amount
        this.level = level
    }
}

/**
 * `FactSchema` 的字段注册契约（用例 F-01 的构建侧）。
 *
 * 字段访问器是**闭包注册表**而不是反射：注册顺序决定 `names()`，未声明的字段一律 `Any`。
 */
@Test
class FactSchema_test {
    /** 注册两个重载都生效，字段顺序稳定，未声明类型按 `Any`。 */
    @TestCase
    public func registersFieldsInOrder(): Unit {
        let schema = FactSchema<SchemaOrder>("Order")
            .field("id", { o => o.id })
            .field("amount", FieldType.Number, { o => o.amount })

        @Assert(schema.typeTag, "Order")
        @Assert(schema.names().size, 2)
        @Assert(schema.names()[0], "id")
        @Assert(schema.names()[1], "amount")
        @Expect(schema.fieldType("id"), FieldType.`Any`)
        @Expect(schema.fieldType("amount"), FieldType.Number)
        @Expect(schema.has("amount"), true)
        @Expect(schema.has("missing"), false)
    }

    /** `lookup` 返回注册的闭包，未注册返回 None。 */
    @TestCase
    public func lookupReturnsRegisteredGetter(): Unit {
        let schema = FactSchema<SchemaOrder>("Order")
            .field("amount", FieldType.Number, { o => o.amount })

        let getter = schema.lookup("amount").getOrThrow()
        match (getter(SchemaOrder("A", 42, 1))) {
            case v: Int64 => @Assert(v, 42)
            case _ => @Expect("getter type", "Int64")
        }
        @Expect(schema.lookup("missing").isNone(), true)
    }

    /** 宿主类型名被记录，供 `f_jit` 拼 lambda 形参类型（design D7）。 */
    @TestCase
    public func recordsHostTypeName(): Unit {
        let schema = FactSchema<SchemaOrder>("Order")
        @Assert(schema.hostTypeName, TypeInfo.of<SchemaOrder>().qualifiedName)
        // 测试包名带 `$test` 后缀，生产包为 normal qualifiedName；只钉住末尾段。
        @Expect(schema.hostTypeName.endsWith(".SchemaOrder"), true)
        @Expect(schema.hostTypeName.startsWith("fountain::f_rule.fact"), true)
        @Assert(schema.hostSimpleName, "SchemaOrder")
    }
}

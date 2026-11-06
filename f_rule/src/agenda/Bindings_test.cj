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
package fountain::f_rule.agenda

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}

/** 绑定表：不可变视图、句柄/实例双视图、稳定指纹。 */
@Test
class Bindings_test {
    private func fact(amount: Int64): Fact {
        let item = DynamicFact("Order")
        item.set("amount", amount)
        item
    }

    /** 合并产生新实例，原实例不变。 */
    @TestCase
    public func mergedReturnsNewImmutableView(): Unit {
        let first = fact(1)
        let second = fact(2)
        let empty = Bindings.empty()
        @Assert(empty.size(), 0)
        @Expect(empty.isEmpty(), true)

        let one = empty.merged("o", FactHandle("default", 1, "Order"), first)
        let two = one.merged("u", FactHandle("default", 2, "Order"), second)
        @Expect(one.resolve("u").isNone(), true)
        @Assert(two.size(), 2)
        @Expect(two.resolve("o").isSome(), true)
        @Expect(two.get("o").isSome(), true)
        @Assert(two.get("o").getOrThrow().id, 1)
    }

    /** `names` 按字典序，`toMap` 交出句柄快照。 */
    @TestCase
    public func namesAndToMapAreStable(): Unit {
        let map = HashMap<String, Fact>()
        map["z"] = fact(1)
        map["a"] = fact(2)
        let view = Bindings.ofFacts(map)
        let names = view.names()
        @Assert(names.size, 2)
        @Assert(names[0], "a")
        @Assert(names[1], "z")
        @Expect(view.get("a").isNone(), true)
    }
}

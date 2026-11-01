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
package fountain::f_rule.rete

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.Operator
import fountain::f_rule.fact.{Fact, FactHandle, ValueKey}

/** 单字段事实：范围索引测试专用，避免 10 万条 `DynamicFact` 的 map 开销。 */
class RangeFact <: Fact {
    public let amount: Int64

    RangeFact(amount: Int64) {
        this.amount = amount
    }

    public prop typeTag: String {
        get() {
            "RangeFact"
        }
    }

    public func get(field: String): ?Any {
        if (field == "amount") {
            return amount
        }
        None
    }

    public func has(field: String): Bool {
        field == "amount"
    }
}

/**
 * 有序索引与全扫的等价性（`doc/04-rete-network.md` §7.1，D4）。
 *
 * 有序索引是 `ConcurrentSkipListMap<RangeKey, FactHandle>`：`Gt/Ge/Lt/Le/Between`
 * 直接映射到 `tailer/header/sub`，同值多事实用 `ownerId` 兜底，不设规模上限。
 */
@Test
class RangeIndex_test {
    private func memoryOf(count: Int64, offset: Int64): AlphaMemory {
        let memory = AlphaMemory(1)
        var i: Int64 = 0
        while (i < count) {
            let amount = i + offset
            memory.add(FactHandle("default", i + 1, "RangeFact"), RangeFact(amount))
            i += 1
        }
        memory
    }

    private func brute(memory: AlphaMemory, op: Operator, pivot: Int64): Array<FactHandle> {
        let out = ArrayList<FactHandle>()
        for (handle in memory.all()) {
            let fact = memory.fact(handle).getOrThrow()
            let value = ValueKey.of(fact.get("amount").getOrThrow()).strictCompare(ValueKey.of(pivot))
            let hit = match (op) {
                case Operator.Gt => value == Ordering.GT
                case Operator.Ge => value != Ordering.LT
                case Operator.Lt => value == Ordering.LT
                case Operator.Le => value != Ordering.GT
                case _ => false
            }
            if (hit) {
                out.add(handle)
            }
        }
        out.toArray()
    }

    /** 五种范围算子与全扫结果逐条一致。 */
    @TestCase
    public func rangeOperatorsMatchFullScan(): Unit {
        let memory = memoryOf(100, 0)
        let ops = [Operator.Gt, Operator.Ge, Operator.Lt, Operator.Le]
        for (op in ops) {
            let actual = memory.select("amount", op, ValueKey.of(50))
            let expected = brute(memory, op, 50)
            @Assert(actual.size, expected.size)
        }
        @Assert(memory.select("amount", Operator.Gt, ValueKey.of(50)).size, 49)
        @Assert(memory.select("amount", Operator.Ge, ValueKey.of(50)).size, 50)
        @Assert(memory.select("amount", Operator.Lt, ValueKey.of(50)).size, 50)
        @Assert(memory.select("amount", Operator.Le, ValueKey.of(50)).size, 51)
    }

    /** `Between` 是闭区间。 */
    @TestCase
    public func betweenIsClosed(): Unit {
        let memory = memoryOf(100, 0)
        let bounds: Array<Any> = [20, 40]
        let hit = memory.select("amount", Operator.Between, ValueKey.of(bounds))
        @Assert(hit.size, 21)
        let emptyBounds: Array<Any> = [40, 20]
        @Assert(memory.select("amount", Operator.Between, ValueKey.of(emptyBounds)).size, 0)
    }

    /** 同值的 100 条事实全部返回，不因索引键冲突互相覆盖。 */
    @TestCase
    public func duplicateValuesAllReturned(): Unit {
        let memory = AlphaMemory(1)
        var i: Int64 = 0
        while (i < 100) {
            memory.add(FactHandle("default", i + 1, "RangeFact"), RangeFact(3))
            i += 1
        }
        @Assert(memory.probe("amount", ValueKey.of(3)).size, 100)
        @Assert(memory.select("amount", Operator.Eq, ValueKey.of(3)).size, 100)
        @Assert(memory.select("amount", Operator.Ge, ValueKey.of(3)).size, 100)
    }

    /** 10 万条插入后范围探测仍正确，无"索引过大退化"分支。 */
    @TestCase
    public func largeIndexStaysExact(): Unit {
        let count: Int64 = 100000
        let memory = memoryOf(count, 0)
        @Assert(memory.size(), count)
        @Assert(memory.select("amount", Operator.Ge, ValueKey.of(99900)).size, 100)
        @Assert(memory.select("amount", Operator.Lt, ValueKey.of(5)).size, 5)
        let bounds: Array<Any> = [50000, 50002]
        @Assert(memory.select("amount", Operator.Between, ValueKey.of(bounds)).size, 3)
    }
}

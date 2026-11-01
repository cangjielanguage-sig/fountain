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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.rule.{ConflictKey, ConflictResolver}

/**
 * 冲突消解策略（`doc/05-agenda-conflict-resolution.md` §4，A-01~A-04）。
 *
 * `compare` 的 `Ordering.LT` 表示 left 先执行。
 */
@Test
class ConflictResolver_test {
    private func key(salience: Int64, specificity: Int64, order: Int64, seq: Int64,
        space: String, ruleId: String): ConflictKey {
        ConflictKey(salience, specificity, order, seq, space, ruleId)
    }

    /** A-01：salience 大的先执行。 */
    @TestCase
    public func salienceDescending(): Unit {
        let resolver = Resolvers.salience()
        let high = key(100, 0, 0, 1, "orders", "R1")
        let low = key(0, 0, 0, 2, "orders", "R2")

        @Expect(resolver.compare(high, low), Ordering.LT)
        @Expect(resolver.compare(low, high), Ordering.GT)
        @Expect(resolver.compare(high, high), Ordering.EQ)
    }

    /** A-02：条件多的先执行。 */
    @TestCase
    public func specificityDescending(): Unit {
        let resolver = Resolvers.specificity()
        let more = key(0, 5, 0, 1, "orders", "R1")
        let less = key(0, 2, 0, 2, "orders", "R2")

        @Expect(resolver.compare(more, less), Ordering.LT)
        @Expect(resolver.compare(less, more), Ordering.GT)
    }

    /** A-03：FIFO 按产生顺序升序，LIFO 降序。 */
    @TestCase
    public func fifoAndLifoFollowSequence(): Unit {
        let early = key(0, 0, 0, 1, "orders", "R1")
        let late = key(0, 0, 0, 2, "orders", "R2")

        @Expect(Resolvers.fifo().compare(early, late), Ordering.LT)
        @Expect(Resolvers.lifo().compare(early, late), Ordering.GT)
    }

    /** 规则声明顺序与规则 id 字典序。 */
    @TestCase
    public func ruleOrderAndRuleId(): Unit {
        let first = key(0, 0, 0, 1, "orders", "B")
        let second = key(0, 0, 1, 2, "orders", "A")

        @Expect(Resolvers.ruleOrder().compare(first, second), Ordering.LT)
        @Expect(Resolvers.ruleId().compare(first, second), Ordering.GT)
    }

    /** 组合策略依次比较：前一级相等才看下一级。 */
    @TestCase
    public func compositeUsesNextResolverOnlyWhenEqual(): Unit {
        let resolver = Resolvers.composite([Resolvers.salience(), Resolvers.specificity()])
        let left = key(100, 1, 0, 1, "orders", "R1")
        let right = key(100, 5, 0, 2, "orders", "R2")

        @Expect(resolver.compare(left, right), Ordering.GT)
    }

    /** A-04：默认链对所有异激活给出非 0 结果。 */
    @TestCase
    public func defaultChainIsTotalOrder(): Unit {
        let resolver = Resolvers.defaultChain()
        var left: Int64 = 0
        while (left < 10) {
            var right: Int64 = 0
            while (right < 10) {
                if (left != right) {
                    let a = key(left % 3, left % 4, left % 5, left, "s${left % 2}", "R${left}")
                    let b = key(right % 3, right % 4, right % 5, right, "s${right % 2}",
                        "R${right}")
                    @Expect(resolver.compare(a, b) != Ordering.EQ, true)
                }
                right += 1
            }
            left += 1
        }
    }

    /** 自定义解析器可插入组合链。 */
    @TestCase
    public func customResolverCanBeComposed(): Unit {
        let resolver = Resolvers.composite([ReverseRuleIdResolver()])
        let first = key(0, 0, 0, 1, "orders", "A")
        let second = key(0, 0, 0, 2, "orders", "B")

        @Expect(resolver.compare(first, second), Ordering.GT)
    }
}

/** 自定义解析器：按规则 id 降序。 */
class ReverseRuleIdResolver <: ConflictResolver {
    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        if (left.ruleId == right.ruleId) {
            return Ordering.EQ
        }
        if (left.ruleId > right.ruleId) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }
}

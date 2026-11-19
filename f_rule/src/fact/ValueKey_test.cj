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
import std.math.numeric.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * `ValueKey` 的归一与全序契约（`doc/02-fact-model.md` §5，用例 F-07/F-08）。
 *
 * 两条容易被破坏的不变量：
 * 1. 索引键必须**跨数值类型**相等（`Int64(1)` 与 `Float64(1.0)`），否则 hash 索引会漏命中；
 * 2. 比较必须**全序**（数值 < 文本 < 布尔 < 时间 < 列表），否则跳表索引会崩；
 *    但排序算子仍要在跨域时显式报 `TYPE_MISMATCH`，不能把 `"abc" > 1` 静默判成 false。
 */
@Test
class ValueKey_test {
    /** `Any` 不实现 `ToString`，断言前先按已知类型渲染。 */
    private static func text(value: Any): String {
        match (value) {
            case v: Int64 => "${v}"
            case v: Float64 => "${v}"
            case v: String => v
            case v: Bool => "${v}"
            case v: Decimal => "${v}"
            case _ => "?"
        }
    }

    /** F-07：整数与浮点归一到同一个键，相等、同 hash、compare 为 EQ。 */
    @TestCase
    public func crossNumericTypeEquality(): Unit {
        let integer = ValueKey.of(1)
        let real = ValueKey.of(1.0)

        @Expect(integer == real, true)
        @Assert(integer.hashCode(), real.hashCode())
        @Expect(integer.compare(real), Ordering.EQ)
        @Assert(ValueKey_test.text(integer.unwrap()), "1")
        @Assert(ValueKey_test.text(real.unwrap()), "1")
    }

    /** `Int32` / `Float32` 同样归一（文档 §5 的归一表）。 */
    @TestCase
    public func narrowerNumericTypesNormalize(): Unit {
        @Expect(ValueKey.of(Int32(7)) == ValueKey.of(Int64(7)), true)
        @Expect(ValueKey.of(Float32(2.5)) == ValueKey.of(Float64(2.5)), true)
        @Expect(ValueKey.of(Int32(7)) == ValueKey.of(Float64(7.0)), true)
    }

    /** `Decimal` 保留精度，但与整数按数值相等。 */
    @TestCase
    public func decimalComparesWithIntegers(): Unit {
        let decimal = ValueKey.of(Decimal.parse("1.00"))
        let integer = ValueKey.of(1)

        @Expect(decimal == integer, true)
        @Assert(decimal.hashCode(), integer.hashCode())

        // 非整数 Decimal 不应被截断成整数
        let half = ValueKey.of(Decimal.parse("0.50"))
        @Expect(half == ValueKey.of(0.5), true)
        @Expect(half == ValueKey.of(0), false)
    }

    /** `DateTime` 归一为 Unix 纳秒，且不落入数值域。 */
    @TestCase
    public func dateTimeNormalizesToUnixNanos(): Unit {
        let now = DateTime.now()
        let key = ValueKey.of(now)
        let nanos = now.toUnixTimeStamp().toNanoseconds()

        @Assert(ValueKey_test.text(key.unwrap()), "${nanos}")
        @Expect(key.domain, ValueDomain.Time)
        // 时间与同值的数值不是同一个键
        @Expect(key == ValueKey.of(nanos), false)
    }

    /** `Array` 保序、`Set` 去重后按值序归一。 */
    @TestCase
    public func listValuesNormalize(): Unit {
        let numbers: Array<Any> = [1, 2.0, 3]
        let same: Array<Any> = [1.0, 2, 3.0]
        let reordered: Array<Any> = [3, 2, 1]

        @Expect(ValueKey.of(numbers) == ValueKey.of(same), true)
        @Expect(ValueKey.of(numbers) == ValueKey.of(reordered), false)
        @Expect(ValueKey.of(numbers).domain, ValueDomain.List)

        // 列表长度不同必然不等
        let shorter: Array<Any> = [1, 2]
        @Expect(ValueKey.of(numbers) == ValueKey.of(shorter), false)

        // Set 无序且去重：与排序后的数组键一致
        let set: ReadOnlySet<Any> = TestSet([3, 1, 2, 1])
        let sorted: Array<Any> = [1, 2, 3]
        @Expect(ValueKey.of(set) == ValueKey.of(sorted), true)
    }

    /** 全序：数值 < 文本 < 布尔 < 时间 < 列表。 */
    @TestCase
    public func domainsAreTotallyOrdered(): Unit {
        let now = ValueKey.of(DateTime.now())
        let single: Array<Any> = [1]
        let list = ValueKey.of(single)

        @Expect(ValueKey.of(999).compare(ValueKey.of("a")), Ordering.LT)
        @Expect(ValueKey.of("a").compare(ValueKey.of(999)), Ordering.GT)
        @Expect(ValueKey.of("zzz").compare(ValueKey.of(false)), Ordering.LT)
        @Expect(ValueKey.of(true).compare(ValueKey.of(false)), Ordering.GT)
        @Expect(ValueKey.of(false).compare(now), Ordering.LT)
        @Expect(now.compare(list), Ordering.LT)
    }

    /** F-08：排序算子使用严格比较，跨域必须抛 `TYPE_MISMATCH`，不得静默返回 false。 */
    @TestCase
    public func strictCompareRejectsCrossDomain(): Unit {
        var caught: ?RuleException = None
        try {
            let _ = ValueKey.of("abc").strictCompare(ValueKey.of(1))
        } catch (e: RuleException) {
            caught = e
        }
        @Assert(caught.getOrThrow().code, RuleErrorCode.TYPE_MISMATCH)

        // 同域放行
        @Expect(ValueKey.of("abc").strictCompare(ValueKey.of("abd")), Ordering.LT)
        @Expect(ValueKey.of(1).strictCompare(ValueKey.of(1.5)), Ordering.LT)
    }

    /** 不支持的类型在构造键时就要失败，不能悄悄归成字符串。 */
    @TestCase
    public func unsupportedValueThrowsTypeMismatch(): Unit {
        var caught: ?RuleException = None
        try {
            let _ = ValueKey.of(ValueKey.of(1))
        } catch (e: RuleException) {
            caught = e
        }
        @Assert(caught.getOrThrow().code, RuleErrorCode.TYPE_MISMATCH)
    }

    /**
     * 签名编码必须区分"同长度、不同内容"的列表。
     *
     * `toString()` 对列表只输出长度，拿它做节点签名会让 `Between [1,2]` 与
     * `Between [3,4]` 共用一个 alpha 节点，产生假阳性。
     */
    @TestCase
    public func encodeDistinguishesListContents(): Unit {
        let first: Array<Any> = [1, 2]
        let second: Array<Any> = [3, 4]
        @Expect(ValueKey.of(first).encode() == ValueKey.of(second).encode(), false)
        @Assert(ValueKey.of("a,b").encode(), "s:a\\,b")
    }
}

/**
 * 测试用只读集合。
 *
 * `HashSet<Any>` 无法实例化（`Any` 不满足 `Hashable`），但 `ValueKey` 的归一契约要求支持
 * `Set` 形态；这里用一个最小的 `ReadOnlySet<Any>` 实现来覆盖去重与无序语义。
 */
class TestSet <: ReadOnlySet<Any> {
    private let items: ArrayList<Any>

    init(values: Array<Any>) {
        this.items = ArrayList<Any>()
        for (value in values) {
            this.items.add(value)
        }
    }

    public prop size: Int64 {
        get() {
            this.items.size
        }
    }

    public func isEmpty(): Bool {
        this.items.isEmpty()
    }

    public func contains(element: Any): Bool {
        for (item in this.items) {
            if (ValueKey.of(item) == ValueKey.of(element)) {
                return true
            }
        }
        false
    }

    public func contains(all!: Collection<Any>): Bool {
        for (element in all) {
            if (!contains(element)) {
                return false
            }
        }
        true
    }

    public func subsetOf(other: ReadOnlySet<Any>): Bool {
        for (item in this.items) {
            if (!other.contains(item)) {
                return false
            }
        }
        true
    }

    public func iterator(): Iterator<Any> {
        this.items.iterator()
    }

    public func toArray(): Array<Any> {
        this.items.toArray()
    }
}

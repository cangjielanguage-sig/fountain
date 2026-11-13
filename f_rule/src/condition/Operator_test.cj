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
package fountain::f_rule.condition

import std.collection.HashSet
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * 15 个算子的语义（`doc/03-condition-expression.md` §2，用例 C-01/C-02/C-03）。
 *
 * 判定统一返回 [Truth]：字段缺失是 `Unknown` 而不是 `False`，只有 `IsNull/NotNull`
 * 能显式判定缺失；排序算子跨域必须抛 `TYPE_MISMATCH`，不能静默 false。
 */
@Test
class Operator_test {
    private func list(values: Array<Any>): ?Any {
        Some(values)
    }

    private func apply(op: Operator, left: ?Any, right: ?Any): Truth {
        OperatorEvaluator.apply(op, left, right)
    }

    /** C-01：等值/不等值。 */
    @TestCase
    public func equalityOperators(): Unit {
        @Expect(apply(Operator.Eq, Some(1), Some(1.0)), Truth.True)
        @Expect(apply(Operator.Eq, Some(1), Some(2)), Truth.False)
        @Expect(apply(Operator.Ne, Some(1), Some(2)), Truth.True)
        @Expect(apply(Operator.Ne, Some("a"), Some("a")), Truth.False)
    }

    /** C-01：四个范围算子，数值与字符串都按同域比较。 */
    @TestCase
    public func orderingOperators(): Unit {
        @Expect(apply(Operator.Gt, Some(300), Some(200)), Truth.True)
        @Expect(apply(Operator.Gt, Some(200), Some(200)), Truth.False)
        @Expect(apply(Operator.Ge, Some(200), Some(200)), Truth.True)
        @Expect(apply(Operator.Lt, Some(100), Some(200)), Truth.True)
        @Expect(apply(Operator.Le, Some(200), Some(200)), Truth.True)
        @Expect(apply(Operator.Lt, Some("abc"), Some("abd")), Truth.True)
    }

    /** C-01：字符串/集合包含。 */
    @TestCase
    public func containsOperators(): Unit {
        @Expect(apply(Operator.Contains, Some("abcd"), Some("bc")), Truth.True)
        @Expect(apply(Operator.Contains, Some("abcd"), Some("xy")), Truth.False)
        @Expect(apply(Operator.Contains, list([1, 2, 3]), Some(2.0)), Truth.True)
        @Expect(apply(Operator.StartsWith, Some("abcd"), Some("ab")), Truth.True)
        @Expect(apply(Operator.EndsWith, Some("abcd"), Some("cd")), Truth.True)
        @Expect(apply(Operator.EndsWith, Some("abcd"), Some("ab")), Truth.False)
    }

    /** C-02：`In` 空集合恒 false，`NotIn` 空集合恒 true，且不抛错。 */
    @TestCase
    public func inWithEmptyCollection(): Unit {
        let empty: Array<Any> = []
        @Expect(apply(Operator.In, Some(1), list(empty)), Truth.False)
        @Expect(apply(Operator.NotIn, Some(1), list(empty)), Truth.True)
        @Expect(apply(Operator.In, Some(2), list([1, 2, 3])), Truth.True)
        @Expect(apply(Operator.In, Some(4), list([1, 2, 3])), Truth.False)
        @Expect(apply(Operator.NotIn, Some(4), list([1, 2, 3])), Truth.True)
    }

    /** C-03：`IsNull` / `NotNull` 是唯一能判定字段缺失的算子。 */
    @TestCase
    public func nullOperators(): Unit {
        @Expect(apply(Operator.IsNull, None, None), Truth.True)
        @Expect(apply(Operator.IsNull, Some(1), None), Truth.False)
        @Expect(apply(Operator.NotNull, None, None), Truth.False)
        @Expect(apply(Operator.NotNull, Some(1), None), Truth.True)
    }

    /** 其它算子遇 `None` 一律 `Unknown`。 */
    @TestCase
    public func missingValueIsUnknown(): Unit {
        @Expect(apply(Operator.Gt, None, Some(100)), Truth.Unknown)
        @Expect(apply(Operator.Eq, Some(1), None), Truth.Unknown)
        @Expect(apply(Operator.Matches, None, Some("a")), Truth.Unknown)
    }

    /** `Matches` 是整串匹配（`f_regex.Regex.matches`）。 */
    @TestCase
    public func matchesIsFullString(): Unit {
        @Expect(apply(Operator.Matches, Some("ABC"), Some("^[A-Z]+$")), Truth.True)
        @Expect(apply(Operator.Matches, Some("AB12"), Some("^[A-Z]+$")), Truth.False)
    }

    /** `Between` 是闭区间。 */
    @TestCase
    public func betweenIsInclusive(): Unit {
        @Expect(apply(Operator.Between, Some(200), list([200, 300])), Truth.True)
        @Expect(apply(Operator.Between, Some(300), list([200, 300])), Truth.True)
        @Expect(apply(Operator.Between, Some(199), list([200, 300])), Truth.False)
        @Expect(apply(Operator.Between, Some(301), list([200, 300])), Truth.False)
    }

    /** 跨域排序抛 `TYPE_MISMATCH`（F-08 的算子侧）。 */
    @TestCase
    public func crossDomainOrderingRejected(): Unit {
        var caught = RuleErrorCode.CLOSED
        try {
            let _ = apply(Operator.Gt, Some("abc"), Some(1))
        } catch (e: RuleException) {
            caught = e.code
        }
        @Expect(caught, RuleErrorCode.TYPE_MISMATCH)

        // 等值不算排序，跨域只返回 false
        @Expect(apply(Operator.Eq, Some("1"), Some(1)), Truth.False)
    }

    /** 15 个算子都能转稳定名并作 HashMap 键。 */
    @TestCase
    public func operatorNamesAreStable(): Unit {
        let names = [
            (Operator.Eq, "Eq"), (Operator.Ne, "Ne"),
            (Operator.Gt, "Gt"), (Operator.Ge, "Ge"),
            (Operator.Lt, "Lt"), (Operator.Le, "Le"),
            (Operator.Contains, "Contains"), (Operator.StartsWith, "StartsWith"),
            (Operator.EndsWith, "EndsWith"), (Operator.In, "In"),
            (Operator.NotIn, "NotIn"), (Operator.IsNull, "IsNull"),
            (Operator.NotNull, "NotNull"), (Operator.Matches, "Matches"),
            (Operator.Between, "Between")
        ]
        @Assert(names.size, 15)
        let hashes = HashSet<Int64>()
        for ((op, name) in names) {
            @Assert(op.toString(), name)
            hashes.add(op.hashCode())
        }
        @Assert(hashes.size, 15)
    }
}

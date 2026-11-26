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

import std.unittest.*
import std.unittest.testmacro.*

/**
 * 三值逻辑真值表（`doc/03-condition-expression.md` §2.1，用例 C-04）。
 *
 * 与 SQL 一致；`Unknown` 与 `False` 在"是否产生激活"上等价，但 `Not Unknown`
 * 不能折叠成 `True`——否则缺失字段会被误判为满足条件。
 */
@Test
class TruthTable_test {
    private static let values = [Truth.True, Truth.False, Truth.Unknown]

    /** `And` 真值表。 */
    @TestCase
    public func andFollowsSqlTable(): Unit {
        // T: 右边原样；F: 恒 F；U: 右边 F -> F，否则 U
        @Expect(Truth.True.and(Truth.True), Truth.True)
        @Expect(Truth.True.and(Truth.False), Truth.False)
        @Expect(Truth.True.and(Truth.Unknown), Truth.Unknown)
        @Expect(Truth.False.and(Truth.True), Truth.False)
        @Expect(Truth.False.and(Truth.False), Truth.False)
        @Expect(Truth.False.and(Truth.Unknown), Truth.False)
        @Expect(Truth.Unknown.and(Truth.True), Truth.Unknown)
        @Expect(Truth.Unknown.and(Truth.False), Truth.False)
        @Expect(Truth.Unknown.and(Truth.Unknown), Truth.Unknown)
    }

    /** `Or` 真值表。 */
    @TestCase
    public func orFollowsSqlTable(): Unit {
        @Expect(Truth.True.or(Truth.True), Truth.True)
        @Expect(Truth.True.or(Truth.False), Truth.True)
        @Expect(Truth.True.or(Truth.Unknown), Truth.True)
        @Expect(Truth.False.or(Truth.True), Truth.True)
        @Expect(Truth.False.or(Truth.False), Truth.False)
        @Expect(Truth.False.or(Truth.Unknown), Truth.Unknown)
        @Expect(Truth.Unknown.or(Truth.True), Truth.True)
        @Expect(Truth.Unknown.or(Truth.False), Truth.Unknown)
        @Expect(Truth.Unknown.or(Truth.Unknown), Truth.Unknown)
    }

    /** `Not Unknown` 仍是 `Unknown`。 */
    @TestCase
    public func notPreservesUnknown(): Unit {
        @Expect(Truth.True.not(), Truth.False)
        @Expect(Truth.False.not(), Truth.True)
        @Expect(Truth.Unknown.not(), Truth.Unknown)
    }

    /** 只有 `True` 产生激活；`Unknown` 与 `False` 都不产生。 */
    @TestCase
    public func onlyTrueActivates(): Unit {
        @Expect(Truth.True.isTrue(), true)
        @Expect(Truth.False.isTrue(), false)
        @Expect(Truth.Unknown.isTrue(), false)
        for (value in TruthTable_test.values) {
            if (value != Truth.True) {
                @Expect(value.isTrue(), false)
            }
        }
    }
}

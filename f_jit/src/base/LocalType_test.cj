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
package fountain::f_jit.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * S1.1 `LocalType` 的失败用例（先写红）。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §11.7 的局部类型表（`0=Int64 … 12=Closure`、`13–255 保留`）；
 * 句柄位分界（4–12 句柄型 / 0–3 值型）来自 §11.7「值型（0–3）槽存原始 cell；句柄型（4–12）槽存句柄 ID」；
 * token ↔ LocalType 的一一对应表同样出自 §11.7 末段；合法集按 verMajor 分派出自
 * `openspec/changes/f-jit-m1/specs/f-jit-base-contracts/spec.md`「版本分派合法集」与 plan-m1 S1.1
 * （v1:0–12、v2:0–14、v3:0–19）。
 */
@Test
public class LocalType_test {
    /** 15 个常量与 §11.7 表逐值一致（0–12 为 M1，13/14 为 M2 §2 增量）。 */
    @TestCase
    public func constantsMatchSpecTable(): Unit {
        @Assert(LocalType.I64, 0u16)
        @Assert(LocalType.F64, 1u16)
        @Assert(LocalType.BOOL, 2u16)
        @Assert(LocalType.UNIT, 3u16)
        @Assert(LocalType.STRING, 4u16)
        @Assert(LocalType.DECIMAL, 5u16)
        @Assert(LocalType.DATETIME, 6u16)
        @Assert(LocalType.DURATION, 7u16)
        @Assert(LocalType.RANGE, 8u16)
        @Assert(LocalType.REGEX, 9u16)
        @Assert(LocalType.LIST, 10u16)
        @Assert(LocalType.MAP, 11u16)
        @Assert(LocalType.CLOSURE, 12u16)
        @Assert(LocalType.HOST_CLOSURE, 13u16)
        @Assert(LocalType.HOST_OBJECT, 14u16)
    }

    /** `name` 与 §11.7 表及 M2 §2 增量逐项一致，且非空。 */
    @TestCase
    public func nameMatchesSpecTable(): Unit {
        let expected = [
            'Int64', 'Float64', 'Bool', 'Unit', 'String', 'Decimal', 'DateTime',
            'Duration', 'Range', 'Regex', 'List', 'Map', 'Closure', 'HostClosure', 'HostObject'
        ]
        @Assert(expected.size, 15)
        for (i in 0..15) {
            @Assert(LocalType.name(UInt16(i)), expected[i])
            @Assert(LocalType.name(UInt16(i)).isEmpty(), false)
        }
    }

    /** 句柄位分界：4–19 为真、0–3 与 20 起为假（§11.7 + M2 的 13/14 + M3 的 15–19）。 */
    @TestCase
    public func isHandleSplitsAtFour(): Unit {
        for (i in 0..4) {
            @Assert(LocalType.isHandle(UInt16(i)), false)
        }
        for (i in 4..20) {
            @Assert(LocalType.isHandle(UInt16(i)), true)
        }
        @Assert(LocalType.isHandle(20u16), false)
        @Assert(LocalType.isHandle(255u16), false)
    }

    /** M3 可转集：0–8、9–11、14、16–19；12/13/15 排除；3 无装箱点。 */
    @TestCase
    public func convertibleSetIsFrozen(): Unit {
        for (i in 0..20) {
            let expect = i <= 11 || i == 14 || (i >= 16 && i <= 19)
            @Assert(LocalType.isConvertible(UInt16(i)), expect)
        }
        @Assert(LocalType.isConvertible(12u16), false)
        @Assert(LocalType.isConvertible(13u16), false)
        @Assert(LocalType.isConvertible(15u16), false)
        @Assert(LocalType.hasBoxPoint(3u16), false)
        @Assert(LocalType.hasBoxPoint(0u16), true)
    }

    /** 码级继承：17/18/19 <: 16，互不构成子类。 */
    @TestCase
    public func jsonCodesHaveCodeLevelInheritance(): Unit {
        @Assert(LocalType.isSameOrDescendant(17u16, 16u16), true)
        @Assert(LocalType.isSameOrDescendant(18u16, 16u16), true)
        @Assert(LocalType.isSameOrDescendant(19u16, 16u16), true)
        @Assert(LocalType.isSameOrDescendant(17u16, 18u16), false)
        @Assert(LocalType.isSameOrDescendant(16u16, 17u16), false)
    }

    /** `fromToken` 与 §11.7 末段一一对应表全等：List↔1、Map↔2、String↔3、Decimal↔4、
     *  DateTime↔5、Duration↔6、Range↔7、Regex↔8、Closure↔9。 */
    @TestCase
    public func fromTokenMatchesTypeTokenTable(): Unit {
        @Assert(LocalType.fromToken(1u16), 10u16) // LIST
        @Assert(LocalType.fromToken(2u16), 11u16) // MAP
        @Assert(LocalType.fromToken(3u16), 4u16) // STRING
        @Assert(LocalType.fromToken(4u16), 5u16) // DECIMAL
        @Assert(LocalType.fromToken(5u16), 6u16) // DATETIME
        @Assert(LocalType.fromToken(6u16), 7u16) // DURATION
        @Assert(LocalType.fromToken(7u16), 8u16) // RANGE
        @Assert(LocalType.fromToken(8u16), 9u16) // REGEX
        @Assert(LocalType.fromToken(9u16), 12u16) // CLOSURE
    }

    /** token 0（保留）与未定义 token 没有对应类型码 ⇒ 返回 `NONE` 哨兵，不与任何合法码撞。 */
    @TestCase
    public func fromTokenRejectsReservedAndUnknown(): Unit {
        @Assert(LocalType.fromToken(0u16), LocalType.NONE) // RESERVED
        // M2 起 10/11 已有定义；12 属 M3（Any）登记位，本步仍未定义
        @Assert(LocalType.fromToken(10u16), LocalType.HOST_CLOSURE)
        @Assert(LocalType.fromToken(11u16), LocalType.HOST_OBJECT)
        @Assert(LocalType.fromToken(12u16), LocalType.ANY)
        @Assert(LocalType.fromToken(0xFFFFu16), LocalType.NONE)
        @Assert(LocalType.isHandle(LocalType.NONE), false)
    }

    /** 合法集按 verMajor 分派：v1=0–12、v2=0–14、v3=0–19；未知主版本一律拒绝。 */
    @TestCase
    public func legalSetIsDispatchedByVerMajor(): Unit {
        // verMajor=1：13 起全部拒绝（§11.7「13–255 保留（加载器拒绝）」）
        @Assert(LocalType.isLegal(0u16, 1u16), true)
        @Assert(LocalType.isLegal(12u16, 1u16), true)
        @Assert(LocalType.isLegal(13u16, 1u16), false)
        @Assert(LocalType.isLegal(14u16, 1u16), false)
        @Assert(LocalType.isLegal(19u16, 1u16), false)
        @Assert(LocalType.isLegal(255u16, 1u16), false)
        // verMajor=2：M2 追加 13=HostClosure、14=HostObject ⇒ 0–14
        @Assert(LocalType.isLegal(13u16, 2u16), true)
        @Assert(LocalType.isLegal(14u16, 2u16), true)
        @Assert(LocalType.isLegal(15u16, 2u16), false)
        // verMajor=3：M3 追加 15=Any、16–19=JSON ⇒ 0–19
        @Assert(LocalType.isLegal(15u16, 3u16), true)
        @Assert(LocalType.isLegal(19u16, 3u16), true)
        @Assert(LocalType.isLegal(20u16, 3u16), false)
        // 未知主版本（0 / 4）一律拒绝
        @Assert(LocalType.isLegal(0u16, 0u16), false)
        @Assert(LocalType.isLegal(0u16, 4u16), false)
    }

    /** `name` 表按码全表（0–19）登记：0–19 全部实名，20 起为保留区。 */
    @TestCase
    public func nameCoversFullRegistryRange(): Unit {
        for (i in 0..20) {
            @Assert(LocalType.name(UInt16(i)).isEmpty(), false)
        }
        @Assert(LocalType.name(15u16), 'Any')
        @Assert(LocalType.name(16u16), 'JsonValue')
        @Assert(LocalType.name(19u16), 'JsonNull')
        @Assert(LocalType.name(20u16).startsWith('Reserved'), true)
    }
}

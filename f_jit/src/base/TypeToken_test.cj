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
 * S1.2 `TypeToken` 的失败用例（先写红）。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §6 的类型 token 表（行 617）：
 * `0 保留，1=List 2=Map 3=String 4=Decimal 5=DateTime 6=Duration 7=Range 8=Regex 9=Closure`；
 * `IS_TYPE/GUARD_TYPE/CAST/H17–H19` 与句柄槽 `tag` 均使用该编码（design-m1 §2.3.9）。
 */
@Test
public class TypeToken_test {
    /** token 0–11 与 §6 表及 M2 §2 增量逐值一致。 */
    @TestCase
    public func constantsMatchSpecTable(): Unit {
        @Assert(TypeToken.RESERVED, 0u16)
        @Assert(TypeToken.LIST, 1u16)
        @Assert(TypeToken.MAP, 2u16)
        @Assert(TypeToken.STRING, 3u16)
        @Assert(TypeToken.DECIMAL, 4u16)
        @Assert(TypeToken.DATETIME, 5u16)
        @Assert(TypeToken.DURATION, 6u16)
        @Assert(TypeToken.RANGE, 7u16)
        @Assert(TypeToken.REGEX, 8u16)
        @Assert(TypeToken.CLOSURE, 9u16)
        @Assert(TypeToken.HOST_CLOSURE, 10u16)
        @Assert(TypeToken.HOST_OBJECT, 11u16)
    }

    /** `name` 与 §6 表及 M2 §2 增量逐项一致且非空。 */
    @TestCase
    public func nameMatchesSpecTable(): Unit {
        let expected = [
            'Reserved', 'List', 'Map', 'String', 'Decimal', 'DateTime', 'Duration',
            'Range', 'Regex', 'Closure', 'HostClosure', 'HostObject'
        ]
        @Assert(expected.size, 12)
        for (i in 0..12) {
            @Assert(TypeToken.name(UInt16(i)), expected[i])
            @Assert(TypeToken.name(UInt16(i)).isEmpty(), false)
        }
    }

    /** 未定义 token（M1/M2 封闭集之外）⇒ `name` 非空兜底，不崩、不与已定义名重复。 */
    @TestCase
    public func nameHasFallbackForUnknownToken(): Unit {
        @Assert(TypeToken.name(12u16).isEmpty(), false)
        @Assert(TypeToken.name(0xFFFFu16).isEmpty(), false)
        @Assert(TypeToken.name(12u16) == TypeToken.name(TypeToken.LIST), false)
    }

    /** token ↔ LocalType 双向闭合并集中在 `LocalType.fromToken` 一处（§11.7 一一对应表 + M2 §2）。 */
    @TestCase
    public func mappingIsClosedWithLocalType(): Unit {
        let pairs = [
            (TypeToken.LIST, LocalType.LIST), (TypeToken.MAP, LocalType.MAP),
            (TypeToken.STRING, LocalType.STRING), (TypeToken.DECIMAL, LocalType.DECIMAL),
            (TypeToken.DATETIME, LocalType.DATETIME), (TypeToken.DURATION, LocalType.DURATION),
            (TypeToken.RANGE, LocalType.RANGE), (TypeToken.REGEX, LocalType.REGEX),
            (TypeToken.CLOSURE, LocalType.CLOSURE),
            (TypeToken.HOST_CLOSURE, LocalType.HOST_CLOSURE),
            (TypeToken.HOST_OBJECT, LocalType.HOST_OBJECT)
        ]
        for ((tok, code) in pairs) {
            @Assert(LocalType.fromToken(tok), code)
            // 反向：句柄型类型码（4–14）必然有唯一 token，且不落在保留位 0
            @Assert(LocalType.isHandle(code), true)
            @Assert(LocalType.fromToken(tok) == LocalType.NONE, false)
        }
    }

    /** 十一个 token 覆盖全部句柄型 LocalType（4–14 共 11 个），无遗漏、无多余。 */
    @TestCase
    public func tokensCoverExactlyTheNineHandleTypes(): Unit {
        var hit = 0
        for (code in 4..15) {
            var found = false
            for (tok in 1..12) {
                if (LocalType.fromToken(UInt16(tok)) == UInt16(code)) {
                    found = true
                }
            }
            if (found) {
                hit += 1
            }
        }
        @Assert(hit, 11)
    }

    /**
     * token 11 是「不透明宿主对象引用」大类，M3 的 JSON 内建码复用同一 tag 11，
     * **不另开 JSON token**：token 12 属 M3 的 Any（本步仍未登记），且没有任何
     * JSON 专属 token 落在 0–11。
     */
    @TestCase
    public func hostObjectTokenIsTheSharedOpaqueCategory(): Unit {
        @Assert(TypeToken.name(TypeToken.HOST_OBJECT), 'HostObject')
        @Assert(LocalType.name(LocalType.fromToken(TypeToken.HOST_OBJECT)), 'HostObject')
        // M2 不登记 token 12（M3 Any），也不为 JSON 增开 token
        @Assert(LocalType.fromToken(12u16), LocalType.NONE)
        @Assert(TypeToken.name(12u16).contains('Unknown'), true)
    }
}

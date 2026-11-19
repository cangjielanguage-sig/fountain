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
package fountain::f_svg

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

internal func m5Table(bytes: Array<Byte>, tag: String): SvgTtfTableReader {
    SvgTtfTableReader(bytes, SvgTtfTable(tag, 0, Int64(bytes.size)))
}

/** kern format 0，单个 (left, right, value) 对。 */
internal func m5KernTable(pairs: Array<(Int64, Int64, Int64)>, horizontal!: Bool = true): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u16(0)
    writer.u16(1)
    writer.u16(0)
    writer.u16(6 + 8 + 6 * pairs.size)
    writer.u16(if (horizontal) { 0x0001 } else { 0x0004 })
    writer.u16(pairs.size)
    writer.u16(0)
    writer.u16(0)
    writer.u16(0)
    for ((left, right, value) in pairs) {
        writer.u16(left)
        writer.u16(right)
        writer.i16(value)
    }
    writer.toArray()
}

@Test
public class SvgKernTableM5_test {
    /** format 0 读取与负值。 */
    @TestCase
    public func parseFormatZero(): Unit {
        let bytes = m5KernTable([(1, 2, -80), (1, 3, 25)])
        let warnings = ArrayList<String>()
        let table = SvgKernPairs.parse(m5Table(bytes, "kern"), warnings)
        @Assert(table.isSome())
        match (table) {
            case Some(value) =>
                @Assert(value.adjust(1, 2) == -80)
                @Assert(value.adjust(1, 3) == 25)
                @Assert(value.adjust(2, 1) == 0)
                @Assert(value.adjust(9, 9) == 0)
            case None => @Fail("应解析成功")
        }
        @Assert(warnings.size == 0)
    }

    /** 非水平子表被忽略。 */
    @TestCase
    public func verticalSubtableIgnored(): Unit {
        let bytes = m5KernTable([(1, 2, -80)], horizontal: false)
        let table = SvgKernPairs.parse(m5Table(bytes, "kern"), ArrayList<String>())
        @Assert(table.isNone())
    }

    /** 两个子表累计超过 65536 条时忽略整表并告警。 */
    @TestCase
    public func pairLimit(): Unit {
        let w = M4ByteWriter()
        w.u16(0).u16(7)
        let perTable: Int64 = 10000
        for (tableIndex in 0..7) {
            w.u16(0)
            w.u16(6 + 8 + 6 * perTable)
            w.u16(0x0001)
            w.u16(perTable).u16(0).u16(0).u16(0)
            for (index in 0..perTable) {
                w.u16(tableIndex * 2)
                w.u16(index % 65536)
                w.i16(0)
            }
        }
        let warnings = ArrayList<String>()
        let table = SvgKernPairs.parse(m5Table(w.toArray(), "kern"), warnings)
        @Assert(table.isNone())
        var sawLimit = false
        for (warning in warnings) {
            if (warning.contains("65536")) {
                sawLimit = true
            }
        }
        @Assert(sawLimit)
    }

    /** 截断表返回 None 并告警。 */
    @TestCase
    public func truncatedTable(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgKernPairs.parse(m5Table([0, 0, 0, 0, 0, 0], "kern"), warnings)
        @Assert(table.isNone())
        @Assert(warnings.size >= 1)
    }
}

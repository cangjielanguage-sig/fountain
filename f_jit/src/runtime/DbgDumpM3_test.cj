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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.test.TCase

/**
 * M3 R6.7：`DbgDump` 对 JSON 内建码（16–19）与 Any（15）的槽位呈现。
 *
 * 口径：**只呈现大类名 + `#idx`**（`<JsonObject>#4`），不取对象、不解析具体类——
 * 与 13/14 的「大类名加尖括号」同款；4–12 的真实类型名不带尖括号（零回归）。
 */
@Test
public class DbgDumpM3_test {
    /** 16–19 与 15：`<大类名>#idx`；13/14 与 4–12 逐位不变。 */
    @TestCase
    public func jsonSlotTextUsesLargeClassName(): Unit {
        HandleTable.resetForTest()
        let name = NameTable()
        name.freeze()
        // JSON 节点句柄 tag 复用 11（v0.3.20），idx 取 3–6
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.JSON_VALUE),
            HandleTable.makeId(3, 11u16, 1u16)), '<JsonValue>#3')
        @Assert(DbgDump.slotText(name, 1, 1, UInt8(LocalType.JSON_OBJECT),
            HandleTable.makeId(4, 11u16, 1u16)), '<JsonObject>#4')
        @Assert(DbgDump.slotText(name, 1, 2, UInt8(LocalType.JSON_ARRAY),
            HandleTable.makeId(5, 11u16, 1u16)), '<JsonArray>#5')
        @Assert(DbgDump.slotText(name, 1, 3, UInt8(LocalType.JSON_NULL),
            HandleTable.makeId(6, 11u16, 1u16)), '<JsonNull>#6')
        // 15（Any 盒）同款
        @Assert(DbgDump.slotText(name, 1, 4, UInt8(LocalType.ANY),
            HandleTable.makeId(7, 12u16, 1u16)), '<Any>#7')
        // 零回归：14 仍是大类名 + idx；4（String）是真实类型名、不带尖括号
        @Assert(DbgDump.slotText(name, 1, 5, UInt8(LocalType.HOST_OBJECT),
            HandleTable.makeId(8, 11u16, 1u16)), '<HostObject>#8')
        @Assert(DbgDump.slotText(name, 1, 6, UInt8(LocalType.STRING),
            HandleTable.makeId(9, 5u16, 1u16)), 'String#9')
        @Assert(TCase.hit('T61/dbgdump-json', true), true)
    }

    /** 空槽（0）：JSON 码同样只呈现 `#0`，不取对象（桩句柄不触发 HANDLE_TYPE）。 */
    @TestCase
    public func jsonNullSlotRendersZero(): Unit {
        HandleTable.resetForTest()
        let name = NameTable()
        name.freeze()
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.JSON_OBJECT), 0), '<JsonObject>#0')
    }
}

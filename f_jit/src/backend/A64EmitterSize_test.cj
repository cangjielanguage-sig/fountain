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
package fountain::f_jit.backend

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `A64Emitter` 的「字节口径」护栏（`optimize-compile-hotpath`）。
 *
 * 内部存储从 `ArrayList<UInt8>` 改成 `ArrayList<UInt32>` 后，
 * **对外暴露的 `size()` / `bind` / 重定位仍是字节偏移**，`finish()` 仍按小端展开。
 * 这三件事一旦错位，分支偏移会整体差 4 倍——本用例专门盯这个面。
 */
@Test
public class A64EmitterSize_test {
    @TestCase
    public func sizeIsBytesNotWords(): Unit {
        let e = A64Emitter(false)
        @Assert(e.size(), 0)
        e.word(0x11223344u32)
        @Assert(e.size(), 4)
        e.word(0xAABBCCDDu32)
        @Assert(e.size(), 8)
        // 三次 add 后 bind，偏移必须是字节口径
        e.bind('X')
        @Assert(e.labelOffset('X'), 8)
    }

    @TestCase
    public func finishExpandsLittleEndian(): Unit {
        let e = A64Emitter(false)
        e.word(0x11223344u32)
        e.word(0xAABBCCDDu32)
        let code = e.finish()
        @Assert(Int64(code.size), 8)
        @Assert(code[0], 0x44u8)
        @Assert(code[1], 0x33u8)
        @Assert(code[2], 0x22u8)
        @Assert(code[3], 0x11u8)
        @Assert(code[4], 0xDDu8)
        @Assert(code[5], 0xCCu8)
        @Assert(code[6], 0xBBu8)
        @Assert(code[7], 0xAAu8)
    }

    /** 分支偏移与字存储必须自洽：b 在 0，目标在 8 ⇒ imm26 = 2。 */
    @TestCase
    public func branchOffsetStaysInBytes(): Unit {
        let e = A64Emitter(false)
        e.b('T')
        e.word(0u32)
        e.bind('T')
        @Assert(e.labelOffset('T'), 8)
        let code = e.finish()
        let w = UInt32(code[0]) | (UInt32(code[1]) << 8) | (UInt32(code[2]) << 16) |
            (UInt32(code[3]) << 24)
        @Assert(w & 0xFC000000u32, 0x14000000u32)
        @Assert(w & 0x03FFFFFFu32, 2u32)
        @Assert(Int64(code.size), 8)
    }
}

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

/** P5.4 `entryThunk`：每函数 16 B 槽，`endbr64; jmp rel32`（§12.3 thunk）。 */
@Test
public class X86Thunk_test {

    @TestCase
    public func thunkSlotsAreSixteenByteAligned(): Unit {
        let b = BackendX86_64()
        @Assert(b.prepareThunks([0x1000, 0x2000]), true)
        let base = b.entryThunkBase()
        @Assert(base % 16, 0)
        @Assert(b.entryThunkFor(0u32), base)
        @Assert(b.entryThunkFor(1u32), base + 16)
        @Assert(b.entryThunkFor(2u32), 0)
        b.releaseThunks()
        @Assert(b.entryThunkBase(), 0)
    }

    @TestCase
    public func thunkJumpsToEntry(): Unit {
        let b = BackendX86_64()
        let entry: Int64 = 0x123450
        @Assert(b.prepareThunks([entry]), true)
        let got = b.thunkBytes(0u32)
        // mmap 基址与 0x123450 距离远超 ±2GB ⇒ 远跳转编码（整槽 16 B）
        @Assert(got.size, 16)
        @Assert(got[0], 0xF3u8)
        @Assert(got[1], 0x0Fu8)
        @Assert(got[2], 0x1Eu8)
        @Assert(got[3], 0xFAu8)
        @Assert(got[4], 0x48u8)
        @Assert(got[5], 0xB8u8)
        var v: Int64 = 0
        var k = 0
        while (k < 8) {
            v = v | (Int64(got[6 + k]) << (8 * k))
            k = k + 1
        }
        @Assert(v, entry)
        @Assert(got[14], 0xFFu8)
        @Assert(got[15], 0xE0u8)
        b.releaseThunks()
    }

}

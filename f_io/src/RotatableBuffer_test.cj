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
package fountain::f_io

import std.unittest.*
import std.unittest.testmacro.*

@Test
class RotatableBufferTest {
    /** 底层流读完后，read 必须返回 0，不能把窗口后半的零/旧字节当成数据。 */
    @TestCase
    func readStopsAtEof(): Unit {
        let input = ByteBuffer([1u8, 2u8, 3u8], toOverwriteOnClearing: false)
        let buffer = RotatableBuffer(input, [0xFFu8, 0xFEu8])
        let out = Array<Byte>(64, repeat: 0)

        let (first, _, _) = buffer.read(out)
        @Expect(first, 3)
        @Expect(out[0], 1u8)
        @Expect(out[1], 2u8)
        @Expect(out[2], 3u8)

        let (second, _, _) = buffer.read(out)
        @Expect(second, 0)
    }

    /** 空流首次 read 就是 0。 */
    @TestCase
    func emptyInputReturnsZero(): Unit {
        let input = ByteBuffer(Array<Byte>(0, repeat: 0), toOverwriteOnClearing: false)
        let buffer = RotatableBuffer(input, [0xFFu8])
        let out = Array<Byte>(16, repeat: 0)
        let (size, _, _) = buffer.read(out)
        @Expect(size, 0)
    }

    /** 恰好半窗的数据在 EOF 时只返回真实长度，第二读为 0。 */
    @TestCase
    func exactHalfWindowStopsAtEof(): Unit {
        let data = Array<Byte>(8, repeat: 7u8)
        let input = ByteBuffer(data, toOverwriteOnClearing: false)
        let buffer = RotatableBuffer(input, [0xFFu8], halfBufferSize: 8)
        let out = Array<Byte>(16, repeat: 0)
        let (first, _, _) = buffer.read(out)
        @Expect(first, 8)
        let (second, _, _) = buffer.read(out)
        @Expect(second, 0)
    }
}

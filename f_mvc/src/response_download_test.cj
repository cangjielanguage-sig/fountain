/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_mvc

import std.unittest.*
import std.unittest.testmacro.*

/**
 * §1.9 / `MVC-4`：`download` 必须只写出实际读到的长度。
 * 修前 `copy` 直接 `write(buf)`，每块多写 (缓冲大小 - 实读长度) 个脏字节；
 * 本用例用内存收集器断言「写出总长度 == 源长度、内容逐字节一致」。
 */
@Test
public class ResponseDownload_test {
    @TestCase
    public func testCopyWritesOnlyReadBytes(): Unit {
        // 源长 19997（非 1024/4096/8192 的整数倍）：修前会写出缓冲的整数倍，长度与内容都对不上
        let size = 19997
        let src = Array<Byte>(size, repeat: 0)
        for (i in 0..size) {
            src[i] = UInt8(i % 251)
        }
        let input = ByteBuffer()
        input.write(src)
        let cap = size * 2
        let out = Array<Byte>(cap, repeat: 0)
        let written = Box<Int64>(0)
        copy(
            input,
            {
                bytes =>
                    for (i in 0..bytes.size) {
                        if (written.value + i < cap) {
                            out[written.value + i] = bytes[i]
                        }
                    }
                    written.value += bytes.size
            }
        )
        @Assert(written.value, size)
        var firstBad = -1
        for (i in 0..size) {
            if (out[i] != src[i]) {
                firstBad = i
                break
            }
        }
        @Assert(firstBad, -1)
    }

    @TestCase
    public func testCopyEmptyInput(): Unit {
        let written = Box<Int64>(0)
        copy(ByteBuffer(), {bytes => written.value += bytes.size})
        @Assert(written.value, 0)
    }
}

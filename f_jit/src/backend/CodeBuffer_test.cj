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
 * P5.1 `CodeBuffer`：mmap RW → write/patch → mprotect RX（W^X）→ munmap。
 *
 * 失败面：`alloc` 失败返回 None（桥降级解释器，不报错）；sealed 后写入/补丁返回 false；
 * `free` 幂等。本机页大小经 `sysconf(_SC_PAGESIZE)` 取得，基址/长度按页对齐。
 */
@Test
public class CodeBuffer_test {

    @TestCase
    public func allocWriteRead(): Unit {
        let b = CodeBuffer_test.allocOrFail(64)
        @Assert(b.size >= 64, true)
        @Assert(b.write([1u8, 2u8, 3u8], 8), true)
        let got = b.read(8, 3)
        @Assert(got.size, 3)
        @Assert(got[0], 1u8)
        @Assert(got[1], 2u8)
        @Assert(got[2], 3u8)
        b.free()
    }

    @TestCase
    public func pageAlignment(): Unit {
        let page = CodeBuffer.pageSize()
        @Assert(page > 0, true)
        let b1 = CodeBuffer_test.allocOrFail(1)
        @Assert(b1.base % page, 0)
        @Assert(b1.size % page, 0)
        b1.free()
        let b2 = CodeBuffer_test.allocOrFail(page + 1)
        @Assert(b2.base % page, 0)
        @Assert(b2.size % page, 0)
        @Assert(b2.size >= page + 1, true)
        b2.free()
    }

    @TestCase
    public func sealEnforcesWx(): Unit {
        let b = CodeBuffer_test.allocOrFail(32)
        @Assert(b.write([0xAAu8], 0), true)
        @Assert(b.patch(1, [0xBBu8]), true)
        @Assert(b.seal(), true)
        // W^X：seal 后不可写 / 不可补丁，但可读
        @Assert(b.write([0xCCu8], 2), false)
        @Assert(b.patch(3, [0xDDu8]), false)
        @Assert(b.read(0, 2)[0], 0xAAu8)
        @Assert(b.read(1, 1)[0], 0xBBu8)
        b.free()
    }

    @TestCase
    public func sealFlushesICache(): Unit {
        CodeBuffer.resetFlushCount()
        let b = CodeBuffer_test.allocOrFail(16)
        @Assert(b.seal(), true)
        @Assert(CodeBuffer.flushCount(), 1)
        b.flushICache()
        @Assert(CodeBuffer.flushCount(), 2)
        b.free()
    }

    @TestCase
    public func freeIsIdempotent(): Unit {
        let b = CodeBuffer_test.allocOrFail(16)
        let base = b.base
        @Assert(base != 0, true)
        b.free()
        @Assert(b.base, 0)
        @Assert(b.size, 0)
        b.free()
        @Assert(b.base, 0)
    }

    @TestCase
    public func outOfRangeIsRejected(): Unit {
        let b = CodeBuffer_test.allocOrFail(16)
        let n = b.size // 映射长度（页对齐）
        @Assert(b.write([1u8], n), false)
        @Assert(b.patch(n - 1, [1u8, 2u8]), false)
        @Assert(b.read(n, 1).size, 0)
        b.free()
    }

    private static func allocOrFail(size: Int64): CodeBuffer {
        match (CodeBuffer.alloc(size)) {
            case Some(b) => b
            case None => @Fail('mmap 失败（本用例要求可分配）')
        }
    }
}

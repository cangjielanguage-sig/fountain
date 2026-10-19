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

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.runtime.JitContext

/**
 * S5.13 代码内存生命周期：缓存键语义、mmap 失败降级、munmap 释放。
 */
@Test
public class CompileCacheKey_test {
    @TestCase
    public func keyEqualityAndHash(): Unit {
        let a = CompileCacheKey('aarch64', 'fp,simd', 42u64)
        let b = CompileCacheKey('aarch64', 'fp,simd', 42u64)
        let c = CompileCacheKey('x86_64', 'fp,simd', 42u64)
        let d = CompileCacheKey('aarch64', 'fp', 42u64)
        let e = CompileCacheKey('aarch64', 'fp,simd', 43u64)
        @Assert(a == b, true)
        @Assert(a == c, false)
        @Assert(a == d, false)
        @Assert(a == e, false)
        @Assert(a.hashCode(), b.hashCode())
        let m = HashMap<CompileCacheKey, Int64>()
        m.add(a, 1)
        @Assert(m.contains(b), true)
        @Assert(m.contains(c), false)
    }

    @TestCase
    public func keyIsInMemoryOnly(): Unit {
        // 键文本只含三元组，不含路径/地址/时间戳（进程重启后仍可重建同一键）
        let k = CompileCacheKey('aarch64', '', 7u64)
        let s = k.toString()
        @Assert(s, 'aarch64//7')
        @Assert(s.contains('/tmp'), false)
    }

    @TestCase
    public func mmapFailureReturnsNoneWithoutErrorSlot(): Unit {
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        // 超大尺寸必然 mmap 失败（不触碰 ctx：降级由调用方决定）
        @Assert(CodeBuffer.alloc(1 << 62).isNone(), true)
        @Assert(CodeBuffer.alloc(0).isNone(), true)
        @Assert(CodeBuffer.alloc(-1).isNone(), true)
        @Assert(ctx.errCode, 0)
        JitContext.free(ctx)
    }

    @TestCase
    public func freeUnmapsAndClearsBase(): Unit {
        let buf = match (CodeBuffer.alloc(64)) {
            case Some(b) => b
            case None => @Fail('alloc 失败'); return
        }
        @Assert(buf.base != 0, true)
        buf.free()
        @Assert(buf.base, 0)
        @Assert(buf.rawPointer().isNull(), true)
        buf.free() // 幂等
        @Assert(buf.base, 0)
    }
}

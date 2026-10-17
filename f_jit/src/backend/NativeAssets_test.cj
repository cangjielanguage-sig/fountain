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
 * P5.2 `FnTable`（函数入口表）与 `ConstMirror`（常量句柄镜像）：
 * 两块**非 GC 内存**资产，基址可烘焙进机器码；生命周期配对、释放幂等。
 */
@Test
public class NativeAssets_test {

    @TestCase
    public func fnTableReadWrite(): Unit {
        NativeAssets.resetCounters()
        let t = NativeAssets_test.fnTableOrFail(2)
        @Assert(t.base() % 8, 0)
        @Assert(t.set(0u32, 0x1000), true)
        @Assert(t.set(1u32, 0x2000), true)
        @Assert(t.entry(0u32), 0x1000)
        @Assert(t.entry(1u32), 0x2000)
        // 越界 / 非法 fid：拒绝
        @Assert(t.set(2u32, 0x3000), false)
        @Assert(t.entry(2u32), 0)
        t.free()
        @Assert(NativeAssets.liveCount(), 0)
    }

    @TestCase
    public func constMirrorMatchesIds(): Unit {
        NativeAssets.resetCounters()
        let ids: Array<Int64> = [11, 22, 33]
        let m = ConstMirror.build(ids)
        @Assert(m.base() % 8, 0)
        @Assert(m.size(), 3)
        @Assert(m.at(0), 11)
        @Assert(m.at(1), 22)
        @Assert(m.at(2), 33)
        @Assert(m.at(3), 0) // 越界读 → 0，不崩
        m.free()
        @Assert(m.base(), 0)
        @Assert(NativeAssets.liveCount(), 0)
    }

    @TestCase
    public func freeIsIdempotent(): Unit {
        NativeAssets.resetCounters()
        let t = NativeAssets_test.fnTableOrFail(1)
        t.free()
        t.free()
        @Assert(t.base(), 0)
        let m = ConstMirror.build([1, 2])
        m.free()
        m.free()
        @Assert(m.base(), 0)
        @Assert(NativeAssets.liveCount(), 0)
    }

    @TestCase
    public func emptyMirrorIsSafe(): Unit {
        let m = ConstMirror.build(Array<Int64>())
        @Assert(m.size(), 0)
        @Assert(m.at(0), 0)
        m.free()
        @Assert(m.base(), 0)
    }

    private static func fnTableOrFail(n: Int64): FnTable {
        match (FnTable.alloc(n)) {
            case Some(t) => t
            case None => @Fail('FnTable.alloc 失败')
        }
    }
}

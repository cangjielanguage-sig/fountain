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
package fountain::f_jit

import std.collection.ArrayList
import std.reflect.TypeInfo
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.JitBindings

/** 仅供本用例使用的宿主类（名字唯一，避免影响其它注册表用例）。 */
public class SnapshotProbeHost {
    public var v: Int64 = 0
}

/**
 * 第二个探针类：专供「发布时机」用例，**保证此前从未登记过**——
 * 否则旧快照里已有同名项，变异（先发布空表）会被旧数据掩盖。
 */
public class SnapshotFreshHost {
    public var v: Int64 = 0
}

/**
 * `JitBindSupport` 快照化的 characterization + 并发护栏（`optimize-call-path-phase4` A）。
 *
 * 这是行为等价重构：旧实现（全局 `mtx` + 两张 `HashMap`）与新实现（不可变快照 + 原子发布）
 * 都必须通过。并发用例锁住「登记与查询并发时结果恒真、不丢项、不崩」。
 */
@Test
public class JitBindSupportSnapshot_test {
    @TestCase
    public func enrolledInterfaceIsVisibleToReaders(): Unit {
        let name = TypeInfo.of<SnapshotProbeHost>().name
        JitBindSupport.enrollInterfaceOf<SnapshotProbeHost>(JitBindings.empty(),
            { o => o is SnapshotProbeHost })
        @Assert(JitBindSupport.isInterface(name), true)
        @Assert(JitBindSupport.acceptsInterface(SnapshotProbeHost(), name), true)
        @Assert(JitBindSupport.acceptsInterface(SnapshotProbeHost(), name + '#absent'), false)
        @Assert(JitBindSupport.isInterface(name + '#absent'), false)
    }

    @TestCase
    public func concurrentEnrollAndReadStayConsistent(): Unit {
        let name = TypeInfo.of<SnapshotProbeHost>().name
        JitBindSupport.enrollInterfaceOf<SnapshotProbeHost>(JitBindings.empty(),
            { o => o is SnapshotProbeHost })
        let target = SnapshotProbeHost()
        let bad = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        // 4 个写者：反复覆盖登记同一接口（写时复制 + 原子发布）。
        while (t < 4) {
            fs.add(spawn {
                var k = 0
                while (k < 2000) {
                    JitBindSupport.enrollInterfaceOf<SnapshotProbeHost>(JitBindings.empty(),
                        { o => o is SnapshotProbeHost })
                    k = k + 1
                }
                0
            })
            t = t + 1
        }
        // 4 个读者：并发查询（旧实现走全局 mtx，新实现读快照）。
        while (t < 8) {
            fs.add(spawn {
                var k = 0
                while (k < 2000) {
                    if (!JitBindSupport.acceptsInterface(target, name) ||
                        !JitBindSupport.isInterface(name)) {
                        let _ = bad.fetchAdd(1)
                    }
                    k = k + 1
                }
                0
            })
            t = t + 1
        }
        for (f in fs) {
            @Assert(f.get(), 0)
        }
        @Assert(bad.load(), 0)
    }

    /**
     * 确定性复现「发布时机」竞态：写者在发布钩子里停住时，读者必须已经能看到本次登记
     * ——即 `store` 必须发生在两张表填充**之后**。变异「先 store、后填充」会让本用例变红。
     */
    @TestCase
    public func publishedSnapshotIsAlwaysComplete(): Unit {
        let name = TypeInfo.of<SnapshotFreshHost>().name
        let entered = AtomicInt64(0)
        let release = AtomicInt64(0)
        JitBindSupport.publishHook = Some({ =>
            let _ = entered.store(1)
            while (release.load() == 0) {}
        })
        let writer = spawn {
            JitBindSupport.enrollInterfaceOf<SnapshotFreshHost>(JitBindings.empty(),
                { o => o is SnapshotFreshHost })
            0
        }
        var spins = 0
        while (entered.load() == 0 && spins < 50000000) {
            spins = spins + 1
        }
        @Assert(entered.load(), 1)
        let visible = JitBindSupport.acceptsInterface(SnapshotFreshHost(), name)
        let _ = release.store(1)
        let joined = writer.get()
        JitBindSupport.publishHook = None
        @Assert(joined, 0)
        @Assert(visible, true)
    }
}

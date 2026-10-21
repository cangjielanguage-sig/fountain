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

import std.sync.*
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/** S6.6：适配器注册表（键、查找、按单元移除、并发）。 */
@Test
public class AdapterRegistry_test {
    @TestCase
    public func registerAndLookup(): Unit {
        AdapterRegistry.register(1u64, 2u32, 'Int64', 7)
        match (AdapterRegistry.lookup(1u64, 2u32, 'Int64')) {
            case Some(v) => @Assert(v, 7)
            case None => @Fail('查无')
        }
        @Assert(AdapterRegistry.lookup(1u64, 2u32, 'Float64').isNone(), true)
        @Assert(AdapterRegistry.lookup(1u64, 3u32, 'Int64').isNone(), true)
        @Assert(AdapterRegistry.lookup(9u64, 2u32, 'Int64').isNone(), true)
        @Assert(AdapterRegistry.removeUnit(1u64) >= 1, true)
    }

    @TestCase
    public func removeUnitOnlyAffectsItsFingerprint(): Unit {
        AdapterRegistry.register(10u64, 0u32, 'Int64', 1)
        AdapterRegistry.register(10u64, 1u32, 'Int64', 2)
        AdapterRegistry.register(11u64, 0u32, 'Int64', 3)
        @Assert(AdapterRegistry.removeUnit(10u64), 2)
        @Assert(AdapterRegistry.lookup(10u64, 0u32, 'Int64').isNone(), true)
        @Assert(AdapterRegistry.lookup(10u64, 1u32, 'Int64').isNone(), true)
        match (AdapterRegistry.lookup(11u64, 0u32, 'Int64')) {
            case Some(v) => @Assert(v, 3)
            case None => @Fail('误删其他单元')
        }
        @Assert(AdapterRegistry.removeUnit(11u64), 1)
    }

    @TestCase
    public func concurrentRegisterAndLookup(): Unit {
        let futures = ArrayList<Future<Unit>>()
        var t = 0
        while (t < 4) {
            let tid = t
            futures.add(spawn {
                var i = 0
                while (i < 50) {
                    let fp = UInt64(100 + tid)
                    AdapterRegistry.register(fp, UInt32(i), 'Int64', Int64(tid * 1000 + i))
                    match (AdapterRegistry.lookup(fp, UInt32(i), 'Int64')) {
                        case Some(v) => @Assert(v, Int64(tid * 1000 + i))
                        case None => @Fail('并发查无')
                    }
                    i = i + 1
                }
            })
            t = t + 1
        }
        for (f in futures) {
            f.get()
        }
        @Assert(AdapterRegistry.removeUnit(100u64), 50)
        @Assert(AdapterRegistry.removeUnit(103u64), 50)
    }
}

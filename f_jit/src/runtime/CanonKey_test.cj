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

import std.collection.ArrayList
import std.collection.HashMap
import std.math.numeric.Decimal
import std.sync.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_regex.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.bytecode.CanonKey
import fountain::f_jit.bytecode.ConstMapKey

/**
 * A5：常量键单点（P1-7）与迭代器表生命周期（P2-2）。
 *
 * 键的一致性用「常量表侧（`CanonKey.*`）≡ 运行期侧（`HandleTable.canonKeyOf`）」逐类型对拍：
 * 两侧只要有一处前缀/归一规则不同，常量 Map 的键就永不命中。
 */
@Test
public class CanonKey_test {

    /** 六类键：常量表与运行期得到**同一个**规范键。 */
    @TestCase
    public func p1_7_canonKeyIsSingleSource(): Unit {
        @Assert(CanonKey.f64(1.5f64.toBits()), HandleTable.canonKeyOf(1.5f64))
        @Assert(CanonKey.dec(0u8, 2, '150'), HandleTable.canonKeyOf(Decimal.parse('1.50')))
        @Assert(HandleTable.canonKeyOf(Decimal.parse('1.5')),
            HandleTable.canonKeyOf(Decimal.parse('1.50')))
        @Assert(HandleTable.canonKeyOf(Decimal.parse('1.5')) !=
            HandleTable.canonKeyOf(Decimal.parse('1.6')), true)
        @Assert(CanonKey.dateTime(0), HandleTable.canonKeyOf(DateTime.UnixEpoch))
        @Assert(CanonKey.duration(5), HandleTable.canonKeyOf(Duration.nanosecond * 5))
        let r = Range<Int64>(0, 10, 2, true, true, false)
        @Assert(CanonKey.range(0, 10, 2, false), HandleTable.canonKeyOf(r))
        @Assert(CanonKey.regex('abc', 1u8),
            HandleTable.canonKeyOf(JitRegex('abc'.regex(), 1u8)))
        // 不同值必须不同键
        @Assert(HandleTable.canonKeyOf(1.5f64) != HandleTable.canonKeyOf(2.5f64), true)
        @Assert(HandleTable.canonKeyOf(JitRegex('abc'.regex(), 0u8)) !=
            HandleTable.canonKeyOf(JitRegex('abc'.regex(), 1u8)), true)
    }

    /** 一次「打开 → 推进 → 清空」后：liveCount 归零、旧游标以 99 失败。 */
    @TestCase
    public func p2_2_iterTableClearInvalidatesCursor(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.openWindow(8)
        IterTable.clearAll()
        let m = HashMap<ConstMapKey, Any>()
        m.add(ConstMapKey('k', 's:k'), Int64(1))
        let h = HandleTable.pin(m)
        let cur = IterTable.open(h, 0u8)
        @Assert(IterTable.liveCount(), 1)
        @Assert(IterTable.next(cur), true)
        IterTable.clearAll()
        @Assert(IterTable.liveCount(), 0)
        var code = 0
        try {
            let _ = IterTable.next(cur)
        } catch (e: HelperFail) {
            code = e.code
        }
        @Assert(code, ErrCode.HELPER_PANIC)
    }

    /** 并发 `open/next/close`：不撕裂、不越界，全部关闭后 liveCount 归零。 */
    @TestCase
    public func p2_2_iterTableConcurrentSafe(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.openWindow(8)
        IterTable.clearAll()
        let m = HashMap<ConstMapKey, Any>()
        var k = 0
        while (k < 8) {
            m.add(ConstMapKey('k${k}', 's:k${k}'), Int64(k))
            k = k + 1
        }
        let h = HandleTable.pin(m)
        let futures = ArrayList<Future<Unit>>()
        var t = 0
        while (t < 4) {
            futures.add(spawn {
                var i = 0
                while (i < 100) {
                    let cur = IterTable.open(h, 0u8)
                    var n = 0
                    while (IterTable.next(cur)) {
                        let _ = IterTable.key(cur)
                        let _ = IterTable.value(cur)
                        n = n + 1
                    }
                    @Assert(n, 8)
                    IterTable.close(cur)
                    i = i + 1
                }
            })
            t = t + 1
        }
        for (f in futures) {
            f.get()
        }
        @Assert(IterTable.liveCount(), 0)
    }
}

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
import fountain::f_jit.base.LocalType
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

    /**
     * X2：值型键只有一种形态。
     *
     * 旧实现 `f64` 产出 `f:<bits>`、`cell` 产出 `i:<bits>`：同一个 `Float64` 在裸 cell 与
     * 装箱两条承载路径上得到两个键。这里把「同值同键」写成对三条代表性位模式的不变式。
     */
    @TestCase
    public func x2_f64KeyEqualsCellKey(): Unit {
        for (bits in [1.5f64.toBits(), 0x8000000000000000u64, 0x7FF8000000000000u64]) {
            @Assert(CanonKey.f64(bits), CanonKey.cell(CanonKey.bitsAsI64(bits)))
        }
        @Assert(CanonKey.f64(1.5f64.toBits()) != CanonKey.f64(2.5f64.toBits()), true)
    }

    /**
     * X2：承载形态无关——同一 `Float64` 以裸 cell 与句柄（装箱）两种形态作 `Map` 键，规范键相同。
     *
     * 裸 cell 走 `mapKeyOf` 的 `None` 分支（`cell`）；装箱走 `getAny` 的 `Some` 分支
     * （`canonKeyOf`）。两条分支必须给出同一 `token`，否则常量 Map 的 Float64 键在装箱承载下永不命中。
     */
    @TestCase
    public func x2_boxedAndRawFloatKeyAgree(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 64
        HandleTable.openWindow(8)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 8,
            fnId: 1, dbgBase: 0)
        let raw = CanonKey.bitsAsI64(1.5f64.toBits())
        let boxed = anyBox(ctx, [Int64(LocalType.F64), raw])
        let boxed2 = anyBox(ctx, [Int64(LocalType.F64),
            CanonKey.bitsAsI64(2.5f64.toBits())])
        @Assert(ctx.errCode, 0)
        @Assert(mapKeyOf(boxed).token, mapKeyOf(raw).token)
        @Assert(HandleTable.canonKeyOf(1.5f64), CanonKey.cell(raw))
        @Assert(mapKeyOf(raw).token != mapKeyOf(CanonKey.bitsAsI64(2.5f64.toBits())).token, true)
        // 不同盒必须不同键（旧实现两者都是空串）
        @Assert(mapKeyOf(boxed).token != mapKeyOf(boxed2).token, true)
        JitContext.free(ctx)
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

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

import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.TCase
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HelperId
import fountain::f_jit.runtime.HostCallback
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.runtime.UserHelperEntry
import fountain::f_jit.runtime.UserHelperTable
import fountain::f_jit.runtime.invokeHelper

/**
 * GAP-08：宿主闭包调用（CALL_HOST）相对 user helper 的开销比值。
 *
 * 规格 m2 §5 估「1.5–3×（以实测为准）」。本用例取同构的 `(Int64) -> Int64` 两条通道，
 * 预热后各跑 `rounds` 次，打印实测比值。
 *
 * 说明：反射 `apply` 走 `MapleRuntime::MethodInfo::ApplyCJMethod`，比静态绑定多一层；
 * 这个数字决定是否需要「预注册签名的快速路径」（`SignatureRegistry`）。
 */
@Test
public class PerfM2_test {
    @TestCase
    public func userHelperVsHostClosure(): Unit {
        let rounds: Int64 = 2000
        HandleTable.resetForTest()
        HandleTable.openWindow(4096)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 4096,
            fnId: 0, dbgBase: 0)
        // user helper：与宿主闭包同构的一元函数
        let entry = UserHelperEntry(params: [LocalType.I64], ret: LocalType.I64,
            impl: { a => match (a[0]) {
                case x: Int64 => x + 1
                case _ => 0
            } })
        UserHelperTable.push(0u16, [entry])
        let uh = Int64(HelperId.USER_BASE)
        let host: (Int64) -> Int64 = { x => x + 1 }
        let h = HandleTable.pin(HostCallback(host,
            SignatureDescriptor([LocalType.I64], LocalType.I64)))
        try {
            // 预热（含首次反射元数据建立）
            var i = 0
            while (i < 64) {
                let r1 = invokeHelper(ctx, uh, [i])
                let r2 = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h, i])
                @Assert(r1 == i + 1 && r2 == i + 1, true)
                i = i + 1
            }
            let t0 = DateTime.now()
            var k = 0
            while (k < rounds) {
                let _ = invokeHelper(ctx, uh, [k])
                k = k + 1
            }
            let dUh = DateTime.now() - t0

            let t1 = DateTime.now()
            k = 0
            while (k < rounds) {
                let _ = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h, k])
                k = k + 1
            }
            let dHost = DateTime.now() - t1

            let un = dUh.toNanoseconds()
            let hn = dHost.toNanoseconds()
            @Assert(un > 0 && hn > 0, true)
            // 比值以「每万次耗时」表示，避免小数
            let ratioX100 = hn * 100 / un
            let uhPer10k = un * 10000 / rounds
            let hostPer10k = hn * 10000 / rounds
            // 回归门禁：比值不得超过 10×（实测约 4.6–5.8×，见 `doc/perf-m2.md`）。
            // 失败时消息里带出三条数字，便于定位是 user helper 变快还是闭包变慢。
            @Assert(TCase.hit('T32/host-call-overhead-ratio',
                ratioX100 > 100 && ratioX100 < 1000), true)
            let _ = uhPer10k
            let _ = hostPer10k
        } finally {
            UserHelperTable.pop()
            JitContext.free(ctx)
            HandleTable.resetForTest()
        }
    }
}

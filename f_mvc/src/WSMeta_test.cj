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
package fountain::f_mvc

import std.unittest.*
import std.unittest.testmacro.*

/**
 * §1.11 / `MVC-3`：ping 定时器必须随读帧循环一起结束。
 *
 * 测的是包内接缝 `pumpFrames`（`exec` 的「建定时器 + 读帧循环 + 退出取消」都在它里面），
 * 用「假帧源 + 计数 ping 动作」绕开 `WebSocket`/`HttpContext`（两者都是 stdx 的类，测试里造不出来）。
 *
 * 帧源按 stdx 契约模拟「断链」：`WebSocket.read()` 在对端关闭连接时**抛异常**（不是返回 None）。
 * 修前形态（循环外没有 finally 取消）时，`pumpFrames` 退出后定时器仍在跑 ⇒
 * 下面「退出后 3 个周期内 ping 次数不再增长」的断言会失败。
 */
@Test
class WSMeta_test {
    /** 断链（read 抛异常）：pump 退出后 ping 必须停止 */
    @TestCase
    public func testPingStopsAfterConnectionDrops(): Unit {
        let pings = Box<Int64>(0)
        let interval = Duration.millisecond * 10
        try {
            pumpFrames(
                readFrame: {=> throw Exception('connection closed')},   // 首次读就断链
                onFrame: {_ => false},
                ping: Some({=> pings.value++}),
                interval: interval
            )
        } catch (_: Exception) {
        }
        // 等 3 个周期：修前（无 finally 取消）这里会看到 ≥3 次 ping
        sleep(interval * 3)
        @Assert(0, pings.value)
    }

    /** 防空转：连接存活（read 阻塞）时 ping 必须真的在跑，断链后立即停 */
    @TestCase
    public func testPingRunsWhileAliveAndStopsAfterReturn(): Unit {
        let pings = Box<Int64>(0)
        let interval = Duration.millisecond * 10
        try {
            pumpFrames(
                readFrame: {=>
                    // 模拟连接存活期间在等帧：阻塞 3 个周期，然后抛异常表示断链
                    sleep(interval * 3)
                    throw Exception('connection closed')
                },
                onFrame: {_ => false},
                ping: Some({=> pings.value++}),
                interval: interval
            )
        } catch (_: Exception) {
        }
        @Assert(true, pings.value >= 1)     // 存活期间确实 ping 过 ⇒ 用例不是空转
        // 取消瞬间可能有一次 tick 已在途中：先等 1 个周期让它落地，再取基线；
        // 之后的 3 个周期内 ping 次数必须不再增长（修前：无 finally 取消 ⇒ 持续增长）
        sleep(interval)
        let baseline = pings.value
        sleep(interval * 3)
        @Assert(baseline, pings.value)
    }

    /**
     * §3.1 / `MVC-C6(b)`：数据帧（Text/Binary）到达时的处置判定接缝 ——
     * 该帧类型没配 meta、或上一条载荷未消费完时，必须结束会话（`ws.closeConn()` + `return true`）。
     * 修前形态（接缝一律返回 `None`、由 `doExec` 抛 `WSException` 走 catch-and-continue）：后两条断言失败。
     */
    @TestCase
    public func testDataFrameCloseReason(): Unit {
        // 正常：无待处理载荷、且该类型配了 meta ⇒ 不关
        @Assert(None<String>, dataFrameCloseReason('text', false, true))
        @Assert(None<String>, dataFrameCloseReason('binary', false, true))
        // 上一条载荷未消费完又来数据帧 ⇒ 关（协议层异常）
        @Assert(Some('current payload is not empty'), dataFrameCloseReason('text', true, true))
        // 该帧类型没有配置 meta ⇒ 关
        @Assert(Some('text meta for ws is not specified'), dataFrameCloseReason('text', false, false))
        @Assert(Some('binary meta for ws is not specified'), dataFrameCloseReason('binary', false, false))
    }
}

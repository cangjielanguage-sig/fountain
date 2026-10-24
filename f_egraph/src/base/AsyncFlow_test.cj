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
package fountain::f_egraph.base

import std.unittest.*
import std.unittest.testmacro.*

/** `AsyncFlow` 的生命周期与端到端路径（`design.md` §5.3、R6）。 */
@Test
class AsyncFlow_test {
    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    /** 未初始化 dispatcher 时构造必须失败（脚本路径的前置条件，`design.md` R6）。 */
    @TestCase
    public func uninitializedDispatcherFailsConstruction(): Unit {
        AsyncFlow.resetDispatcherForTest()
        var failed = false
        try {
            let _ = AsyncFlow(category: AsyncFlow_test.category("uninit"), tag: "v1")
        } catch (e: Exception) {
            failed = true
        } finally {
            AsyncFlow.initDispatcher()
        }
        @Assert(failed, true)
    }

    /** 初始化后可构造并跑通「开始 → 任务 → 结束」。 */
    @TestCase
    public func initializedDispatcherRunsFlow(): Unit {
        AsyncFlow.initDispatcher()
        let c = AsyncFlow_test.category("e2e")
        let flow = AsyncFlow(category: c, tag: "v1")
        flow.registerStart("created")
        flow.registerEnd()
        flow.registerTask("created") { e =>
            EndEvent(category: c, tag: "v1", data: "done")
        }
        let end = flow.start("go").get().get()
        @Assert(end.eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(end), "done")
        flow.remove()
    }
}

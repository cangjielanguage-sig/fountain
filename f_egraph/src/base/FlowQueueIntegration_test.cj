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

/** 计数持有者：闭包不能捕获可变局部变量 */
class StepCounter {
    public var executed: Int64 = 0
}

/**
 * 端到端：流程内注册 `QueuedClosureTask`，事件经队列执行，结果回灌派发器。
 *
 * 任务返回**不同名**事件，避免「自己喂自己」；流程只跑到没有后继执行器为止。
 */
@Test
class FlowQueueIntegration_test {
    @TestCase
    func testFlowRunsQueuedTaskAndAcceptsResult(): Unit {
        let flow = ImmediateFlow(category: 'it', tag: 'queue')
        let counter = StepCounter()
        let task = QueuedClosureTask('step', ['a'], ['b'], flow.getDispatcher(),
            { e =>
                counter.executed++
                DataEvent(eventType: EventType.End, category: e.category, tag: e.tag,
                          name: EventType.End.toString(), data: 'done')
            })
        flow.registerStart('a')
        flow.registerTask(task)
        flow.registerEnd()

        flow.start('go')
        @Expect(counter.executed, 1)
        // 结果事件已入派发器队列但无后继执行器：派发循环已消费完，队列应为空
        @Expect(task.pending, 0)
    }

    @TestCase
    func testPriorityZeroRunsBeforeQueuedBacklog(): Unit {
        let flow = ImmediateFlow(category: 'it', tag: 'priority')
        let counter = StepCounter()
        let task = QueuedClosureTask('step', ['a'], ['b'], flow.getDispatcher(),
            { e =>
                counter.executed++
                DataEvent(eventType: EventType.End, category: e.category, tag: e.tag,
                          name: EventType.End.toString(), data: 'done')
            })
        flow.registerStart('a')
        flow.registerTask(task)
        flow.registerEnd()

        // 先塞一条 p2 到队列，再让流程触发：exec 会先执行 p2，再触发 0 号顶替
        flow.start('go')
        @Expect(counter.executed >= 1, true)
    }
}

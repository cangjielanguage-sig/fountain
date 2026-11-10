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

import fountain::f_concurrent.*

/** 回归用例：`SyncPriorityQueue` 容量为 0 时曾因 grow 死循环导致 submit 挂起 */
@Test
class QueueCapacityRegression_test {
    @TestCase
    func testSyncPriorityQueueAddWithZeroCapacity(): Unit {
        let queue = SyncPriorityQueue<Int64>({ a, b => a.compare(b) })
        queue.add(3)
        queue.add(1)
        queue.add(2)
        @Expect(queue.size, 3)
        @Expect(queue.peek().getOrThrow(), 1)
    }

    @TestCase
    func testQueuedTaskSubmitWithRealDispatcher(): Unit {
        let dispatcher = ImmediateDispatcher()
        let task = QueuedClosureTask('p', ['a'], ['b'], dispatcher, { e => e })
        task.submit(DataEvent(eventType: EventType.Task, category: 'probe', tag: 't',
                              name: 'a', data: 'in', priority: 2))
        @Expect(task.pending, 1)
    }
}

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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class QueuedClosureTask_test {
    private func ev(name: String, priority: Int64, cancelPrev!: Int64 = 0): DataEvent {
        DataEvent(eventType: EventType.Task, category: 'c', tag: 't', name: name,
                  data: name, priority: priority, cancelPrev: cancelPrev)
    }

    private func newTask(seen: ArrayList<String>): QueuedClosureTask {
        QueuedClosureTask('queued', ['c'], ['c'], { e => e },
                          onResult: { r => seen.add(r.name) })
    }

    @TestCase
    func testOrdersByPriorityThenBirth(): Unit {
        let seen = ArrayList<String>()
        let task = newTask(seen)
        task.submit(ev('p2-a', 2))
        task.submit(ev('p1', 1))
        task.submit(ev('p2-b', 2))
        task.submit(ev('p0', 0))

        @Expect(task.drain(), 3)          // 0 批 + 1 批 + 两条 2 号
        @Expect(seen[0], 'priority-batch')  // p0 合并批
        @Expect(seen[1], 'priority-batch')  // p1 合并批
        @Expect(seen[2], 'p2-a')            // 同优先级按 birth（提交顺序）
        @Expect(seen[3], 'p2-b')
    }

    @TestCase
    func testPriorityZeroBatchesIntoOneExecution(): Unit {
        let seen = ArrayList<String>()
        let task = newTask(seen)
        task.submit(ev('a', 0))
        task.submit(ev('b', 0))

        @Expect(task.drain(), 1)
        @Expect(seen.size, 1)
    }

    @TestCase
    func testPriorityOneBatchesIntoOneExecution(): Unit {
        let seen = ArrayList<String>()
        let task = newTask(seen)
        task.submit(ev('a', 1))
        task.submit(ev('b', 1))

        @Expect(task.drain(), 1)
        @Expect(seen.size, 1)
    }

    @TestCase
    func testPriorityTwoRunsSequentially(): Unit {
        let seen = ArrayList<String>()
        let task = newTask(seen)
        task.submit(ev('a', 2))
        task.submit(ev('b', 2))

        @Expect(task.drain(), 2)
        @Expect(seen[0], 'a')
        @Expect(seen[1], 'b')
    }

    @TestCase
    func testCancelPrevRemovesSamePriority(): Unit {
        let task = newTask(ArrayList<String>())
        task.submit(ev('a', 2))
        task.submit(ev('b', 2))
        task.submit(ev('c', 2, cancelPrev: 1))   // 撤销前一条同优先级（b）

        @Expect(task.pending, 2)
        @Expect(task.drain(), 2)
    }

    @TestCase
    func testEmptyEventDeletesQueuedEvents(): Unit {
        let task = newTask(ArrayList<String>())
        task.submit(ev('a', 2))
        task.submit(ev('b', 2))
        task.submit(EmptyEvent(cancelPrev: 1))   // 删除队列尾部 1 条

        @Expect(task.pending, 1)
        @Expect(task.drain(), 1)
    }

    @TestCase
    func testEmptyEventWithoutCancelIsNoop(): Unit {
        let task = newTask(ArrayList<String>())
        task.submit(EmptyEvent())

        @Expect(task.pending, 0)
        @Expect(task.drain(), 0)
    }

    @TestCase
    func testNegativePriorityRejected(): Unit {
        var message = ''
        try{
            ev('bad', -1)
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('priority'), true)
    }

    @TestCase
    func testPriorityZeroPreemptsCurrentResult(): Unit {
        let seen = ArrayList<String>()
        let holder = Holder()
        let task = QueuedClosureTask('preempt', ['c'], ['c'],
            { e =>
                if(e.name == 'slow'){
                    // 模拟执行中被 0 号事件抢占：发布事件后当前批次结果应被丢弃
                    match(holder.task){
                        case Some(target) => target.submit(ev('urgent', 0))
                        case None => ()
                    }
                    holder.executed = true
                }
                e
            },
            onResult: { r => seen.add(r.name) })
        holder.task = Some(task)

        task.submit(ev('slow', 2))
        @Expect(task.drain(), 2)          // slow 被抢占（结果丢弃）+ urgent 批
        @Expect(task.cancelledCount, 1)
        @Expect(seen.size, 1)             // 只有 urgent 批的结果
        @Expect(holder.executed, true)    // 任务体确实跑完了（协作式，不能强杀）
    }
}

class Holder {
    public var task: ?QueuedClosureTask = None
    public var executed: Bool = false
}

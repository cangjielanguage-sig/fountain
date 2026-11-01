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

    private func newTask(recorder: RecordingDispatcher): QueuedClosureTask {
        QueuedClosureTask('queued', ['c'], ['c'], recorder, { e => e })
    }

    private func names(recorder: RecordingDispatcher): ArrayList<String> {
        let result = ArrayList<String>()
        for(item in recorder.events){
            result.add(item.name)
        }
        result
    }

    @TestCase
    func testPriorityZeroRunsImmediately(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('z', 0))

        // 0 号不等 drain，提交即执行，结果进 dispatcher
        @Expect(recorder.events.size, 1)
        @Expect(recorder.events[0].name, 'z')
        @Expect(task.pending, 0)
    }

    @TestCase
    func testExecDrainsQueueIntoDispatcher(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)

        let returned = task.exec(ev('a', 2))
        @Expect(returned is DummyEvent, true)   // 返回值给 TaskExecutor，会被 dispatch 跳过
        @Expect(recorder.events.size, 1)
        @Expect(recorder.events[0].name, 'a')
        @Expect(task.pending, 0)
    }

    @TestCase
    func testOrdersByPriorityThenBirth(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('p2-a', 2))
        task.submit(ev('p1', 1))
        task.submit(ev('p2-b', 2))
        task.submit(ev('p0', 0))

        let seen = names(recorder)
        @Expect(seen[0], 'p0')          // 0 号先执行（提交时）
        @Expect(task.drain(), 3)        // p1 批 + 两条 2 号
        @Expect(seen[1], 'p1')          // 1 号同名合并批，name 取批内首条
        @Expect(seen[2], 'p2-a')        // 同优先级按 birth（提交顺序）
        @Expect(seen[3], 'p2-b')
    }

    @TestCase
    func testPriorityOneBatchesSameName(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('a', 1))
        task.submit(ev('b', 1))
        task.submit(ev('c', 1))

        @Expect(task.drain(), 1)
        @Expect(recorder.events.size, 1)
        @Expect(recorder.events[0].name, 'a')
    }

    @TestCase
    func testPriorityOneBatchesPerName(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('a', 1))
        task.submit(ev('b', 1))
        task.submit(ev('a', 1))

        // 同名 a 一批、b 一批
        @Expect(task.drain(), 2)
        @Expect(recorder.events.size, 2)
    }

    @TestCase
    func testPriorityTwoRunsSequentially(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('a', 2))
        task.submit(ev('b', 2))

        @Expect(task.drain(), 2)
        @Expect(recorder.events[0].name, 'a')
        @Expect(recorder.events[1].name, 'b')
    }

    @TestCase
    func testCancelPrevRemovesSamePriority(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('a', 2))
        task.submit(ev('b', 2))
        task.submit(ev('c', 2, cancelPrev: 1))   // 撤销前一条同优先级（b）

        @Expect(task.pending, 2)
        @Expect(task.drain(), 2)
    }

    @TestCase
    func testEmptyEventDeletesQueuedEvents(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
        task.submit(ev('a', 2))
        task.submit(ev('b', 2))
        task.submit(EmptyEvent(cancelPrev: 1))   // 删除队列尾部 1 条

        @Expect(task.pending, 1)
        @Expect(task.drain(), 1)
    }

    @TestCase
    func testEmptyEventWithoutCancelIsNoop(): Unit {
        let recorder = RecordingDispatcher()
        let task = newTask(recorder)
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

    /** 0 号事件顶替**同名**的正在执行事件：外层结果丢弃，内层立即执行 */
    @TestCase
    func testPriorityZeroReplacesSameNameExecution(): Unit {
        let recorder = RecordingDispatcher()
        let holder = Holder()
        let task = QueuedClosureTask('preempt', ['c'], ['c'], recorder,
            { e =>
                let payload = match(e){
                    case d: DataEvent => match(d.tryGet<String>()){
                        case Some(text) => text
                        case None => ''
                    }
                    case _ => ''
                }
                if(payload == 'slow'){
                    match(holder.task){
                        case Some(target) => target.submit(ev('slow', 0))
                        case None => ()
                    }
                    holder.slow++
                }else if(payload == 'urgent'){
                    holder.urgent++
                }
                e
            })
        holder.task = Some(task)

        task.submit(ev('slow', 2))
        @Expect(task.drain(), 1)          // 只执行外层一次（结果被丢弃）
        @Expect(holder.slow, 1)           // 外层任务体确实跑完了（协作式）
        @Expect(holder.urgent, 1)         // 0 号立即执行
        @Expect(task.cancelledCount, 1)
        @Expect(recorder.events.size, 1)  // 只有 0 号的结果进入 dispatcher
    }

    /** 不同名的 0 号事件不取消正在执行的事件 */
    @TestCase
    func testPriorityZeroWithOtherNameDoesNotCancel(): Unit {
        let recorder = RecordingDispatcher()
        let holder = Holder()
        let task = QueuedClosureTask('preempt', ['c'], ['c'], recorder,
            { e =>
                let payload = match(e){
                    case d: DataEvent => match(d.tryGet<String>()){
                        case Some(text) => text
                        case None => ''
                    }
                    case _ => ''
                }
                if(payload == 'slow'){
                    match(holder.task){
                        case Some(target) => target.submit(ev('other', 0))
                        case None => ()
                    }
                }
                e
            })
        holder.task = Some(task)

        task.submit(ev('slow', 2))
        @Expect(task.drain(), 1)
        @Expect(task.cancelledCount, 0)
        @Expect(recorder.events.size, 2)  // 0 号 + 外层都进 dispatcher
    }
}

class Holder {
    public var task: ?QueuedClosureTask = None
    public var slow: Int64 = 0
    public var urgent: Int64 = 0
}

/** 记录收到的结果事件（只实现管道所需的接口） */
class RecordingDispatcher <: Dispatcher {
    let events = ArrayList<Event>()

    public func accept(event: Event): Unit {
        events.add(event)
    }

    protected func dispatch(): Unit {
    }

    public func registerStart(category!: String, tag!: String, eventName!: String): Unit {
    }

    public func registerError(category!: String, tag!: String): Unit {
    }

    public func registerEnd(category!: String, tag!: String): Unit {
    }

    public func registerTask(category!: String, tag!: String, eventName!: String,
                             task!: (Event) -> Event): Unit {
    }

    protected func doRegisterMulti(category!: String, tag!: String,
                                   task!: (Event) -> Event): Unit {
    }

    protected func doStartEventName(category!: String, tag!: String): ?String {
        None
    }

    public func start(event: StartEvent): Dispatcher {
        this
    }

    public func get(): EndExecutor {
        throw GraphException('RecordingDispatcher has no EndExecutor')
    }

    public func tryGet(): ?EndExecutor {
        None
    }

    public func removeIf(predicate: (Event) -> Bool): Unit {
    }
}

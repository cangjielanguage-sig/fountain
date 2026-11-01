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
import std.sync.*

import fountain::f_collection.*
import fountain::f_concurrent.*

/**
 * 带事件优先级队列的 [ClosureTask]，队列用 [fountain::f_concurrent.SyncPriorityQueue]。
 *
 * Flow 收到事件后立即调用 `exec(e)`——本类只入队、立刻返回 [DummyEvent]，
 * 真正的执行由 `runNext()` / `drain()` 驱动（便于单线程确定性，也便于外部接入线程池）。
 *
 * 队列顺序：`priority` 升序；同优先级按 `birth` 先进先出，`birth` 相同再按入队序号
 * （堆不保证稳定，所以把序号放进比较器，而不是依赖插入顺序）。
 *
 * 执行批次：
 * - `priority = 0`：所有 0 号事件合并成一批，**抢占**当前执行——执行中的高优先级批次返回后
 *   发现版本号已变，结果被丢弃（协作式：Cangjie 无法强制终止闭包，长任务应自行轮询 `generation`）；
 * - `priority = 1`：所有 1 号事件合并成一批，等当前结束后执行；
 * - `priority >= 2`：逐条执行。
 *
 * 取消：`cancelPrev > 0` 撤销队列中前面 N 条**同优先级**事件；[EmptyEvent] 的
 * `cancelPrev > 0` 撤销队列尾部 N 条事件（跨优先级），自身不执行。
 */
public class QueuedClosureTask <: ClosureTask {
    /** 我们的锁保护「批量取出 + 版本号」，队列表自身也是线程安全的（内层锁） */
    private let mutex = Mutex()
    private let queue: SyncPriorityQueue<QueueEntry>
    private var sequence: Int64 = 0
    private var epoch: Int64 = 0
    private var cancelled: Int64 = 0
    private let sink: (Event) -> Unit

    public init(name: String, acceptableEvents: Array<String>, producingEvents: Array<String>,
        body: (Event) -> Event, onResult!: (Event) -> Unit = { _ => () }) {
        super(name, acceptableEvents, producingEvents, body)
        this.sink = onResult
        this.queue = SyncPriorityQueue<QueueEntry>(QueuedClosureTask.compareEntries)
    }

    /** Flow 调用入口：只入队，立即返回 */
    public override func exec(e: Event): Event {
        submit(e)
        DummyEvent.instance
    }

    public func submit(e: Event): Unit {
        synchronized(mutex){
            if(e.cancelPrev > 0){
                if(e is EmptyEvent){
                    dropTail(e.cancelPrev)
                    return
                }
                dropTailSamePriority(e.priority, e.cancelPrev)
            }
            if(e is EmptyEvent){
                return
            }
            if(e.priority == 0){
                // 0 号事件抢占：正在执行的高优先级批次结束后会丢弃结果
                epoch++
            }
            sequence++
            queue.add(QueueEntry(e, sequence))
        }
    }

    public prop pending: Int64 {
        get() {
            queue.size
        }
    }

    /** 因被 0 号事件抢占而丢弃结果的次数 */
    public prop cancelledCount: Int64 {
        get() {
            synchronized(mutex){
                cancelled
            }
        }
    }

    /** 当前执行版本号：0 号事件入队即递增 */
    public prop generation: Int64 {
        get() {
            synchronized(mutex){
                epoch
            }
        }
    }

    /** 执行下一批；返回是否执行了（队列为空返回 false） */
    public func runNext(): Bool {
        let batch = takeBatch()
        if(batch.isEmpty()){
            return false
        }
        let priority = batch[0].priority
        let deadline = generation
        let payload = if(batch.size == 1){
            batch[0]
        }else{
            MultiEvent(category: batch[0].category, tag: batch[0].tag,
                       name: 'priority-batch', events: batch)
        }
        let result = evaluate(payload)
        if(priority != 0 && generation != deadline){
            synchronized(mutex){
                cancelled++
            }
            return true
        }
        sink(result)
        true
    }

    /** 一直执行到队列为空，返回执行的批次数 */
    public func drain(): Int64 {
        var count: Int64 = 0
        while(runNext()){
            count++
        }
        count
    }

    // ---- queue internals ----

    private func takeBatch(): ArrayList<Event> {
        synchronized(mutex){
            let batch = ArrayList<Event>()
            match(queue.peek()){
                case Some(head) =>
                    if(head.event.priority <= 1){
                        while(true){
                            match(queue.peek()){
                                case Some(top) =>
                                    if(top.event.priority != head.event.priority){
                                        break
                                    }
                                    match(queue.remove()){
                                        case Some(item) => batch.add(item.event)
                                        case None => break
                                    }
                                case None => break
                            }
                        }
                    }else{
                        match(queue.remove()){
                            case Some(item) => batch.add(item.event)
                            case None => ()
                        }
                    }
                case None => ()
            }
            batch
        }
    }

    private static func compareEntries(a: QueueEntry, b: QueueEntry): Ordering {
        var cmp = a.event.priority.compare(b.event.priority)
        if(cmp == Ordering.EQ){
            // birth 是纳秒级：同优先级按入队时间先进先出
            cmp = a.event.birth.compare(b.event.birth)
        }
        if(cmp == Ordering.EQ){
            // 同一时刻（纳秒相同）再按入队序号，避免堆顺序不稳定
            cmp = a.sequence.compare(b.sequence)
        }
        cmp
    }

    /** 删除队列尾部 n 条（跨优先级，按入队序号从新到旧） */
    private func dropTail(n: Int64): Unit {
        let entries = queue.toArray()
        sortBySequenceDesc(entries)
        let limit = if(n > Int64(entries.size)){ Int64(entries.size) }else{ n }
        for(index in 0..limit){
            let target = entries[index].sequence
            queue.removeIf({ item => item.sequence == target })
        }
    }

    /** 删除队列尾部 n 条同优先级事件 */
    private func dropTailSamePriority(priority: Int64, n: Int64): Unit {
        let matched = ArrayList<QueueEntry>()
        for(item in queue.toArray()){
            if(item.event.priority == priority){
                matched.add(item)
            }
        }
        let entries = matched.toArray()
        sortBySequenceDesc(entries)
        let limit = if(n > Int64(entries.size)){ Int64(entries.size) }else{ n }
        for(index in 0..limit){
            let target = entries[index].sequence
            queue.removeIf({ item => item.sequence == target })
        }
    }

    private static func sortBySequenceDesc(entries: Array<QueueEntry>): Unit {
        for(index in 1..entries.size){
            let current = entries[index]
            var position = index - 1
            while(position >= 0 && entries[position].sequence < current.sequence){
                entries[position + 1] = entries[position]
                position--
            }
            entries[position + 1] = current
        }
    }
}

/** 队列条目：事件 + 入队序号（为堆提供稳定顺序） */
class QueueEntry {
    let event: Event
    let sequence: Int64

    init(event: Event, sequence: Int64) {
        this.event = event
        this.sequence = sequence
    }
}

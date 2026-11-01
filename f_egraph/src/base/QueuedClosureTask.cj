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
 * Flow 收到事件后立即调用 `exec(e)`：
 * - `priority = 0`：**在提交线程立即执行**；若当前正在执行的事件**同名**，把它标记为被顶替，
 *   其返回结果被丢弃（协作式：Cangjie 无法强杀闭包，任务体可轮询 `generation` 提前退出）；
 * - `priority = 1`：入队，等当前事件结束后，把**同名的 1 号事件**合并成一批执行；
 * - `priority >= 2`：入队，按 `(priority, birth, 入队序号)` 顺序逐条执行。
 *
 * 取消：
 * - `cancelPrev > 0`：撤销队列中前面 N 条**同优先级**事件；
 * - [EmptyEvent] 的 `cancelPrev > 0`：撤销队列尾部 N 条事件（跨优先级），自身不执行。
 *
 * 执行由 `runNext()` / `drain()` 驱动（便于单线程确定性；`exec` 里的 0 号事件除外，它是立即的）。
 */
public class QueuedClosureTask <: ClosureTask {
    private let mutex = Mutex()
    private let queue: SyncPriorityQueue<QueueEntry>
    private var sequence: Int64 = 0
    private var epoch: Int64 = 0
    private var cancelled: Int64 = 0
    private var currentName: String = ''
    private var currentToken: ?CancelToken = None
    private var tokenCounter: Int64 = 0
    private let sink: (Event) -> Unit

    public init(name: String, acceptableEvents: Array<String>, producingEvents: Array<String>,
        body: (Event) -> Event, onResult!: (Event) -> Unit = { _ => () }) {
        super(name, acceptableEvents, producingEvents, body)
        this.sink = onResult
        this.queue = SyncPriorityQueue<QueueEntry>(QueuedClosureTask.compareEntries)
    }

    /** Flow 调用入口：0 号立即执行并返回其结果，其余入队后返回 [DummyEvent] */
    public override func exec(e: Event): Event {
        if(e.priority == 0){
            return submitImmediate(e)
        }
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
            sequence++
            queue.add(QueueEntry(e, sequence))
        }
    }

    /**
     * 0 号事件：提交线程立即执行。
     *
     * 若当前执行中的事件与它**同名**，给当前执行打取消标记——外层结束后结果丢弃，
     * 由本条 0 号事件顶替。
     */
    private func submitImmediate(e: Event): Event {
        var token = CancelToken(0)
        synchronized(mutex){
            tokenCounter++
            token = CancelToken(tokenCounter)
            epoch++
            if(currentName == e.name){
                match(currentToken){
                    case Some(running) =>
                        if(!running.cancelled){
                            running.cancelled = true
                            cancelled++
                        }
                    case None => ()
                }
            }
            currentName = e.name
            currentToken = Some(token)
        }
        let result = evaluate(e)
        synchronized(mutex){
            if(!token.cancelled){
                sink(result)
            }
            match(currentToken){
                case Some(active) =>
                    if(active.id == token.id){
                        currentName = ''
                        currentToken = None
                    }
                case None => ()
            }
        }
        result
    }

    public prop pending: Int64 {
        get() {
            queue.size
        }
    }

    /** 被同名 0 号事件顶替而丢弃结果的次数 */
    public prop cancelledCount: Int64 {
        get() {
            synchronized(mutex){
                cancelled
            }
        }
    }

    /** 当前执行版本号：0 号事件提交即递增 */
    public prop generation: Int64 {
        get() {
            synchronized(mutex){
                epoch
            }
        }
    }

    /** 执行下一批；返回是否执行了（队列为空返回 false） */
    public func runNext(): Bool {
        var token = CancelToken(0)
        var batch: ArrayList<Event> = ArrayList<Event>()
        synchronized(mutex){
            tokenCounter++
            token = CancelToken(tokenCounter)
            batch = takeBatchLocked()
            if(batch.isEmpty()){
                return false
            }
            currentName = batch[0].name
            currentToken = Some(token)
        }
        let payload = if(batch.size == 1){
            batch[0]
        }else{
            MultiEvent(category: batch[0].category, tag: batch[0].tag,
                       name: batch[0].name, events: batch)
        }
        let result = evaluate(payload)
        synchronized(mutex){
            match(currentToken){
                case Some(active) =>
                    if(active.id == token.id){
                        currentName = ''
                        currentToken = None
                    }
                case None => ()
            }
            if(token.cancelled){
                return true
            }
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

    /** 取一批：0/1 号按「同优先级 + 同名」合并，>=2 取一条（调用方持有 mutex） */
    private func takeBatchLocked(): ArrayList<Event> {
        let batch = ArrayList<Event>()
        match(queue.peek()){
            case Some(head) =>
                let priority = head.event.priority
                let name = head.event.name
                if(priority <= 1){
                    while(true){
                        match(queue.peek()){
                            case Some(top) =>
                                if(top.event.priority != priority || top.event.name != name){
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

/** 执行令牌：0 号事件顶替同名执行时把它标记为 cancelled */
class CancelToken {
    let id: Int64
    var cancelled: Bool = false

    init(id: Int64) {
        this.id = id
    }
}

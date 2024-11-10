/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_concurrent.eventbus

import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicBool
import f_concurrent.eventbus.exception.EventBusException
/**
 * 任务线程
 */
public class Worker {
    private let abilities = ConcurrentHashMap<Event, (Event) -> Event>()
    private let queue: JobQueue
    private let retired = AtomicBool(false)
    private let index: Int64
    private let eventBus: EventBus
    /**
     * maxWaitingJob 最大等待任务数
     */
    public init(eventBus: EventBus, index: Int64, maxWaitingJob: Int64,
        abilities!: Array<(Event, (Event) -> Event)> = []) {
        this.eventBus = eventBus
        this.index = index
        queue = JobQueue(maxWaitingJob)
        register(abilities)
        spawn {
            while (!retired.load() || queue.size > 0) {
                var e = if (let Some(e) <- tryDequeue()) {
                    e
                } else {
                    eventBus.seizeBy(index)
                    queue.dequeue()
                }
                while (true) {
                    let ee = this.abilities[e](e)
                    ee.workerId = e.workerId
                    ee.deliverResult = e.deliverResult
                    ee.arrangedThreadId = e.arrangedThreadId
                    e = ee
                    if (e is EndEvent) {
                        break
                    }
                }
                deliverIfNeed(e)
            }
        }
    }
    /**
     * 退役
     */
    public func retire(): Unit {
        retired.store(true)
    }
    private func deliverIfNeed(event: Event){
        eventBus.deliverIfNeed(event)
    }
    /**
     * 注册工作线程的能力
     */
    func register(event: Event, ability: (Event) -> Event): Unit {
        abilities[event] = ability
    }
    func register(abilities: Array<(Event, (Event) -> Event)>) {
        for (ability in abilities) {
            register(ability[0], ability[1])
        }
    }
    func force(e: Event) {
        if (e is EndEvent) {
            deliverIfNeed(e)
            return
        }
        var ee = e
        while (!queue.tryEnqueue(ee, Duration.Zero)) {
            ee = abilities[ee](ee)
            if (ee is EndEvent) {
                deliverIfNeed(ee)
                return
            }
        }
        deliverIfNeed(ee)
    }
    func arrange(event: Event): Unit {
        if (retired.load()) {
            throw EventBusException("index of ${index} worker is retired")
        }
        queue.enqueue(event)
    }
    /**
     * 给工作线程安排任务
     */
    func tryArrange(event: Event, timeout!: Duration = Duration.Zero): Bool {
        if (retired.load()) {
            throw EventBusException("index of ${index} worker is retired")
        }
        queue.tryEnqueue(event, timeout)
    }
    func discard(){
        queue.tryDequeue()
    }
    prop waitingJobSize: Int64 {
        get() {
            queue.size
        }
    }
    func tryDequeue(): ?Event {
        if (let Some(e) <- queue.tryDequeue()) {
            eventBus.putQueueSize(index)
            e.workerId = index
            e
        } else {
            None<Event>
        }
    }
}

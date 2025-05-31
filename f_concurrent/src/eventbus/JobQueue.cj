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

import std.collection.concurrent.{LinkedBlockingQueue, ConcurrentHashMap}
import f_concurrent.eventbus.exception.EventBusException

/**
 * 工作任务队列
 */
public class JobQueue {
    private let queue: LinkedBlockingQueue<Event>
    /**
     * max 队列最大长度
     * strategy 满队列策略
     */
    public JobQueue(
        private let max: Int64
    ) {
        queue = LinkedBlockingQueue<Event>(max)
    }
    func enqueue(event: Event) {
        queue.enqueue(event)
    }
    func tryEnqueue(event: Event, timeout: Duration): Bool {
        queue.enqueue(event, timeout)
    }
    func dequeue(): Event {
        queue.dequeue()
    }
    func tryDequeue(): ?Event {
        queue.tryDequeue()
    }
    public prop size: Int64 {
        get(){
            queue.size
        }
    }
}

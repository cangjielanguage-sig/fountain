/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_concurrent

import std.collection.concurrent.BlockingQueue
import std.process.Process
import std.sync.Timer
import std.time.MonoTime

import f_base.ZERO_TIMER
import f_concurrent.exception.RateLimiterException

/**
 * 滑动窗口限流器
 */
public class SlidingWindowRateLimiter<T> <: RateLimiter<T> {
    private let queue: BlockingQueue<MonoTime>
    /**
     * @param timeout 时间窗口
     * @param limit 时间窗口内最大任务数
     */
    public init(timeout!: Duration, limit!: Int64){
        super(timeout)
        queue = BlockingQueue<MonoTime>(limit)
        let timer = Timer.after(Duration.Zero){
            queue.dequeue() + timeout - MonoTime.now()
        }
        Process.current.atExit(timer.cancel)
    }
    public func exec(default: ?T, task: () -> ?T): ?T{
        if(queue.enqueue(MonoTime.now(), timeout) && let Some(x) <- task()){
            x
        } else {
            default
        }
    }
}

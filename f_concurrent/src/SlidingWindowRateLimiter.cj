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

import std.collection.concurrent.ArrayBlockingQueue
import std.process.Process
import std.sync.{Timer, AtomicInt64, ReentrantMutex}
import std.time.MonoTime

import f_base.ZERO_TIMER
import f_concurrent.exception.RateLimiterException

/**
 * 滑动窗口限流器
 */
public class SlidingWindowRateLimiter<T> <: RateLimiter<T> {
    private let mutex = ReentrantMutex()
    private let queue: ArrayBlockingQueue<Mono>
    /**
     * @param timeout 时间窗口
     * @param limit 时间窗口内最大任务数
     */
    public init(window!: Duration, timeout!: Duration, limit!: Int64){
        super(timeout)
        if(window <= Duration.Zero || limit <= 0){
            throw RateLimiterException('all parameters must be larger than zero')
        }
        queue = ArrayBlockingQueue<Mono>(limit)
        let timer = Timer.after(Duration.Zero){
            queue.dequeue().time + window - MonoTime.now()
        }
        Process.current.atExit(timer.cancel)
    }
    public func exec(default: ?T, task: () -> ?T): ?T{
        let mono = Mono()
        if(queue.enqueue(mono, timeout)){
            mono.time = MonoTime.now()
            if(let Some(x) <- task()){
                x
            }else{
                default
            }
        } else {
            default
        }
    }
}
private class Mono {
    private var _time = None<MonoTime>
    private let _count = AtomicInt64(0)

    mut prop time: MonoTime{
        get(){
            _time.getOrThrow()
        }
        set(value){
            _time = value
            _count.fetchAdd(1)
        }
    }
    prop count: Int64{
        get(){
            _count.fetchAdd(1)
        }
    }
}
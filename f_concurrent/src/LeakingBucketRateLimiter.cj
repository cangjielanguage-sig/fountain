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
import std.sync.{Monitor, AtomicBool, CatchupStyle, Timer, AtomicInt64, SyncCounter, AtomicOptionReference, ReentrantMutex}
import std.time.MonoTime

import f_concurrent.exception.RateLimiterException

/**
 * 漏桶限流器
 */
public class LeakingBucketRateLimiter<T> <: RateLimiter<T> {
    private let bucket: ArrayBlockingQueue<(MonoTime, SyncCounter)>
    private let leaked = AtomicInt64(0)
    /**
     * @param timeout 任务等待时长
     * @param maxWaitings 允许等待的最大任务数
     * @param leakingPerDuration 每个漏桶周期漏下的任务数
     * @param leakingDuration 漏桶周期
     */
    public init(
        timeout!: Duration,
        maxWaitings!: Int64,
        leakingPerDuration!: Int64,
        leakingDuration!: Duration
    ) {
        super(timeout)
        if(leakingDuration <= Duration.Zero || leakingPerDuration <= 0 || maxWaitings <= 0){
            throw RateLimiterException('all parameters must be larger than zero')
        }
        this.bucket = ArrayBlockingQueue<(MonoTime, SyncCounter)>(maxWaitings)
        let timer = Timer.after(Duration.Zero){
            leaked.store(0)
            var end: MonoTime
            var next: Duration
            do{
                end = MonoTime.now() + leakingDuration
                while (leaked.load() < leakingPerDuration && 
                    let remainder <- end - MonoTime.now() && remainder > Duration.Zero &&
                    let Some((d, c)) <- bucket.dequeue(remainder)) {
                    if(MonoTime.now() - d < timeout){//这个条件不能合并到while循环条件，这个条件不论结果都得继续下次循环
                        c.dec()
                        leaked.fetchAdd(1)
                    }
                }
                next = end - MonoTime.now()
            }while(next <= Duration.Zero)
            next
        }
        Process.current.atExit(timer.cancel)
    }
    public func exec(default: ?T, task: () -> ?T): ?T {
        let tag = SyncCounter(1)
        let start = MonoTime.now()
        if (bucket.enqueue((start, tag), timeout) && 
            let _ <- tag.waitUntilZero(timeout: start + timeout - MonoTime.now()) && 
            tag.count <= 0 &&
            let Some(x) <- task()) {
            x
        }else {
            default
        }
    }
}

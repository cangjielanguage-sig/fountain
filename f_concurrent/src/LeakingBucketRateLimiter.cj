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
import std.sync.{Monitor, AtomicBool, CatchupStyle, Timer, AtomicInt64}
import std.time.DateTime

import f_concurrent.exception.RateLimiterException

/**
 * 漏桶限流器
 */
public class LeakingBucketRateLimiter<T> <: RateLimiter<T> {
    private let bucket: ArrayBlockingQueue<(DateTime, ArrayBlockingQueue<Unit>)>
    private let leaked = AtomicInt64(0)
    /**
     * @param timeout 任务等待时长
     * @param maxWaitings 允许等待的最大任务数
     * @param leakingPerDuration 每个漏桶周期漏下的任务数
     * @param leakingDuration 漏桶周期
     */
    public init(
        timeout!: Duration,
        maxWaitings!: Int64 = 0,
        leakingPerDuration!: Int64 = 1,
        leakingDuration!: Duration = Duration.second
    ) {
        super(timeout)
        this.bucket = ArrayBlockingQueue<(DateTime, ArrayBlockingQueue<Unit>)>(maxWaitings)
        let timer = Timer.repeat(
            Duration.Zero,
            leakingDuration,
            {
                =>
                let opt = this.bucket.head()
                while (leaked.load() < leakingPerDuration && 
                       let Some((d, q)) <- bucket.head() && 
                       DateTime.now() - d < timeout) {
                    bucket.tryDequeue()
                    leaked.fetchAdd(1)
                    q.enqueue(())
                }
            },
            style: Skip
        )
        Process.current.atExit {
            while (bucket.size > 0) {}
            timer.cancel()
        }
    }
    public func exec(default: ?T, task: () -> T): T {
        let tag = ArrayBlockingQueue<Unit>(1)
        let start = DateTime.now()
        if (bucket.enqueue((start, tag), timeout) && let remainder <- (timeout - (DateTime.now() - start)) && 
            remainder > Duration.Zero && let _ <- tag.dequeue(remainder)) {
            try{
                return task()
            }finally{
                leaked.fetchSub(1)
            }
        }else if (let Some(v) <- default) {
            v
        } else {
            throw RateLimiterException('timeout for ${timeout} since ${start}')
        }
    }
}

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

import std.time.DateTime
import std.sync.{AtomicInt64, Monitor}
import f_concurrent.exception.RateLimiterException

/**
 * 任意时刻限流器
 */
public class AnyMomentRateLimiter<T> <: RateLimiter<T> {
    private let tokens = AtomicInt64(0)
    private let monitor = Monitor()
    /**
     * @param maxTokens 任意时刻允许最多这么多任务并发执行
     * @param timeout 任务等待时长
     */
    public init(maxTokens!: Int64, timeout!: Duration) {
        super(timeout)
        tokens.fetchAdd(maxTokens)
    }

    public func exec(default: ?T, task: () -> T): ?T {
        func call(callback: () -> ?T): ?T {
            let current = tokens.fetchSub(1)
            if (current > 0) {
                try {
                    task()
                } finally {
                    tokens.fetchAdd(1)
                    synchronized(monitor) {
                        monitor.notifyAll()
                    }
                }
            } else {
                tokens.fetchAdd(1)
                if (let Some(_) <- default) {
                    default
                } else {
                    callback()
                }
            }
        }
        let start = DateTime.now()
        do {
            let result = call {
                synchronized(monitor) {
                    monitor.wait(timeout: timeout)
                    None
                }
            }
            if (let Some(v) <- result) {
                return v
            }
        } while (DateTime.now() - start < timeout)
        if (let Some(v) <- default) {
            return v
        } else {
            return None<T>
        }
    }
}

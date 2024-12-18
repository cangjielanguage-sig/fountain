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

import std.sync.AtomicInt64
import std.time.MonoTime
import f_concurrent.exception.RateLimiterException

/**
 * 任意时刻限流器
 */
public class AnyMomentRateLimiter<T> <: RateLimiter<T> {
    private let tokens = AtomicInt64(0)
    /**
     * @param maxTokens 任意时刻允许最多这么多任务并发执行
     * @param timeout 任务等待时长
     */
    public init(maxTokens!: Int64, timeout!: Duration) {
        super(timeout)
        tokens.fetchAdd(maxTokens)
    }

    public func exec(default: ?T, task: () -> ?T): ?T {
        let start = MonoTime.now()
        do {
            let current = tokens.fetchSub(1)
            let result = if (current > 0) {
                try{
                    if(let Some(x) <- task()){
                        x
                    }else{
                        default
                    }
                }finally{
                    tokens.fetchAdd(1)
                }
            } else {
                tokens.fetchAdd(1)
                default
            }
            return if (let Some(v) <- result) {
                v
            }else{
                default
            }
        } while (MonoTime.now() - start < timeout)
        default
    }
}

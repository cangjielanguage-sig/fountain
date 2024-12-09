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
import std.sync.Timer
import std.process.Process

import f_concurrent.exception.RateLimiterException

/**
 * 令牌桶限流器
 */
public class TokenBucketRateLimiter<T> <: RateLimiter<T> {
    private let tokens: BlockingQueue<Unit>
    public init(
        tokens!: Int64,
        timeout!: Duration,
        tokenDuration!: Duration = Duration.second){
        super(timeout)
        this.tokens = BlockingQueue<Unit>(tokens)
        let timer = Timer.repeat(Duration.Zero, tokenDuration, {=>
            while(this.tokens.size < tokens){
                this.tokens.enqueue(())
            }
        }, style: Skip)
        Process.current.atExit(timer.cancel)
    }
    public func exec(default: ?T, task: () -> ?T): ?T{
        if (let Some(_) <- tokens.dequeue(timeout) && let Some(x) <- task()) {
            x
        } else {
            default
        }
    }
}

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

/**
 * 令牌桶限流器
 */
public class TokenBucketRateLimiter<T> <: RateLimiter<T> {
    private let tokens: BlockingQueue<Unit>
    public init(tokens!: Int64, timeout!: Duration, populationPeriod!: Duration){
        super(timeout)
        if(tokens <= 0 || timeout <= Duration.Zero || populationPeriod <= Duration.Zero){
            throw RateLimiterException('all parameters must be larger than zero')
        }
        this.tokens = BlockingQueue<Unit>(tokens)
        let timer = Timer.after(Duration.Zero){
            var end: MonoTime
            var next: Duration
            do{
                end = MonoTime.now() + populationPeriod
                var i = 0
                while(i < tokens && this.tokens.size < tokens){
                    this.tokens.enqueue(())
                    i++
                }
                next = end - MonoTime.now()
            }while(next <= Duration.Zero)
            next
        }
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

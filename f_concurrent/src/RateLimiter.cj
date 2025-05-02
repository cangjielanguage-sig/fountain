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

sealed abstract class RateLimiter<T> {
    public RateLimiter(protected let timeout: Duration){
        if(timeout <= Duration.Zero){
            throw RateLimiterException('timeout must be greater than zero, but current is ${timeout}')
        }
    }
    public func exec(task: () -> ?T): ?T {
        exec(None<T>, task)
    }
    public func exec(default: ?T, task: () -> ?T): ?T
}
public class UnlimitedRateLimiter<T> <: RateLimiter<T> {
    // public static let INSTANCE = UnlimitedRateLimiter<T>()
    public init(){
        super(Duration.Max)
    }
    public func exec(default: ?T, task: () -> ?T): ?T {
        task()
    }
}
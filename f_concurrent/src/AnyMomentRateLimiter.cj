/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_concurrent

/**
 * 任意时刻限流器
 */
public class AnyMomentRateLimiter<T> <: RateLimiter<T> {
    private let queue: ArrayBlockingQueue<Unit>
    /**
     * @param maxTokens 任意时刻允许最多这么多任务并发执行
     * @param timeout 任务等待时长
     */
    public init(maxTokens!: Int64, timeout!: Duration) {
        super(timeout)
        queue = ArrayBlockingQueue<Unit>(maxTokens)
    }

    public func exec(default: ?T, task: () -> ?T): ?T {
        if (queue.add((), timeout)) {
            let result = try {
                task()
            } finally {
                queue.tryRemove()
            }
            if (let Some(x) <- result) {
                x
            } else {
                default
            }
        } else {
            default
        }
    }
}

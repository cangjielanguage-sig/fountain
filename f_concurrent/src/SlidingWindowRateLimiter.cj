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
 * 滑动窗口限流器
 */
public class SlidingWindowRateLimiter<T> <: RateLimiter<T> {
    private let queue: ArrayBlockingQueue<Mono>
    private let prev = AtomicOptionReference<Mono>()
    private let unfinishedTasks = AtomicInt64(1)
    /**
     * @param timeout 时间窗口
     * @param limit 时间窗口内最大任务数
     */
    public init(window!: Duration, timeout!: Duration, limit!: Int64) {
        super(timeout)
        if (window <= Duration.Zero || limit <= 0) {
            throw RateLimiterException('all parameters must be larger than zero')
        }
        queue = ArrayBlockingQueue<Mono>(limit)
        let timer = Timer.after(Duration.Zero) {
            if (let Some(out) <- this.prev.load() && !out.finished) {
                println(
                    'SlidingWindowRateLimiter: ${unfinishedTasks.fetchAdd(1)} tasks are timeout in SlidingWindowRateLimiter for ${TypeInfos.get<T>()}.')
            }
            let mono = queue.remove()
            prev.store(mono)
            mono.time + window - MonoTime.now()
        }
        atExit(timer.cancel)
    }
    public func exec(default: ?T, task: () -> ?T): ?T {
        let mono = Mono()
        func exec() {
            try {
                task()
            } finally {
                mono.finished = true
            }
        }
        if (queue.add(mono, timeout)) {
            mono.time = MonoTime.now()
            if (let Some(x) <- exec()) {
                x
            } else {
                default
            }
        } else {
            default
        }
    }
}

private class Mono {
    private var _time = AtomicOptionReference<Box<MonoTime>>()
    private let _finished = AtomicBool(false)

    mut prop time: MonoTime {
        get() {
            while (_time.load().isNone()) {}
            _time.load().getOrThrow().value
        }
        set(value) {
            _time.store(Box<MonoTime>(value))
        }
    }
    mut prop finished: Bool {
        get() {
            _finished.load()
        }
        set(value) {
            _finished.store(value)
        }
    }
}

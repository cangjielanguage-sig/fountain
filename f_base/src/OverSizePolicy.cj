/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

import std.sync.Mutex

public interface OverSizePolicy<T> {
    /**
       o 是待添加的新值，
       fn是执行策略以后要执行的函数，比如执行策略以后又可以添加新值了就可以在fn内包含添加新值的逻辑
     */
    func reject(o: T, fn: () -> Unit): Unit
}

public class AbortOverSizePolicy<T> <: OverSizePolicy<T> {
    public AbortOverSizePolicy(private let max: Int64) {}
    public func reject(o: T, fn: () -> Unit): Unit {
        throw OverSizeException("max size is ${max}")
    }
}
public class DiscardOverSizePolicy<T> <: OverSizePolicy<T> {
    public func reject(o: T, fn: () -> Unit): Unit {}
}
public class RemoveSomeOnePolicy<T> <: OverSizePolicy<T> {
    public RemoveSomeOnePolicy(private let remove: (T) -> Unit) {}
    public func reject(o: T, fn: () -> Unit): Unit {
        remove(o)
        fn()
    }
}
public class CallerRunsOverSizePolicy<T> <: OverSizePolicy<T> {
    public func reject(o: T, fn: () -> Unit): Unit {
        fn()
    }
}
public class BlockingOverSizePolicy<T> <: OverSizePolicy<T> {
    private let monitor = Mutex()
    private let condition = synchronized(monitor){
        monitor.condition()
    }
    public BlockingOverSizePolicy(
        private let recovered: (T) -> Bool,
        private let timeout!: Duration = Duration.Max,
        private let policy!: OverSizePolicy<T> = DiscardOverSizePolicy<T>()
    ) {}
    public func reject(o: T, fn: () -> Unit): Unit {
        synchronized(monitor) {
            condition.wait(timeout: timeout)
        }
        if (recovered(o)) {
            policy.reject(o, fn)
        }
    }
    public func notifyAll() {
        synchronized(monitor) {
            condition.notifyAll()
        }
    }
    public func notify() {
        synchronized(monitor) {
            condition.notify()
        }
    }
}

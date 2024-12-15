/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_ticktock

import std.reflect.TypeInfo
import std.sync.AtomicInt64

public abstract class TicktockTask <: TicktockTaskDef & Hashable & Equatable<TicktockTaskDef> & Equatable<String> {
    private var stamped = AtomicInt64(0)

    /**
     * 不需要覆盖本方法，任务逻辑都在void execute()方法实现，
     * 控制逻辑都在boolean concurrentable() boolean executing(boolean) 和 boolean once()
     */
    public func run(): Unit {
        let currentStamp = stamped.fetchAdd(1) + 1
        let notExecuting = !executing(currentStamp)
        if (notExecuting || (concurrentable && !this.once)) {
            try {
                execute()
            } finally {
                reset(currentStamp)
            }
        }
    }
    public func hashCode(): Int64 {
        return name.hashCode()
    }
    public operator func ==(task: TicktockTaskDef): Bool {
        return this.name == task.name
    }
    public operator func !=(task: TicktockTaskDef): Bool {
        return this.name != task.name
    }
    public operator func ==(name: String): Bool {
        return this.name == name
    }
    public operator func !=(name: String): Bool {
        return this.name != name
    }

    public open prop once: Bool {
        get() {
            false
        }
    }

    public open prop concurrentable: Bool {
        get() {
            false
        }
    }
    public open prop name: String {
        get(){
            TypeInfo.of(this).qualifiedName
        }
    }

    /**
     * 当前任务是否正在执行
     *
     * @return
     */
    public open func executing(stamp: Int64): Bool {
        return DefaultTicktockTaskExecuting.executing(name, stamp)
    }

    /**
     * 重置执行状态
     */
    public open func reset(stamp: Int64): Unit {
        DefaultTicktockTaskExecuting.reset(name, stamp)
    }
}
public abstract class CronTicktockTask <: TicktockTask & CronTicktockTaskDef {}

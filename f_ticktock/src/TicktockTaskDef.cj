/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_ticktock

public interface TicktockTaskDef <: ToString {
    /**
     * 是否只执行一次的任务，需要只执行一次的重写这个方法
     *
     * @return
     */
    prop once: Bool {
        get() {
            return false
        }
    }

    /**
     * 是否可以并发执行任务
     *
     * @return
     */
    prop concurrentable: Bool {
        get() {
            return false
        }
    }

    /**
     * 当前任务是否正在执行
     *
     * @return
     */
    func executing(stamp: Int64): Bool {
        return DefaultTicktockTaskExecuting.executing(name, stamp)
    }

    /**
     * 重置执行状态
     */
    func reset(stamp: Int64): Unit {
        DefaultTicktockTaskExecuting.reset(name, stamp)
    }

    /**
     * 必须确保在整个时间轮内所有任务拥有惟一的name，否则后加入的任务会覆盖前面加入的同名任务
     *
     * @return
     */
    prop name: String

    /**
     * 定时任务逻辑
     */
    func execute(): Unit

    func toString(): String {
        return this.name
    }
}

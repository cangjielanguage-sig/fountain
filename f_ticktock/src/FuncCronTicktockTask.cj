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

public class FuncCronTicktockTask <: CronTicktockTask {
    public FuncCronTicktockTask(
        private let taskName!: String,
        private let taskCron!: String,
        private let execOnce!: Bool = false,
        private let concurrenctly!: Bool = false,
        private let executor!: () -> Unit,
        private let isExecuting!: (Int64) -> Bool = {stamp => DefaultTicktockTaskExecuting.executing(taskName, stamp)},
        private let toReset!: (Int64) -> Unit = {stamp => DefaultTicktockTaskExecuting.reset(taskName, stamp)}
    ) {}
    public prop name: String {
        get() {
            taskName
        }
    }
    public prop cron: String {
        get() {
            taskCron
        }
    }
    public func execute(): Unit {
        executor()
    }
    public prop once: Bool {
        get() {
            execOnce
        }
    }
    public prop concurrentable: Bool {
        get() {
            concurrenctly
        }
    }
    public func executing(stamp: Int64): Bool {
        return isExecuting(stamp)
    }

    public func reset(stamp: Int64): Unit {
        toReset(stamp)
    }
}

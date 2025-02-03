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

import std.time.Month
import std.time.DateTime
import f_time.ExtendDateTime

public class DelayedCronTicktockTask <: FuncInvocationTask {
    private var executingTime = DateTime.now()
    private var delayedPeriodic_: DelayedPeriodic
    private var immediate_: Bool = false
    private var delay_: Duration

    public init(name: String, delayedPeriodic: DelayedPeriodic, delay: Duration, immediate: Bool, function: () -> Unit) {
        super(name, function)
        this.executingTime += delay
        this.delayedPeriodic_ = delayedPeriodic
        this.delay_ = delay
        this.immediate_ = immediate
        setOnce(true)
    }
    public init(task: DelayedCronTicktockTaskDef) {
        this(task.name, task.delayedPeriodic, task.delay, task.immediate, task.execute)
    }

    prop delayedPeriodic: DelayedPeriodic {
        get() {
            delayedPeriodic_
        }
    }

    public prop immediate: Bool {
        get() {
            return immediate_
        }
    }

    public prop delay: Duration {
        get() {
            delay_
        }
    }

    public prop cron: String {
        get() {
            let t = executingTime
            "${t.second} ${t.minute} ${t.hour} ${t.dayOfMonth} ${t.month.value()} ${t.dayOfWeek.value()} ${t.year}"
        }
    }
    public func wrapExecutor(remover: (String) -> Unit, repeater: (DelayedCronTicktockTask) -> Unit) {
        let fn = function
        if (once) {
            function = {
                 =>
                remover(name)
                fn()
            }
        } else {
            function = match (delayedPeriodic) {
                case FixedRate => {
                     =>
                    remover(name)
                    repeater(this)
                    fn()
                }
                case FixedDelay => {
                     =>
                    remover(name)
                    fn()
                    repeater(this)
                }
            }
        }
    }
}

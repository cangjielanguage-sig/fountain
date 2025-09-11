/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package f_ticktock

import std.time.Month
import std.time.DateTime

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
            "${t.second} ${t.minute} ${t.hour} ${t.dayOfMonth} ${t.month.toInteger()} ${t.dayOfWeek.toInteger()} ${t.year}"
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

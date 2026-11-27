/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_ticktock

import std.collection.ArrayList
import std.reflect.*
import fountain::f_data.*

@Annotation[target: [MemberFunction]]
public class CronTask {
    public const CronTask(
        public let cron!: String,
        public let once!: Bool = false,
        public let concurrentable!: Bool = false
    ){}
}
@Annotation[target: [MemberFunction]]
public class DelayedTask {
    public const DelayedTask(
        public let delayedPeriodic!: DelayedPeriodic = DelayedPeriodic.FixedDelay,
        public let immediate!: Bool = false,
        public let delay!: String
    ){}
}
public class CronTicktockTaskImpl <: CronTicktockTask {
    /**
     * @param taskName 时间轮内的唯一名字（`@TicktockTasks` 以"类名#方法名"生成）。
     *        不能用默认的类全限定名：同一类的多个方法会得到同一个名字，后登记的会覆盖前面的。
     */
    public CronTicktockTaskImpl(
        private let taskName: String,
        private let task: CronTask,
        private let callee: () -> Unit
    ){}
    public prop name: String {
        get() {
            taskName
        }
    }
    public prop cron: String {
        get() {
            return task.cron
        }
    }
    public prop once: Bool {
        get() {
            return task.once
        }
    }
    public prop concurrentable: Bool {
        get() {
            return task.concurrentable
        }
    }

    public func execute(): Unit {
        callee()
    }

    public static func extract<T>(): ArrayList<(CronTask, String)> {
        let list = ArrayList<(CronTask, String)>()
        let klass = ClassTypeInfo.of<T>()
        for(f in klass.instanceFunctions where f.parameters.isEmpty()){
            if(let Some(a) <- f.findAnnotation<CronTask>()){
                let fn = f.name
                list.add((a, fn))
            }
        }
        list
    }
}
public class DelayedTicktockTaskImpl <: DelayedTicktockTask {
    /** @param taskName 时间轮内的唯一名字，含义同 {@link CronTicktockTaskImpl}。 */
    public DelayedTicktockTaskImpl(
        private let taskName: String,
        private let task: DelayedTask,
        private let callee: () -> Unit
    ){}
    public prop name: String {
        get() {
            taskName
        }
    }
    public prop delayedPeriodic: DelayedPeriodic {
        get() {
            return task.delayedPeriodic
        }
    }
    public prop immediate: Bool {
        get() {
            return task.immediate
        }
    }
    public prop delay: Duration {
        get() {
            return Duration.parse(task.delay)
        }
    }
    public func execute(): Unit {
        callee()
    }

    public static func extract<T>(): ArrayList<(DelayedTask, String)> {
        let list = ArrayList<(DelayedTask, String)>()
        let klass = ClassTypeInfo.of<T>()
        for(f in klass.instanceFunctions where f.parameters.isEmpty()){
            if(let Some(a) <- f.findAnnotation<DelayedTask>()){
                let fn = f.name
                list.add((a, fn))
            }
        }
        list
    }
}
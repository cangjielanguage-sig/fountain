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
        public let delay!: Duration
    ){}
}
public class CronTicktockTaskImpl <: CronTicktockTask {
    public CronTicktockTaskImpl(
        private let task: CronTask,
        private let callee: () -> Unit
    ){}
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
    public DelayedTicktockTaskImpl(
        private let task: DelayedTask,
        private let callee: () -> Unit
    ){}
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
            return task.delay
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
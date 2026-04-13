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
package fountain::f_egraph.base

public class AsyncTaskExecutor <: Executor {
    private let executor: TaskExecutor
        /**
     * task: {e => ImmediateFlow(category: e.category, tag: e.tag).emmit(eventType: e.eventType, 'eventName', eventData)
     *             ...
     *       }
     * task: {e => AsyncFlow(category: e.category, tag: e.tag).emmit(eventType: e.eventType, 'eventName', eventData)
     *            ....
     *       }
     */
    public init(acceptingEvent!: Event, accepter!: Accepter, task!: (Event) -> Event){
        executor = TaskExecutor(acceptingEvent: acceptingEvent, accepter: accepter, task: task)
    }
    public prop acceptable: Event {
        get(){
            executor.acceptable
        }
    }
    public func execute(event: Event): Unit {
        spawn{
            executor.execute(event)
        }
    }
    public func accept(event: Event): Unit {
        if(event == acceptable){
            execute(event)
        }else{
            throw GraphException('current Executor accepts ${acceptable}, but receives ${event}')
        }
    }
}
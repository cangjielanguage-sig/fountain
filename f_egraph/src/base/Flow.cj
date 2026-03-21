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

public interface Flow<G> <: Emitter & Hashable & Equatable<ImmediateFlow> & Equatable<AsyncFlow> & ToString where G <: EndExecutorGetter {
    static func remove(category!: String, tag!: String): Unit
    static func removeExcept(category!: String, exceptTag!: String): Unit
    prop dependencied: ConcurrentHashSet<String>
    func registerStart(eventName: String): Unit
    func registerEnd(): Unit
    func registerError(): Unit
    func registerTask(eventName: String, task: (Event) -> Event): Unit
    func registerTask(task: Task): Unit
    func registerTask(task: BarrierTask<G>): Unit {
        task.flow = this
        let t: Task = task
        registerTask(t)
    }
    func registerMultiEventTask(): Unit {
        registerTask(EventType.Multi.toString()){e =>
            if(let e: MultiEvent <- e && let me: MultiEvent <- e && let events: Iterable<Event> <- me.data){
                for(event in events){
                    let de = (event as DataEvent) ?? throw GraphException("event must be instance of DataEvent")
                    emit(eventType: event.eventType, name: event.name, data: de.data)
                }
                DummyEvent.instance
            }else{
                throw GraphException("event must be instance of MultiEvent and with data which type is Iterable<Event>")
            }
        }
    }
    /**
     * 使用指定流程作为任务执行器的构造函数参数
     * @param flow 任务事件执行器的逻辑
     */
    func registerTaskByFlow<G, F>(eventName!: String, flow!: F): Unit where G <: EndExecutorGetter, F <: Flow<G> {
        registerTask(eventName) {e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}
        flow.dependencied.add(this.toString())
    }
    /**
     * 使用指定的同步流程作为任务执行器的构造函数参数
     * @param subCategory 子流程的唯一标识
     * @param subTag 子流程的版本
     */
    func registerTaskByImmediateFlow(eventName!: String, subCategory!: String, subTag!: String): Unit {
        registerTaskByFlow<EndExecutorGetter, ImmediateFlow>(eventName: eventName, flow: ImmediateFlow(category: subCategory, tag: subTag))
    }
    /**
     * 使用指定的异步流程作为任务执行器的构造函数参数
     * @param subCategory 子流程的唯一标识
     * @param subTag 子流程的版本
     */
    func registerTaskByAsyncFlow(eventName!: String, subCategory!: String, subTag!: String): Unit {
        registerTaskByFlow<AsyncEndExecutorGetter, AsyncFlow>(eventName: eventName, flow: AsyncFlow(category: subCategory, tag: subTag))
    }
    func start(data: Any): G
    func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
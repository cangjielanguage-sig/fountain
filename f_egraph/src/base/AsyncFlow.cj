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

public class AsyncFlow <: Flow<AsyncEndExecutorGetter> {
    private static var dispatcher = None<AsyncDispatcher>
    public static func initDispatcher(clearTimerDuration!: Duration = Duration.second, toThrowIfNoExecutor!: Bool = true): Unit {
        dispatcher = AsyncDispatcher(clearTimerDuration: clearTimerDuration, toThrowIfNoExecutor: toThrowIfNoExecutor)
    }
    private static let dependencied_ = ConcurrentHashMap<AsyncFlow, ConcurrentHashSet<String>>()
    private static func checkFlow(flow: AsyncFlow): Unit {
        if(let Some(x) <- dependencied_.get(flow)){
            if(x.size > 0){
                let dependencied = StringGenerator()
                for(d in x){
                    if(dependencied.size > 0){
                        dependencied.append(', ')
                    }
                    dependencied.append(d)
                }
                throw GraphException('${flow} to be removed is dependencied by ${dependencied}')
            }else{
                dependencied_.remove(flow)
            }
        }
    }
    public static func remove(category!: String, tag!: String): Unit {
        let flow = AsyncFlow(category: category, tag: tag)
        checkFlow(flow)
        dispatcher?.removeIf{e => e.category == category && e.tag == tag}
    }
    public static func removeExcept(category!: String, exceptTag!: String): Unit {
        let flow = AsyncFlow(category: category, tag: exceptTag)
        checkFlow(flow)
        dispatcher?.removeIf{e => e.category == category && e.tag != exceptTag}
    }
    let h: Int64
    public AsyncFlow(let category!: String, let tag!: String){
        h = HashBuilder().append(category).append(tag).build()
        registerMultiEventTask()
    }
    
    public func hashCode(): Int64 {
        h
    }
    public operator func ==(other: AsyncFlow): Bool {
        h == other.h && category == other.category && tag == other.tag
    }
    public operator func ==(other: ImmediateFlow): Bool {
        h == other.h && category == other.category && tag == other.tag
    }
    public func toString(): String {
        '${category}-${tag}'
    }
    private func getDispatcher(){
        dispatcher.getOrThrow()
    }
    public prop dependencied: ConcurrentHashSet<String>{
        get(){
            dependencied_.computeIfAbsent(this){ConcurrentHashSet<String>()}
        }
    }
    private var startName = ''
    private var hasFirstTask = false

    public func registerStart(eventName: String): Unit {
        startName = eventName
        getDispatcher().registerStart(category: category, tag: tag, eventName: eventName)
    }
    public func registerEnd(): Unit {
        getDispatcher().registerEnd(category: category, tag: tag)
    }
    public func registerError(): Unit {
        getDispatcher().registerError(category: category, tag: tag)
    }
    public func registerTask(eventName: String, task: (Event) -> Event): Unit {
        if(startName.size == 0){
            throw GraphException('There must be with StartExecutor before registering first TaskExecutor')
        }else if(!hasFirstTask && startName == eventName){
            hasFirstTask = true
        }else if(!hasFirstTask){
            throw GraphException('First TaskExecutor name must be same as StartExecutor name')
        }
        getDispatcher().registerTask(category: category, tag: tag, eventName: eventName, task: task)
    }
    public func registerTask(task: Task): Unit {
        for(e in task.acceptableEvents){
            registerTask(e, task.exec)
        }
    }
    public func start(data: Any): AsyncEndExecutorGetter {
        match(getDispatcher().start(StartEvent(category: category, tag: tag, name: startName, data: data))){
            case x: AsyncEndExecutorGetter => x
            case _ => throw GraphException()
        }
    }
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit {
        dispatcher.getOrThrow().accept(DataEvent(eventType: eventType, category: category, tag: tag, name: name, data: data))
    }
}

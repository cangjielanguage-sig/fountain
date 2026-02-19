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
package fountain::f_egraph.base

public class AsyncFlow <: Flow<AsyncEndExecutorGetter> {
    private static var dispatcher = None<AsyncDispatcher>
    public static func initDispatcher(clearTimerDuration!: Duration = Duration.second, toThrowIfNoExecutor!: Bool = true): Unit {
        dispatcher = AsyncDispatcher(clearTimerDuration: clearTimerDuration, toThrowIfNoExecutor: toThrowIfNoExecutor)
    }
    public static func remove(category!: String, tag!: String): Unit {
        dispatcher?.removeIf{e => e.category == category && e.tag == tag}
    }
    public AsyncFlow(private let category!: String, private let tag!: String){}
    
    private func getDispatcher(){
        dispatcher.getOrThrow()
    }

    private var startName = ''
    private var hasFirstTask = false

    public func registerStart(name: String): Unit {
        startName = name
        getDispatcher().registerStart(category: category, tag: tag, name: name)
    }
    public func registerEnd(): Unit {
        getDispatcher().registerEnd(category: category, tag: tag)
    }
    public func registerError(): Unit {
        getDispatcher().registerError(category: category, tag: tag)
    }
    public func registerTask(name: String, task: (Event) -> Event): Unit {
        if(startName.size == 0){
            throw GraphException('There must be with StartExecutor before registering first TaskExecutor')
        }else if(!hasFirstTask && startName == name){
            hasFirstTask = true
        }else if(!hasFirstTask){
            throw GraphException('First TaskExecutor name must be same as StartExecutor name')
        }
        getDispatcher().registerTask(category: category, tag: tag, name: name, task: task)
    }
    public func registerTask(task: Task): Unit {
        registerTask(task.name, task.exec)
    }
    public func start(data: Any): AsyncEndExecutorGetter {
        match(getDispatcher().start(StartEvent(category: category, tag: tag, name: startName, data: data))){
            case x: AsyncEndExecutorGetter => x
            case _ => throw GraphException()
        }
    }
}

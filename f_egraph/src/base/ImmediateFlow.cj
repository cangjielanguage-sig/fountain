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

public struct ImmediateFlow <: Flow<EndExecutorGetter> & Hashable & Equatable<ImmediateFlow> {
    private static let dispatchers = ConcurrentHashMap<ImmediateFlow, ImmediateDispatcher>()
    private let h: Int64
    public ImmediateFlow(private let category!: String, private let tag!: String){
        h = HashBuilder().append(category).append(tag).build()
    }
    public static func remove(category!: String, tag!: String): Unit {
        dispatchers.remove(ImmediateFlow(category: category, tag: tag))
    } 
    public func hashCode(): Int64 {
        h
    }
    public operator func ==(other: ImmediateFlow): Bool {
        h == other.h && category == other.category && tag == other.tag
    }
    private func getDispatcher() {
        dispatchers.computeIfAbsent(this){
            ImmediateDispatcher()
        }
    }
    public func registerStart(): Unit {
        getDispatcher().registerStart(category: category, tag: tag)
    }
    public func registerEnd(): Unit {
        getDispatcher().registerEnd(category: category, tag: tag)
    }
    public func registerError(): Unit {
        getDispatcher().registerError(category: category, tag: tag)
    }
    public func registerTask(name: String, task: (Event) -> Event): Unit {
        getDispatcher().registerTask(category: category, tag: tag, name: name, task: task)
    }
    public func registerTask(task: Task): Unit {
        registerTask(task.name, task.exec)
    }
    public func start(data: Any): EndExecutorGetter {
        dispatchers[this].start(StartEvent(category: category, tag: tag, data: data))
    }
}

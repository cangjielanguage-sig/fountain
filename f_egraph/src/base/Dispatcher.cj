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

public abstract class Dispatcher <: Accepter & EndExecutorGetter {
    public func registerStart(category!: String, tag!: String): Unit
    public func registerError(category!: String, tag!: String): Unit
    public func registerEnd(category!: String, tag!: String): Unit
    public func registerTask(category!: String, tag!: String, name!: String, task!: (Event) -> Event): Unit 
    protected func dispatch(): Unit
    public func accept(event: Event): Unit
    public func start(event: StartEvent): Dispatcher
    public func get(): EndExecutor
    public func tryGet(): ?EndExecutor
    public func removeIf(predicate: (Event) -> Bool): Unit
}
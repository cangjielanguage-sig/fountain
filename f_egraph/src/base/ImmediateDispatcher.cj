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

public class ImmediateDispatcher <: Dispatcher {
    private let executors = HashMap<Event, ArrayList<Executor>>()
    private let eventQueue = LinkedBlockingQueue<Event>()
    private func doRegister(name: String, executor: Executor){
        let list = executors.computeIfAbsent(executor.acceptable){
            ArrayList<Executor>()
        }
        if(list.size > 0){
            throw GraphException('${name} has already been registered')
        }else{
            list.add(executor)
        }
    }
    public func registerStart(category!: String, tag!: String): Unit {
        doRegister('StartExecutor', StartExecutor(acceptingEvent: Event(eventType: EventType.Start, category: category, tag: tag, name: EventType.Start.toString()), accepter: this))
    }
    public func registerError(category!: String, tag!: String): Unit {
        doRegister(ErrorExecutor(acceptingEvent: Event(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString())))
    }
    public func registerEnd(category!: String, tag!: String): Unit {
        doRegister('EndExecutor', EndExecutor(acceptingEvent: Event(eventType: EventType.End, category: category, tag: tag, name: EventType.End.toString())))
    }
    private func doRegister(executor: Executor): Unit {
        executors.computeIfAbsent(executor.acceptable) {
            ArrayList<Executor>() 
        }.add(executor)
    }
    public func registerTask(category!: String, tag!: String, name!: String, task!: (Event) -> Event): Unit {
        let executor = TaskExecutor(acceptingEvent: Event(eventType: EventType.Task, category: category, tag: tag, name: name), 
            accepter: this, task: task)
        doRegister(executor)
    }
    private var end = None<EndExecutor>
    protected func dispatch(): Unit {
        if(eventQueue.size == 0){
            throw GraphException('To invoke func dispatch must be after accepting an Event instance')
        }
        while(let event <- getEvent()){
            if(let Some(executors) <- getExecutors(event)){
                for(executor in executors){
                    executor.accept(event)
                    if(let end: EndExecutor <- executor){
                        return this.end = end
                    }
                }
            }else{
                throw GraphException("No executor found for event: ${event}")
            }
        }
    }
    public func accept(event: Event): Unit {
        eventQueue.add(event)
    }
    public func start(event: StartEvent): Dispatcher {
        accept(event)
        dispatch()
        this
    }
    public func get(): EndExecutor {
        end.getOrThrow()
    }
    public func tryGet(): ?EndExecutor {
        end
    }
    public func removeIf(predicate: (Event) -> Bool): Unit {
        executors.removeIf{e, _ => predicate(e)}
    }
    func getEvent(): Event{
        eventQueue.remove()
    }
    func getExecutors(event: Event): ?ArrayList<Executor> {
        executors.get(event)
    }
}
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

public class AsyncDispatcher <: Dispatcher & AsyncEndExecutorGetter {
    private static let log = LoggerFactory.getLogger<AsyncDispatcher>()
    private let mutex = Mutex()
    private let endMutex = Mutex()
    private let end = ConcurrentHashMap<Int64, WeakRef<EndExecutor>>()
    private let endCondition = synchronized(endMutex){
        endMutex.condition()
    }
    private let dispatcher = ImmediateDispatcher()
    public AsyncDispatcher(
        clearTimerDuration!: Duration = Duration.second,
        private let toThrowIfNoExecutor!: Bool = true){
        spawn{
            while(true){
                end.removeIf{_, ref => ref.value.isNone()}
                sleep(clearTimerDuration)
            }
        }
    }
    public func registerStart(category!: String, tag!: String, eventName!: String): Unit {
        synchronized(mutex){
            dispatcher.registerStart(category: category, tag: tag, eventName: eventName)
        }
    }
    public func registerEnd(category!: String, tag!: String): Unit {
        synchronized(mutex){
            dispatcher.registerEnd(category: category, tag: tag)
        }
    }
    public func registerError(category!: String, tag!: String): Unit {
        synchronized(mutex){
            dispatcher.registerError(category: category, tag: tag)
        }
    }
    public func registerTask(category!: String, tag!: String, eventName!: String, task!: (Event) -> Event): Unit {
        synchronized(mutex){
            dispatcher.registerTask(category: category, tag: tag, eventName: eventName, task: task)
        }
    }
    public func accept(event: Event): Unit {
        dispatcher.accept(event)
    }
    public func start(event: StartEvent): Dispatcher {
        accept(event)
        dispatch()
        this
    }
    public func get(): EndExecutor {
        if(let Some(x) <- tryGet()){
            return x
        }
        synchronized(endMutex){
            if(let Some(x) <- tryGet()){
                return x
            }
            endCondition.wait()
            tryGet().getOrThrow()
        }
    }
    public func tryGet(): ?EndExecutor {
        end.remove(Thread.currentThread.id)?.value ?? None<EndExecutor>
    }
    public func tryGet(timeout!: Duration): ?EndExecutor {
        let start = MonoTime.now()
        if(let Some(x) <- tryGet()){
            return x
        }
        synchronized(endMutex){
            if(let Some(x) <- tryGet()){
                return x
            }
            endCondition.wait(timeout: timeout - (MonoTime.now() - start))
            tryGet()
        }
    }
    public func removeIf(predicate: (Event) -> Bool): Unit {
        synchronized(mutex){
            dispatcher.removeIf(predicate)
        }
    }
    private func notifyEnd(tid: Int64, executor: Executor){
        if(let end: EndExecutor <- executor){
            synchronized(endMutex){
                this.end[tid] = WeakRef(end, DEFERRED)
                endCondition.notifyAll()
            }
        }
    }
    private func asyncExecute(tid: Int64, executor: Executor, event: Event){
        spawn{
            notifyEnd(tid, executor)
            executor.accept(event)
        }
    }
    private func asyncDispatch(tid: Int64, executors: ArrayList<Executor>, event: Event){
        spawn{
            for(executor in executors){
                asyncExecute(tid, executor, event)
            }
        }
    }
    private func doDispatch(tid: Int64, event: Event){
        if(let Some(executors) <- getExecutors(event)){
            asyncDispatch(tid, executors, event)
        }else if(toThrowIfNoExecutor) {
            throw GraphException("No executor found for event: ${event}")
        }else{
            log.warn("No executor found for event: ${event}")
        }
    }
    protected func dispatch(): Unit {
        let tid = Thread.currentThread.id
        spawn{
            while(let event <- getEvent()){
                if(event is DummyEvent){
                    continue
                }
                doDispatch(tid, event)
            }
        }
    }
    private func getExecutors(event: Event): ?ArrayList<Executor> {
        synchronized(mutex){
            dispatcher.getExecutors(event)
        }
    }
    private func getEvent(): Event {
        synchronized(mutex){
            dispatcher.getEvent()
        }
    }
}
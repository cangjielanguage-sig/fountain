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
    /** 测试专用：清空全局 dispatcher，便于验证「未初始化」失败路径。 */
    internal static func resetDispatcherForTest(): Unit {
        dispatcher = None<AsyncDispatcher>
    }
    private static let dependencied_ = ConcurrentHashMap<AsyncFlow, ConcurrentHashSet<String>>()
    public func canBeRemoved(): Unit {
        if(let Some(x) <- dependencied_.get(this)){
            if(x.size > 0){
                let dependencied = StringGenerator()
                for(d in x){
                    if(dependencied.size > 0){
                        dependencied.append(', ')
                    }
                    dependencied.append(d)
                }
                throw GraphException('${this} to be removed is dependencied by ${dependencied}')
            }else{
                dependencied_.remove(this)
            }
        }
    }
    public func remove(): Unit {
        doRemove(false)
    }
    public func removeExceptCurrentTag(): Unit {
        doRemove(true)
    }
    /**
     * 按 tag 清理执行器。
     *
     * `flows` 的删除必须放在 `removeIf` **之后**：谓词里重建的 `AsyncFlow` 一旦发现自己不在
     * `flows` 中，会重新登记 Multi 任务，而 `AsyncDispatcher` 的 `mutex` 不可重入——同一次
     * `removeIf` 里删集合会在下一个事件上自锁（`design.md` D9 的 `flows` 判重集合）。
     */
    private func doRemove(except: Bool){
        let removed = ArrayList<AsyncFlow>()
        dispatcher?.removeIf{e => 
            if(e.category == category && if(except){e.tag != tag}else{e.tag == tag}){
                let flow = AsyncFlow(category: category, tag: e.tag)
                flow.canBeRemoved()
                removed.add(flow)
                true
            }else{
                false
            }
        }
        for(flow in removed){
            flows.remove(flow)
        }
    }
    private static let flows = ConcurrentHashSet<AsyncFlow>()
    let h: Int64
    public AsyncFlow(let category!: String, let tag!: String){
        h = HashBuilder().append(category).append(tag).build()
        if(!flows.contains(this)){
            registerMultiEventTask()
            flows.add(this)
        }
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
    /**
     * 构造期注册 Multi 任务：直接走 dispatcher 的专用入口，绕开业务任务的注册顺序校验（`design.md` D9）。
     */
    public func registerMultiEventTask(): Unit {
        getDispatcher().registerMultiTask(category: category, tag: tag, task: multiEventTaskBody(this))
    }
    /**
     * 开始流程。本地 `startName` 为空时回退到 dispatcher 记录的开始事件名（`design.md` D11）：
     * 宿主在 `initialize()` 之后新建的实例读不到脚本里 `registerStart` 写下的名字。
     */
    public func start(data: Any): AsyncEndExecutorGetter {
        let name = if(startName.size > 0){
            startName
        }else{
            getDispatcher().startEventName(category: category, tag: tag) ?? ""
        }
        match(getDispatcher().start(StartEvent(category: category, tag: tag, name: name, data: data))){
            case x: AsyncEndExecutorGetter => x
            case _ => throw GraphException()
        }
    }
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit {
        dispatcher.getOrThrow().accept(DataEvent(eventType: eventType, category: category, tag: tag, name: name, data: data))
    }
}

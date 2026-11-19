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

public abstract class Dispatcher <: Accepter & EndExecutorGetter {
    public func registerStart(category!: String, tag!: String, eventName!: String): Unit
    public func registerError(category!: String, tag!: String): Unit
    public func registerEnd(category!: String, tag!: String): Unit
    public func registerTask(category!: String, tag!: String, eventName!: String, task!: (Event) -> Event): Unit 
    /**
     * 登记 Multi 任务：接受事件固定为 `EventType.Multi`，供流程构造期使用（`design.md` D9）。
     *
     * 与业务 `registerTask` 的区别只在 acceptable 事件类型；不参与流程层的注册顺序校验，
     * 包外不可见，公开签名不变。仓颉要求抽象成员只能是 `public`/`protected`，故实际由
     * `protected doRegisterMulti` 承担抽象，本函数只做包内转发。
     */
    internal func registerMultiTask(category!: String, tag!: String, task!: (Event) -> Event): Unit {
        doRegisterMulti(category: category, tag: tag, task: task)
    }
    protected func doRegisterMulti(category!: String, tag!: String, task!: (Event) -> Event): Unit
    /**
     * 查询已登记的开始事件名（`design.md` D11）。
     *
     * 流程的 `startName` 是实例字段，宿主在初始化后新建的实例读不到脚本里登记的名字；
     * 该查询让 `start` 在本地为空时回退到共享侧。未登记时返回 `None`。
     * 与 `registerMultiTask` 同理，抽象由 `protected doStartEventName` 承担。
     */
    internal func startEventName(category!: String, tag!: String): ?String {
        doStartEventName(category: category, tag: tag)
    }
    protected func doStartEventName(category!: String, tag!: String): ?String

    protected func dispatch(): Unit
    public func accept(event: Event): Unit
    public func start(event: StartEvent): Dispatcher
    public func get(): EndExecutor
    public func tryGet(): ?EndExecutor
    public func removeIf(predicate: (Event) -> Bool): Unit
}
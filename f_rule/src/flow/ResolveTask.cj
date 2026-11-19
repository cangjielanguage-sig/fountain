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
package fountain::f_rule.flow

import std.collection.ArrayList
import fountain::f_egraph.base.{Event, EventType, MultiEvent, Task, TaskEvent}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 一对多扇出（`doc/06-flow-orchestration.md` §3，P-03/P-04/P-12）。
 *
 * `f_egraph` 一个事件只能挂一个执行器，`MultiEvent` 是唯一的扇出通道：
 * 本任务把 `plan` 返回的子事件逐个包成 `RuleEnvelope` 的 `TaskEvent`，再交给
 * `ImmediateFlow` 构造时自动注册的 Multi 执行器分发。
 *
 * 子事件的 `session` 取父事件信封，避免 `f_egraph.emit` 新建随机 UUID 后串会话。
 */
public class ResolveTask <: Task {
    private let name_: String
    private let acceptable_: Array<String>
    private let producing_: Array<String>
    private let plan_: (Event) -> Array<(String, Any)>

    /**
     * @param name 任务名，用于日志与追踪
     * @param acceptable 接受的事件名
     * @param producing 产出的事件名（子事件），仅用于声明与校验
     * @param plan 拆解函数：输入原事件，输出若干 (子事件名, 子载荷)
     */
    public init(name!: String, acceptable!: Array<String>, producing!: Array<String>,
        plan!: (Event) -> Array<(String, Any)>) {
        this.name_ = name
        this.acceptable_ = acceptable
        this.producing_ = producing
        this.plan_ = plan
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public prop acceptableEvents: Array<String> {
        get() {
            acceptable_
        }
    }

    public prop producingEvents: Array<String> {
        get() {
            producing_
        }
    }

    public func exec(e: Event): Event {
        var parts: Array<(String, Any)>
        try {
            parts = plan_(e)
        } catch (cause: Exception) {
            throw RuleException(
                RuleErrorCode.ACTION_FAILED,
                "ResolveTask '${name_}' 拆解失败",
                cause
            )
        }
        if (parts.size == 0) {
            throw RuleException(
                RuleErrorCode.EMPTY_FANOUT,
                "ResolveTask '${name_}' 没有产出任何子事件"
            )
        }
        let envelope = RuleEnvelope.from(e)
        let events = ArrayList<Event>(parts.size)
        for ((childName, payload) in parts) {
            events.add(TaskEvent(
                category: e.category,
                tag: e.tag,
                name: childName,
                data: RuleEnvelope.wrap(e, payload),
                session: envelope.session
            ))
        }
        MultiEvent(
            category: e.category,
            tag: e.tag,
            name: EventType.Multi.toString(),
            events: events,
            session: envelope.session
        )
    }
}

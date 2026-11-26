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

import fountain::f_egraph.base.{DataEvent, Event}

/**
 * 所有 f_rule 事件载荷的统一外壳（`doc/06-flow-orchestration.md` §3.5）。
 *
 * `f_egraph` 的 `emit` 与 `multiEventTaskBody` 都不传 session，会为新事件生成随机 UUID；
 * 因此 session 必须由载荷承载，下游 Task 只读信封、不读 `Event.session`。
 */
public class RuleEnvelope <: ToString {
    /** 原始会话标识，贯穿整个流程。 */
    public let session: String
    /** 规则集标识。 */
    public let ruleSetId: String
    /** 业务载荷。 */
    public let payload: Any
    /** 透传的追踪 id，用于日志串联。 */
    public let traceId: String

    public init(session!: String, ruleSetId!: String, payload!: Any, traceId!: String = "") {
        this.session = session
        this.ruleSetId = ruleSetId
        this.payload = payload
        this.traceId = traceId
    }

    /** 从事件构造：session 优先取载荷中的信封，其次回退到 `event.session`。 */
    public static func from(event: Event): RuleEnvelope {
        if (let data: DataEvent <- event) {
            if (let outer: RuleEnvelope <- data.data) {
                return outer
            }
            return RuleEnvelope(
                session: event.session,
                ruleSetId: "",
                payload: data.data
            )
        }
        RuleEnvelope(session: event.session, ruleSetId: "", payload: event)
    }

    /** 用父事件的元信息包裹新载荷。 */
    public static func wrap(parent: Event, payload: Any): RuleEnvelope {
        let base = from(parent)
        RuleEnvelope(
            session: base.session,
            ruleSetId: base.ruleSetId,
            payload: payload,
            traceId: base.traceId
        )
    }

    /** 业务载荷。 */
    public func unwrap(): Any {
        payload
    }

    public func toString(): String {
        "RuleEnvelope(session: ${session}, ruleSetId: ${ruleSetId}, traceId: ${traceId})"
    }
}

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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.TaskEvent

/**
 * `RuleEnvelope` 的 session 透传契约（`doc/06-flow-orchestration.md` §3.5）。
 *
 * f_egraph 的 `emit`/`multiEventTaskBody` 不传 session，会为新事件生成随机 UUID，
 * 因此所有 f_rule 事件载荷都要包信封，下游只读信封。
 */
@Test
class RuleEnvelope_test {
    /** 载荷已是信封时，`from` 直接取信封，而不是事件上的随机 session。 */
    @TestCase
    public func fromPrefersPayloadEnvelope(): Unit {
        let inner = RuleEnvelope(session: "s1", ruleSetId: "pricing", payload: 42, traceId: "t1")
        let event = TaskEvent(category: "c", tag: "v1", name: "n", data: inner, session: "event-session")
        let got = RuleEnvelope.from(event)
        @Expect(got.session, "s1")
        @Expect(got.ruleSetId, "pricing")
        @Expect(got.traceId, "t1")
        @Expect(got.unwrap() as Int64, 42)
    }

    /** 载荷不是信封时回退 `event.session`，不抛错。 */
    @TestCase
    public func fromFallsBackToEventSession(): Unit {
        let event = TaskEvent(category: "c", tag: "v1", name: "n", data: "raw", session: "event-session")
        let got = RuleEnvelope.from(event)
        @Expect(got.session, "event-session")
        @Expect(got.ruleSetId, "")
        @Expect(got.traceId, "")
        @Expect(got.unwrap() as String, "raw")
    }

    /** `wrap` 继承父信封的 session/ruleSetId/traceId，只替换载荷。 */
    @TestCase
    public func wrapInheritsEnvelopeMetadata(): Unit {
        let parent = TaskEvent(category: "c", tag: "v1", name: "n",
            data: RuleEnvelope(session: "s1", ruleSetId: "pricing", payload: "old", traceId: "t1"),
            session: "event-session")
        let child = RuleEnvelope.wrap(parent, "new")
        @Expect(child.session, "s1")
        @Expect(child.ruleSetId, "pricing")
        @Expect(child.traceId, "t1")
        @Expect(child.unwrap() as String, "new")
    }

    /** 父事件没有信封时，`wrap` 至少保留事件 session。 */
    @TestCase
    public func wrapWithoutEnvelopeKeepsEventSession(): Unit {
        let parent = TaskEvent(category: "c", tag: "v1", name: "n", data: "old", session: "event-session")
        let child = RuleEnvelope.wrap(parent, "new")
        @Expect(child.session, "event-session")
        @Expect(child.unwrap() as String, "new")
    }

    /** `toString()` 含 session 与 ruleSetId，便于日志定位。 */
    @TestCase
    public func toStringShowsSession(): Unit {
        let env = RuleEnvelope(session: "s1", ruleSetId: "pricing", payload: 1)
        @Expect(env.toString().contains("s1"), true)
        @Expect(env.toString().contains("pricing"), true)
    }
}

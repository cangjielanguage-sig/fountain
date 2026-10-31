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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.{DummyEvent, EndEvent, Event, EventType, ImmediateFlow, TaskEvent}

/** 记录残留分支实际被哪一轮的 start 消费。 */
class ResidueBox {
    public let arrivals = ArrayList<String>()
}

/**
 * 残留事件回归（P-05b，`design.md` D8 最后一条）。
 *
 * `ImmediateDispatcher.dispatch()` 遇到 `EndExecutor` 立即返回，队列剩余事件既不会
 * 在本轮执行、也不会被清空，而会在下一次 `start()` 被重放。本用例故意构造缺
 * `JoinTask` 的流程并连续 `start()` 两次，锁定"第二次 start 消费第一次残留分支"
 * 这一上游行为，防止未来误判为 `RuleSetFlow` 的 bug。
 *
 * 正因如此，构建期拦截是必须的——不能指望运行期自行收敛。
 */
@Test
class FlowSessionRegression_test {
    /** 第一次 start 的 b 分支会留到第二次 start 才被处理。 */
    @TestCase
    public func secondStartConsumesResidualBranch(): Unit {
        let category = "flow-residue-regression"
        let flow = ImmediateFlow(category: category, tag: "v1")
        let box = ResidueBox()
        flow.registerStart("go")
        flow.registerTask(ResolveTask(
            name: "split",
            acceptable: ["go"],
            producing: ["a", "b"],
            plan: { e =>
                let payload = RuleEnvelope.from(e).unwrap()
                [("a", payload), ("b", payload)]
            }
        ))
        flow.registerTask("a") { e =>
            EndEvent(category: category, tag: "v1", data: RuleEnvelope.from(e).unwrap())
        }
        flow.registerTask("b") { e =>
            let session = RuleEnvelope.from(e).session
            TaskEvent(category: category, tag: "v1", name: "c",
                data: RuleEnvelope.wrap(e, RuleEnvelope.from(e).unwrap()), session: session)
        }
        flow.registerTask("c") { e =>
            box.arrivals.add((RuleEnvelope.from(e).unwrap() as String).getOrThrow())
            DummyEvent.instance
        }
        flow.registerEnd()

        let first = flow.start("first-round").get().get()
        @Expect(first.eventType, EventType.End)
        @Expect(box.arrivals.size, 0)

        let second = flow.start("second-round").get().get()
        @Expect(second.eventType, EventType.End)
        // 第二次 start 先消费了第一次的残留 b（载荷仍是 first-round）
        @Expect(box.arrivals.size, 1)
        @Expect(box.arrivals[0], "first-round")
    }
}

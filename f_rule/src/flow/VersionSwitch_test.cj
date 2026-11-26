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
import fountain::f_egraph.base.{EndEvent, EventType, ImmediateFlow}
import fountain::f_egraph.exception.GraphException

/**
 * 版本切换（`doc/06-flow-orchestration.md` §2.2，P-10/P-11）。
 *
 * 先注册新 tag，再 `removeExceptCurrentTag()` 删除旧 tag；旧 tag 被其他流程
 * `dependencied` 引用时，删除抛 `GraphException`。
 */
@Test
class VersionSwitch_test {
    private func buildFlow(category: String, tag: String): ImmediateFlow {
        let flow = ImmediateFlow(category: category, tag: tag)
        flow.registerStart("go")
        flow.registerTask("go") { e =>
            EndEvent(category: category, tag: tag, data: "${category}-${tag}")
        }
        flow.registerEnd()
        flow
    }

    /** 新 tag 注册后移除旧 tag，新 tag 可启动、旧 tag 不可再启动（P-10）。 */
    @TestCase
    public func newTagReplacesOldTag(): Unit {
        let category = "version-switch-plain"
        let v1 = buildFlow(category, "v1")
        let v2 = buildFlow(category, "v2")
        v2.removeExceptCurrentTag()

        let end = v2.start("go").get().get()
        @Expect(end.eventType, EventType.End)

        var oldFailed = false
        try {
            let _ = v1.start("go")
        } catch (e: Exception) {
            oldFailed = true
        }
        @Expect(oldFailed, true)
    }

    /** 旧 tag 仍被父流程依赖时，移除抛 `GraphException`（P-11）。 */
    @TestCase
    public func removingDependentOldTagFails(): Unit {
        let category = "version-switch-dependent"
        let parent = ImmediateFlow(category: "${category}-parent", tag: "v1")
        parent.registerStart("go")
        let _ = buildFlow(category, "v1")
        let v2 = buildFlow(category, "v2")
        parent.registerTaskByImmediateFlow(eventName: "go", subCategory: category, subTag: "v1")

        var message = ""
        try {
            v2.removeExceptCurrentTag()
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("dependencied by"), true)
        // 清理依赖，避免影响后续用例
        ImmediateFlow(category: category, tag: "v1").dependencied.clear()
        parent.remove()
    }
}

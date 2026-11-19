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

import std.unittest.*
import std.unittest.testmacro.*

/** `EventType` 的六个值与其 `ToString`/`Hashable`/`Equatable` 实现。 */
@Test
class EventType_test {
    private static let all = [
        EventType.Start, EventType.Task, EventType.End,
        EventType.Error, EventType.Multi, EventType.Dummy
    ]

    /** 六个值的 `toString` 与脚本侧使用的固定名字一致（`design.md` D9 的 Multi 契约）。 */
    @TestCase
    public func toStringMatchesContract(): Unit {
        let names = Array<String>(all.size, repeat: "")
        for (i in 0 .. all.size) {
            names[i] = all[i].toString()
        }
        @Assert(names, ["Start", "Task", "End", "Error", "Multi", "Dummy"])
        @Assert(EventType.Multi.toString(), "Multi")
    }

    /** 同一值的 `hashCode` 稳定，且等于包名限定的字符串哈希。 */
    @TestCase
    public func hashCodeIsStable(): Unit {
        @Assert(EventType.Start.hashCode(), EventType.Start.hashCode())
        @Assert(EventType.Start.hashCode(),
            "fountain::f_egraph.base.EventType.Start".hashCode())
        @Expect(EventType.Start.hashCode() != EventType.Task.hashCode(), true)
    }

    /** 同值相等、跨值不等。 */
    @TestCase
    public func equalityDistinguishesValues(): Unit {
        for (i in 0 .. all.size) {
            for (j in 0 .. all.size) {
                @Expect(all[i] == all[j], i == j)
            }
        }
    }
}

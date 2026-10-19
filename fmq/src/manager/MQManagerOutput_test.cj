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
package fountain::fmq.manager

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQManagerOutputTest {
    @TestCase
    public func cjkWidthIsTwo(): Unit {
        @Assert(MQManagerOutput.width("abc") == 3)
        @Assert(MQManagerOutput.width("主题") == 4)
        @Assert(MQManagerOutput.width("a中") == 3)
    }

    @TestCase
    public func emptyTableShowsPlaceholder(): Unit {
        @Assert(MQManagerOutput.table(["topic"], []) == "（空）")
    }

    @TestCase
    public func tableColumnsAreAligned(): Unit {
        let text = MQManagerOutput.table(["topic", "分配"], [["/a", "0→0"], ["/订单", "1→2,3→0"]])
        let lines = text.split("\n")
        @Assert(lines.size == 3)
        // 每行的显示宽度一致（含分隔符）
        let first = MQManagerOutput.width(lines[0])
        @Assert(MQManagerOutput.width(lines[1]) == first)
        @Assert(MQManagerOutput.width(lines[2]) == first)
    }

    @TestCase
    public func errorUsesStablePrefix(): Unit {
        let text = MQManagerOutput.error("boom")
        @Assert(text.startsWith(MQManagerOutput.ERROR_PREFIX))
        @Assert(text.contains("boom"))
    }
}

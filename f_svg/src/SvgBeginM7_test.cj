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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgBeginM7_test {
    /** 绝对偏移按秒写 `s`，且走 `formatSvgNumber` 的规范格式。 */
    @TestCase
    public func offsetSeconds(): Unit {
        @Assert(SvgBegin.offset(0.0).toString() == "0s")
        @Assert(SvgBegin.offset(1.5).toString() == "1.5s")
    }

    /** 时钟字符串原样保存，不解析单位。 */
    @TestCase
    public func clockValue(): Unit {
        @Assert(SvgBegin.clock("500ms").toString() == "500ms")
    }

    /** `at` 默认引用开始时刻，`begin: false` 引用结束时刻。 */
    @TestCase
    public func atReference(): Unit {
        @Assert(SvgBegin.at("a").toString() == "a.begin")
        @Assert(SvgBegin.at("a", begin: false).toString() == "a.end")
    }

    /** `after` 正偏移拼 `+`，负偏移拼 `-`，零偏移省略符号。 */
    @TestCase
    public func afterOffset(): Unit {
        @Assert(SvgBegin.after("a", 1.0).toString() == "a.end+1s")
        @Assert(SvgBegin.after("a", -0.5).toString() == "a.end-0.5s")
        @Assert(SvgBegin.after("a", 0.0).toString() == "a.end")
        @Assert(SvgBegin.after("a").toString() == "a.end")
    }

    /** 重复引用、事件名、indefinite 与 literal 的原样输出。 */
    @TestCase
    public func repeatEventIndefiniteAndLiteral(): Unit {
        @Assert(SvgBegin.repeatOf("a", 2).toString() == "a.repeat(2)")
        @Assert(SvgBegin.event("click").toString() == "click")
        @Assert(SvgBegin.indefinite().toString() == "indefinite")
        @Assert(SvgBegin.literal("5s").toString() == "5s")
    }

    /** `join` 生成分号列表，且不修改任一入参。 */
    @TestCase
    public func joinKeepsOperandsImmutable(): Unit {
        let joined = SvgBegin.offset(0.0)
            .join(SvgBegin.after("a", 1.0))
            .join(SvgBegin.event("click"))
        @Assert(joined.toString() == "0s; a.end+1s; click")

        let base = SvgBegin.offset(0.0)
        let left = base.join(SvgBegin.after("a", 1.0))
        let right = base.join(SvgBegin.event("click"))
        @Assert(base.toString() == "0s")
        @Assert(left.toString() == "0s; a.end+1s")
        @Assert(right.toString() == "0s; click")
        @Assert(joined.toString() == "0s; a.end+1s; click")
    }
}

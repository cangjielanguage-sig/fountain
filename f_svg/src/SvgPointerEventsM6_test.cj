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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgPointerEventsM6_test {
    /** 11 个 SVG 取值全部可解析，且大小写不敏感。 */
    @TestCase
    public func parseAllValues(): Unit {
        let cases: Array<(String, SvgPointerEvents)> = [
            ("auto", SvgPointerEvents.Auto),
            ("none", SvgPointerEvents.None),
            ("visiblePainted", SvgPointerEvents.VisiblePainted),
            ("visibleFill", SvgPointerEvents.VisibleFill),
            ("visibleStroke", SvgPointerEvents.VisibleStroke),
            ("visible", SvgPointerEvents.Visible),
            ("painted", SvgPointerEvents.Painted),
            ("fill", SvgPointerEvents.Fill),
            ("stroke", SvgPointerEvents.Stroke),
            ("all", SvgPointerEvents.All),
            ("bounding-box", SvgPointerEvents.BoundingBox)
        ]
        for ((text, expected) in cases) {
            @Assert(SvgPointerEvents.fromName(text) == Some(expected))
            @Assert(SvgPointerEvents.fromName(text.toAsciiUpper()) == Some(expected))
            @Assert(SvgPointerEvents.fromName("  " + text + "  ") == Some(expected))
        }
    }

    /** 规范字符串往返。 */
    @TestCase
    public func toStringRoundTrip(): Unit {
        let cases: Array<(SvgPointerEvents, String)> = [
            (SvgPointerEvents.Auto, "auto"),
            (SvgPointerEvents.None, "none"),
            (SvgPointerEvents.VisiblePainted, "visiblePainted"),
            (SvgPointerEvents.VisibleFill, "visibleFill"),
            (SvgPointerEvents.VisibleStroke, "visibleStroke"),
            (SvgPointerEvents.Visible, "visible"),
            (SvgPointerEvents.Painted, "painted"),
            (SvgPointerEvents.Fill, "fill"),
            (SvgPointerEvents.Stroke, "stroke"),
            (SvgPointerEvents.All, "all"),
            (SvgPointerEvents.BoundingBox, "bounding-box")
        ]
        for ((value, text) in cases) {
            @Assert(value.toString() == text)
            @Assert(SvgPointerEvents.fromName(text) == Some(value))
        }
    }

    /** 未知值、空串与非法拼接返回 None。 */
    @TestCase
    public func unknownValues(): Unit {
        for (text in ["", "visible-painted", "bounding", "visible painted", "auto all", "0"]) {
            @Assert(SvgPointerEvents.fromName(text).isNone())
        }
    }

    /** 枚举相等语义。 */
    @TestCase
    public func equality(): Unit {
        @Assert(SvgPointerEvents.Fill == SvgPointerEvents.Fill)
        @Assert(SvgPointerEvents.Fill != SvgPointerEvents.Stroke)
        @Assert(SvgPointerEvents.None != SvgPointerEvents.Auto)
    }
}

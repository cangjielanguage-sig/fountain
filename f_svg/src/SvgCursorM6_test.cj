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
public class SvgCursorM6_test {
    /** 关键字白名单全部保留，大小写归一。 */
    @TestCase
    public func keywordWhitelist(): Unit {
        let keywords = [
            "auto", "default", "none", "context-menu", "help", "pointer", "progress", "wait",
            "cell", "crosshair", "text", "vertical-text", "alias", "copy", "move", "no-drop",
            "not-allowed", "grab", "grabbing", "e-resize", "n-resize", "ne-resize", "nw-resize",
            "s-resize", "se-resize", "sw-resize", "w-resize", "ew-resize", "ns-resize",
            "nesw-resize", "nwse-resize", "col-resize", "row-resize", "all-scroll", "zoom-in",
            "zoom-out"
        ]
        for (keyword in keywords) {
            let parsed = SvgCursor.parse(keyword)
            @Assert(parsed.toString() == keyword)
            @Assert(SvgCursor.parse(keyword.toAsciiUpper()).toString() == keyword)
            @Assert(SvgCursor.parse("  " + keyword + "  ").toString() == keyword)
        }
    }

    /** `url(...)` 不加载资源，回退 auto 并 warning。 */
    @TestCase
    public func urlFallsBackToAuto(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgCursor.parse("url(cursor.cur), pointer", warnings).toString() == "auto")
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("url"))
        let second = ArrayList<String>()
        @Assert(SvgCursor.parse("url(data:image/png;base64,AAAA)", second).toString() == "auto")
        @Assert(second.size == 1)
    }

    /** 未知关键字回退 auto 并 warning。 */
    @TestCase
    public func unknownFallsBackToAuto(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgCursor.parse("hand", warnings).toString() == "auto")
        @Assert(warnings.size == 1)
        @Assert(SvgCursor.parse("", warnings).toString() == "auto")
        @Assert(warnings.size == 2)
    }

    /** 默认值 auto 无 warning。 */
    @TestCase
    public func defaultIsSilent(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgCursor.parse("auto", warnings).toString() == "auto")
        @Assert(SvgCursor.parse("AUTO", warnings).toString() == "auto")
        @Assert(warnings.size == 0)
    }
}

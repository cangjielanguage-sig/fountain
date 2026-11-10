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
public class SvgPaintOrderM5_test {
    /** 解析与缺省补齐。 */
    @TestCase
    public func parseAndFillDefaults(): Unit {
        let order = SvgPaintOrder.parse("stroke fill")
        @Assert(order.layers.size == 3)
        @Assert(order.layers[0] == SvgPaintLayer.Stroke)
        @Assert(order.layers[1] == SvgPaintLayer.Fill)
        @Assert(order.layers[2] == SvgPaintLayer.Markers)
        @Assert(order.toString() == "stroke fill markers")
    }

    /** 单值与空值。 */
    @TestCase
    public func singleAndEmpty(): Unit {
        let strokeOnly = SvgPaintOrder.parse("stroke")
        @Assert(strokeOnly.layers.size == 3)
        @Assert(strokeOnly.layers[0] == SvgPaintLayer.Stroke)
        @Assert(strokeOnly.toString() == "stroke fill markers")
        let empty = SvgPaintOrder.parse("")
        @Assert(empty.toString() == "fill stroke markers")
        @Assert(SvgPaintOrder.parse("   ").toString() == "fill stroke markers")
    }

    /** 重复项去重并追加 warning。 */
    @TestCase
    public func duplicatesAreDeduplicated(): Unit {
        let warnings = ArrayList<String>()
        let order = SvgPaintOrder.parse("fill stroke fill", warnings)
        @Assert(order.layers.size == 3)
        @Assert(order.layers[0] == SvgPaintLayer.Fill)
        @Assert(order.layers[1] == SvgPaintLayer.Stroke)
        @Assert(order.layers[2] == SvgPaintLayer.Markers)
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("paint-order"))
    }

    /** 未知关键字被丢弃并告警；全部未知时用完整默认顺序。 */
    @TestCase
    public func unknownKeywords(): Unit {
        let warnings = ArrayList<String>()
        let partial = SvgPaintOrder.parse("fill shadows", warnings)
        @Assert(partial.toString() == "fill stroke markers")
        @Assert(warnings.size == 1)
        let warnings2 = ArrayList<String>()
        let allUnknown = SvgPaintOrder.parse("shadow glow", warnings2)
        @Assert(allUnknown.toString() == "fill stroke markers")
        @Assert(warnings2.size == 2)
    }

    /** 大小写不敏感与 toString 往返。 */
    @TestCase
    public func caseAndRoundTrip(): Unit {
        let order = SvgPaintOrder.parse("MARKERS Fill")
        @Assert(order.toString() == "markers fill stroke")
        @Assert(SvgPaintOrder.parse(order.toString()).toString() == order.toString())
    }

    /** 计算样式中的未知关键字逐项丢弃，合法项保留。 */
    @TestCase
    public func unknownKeywordIsDroppedInComputedStyle(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { paint-order: stroke shadows fill }</style><rect id=\"r\"/></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.get("paint-order") == Some("stroke fill markers"))
        var sawShadows = false
        for (warning in resolver.warnings) {
            if (warning.contains("shadows")) {
                sawShadows = true
            }
        }
        @Assert(sawShadows)
    }
}
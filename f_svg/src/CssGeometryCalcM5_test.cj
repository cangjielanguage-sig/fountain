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
public class CssGeometryCalcM5_test {
    /** `width` 上的 calc 进入计算样式，并被几何读取。 */
    @TestCase
    public func widthCalcAffectsGeometry(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { width: calc((10px + 5px) * 2); height: 10px }</style>" +
            "<rect id=\"r\"/></svg>"
        )
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let style = m5StyleOf(tree, Some(element))
        let width = SvgLength.tryParse(style.get("width") ?? "")
        @Assert(width.isSome())
        match (width) {
            case Some(value) => @Assert(value.value == 30.0)
            case None => ()
        }
        let bounds = SvgGeometry.bounds(element, style: style)
        @Assert(m5BoxNear(bounds, 0.0, 0.0, 30.0, 10.0))
        let rect = match (element) {
            case value: SvgRect => value
            case _ => throw invalidValue("不是矩形")
        }
        // 元素级属性 getter 仍只读原始属性。
        @Assert(rect.width.isNone())
    }

    /** `x: calc(10% + 5px)` 在 200 宽视口求值为 25。 */
    @TestCase
    public func percentageCalcUsesViewportWidth(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { x: calc(10% + 5px); width: 10px; height: 10px }</style>" +
            "<rect id=\"r\"/></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root, mediaWidth: 200.0)
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let style = m5StyleOf(tree, Some(element))
        @Assert(m5BoxNear(SvgGeometry.bounds(element, style: style), 25.0, 0.0, 10.0, 10.0))
    }

    /** 几何属性的百分比按对应视口轴换算，允许与 px 混合。 */
    @TestCase
    public func mixedUnitsUseViewportAxes(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { x: calc(10% + 5px); y: calc(20% + 5px); " +
            "width: calc(50% + 10px); height: calc(10% + 2px) }</style>" +
            "<rect id=\"r\"/></svg>"
        )
        let tree = SvgStyleResolver().compute(
            document.root,
            mediaWidth: 200.0,
            mediaHeight: 100.0
        )
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let style = m5StyleOf(tree, Some(element))
        @Assert(m5BoxNear(SvgGeometry.bounds(element, style: style), 25.0, 25.0, 110.0, 12.0))
    }

    /** 非法 calc 回退初始值并告警。 */
    @TestCase
    public func invalidGeometryCalcFallsBack(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { width: calc(10px * 2px) }</style><rect id=\"r\"/></svg>"
        )
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let style = m5StyleOf(tree, Some(element))
        @Assert(style.get("width") == Some("auto"))
        @Assert(SvgGeometry.bounds(element, style: style).isNone())
        var sawCalc = false
        for (warning in resolver.warnings) {
            if (warning.contains("calc") || warning.contains("width")) {
                sawCalc = true
            }
        }
        @Assert(sawCalc)
    }

    /** 渲染路径读取 CSS 宽度，而不是只读属性。 */
    @TestCase
    public func renderUsesComputedWidth(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><style>" +
            "rect { width: calc(20px + 5px); height: 10px; fill: red }</style>" +
            "<rect x=\"2\" y=\"3\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(bitmap.pixel(20, 8).alpha > 0.9)
        @Assert(bitmap.pixel(30, 8).alpha == 0.0)
    }
}

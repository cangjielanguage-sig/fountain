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
public class SvgBBoxM5_test {
    /** 嵌套 svg 的 viewBox 参与 clipped 裁剪。 */
    @TestCase
    public func nestedViewBoxClip(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<svg width=\"50\" height=\"50\" viewBox=\"0 0 100 100\">" +
            "<rect id=\"r\" x=\"60\" y=\"0\" width=\"100\" height=\"10\"/></svg></svg>"
        )
        let rect = document.elementById("r") ?? throw invalidValue("缺少矩形")
        @Assert(m5BoxNear(rect.getBBox(options: SvgBBoxOptions(clipped: true)), 60.0, 0.0, 40.0, 10.0))
    }

    /** 嵌套 svg 的 viewBox min-x / min-y 参与 clipped 裁剪。 */
    @TestCase
    public func nestedViewBoxClipUsesOrigin(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<svg width=\"50\" height=\"50\" viewBox=\"10 10 100 100\">" +
            "<rect id=\"r\" x=\"-50\" y=\"20\" width=\"100\" height=\"10\"/></svg></svg>"
        )
        let rect = document.elementById("r") ?? throw invalidValue("缺少矩形")
        @Assert(m5BoxNear(rect.getBBox(options: SvgBBoxOptions(clipped: true)), 10.0, 20.0, 40.0, 10.0))
    }

    /** display:none / visibility:hidden 不产生包围盒。 */
    @TestCase
    public func hiddenElementsHaveNoBBox(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect id=\"none\" width=\"10\" height=\"10\" display=\"none\"/>" +
            "<rect id=\"hidden\" width=\"10\" height=\"10\" visibility=\"hidden\"/>" +
            "<g id=\"mixed\"><rect width=\"10\" height=\"10\" visibility=\"hidden\"/>" +
            "<rect x=\"20\" width=\"10\" height=\"10\"/></g></svg>"
        )
        @Assert((document.elementById("none") ?? throw invalidValue("缺少元素")).getBBox().isNone())
        @Assert((document.elementById("hidden") ?? throw invalidValue("缺少元素")).getBBox().isNone())
        let group = document.elementById("mixed") ?? throw invalidValue("缺少组")
        @Assert(m5BoxNear(group.getBBox(), 20.0, 0.0, 10.0, 10.0))
    }

    /** use 循环引用有保护，不递归溢出。 */
    @TestCase
    public func useCycleIsGuarded(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><use id=\"u\" href=\"#u\"/></defs><use id=\"outer\" href=\"#u\"/></svg>"
        )
        let outer = document.elementById("outer") ?? throw invalidValue("缺少 use")
        @Assert(outer.getBBox().isNone())
    }

    /** use 指向 symbol 时返回 symbol 子内容的包围盒。 */
    @TestCase
    public func useSymbolTarget(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<symbol id=\"s\"><rect width=\"10\" height=\"10\"/></symbol>" +
            "<use id=\"u\" href=\"#s\" x=\"5\" y=\"6\"/></svg>"
        )
        let use = document.elementById("u") ?? throw invalidValue("缺少 use")
        @Assert(m5BoxNear(use.getBBox(), 5.0, 6.0, 10.0, 10.0))
    }

    /** 容器子元素变换使用 transform-origin。 */
    @TestCase
    public func containerChildTransformOrigin(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<g id=\"g\"><rect x=\"10\" y=\"20\" width=\"20\" height=\"10\" " +
            "transform=\"rotate(90)\" transform-origin=\"50% 50%\" transform-box=\"fill-box\"/>" +
            "</g></svg>"
        )
        let group = document.elementById("g") ?? throw invalidValue("缺少组")
        @Assert(m5BoxNear(group.getBBox(), 15.0, 15.0, 10.0, 20.0))
    }

    /** getBBox 的 mediaWidth 与渲染选项一致。 */
    @TestCase
    public func bboxMediaWidth(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"300\" height=\"50\"><style>" +
            "@media (max-width: 100px) { rect { display: none } }</style>" +
            "<rect id=\"r\" width=\"10\" height=\"10\"/></svg>"
        )
        let rect = document.elementById("r") ?? throw invalidValue("缺少矩形")
        @Assert(rect.getBBox(mediaWidth: 300.0).isSome())
        @Assert(rect.getBBox(mediaWidth: 80.0).isNone())
    }

    /** getCTM 使用调用方视口计算百分比 transform-origin。 */
    @TestCase
    public func ctmUsesViewportFallback(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " +
            "transform=\"rotate(90)\" transform-origin=\"50% 50%\"/></svg>"
        )
        let rect = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let matrix = rect.getCTM(mediaWidth: 200.0, mediaHeight: 100.0)
        @Assert(m5PointNear(matrix.apply(SvgPoint(100.0, 50.0)), 100.0, 50.0))
    }

    /** absoluteBounds 使用真实视口而非固定 300×150。 */
    @TestCase
    public func absoluteBoundsUsesViewport(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" x=\"90\" y=\"40\" " +
            "width=\"20\" height=\"20\" transform=\"rotate(90)\" transform-origin=\"50% 50%\"/></svg>"
        )
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let tree = SvgStyleResolver().compute(
            document.root,
            mediaWidth: 200.0,
            mediaHeight: 100.0
        )
        let style = tree.get(element) ?? throw invalidValue("缺少样式")
        let bounds = SvgGeometry.absoluteBounds(
            element,
            style: style,
            styles: tree,
            viewportWidth: 200.0,
            viewportHeight: 100.0
        )
        @Assert(m5BoxNear(bounds, 90.0, 40.0, 20.0, 20.0))
    }
}

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

internal func m5RenderWithWarnings(svg: String): (SvgBitmap, ArrayList<String>) {
    let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
    let bitmap = renderer.render(SvgParser.parse(svg))
    (bitmap, renderer.warnings)
}

internal func m5HasWarning(warnings: ArrayList<String>, keyword: String): Bool {
    for (warning in warnings) {
        if (warning.contains(keyword)) {
            return true
        }
    }
    false
}

@Test
public class SvgContextPaintRenderM5_test {
    /** 实例内的 context-fill 取被引用元素的 fill。 */
    @TestCase
    public func contextFillUsesReferencedPaint(): Unit {
        let (bitmap, warnings) = m5RenderWithWarnings(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><g id=\"g\" fill=\"red\"><rect width=\"20\" height=\"20\" fill=\"context-fill\"/></g></defs>" +
            "<use href=\"#g\"/></svg>"
        )
                @Assert(m5ColorNear(bitmap.pixel(10, 10), 255, 0, 0))
        @Assert(!m5HasWarning(warnings, "context-fill"))
    }

    /** 实例内的 context-stroke 取被引用元素的 stroke。 */
    @TestCase
    public func contextStrokeUsesReferencedPaint(): Unit {
        let (bitmap, warnings) = m5RenderWithWarnings(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><g id=\"g\" stroke=\"blue\" stroke-width=\"4\">" +
            "<rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"none\" stroke=\"context-stroke\"/>" +
            "</g></defs><use href=\"#g\"/></svg>"
        )
        @Assert(m5ColorNear(bitmap.pixel(10, 5), 0, 0, 255))
        @Assert(!m5HasWarning(warnings, "context-stroke"))
    }

    /** 嵌套 use 取最近一层的上下文帧。 */
    @TestCase
    public func nestedUseUsesNearestFrame(): Unit {
        let (bitmap, _) = m5RenderWithWarnings(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><g id=\"outer\" fill=\"red\"><use href=\"#inner\"/></g>" +
            "<g id=\"inner\" fill=\"black\"><rect width=\"20\" height=\"20\" fill=\"context-fill\"/></g>" +
            "</defs><use href=\"#outer\"/></svg>"
        )
        @Assert(m5ColorNear(bitmap.pixel(10, 10), 0, 0, 0))
    }

    /** 无 use 上下文：回退 none 并告警。 */
    @TestCase
    public func withoutUseFallsBack(): Unit {
        let (bitmap, warnings) = m5RenderWithWarnings(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect width=\"20\" height=\"20\" fill=\"context-fill\"/></svg>"
        )
        @Assert(bitmap.pixel(10, 10).alpha == 0.0)
        @Assert(m5HasWarning(warnings, "context-fill"))
    }

    /** 被引用元素自身为 context-* 时回退 none，不递归。 */
    @TestCase
    public func selfReferenceFallsBack(): Unit {
        let (bitmap, warnings) = m5RenderWithWarnings(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><rect id=\"r\" width=\"20\" height=\"20\" fill=\"context-fill\"/></defs>" +
            "<use href=\"#r\"/></svg>"
        )
        @Assert(bitmap.pixel(10, 10).alpha == 0.0)
        @Assert(m5HasWarning(warnings, "context-fill"))
    }

    /** context-* 优先于 currentColor。 */
    @TestCase
    public func contextPaintBeatsCurrentColor(): Unit {
        let (bitmap, _) = m5RenderWithWarnings(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><g id=\"g\" fill=\"red\">" +
            "<rect width=\"20\" height=\"20\" fill=\"context-fill\" color=\"green\"/></g></defs>" +
            "<use href=\"#g\"/></svg>"
        )
        @Assert(m5ColorNear(bitmap.pixel(10, 10), 255, 0, 0))
    }
}

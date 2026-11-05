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

private func m4VerticalLayout(text: SvgTextElement): SvgTextLayout {
    SvgTextRenderer().layout(text, style: textStyleOf(text))
}

@Test
public class SvgTextWritingModeM4_test {
    /** lr / lr-tb 与水平布局一致。 */
    @TestCase
    public func horizontalModes(): Unit {
        let plain = makeText("AB", size: 20.0)
        let plainLayout = m4VerticalLayout(plain)

        let lr = makeText("AB", size: 20.0)
        lr.setAttr("writing-mode", "lr")
        let lrLayout = m4VerticalLayout(lr)

        let lrTb = makeText("AB", size: 20.0)
        lrTb.setAttr("writing-mode", "lr-tb")
        let lrTbLayout = m4VerticalLayout(lrTb)

        @Assert(lrLayout.glyphs.size == 2)
        @Assert(near(lrLayout.glyphs[0].x, plainLayout.glyphs[0].x))
        @Assert(near(lrLayout.glyphs[1].x, plainLayout.glyphs[1].x))
        @Assert(near(lrTbLayout.glyphs[1].x, plainLayout.glyphs[1].x))
        @Assert(near(lrLayout.glyphs[0].angle, 0.0))
    }

    /** tb-rl：沿 y 递增、字形顺时针 90°。 */
    @TestCase
    public func verticalSingleColumn(): Unit {
        let text = makeText("AB", size: 20.0)
        text.setAttr("writing-mode", "tb-rl")
        let layout = m4VerticalLayout(text)
        @Assert(layout.glyphs.size == 2)
        @Assert(near(layout.glyphs[0].y, 0.0))
        @Assert(near(layout.glyphs[1].y, layout.glyphs[0].advance))
        @Assert(near(layout.glyphs[0].x, layout.glyphs[1].x))
        @Assert(near(layout.glyphs[0].angle, 90.0))
        @Assert(near(layout.glyphs[1].angle, 90.0))
    }

    /** 两列从右到左：x 递减，列内 y 重置。 */
    @TestCase
    public func twoColumns(): Unit {
        let text = makeText("ABCD", size: 20.0)
        text.setAttr("writing-mode", "tb-rl")
        text.x = [SvgLength(20.0), SvgLength(20.0), SvgLength(10.0), SvgLength(10.0)]
        text.y = [SvgLength(0.0), SvgLength(0.0), SvgLength(0.0), SvgLength(0.0)]
        let layout = m4VerticalLayout(text)
        @Assert(layout.glyphs.size == 4)
        @Assert(near(layout.glyphs[0].x, 20.0))
        @Assert(near(layout.glyphs[1].x, 20.0))
        @Assert(near(layout.glyphs[2].x, 10.0))
        @Assert(near(layout.glyphs[3].x, 10.0))
        @Assert(near(layout.glyphs[0].y, 0.0))
        @Assert(near(layout.glyphs[1].y, layout.glyphs[0].advance))
        @Assert(near(layout.glyphs[2].y, 0.0))
        @Assert(near(layout.glyphs[3].y, layout.glyphs[2].advance))
    }

    /** text-anchor 沿列方向生效。 */
    @TestCase
    public func verticalAnchor(): Unit {
        let text = makeText("AB", size: 20.0)
        text.setAttr("writing-mode", "tb-rl")
        text.setAttr("y", "100")
        text.setAttr("text-anchor", "middle")
        let layout = m4VerticalLayout(text)
        @Assert(near(layout.glyphs[0].y, 100.0 - layout.advance / 2.0))

        text.setAttr("text-anchor", "end")
        let end = m4VerticalLayout(text)
        @Assert(near(end.glyphs[0].y, 100.0 - end.advance))
    }

    /** 与 textPath 冲突时忽略 writing-mode 并 warning。 */
    @TestCase
    public func textPathConflict(): Unit {
        let text = SvgText()
        text.fontFamily = "Hershey"
        text.fontSize = SvgLength(20.0)
        text.setAttr("writing-mode", "tb-rl")
        let path = SvgTextPath()
        path.setAttr("path", "M0 0 L 100 0")
        path.appendText("A")
        text.appendElement(path)
        let renderer = SvgTextRenderer()
        let layout = renderer.layout(text, style: textStyleOf(text))
        @Assert(layout.glyphs.size == 1)
        @Assert(near(layout.glyphs[0].angle, 0.0))
        @Assert(near(layout.glyphs[0].y, 0.0))
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("writing-mode")) {
                found = true
            }
        }
        @Assert(found)
    }
}

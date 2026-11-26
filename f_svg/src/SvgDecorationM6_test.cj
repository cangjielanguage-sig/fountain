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
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgDecorationM6_test {
    private func runsOf(body: String): ArrayList<SvgDecorationRun> {
        let document = svgDoc(body, width: 60, height: 60)
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let text = match (element) {
            case value: SvgTextElement => value
            case _ => throw invalidValue("不是文本元素")
        }
        let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
        SvgTextRenderer().decorationRuns(
            text,
            style: style,
            root: Some(document.root),
            styles: tree
        )
    }

    private func bitmapOf(body: String): SvgBitmap {
        let document = svgDoc(body, width: 60, height: 60)
        SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
    }

    private func inkAt(bitmap: SvgBitmap, x: Int64, y: Int64): Bool {
        bitmap.pixel(x, y).alpha > 0.2
    }

    /** 样式与厚度：dashed + 3 用户单位厚，实际产生多段且厚度为 3。 */
    @TestCase
    public func styleAndThicknessRender(): Unit {
        let solid = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-thickness="3">A</text>'
        )
        let dashed = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-style="dashed" ' +
            'text-decoration-thickness="3">A</text>'
        )
        @Assert(solid.size == 1 && dashed.size == 1)
        @Assert(dashed[0].path.commands.size > solid[0].path.commands.size)
        @Assert(abs(dashed[0].thickness - 3.0) < 1e-9)
        let bitmap = bitmapOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-thickness="3">A</text>'
        )
        // 基线 30，auto 偏移 2，厚度 3：32..34 三行。
        @Assert(inkAt(bitmap, 5, 32))
        @Assert(inkAt(bitmap, 5, 33))
        @Assert(inkAt(bitmap, 5, 34))
    }

    /** 双线：总厚度为声明厚度，命令数大于单线。 */
    @TestCase
    public func doubleLine(): Unit {
        let solid = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-thickness="3">A</text>'
        )
        let double = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-style="double" ' +
            'text-decoration-thickness="3">A</text>'
        )
        @Assert(double[0].path.commands.size > solid[0].path.commands.size)
        let bounds = pathDataBounds(double[0].path) ?? throw invalidValue("缺少包围盒")
        @Assert(abs(bounds.height - 3.0) < 1e-9)
    }

    /** 独立颜色：装饰线蓝色，字形红色。 */
    @TestCase
    public func independentColor(): Unit {
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-color="blue">A</text>',
            width: 30,
            height: 40
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let line = bitmap.pixel(5, 32)
        @Assert(line.alpha > 0.2)
        @Assert(line.blue > 150 && line.red < 60)
        let glyph = bitmap.pixel(1, 25)
        @Assert(glyph.alpha > 0.2)
        @Assert(glyph.red > 150 && glyph.blue < 60)
    }

    /** 子级 `text-decoration-line: none` 覆盖父级简写。 */
    @TestCase
    public func childNoneOverridesParent(): Unit {
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="underline"><tspan text-decoration-line="none">A</tspan></text>',
            width: 30,
            height: 40
        )
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let text = match (element) {
            case value: SvgTextElement => value
            case _ => throw invalidValue("不是文本元素")
        }
        let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
        let runs = SvgTextRenderer().decorationRuns(
            text,
            style: style,
            root: Some(document.root),
            styles: tree
        )
        @Assert(runs.size == 0)
    }

    /** 简写颜色展开：`underline dotted red` 的装饰线为红色。 */
    @TestCase
    public func shorthandColor(): Unit {
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="black" ' +
            'text-decoration="underline dotted red">A</text>',
            width: 30,
            height: 40
        )
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let style = tree.get(element) ?? throw invalidValue("缺少样式")
        @Assert(style.textDecorationColor() == Some(SvgColor(255, 0, 0)))
        @Assert(style.textDecorationStyle() == SvgTextDecorationStyle.Dotted)
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        var found = false
        for (x in 0..20) {
            let color = bitmap.pixel(x, 32)
            if (color.alpha > 0.2 && color.red > 150 && color.blue < 60) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 百分比厚度按字号换算。 */
    @TestCase
    public func percentThickness(): Unit {
        let runs = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-thickness="10%">A</text>'
        )
        @Assert(abs(runs[0].thickness - 2.0) < 1e-9)
    }

    /** wavy 在垂直方向波动。 */
    @TestCase
    public func wavyLine(): Unit {
        let runs = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-style="wavy">A</text>'
        )
        let bounds = pathDataBounds(runs[0].path) ?? throw invalidValue("缺少包围盒")
        @Assert(bounds.height > runs[0].thickness)
    }

    /** wavy 按 thickness 描边，而不是开放折线填充出的双叶带。 */
    @TestCase
    public func wavyStrokeWidth(): Unit {
        // 基线 30、auto 偏移 2、厚度 4：波谷中心 y = 36，描边覆盖 34..38；
        // 填充带止于波谷 36，第 37 行只可能来自描边。
        let bitmap = bitmapOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-decoration-style="wavy" ' +
            'text-decoration-thickness="4">T</text>'
        )
        var belowWave = false
        for (x in 0..7) {
            if (inkAt(bitmap, x, 37)) {
                belowWave = true
            }
        }
        @Assert(belowWave)
    }

    /** `under` 再下移 descent；`above` 位于基线上方。 */
    @TestCase
    public func underlinePositionModes(): Unit {
        let auto = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline">A</text>'
        )
        let under = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-underline-position="under">A</text>'
        )
        let above = runsOf(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration-line="underline" text-underline-position="above">A</text>'
        )
        let autoY = (pathDataBounds(auto[0].path) ?? throw invalidValue("缺少包围盒")).y
        let underY = (pathDataBounds(under[0].path) ?? throw invalidValue("缺少包围盒")).y
        let aboveY = (pathDataBounds(above[0].path) ?? throw invalidValue("缺少包围盒")).y
        @Assert(underY > autoY)
        @Assert(aboveY < autoY)
    }
}

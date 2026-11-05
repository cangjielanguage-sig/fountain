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
public class SvgTextPathExtensionM4_test {
    /** side / method / spacing 默认值与非法值回退。 */
    @TestCase
    public func model(): Unit {
        let path = SvgTextPath()
        @Assert(path.side == SvgTextPathSide.Left)
        @Assert(path.method == SvgTextPathMethod.Align)
        @Assert(path.spacing == SvgTextPathSpacing.Auto)

        path.setAttr("side", "right")
        path.setAttr("method", "stretch")
        path.setAttr("spacing", "exact")
        @Assert(path.side == SvgTextPathSide.Right)
        @Assert(path.method == SvgTextPathMethod.Stretch)
        @Assert(path.spacing == SvgTextPathSpacing.Exact)

        let warnings = ArrayList<String>()
        @Assert(SvgTextPathSide.fromNameOrWarn(Some("top"), warnings, "side") == SvgTextPathSide.Left)
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("side"))
        let methodWarnings = ArrayList<String>()
        @Assert(SvgTextPathMethod.fromNameOrWarn(Some("scale"), methodWarnings, "method") ==
            SvgTextPathMethod.Align)
        let spacingWarnings = ArrayList<String>()
        @Assert(SvgTextPathSpacing.fromNameOrWarn(Some("tight"), spacingWarnings, "spacing") ==
            SvgTextPathSpacing.Auto)
    }

    /** side 沿法线偏移且不改变切线角。 */
    @TestCase
    public func sideOffset(): Unit {
        let path = SvgPathData.parse("M0 0 L100 0")
        let advances: Array<Float64> = [10.0, 10.0]
        let offsets: Array<Float64> = [10.0, 10.0]
        let left = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start,
            side: SvgTextPathSide.Left,
            sideOffsets: offsets
        )
        @Assert(left.size == 2)
        @Assert(near(left[0].originY, 10.0))
        @Assert(near(left[0].angle, 0.0))

        let right = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start,
            side: SvgTextPathSide.Right,
            sideOffsets: offsets
        )
        @Assert(near(right[0].originY, -10.0))
        @Assert(near(left[0].originY, -right[0].originY))
    }

    /** method="stretch" 覆盖全长。 */
    @TestCase
    public func stretch(): Unit {
        let path = SvgPathData.parse("M0 0 L100 0")
        let advances: Array<Float64> = [25.0, 25.0]
        let placed = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start,
            method: SvgTextPathMethod.Stretch
        )
        @Assert(placed.size == 2)
        @Assert(near(placed[0].x, 25.0))
        @Assert(near(placed[1].x, 75.0))

        let align = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start
        )
        @Assert(near(align[0].x, 12.5))
        @Assert(near(align[1].x, 37.5))
    }

    /** spacing="exact" 使用 dx 精确定位。 */
    @TestCase
    public func exactSpacing(): Unit {
        let path = SvgPathData.parse("M0 0 L100 0")
        let advances: Array<Float64> = [10.0, 10.0]
        let dxOffsets: Array<Float64> = [5.0, 0.0]
        let placed = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start,
            spacing: SvgTextPathSpacing.Exact,
            dxOffsets: dxOffsets
        )
        @Assert(near(placed[0].originX, 5.0))
        @Assert(near(placed[1].originX, 15.0))

        let auto = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start
        )
        @Assert(near(auto[0].originX, 0.0))
    }

    /** 缺省行为与 M3 落位一致。 */
    @TestCase
    public func defaultsMatchM3(): Unit {
        let path = SvgPathData.parse("M0 0 L10 10")
        let advances: Array<Float64> = [5.0, 5.0]
        let legacy = SvgTextPathLayout().place(advances, path, SvgLength(0.0), SvgTextAnchor.Start)
        let explicit = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start,
            side: SvgTextPathSide.Left,
            sideOffsets: [0.0, 0.0],
            method: SvgTextPathMethod.Align,
            spacing: SvgTextPathSpacing.Auto
        )
        @Assert(legacy.size == explicit.size)
        for (index in 0..legacy.size) {
            @Assert(near(legacy[index].x, explicit[index].x))
            @Assert(near(legacy[index].y, explicit[index].y))
            @Assert(near(legacy[index].angle, explicit[index].angle))
        }

        let rotated = SvgTextPathLayout().place(
            advances,
            path,
            SvgLength(0.0),
            SvgTextAnchor.Start,
            side: SvgTextPathSide.Left,
            sideOffsets: [10.0, 10.0]
        )
        @Assert(near(rotated[0].angle, 45.0))
    }
}

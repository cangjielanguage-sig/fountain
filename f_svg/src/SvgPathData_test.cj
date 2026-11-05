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

internal func expectPathError(text: String): SvgException {
    let current = text
    return expectSvgException({=> SvgPathData.parse(current)})
}

@Test
public class SvgPathData_test {
    /** 十条命令的绝对形式与参数个数。 */
    @TestCase
    public func absoluteCommands(): Unit {
        let data = SvgPathData.parse(
            "M1 2 L3 4 H5 V6 C7 8 9 10 11 12 S13 14 15 16 Q17 18 19 20 T21 22 A23 24 25 0 1 26 27 Z"
        )
        @Assert(data.commands.size == 10)
        @Assert(data.commands[0].kind == SvgPathCommandKind.MoveTo && !data.commands[0].relative)
        @Assert(data.commands[0].values == [1.0, 2.0])
        @Assert(data.commands[1].kind == SvgPathCommandKind.LineTo && data.commands[1].values == [3.0, 4.0])
        @Assert(data.commands[2].kind == SvgPathCommandKind.HorizontalLineTo && data.commands[2].values == [5.0])
        @Assert(data.commands[3].kind == SvgPathCommandKind.VerticalLineTo && data.commands[3].values == [6.0])
        @Assert(data.commands[4].kind == SvgPathCommandKind.CurveTo)
        @Assert(data.commands[4].values == [7.0, 8.0, 9.0, 10.0, 11.0, 12.0])
        @Assert(data.commands[5].kind == SvgPathCommandKind.SmoothCurveTo)
        @Assert(data.commands[5].values == [13.0, 14.0, 15.0, 16.0])
        @Assert(data.commands[6].kind == SvgPathCommandKind.QuadraticBezierTo)
        @Assert(data.commands[6].values == [17.0, 18.0, 19.0, 20.0])
        @Assert(data.commands[7].kind == SvgPathCommandKind.SmoothQuadraticBezierTo)
        @Assert(data.commands[7].values == [21.0, 22.0])
        @Assert(data.commands[8].kind == SvgPathCommandKind.ArcTo)
        @Assert(data.commands[8].values == [23.0, 24.0, 25.0, 0.0, 1.0, 26.0, 27.0])
        @Assert(data.commands[9].kind == SvgPathCommandKind.ClosePath)
        @Assert(data.commands[9].values.size == 0)
    }

    /** 十条命令的相对形式。 */
    @TestCase
    public func relativeCommands(): Unit {
        let data = SvgPathData.parse(
            "m1 2 l3 4 h5 v6 c7 8 9 10 11 12 s13 14 15 16 q17 18 19 20 t21 22 a23 24 25 0 1 26 27 z"
        )
        @Assert(data.commands.size == 10)
        for (index in 0..10) {
            @Assert(data.commands[index].relative)
        }
        @Assert(data.commands[0].kind == SvgPathCommandKind.MoveTo)
        @Assert(data.commands[9].kind == SvgPathCommandKind.ClosePath)
    }

    /** 词法边界。 */
    @TestCase
    public func lexicalBoundaries(): Unit {
        let signed = SvgPathData.parse("M1-2L3 4")
        @Assert(signed.commands[0].values == [1.0, -2.0])
        @Assert(signed.commands[1].values == [3.0, 4.0])

        let decimals = SvgPathData.parse("M0.5.5")
        @Assert(decimals.commands[0].values == [0.5, 0.5])

        let exponent = SvgPathData.parse("M1e3 1E-3")
        @Assert(exponent.commands[0].values == [1000.0, 0.001])

        let arc = SvgPathData.parse("M0 0A5 5 0 0110 10")
        @Assert(arc.commands[1].kind == SvgPathCommandKind.ArcTo)
        @Assert(arc.commands[1].values == [5.0, 5.0, 0.0, 0.0, 1.0, 10.0, 10.0])

        let mixed = SvgPathData.parse("M0,0 L1,1 L2 2")
        @Assert(mixed.commands.size == 3)
        @Assert(mixed.commands[2].values == [2.0, 2.0])

        let afterClose = SvgPathData.parse("M0 0 Z M1 1")
        @Assert(afterClose.commands.size == 3)
        @Assert(afterClose.commands[2].kind == SvgPathCommandKind.MoveTo)
    }

    /** 空路径合法。 */
    @TestCase
    public func emptyPath(): Unit {
        @Assert(SvgPathData.parse("").commands.size == 0)
        @Assert(SvgPathData.parse("   ").commands.size == 0)
        @Assert(SvgPathData.parse(" \t\n ").commands.size == 0)
    }

    /** 隐式重复：M 后按 L，其余命令按自身重复。 */
    @TestCase
    public func implicitRepetition(): Unit {
        let move = SvgPathData.parse("M1 2 3 4 5 6")
        @Assert(move.commands.size == 3)
        @Assert(move.commands[0].kind == SvgPathCommandKind.MoveTo)
        @Assert(move.commands[1].kind == SvgPathCommandKind.LineTo)
        @Assert(move.commands[2].kind == SvgPathCommandKind.LineTo)
        @Assert(move.commands[2].values == [5.0, 6.0])

        let relativeMove = SvgPathData.parse("m1 2 3 4")
        @Assert(relativeMove.commands[1].kind == SvgPathCommandKind.LineTo)
        @Assert(relativeMove.commands[1].relative)

        let line = SvgPathData.parse("L1 2 3 4")
        @Assert(line.commands.size == 2)
        @Assert(line.commands[1].kind == SvgPathCommandKind.LineTo)
        @Assert(line.commands[1].values == [3.0, 4.0])
    }

    /** 非法语法。 */
    @TestCase
    public func invalidSyntax(): Unit {
        let bad = [
            "M1", "M1 2 L3", "M0,,0", "M0 0,", "M0 0, L1 1", "M0 0 Z 1", "M0 0 Z, L1 1",
            "X1 2", "M1 2 A5 5 0 2 1 10 10", "M1 2 A5 5 0 0 1 10", "M1e 2", "M1 2 L",
            "M0 0 G1 1"
        ]
        for (text in bad) {
            let error = expectPathError(text)
            @Assert(error.kind == SvgErrorKind.InvalidValue || error.kind == SvgErrorKind.Syntax)
            @Assert(SvgPathData.tryParse(text).isNone())
        }
    }

    /** toAbsolute：当前点、子路径起点、H/V 转 L。 */
    @TestCase
    public func toAbsoluteBasics(): Unit {
        let absolute = SvgPathData.parse("m10 10h5v5z").toAbsolute()
        @Assert(absolute.toString() == "M 10 10 L 15 10 L 15 15 Z")
        @Assert(!absolute.commands[0].relative)
        @Assert(absolute.commands[0].values == [10.0, 10.0])

        let restart = SvgPathData.parse("M5 5 l1 1 z m2 2 l1 0").toAbsolute()
        @Assert(restart.commands[3].values == [7.0, 7.0])

        let line = SvgPathData.parse("M1 2 l3 4").toAbsolute()
        @Assert(line.commands[1].values == [4.0, 6.0])
    }

    /** toAbsolute：曲线、平滑曲线、二次曲线与弧。 */
    @TestCase
    public func toAbsoluteCurvesAndArcs(): Unit {
        let curve = SvgPathData.parse("m1 1 c1 1 2 2 3 3").toAbsolute()
        @Assert(curve.commands[1].values == [2.0, 2.0, 3.0, 3.0, 4.0, 4.0])

        let smooth = SvgPathData.parse("m0 0 s1 1 2 2").toAbsolute()
        @Assert(smooth.commands[1].values == [1.0, 1.0, 2.0, 2.0])
        @Assert(smooth.commands[1].kind == SvgPathCommandKind.SmoothCurveTo)

        let quadratic = SvgPathData.parse("m1 1 q1 1 2 2").toAbsolute()
        @Assert(quadratic.commands[1].values == [2.0, 2.0, 3.0, 3.0])

        let smoothQuadratic = SvgPathData.parse("m1 1 t2 2").toAbsolute()
        @Assert(smoothQuadratic.commands[1].values == [3.0, 3.0])

        let arc = SvgPathData.parse("m1 1 a2 2 30 0 1 3 4").toAbsolute()
        @Assert(arc.commands[1].kind == SvgPathCommandKind.ArcTo)
        @Assert(arc.commands[1].values == [2.0, 2.0, 30.0, 0.0, 1.0, 4.0, 5.0])
    }

    /** 序列化规范形式与往返。 */
    @TestCase
    public func serialization(): Unit {
        let data = SvgPathData.parse("M1 2L3 4Z")
        @Assert(data.toString() == "M 1 2 L 3 4 Z")
        let relative = SvgPathData.parse("m1 2l3 4z")
        @Assert(relative.toString() == "m 1 2 l 3 4 z")

        let samples = [
            "M 0 0 L 10 10 Z",
            "M 1.5 -2.5 C 1 2 3 4 5 6 S 7 8 9 10",
            "M 0 0 A 5 5 0 0 1 10 10",
            "m 1 1 h 2 v 3 q 1 1 2 2 t 3 3",
            "M 0 0 Z M 1 1 L 2 2 Z"
        ]
        for (text in samples) {
            let parsed = SvgPathData.parse(text)
            @Assert(SvgPathData.parse(parsed.toString()) == parsed)
        }
    }

    /** 弧参数结构。 */
    @TestCase
    public func arcParams(): Unit {
        let params = SvgArcParams(5.0, 6.0, 30.0, true, false, 10.0, 20.0)
        @Assert(params.rx == 5.0)
        @Assert(params.ry == 6.0)
        @Assert(params.xAxisRotation == 30.0)
        @Assert(params.largeArc)
        @Assert(!params.sweep)
        @Assert(params.x == 10.0)
        @Assert(params.y == 20.0)
    }
}

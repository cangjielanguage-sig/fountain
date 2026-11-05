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
public class SvgPreserveAspectRatio_test {
    /** 九种对齐与 none。 */
    @TestCase
    public func alignments(): Unit {
        let names = [
            ("xMinYMin", SvgAspectAlign.XMinYMin),
            ("xMidYMin", SvgAspectAlign.XMidYMin),
            ("xMaxYMin", SvgAspectAlign.XMaxYMin),
            ("xMinYMid", SvgAspectAlign.XMinYMid),
            ("xMidYMid", SvgAspectAlign.XMidYMid),
            ("xMaxYMid", SvgAspectAlign.XMaxYMid),
            ("xMinYMax", SvgAspectAlign.XMinYMax),
            ("xMidYMax", SvgAspectAlign.XMidYMax),
            ("xMaxYMax", SvgAspectAlign.XMaxYMax)
        ]
        for (entry in names) {
            let ratio = SvgPreserveAspectRatio.parse(entry[0])
            @Assert(ratio.align == entry[1])
            @Assert(!ratio.slice)
        }
        @Assert(SvgPreserveAspectRatio.parse("none").align == SvgAspectAlign.NoAlign)
        @Assert(SvgPreserveAspectRatio.Default.align == SvgAspectAlign.XMidYMid)
        @Assert(!SvgPreserveAspectRatio.Default.slice)
    }

    /** meet / slice 修饰与序列化。 */
    @TestCase
    public func meetAndSlice(): Unit {
        let meet = SvgPreserveAspectRatio.parse("xMidYMid meet")
        @Assert(meet.align == SvgAspectAlign.XMidYMid && !meet.slice)
        let slice = SvgPreserveAspectRatio.parse("xMinYMax slice")
        @Assert(slice.align == SvgAspectAlign.XMinYMax && slice.slice)
        @Assert(SvgPreserveAspectRatio.parse("none").toString() == "none")
        @Assert(SvgPreserveAspectRatio.parse("xMidYMid").toString() == "xMidYMid meet")
        @Assert(SvgPreserveAspectRatio.parse("xMinYMax slice").toString() == "xMinYMax slice")
        let samples = ["none", "xMidYMid meet", "xMaxYMin slice"]
        for (text in samples) {
            let ratio = SvgPreserveAspectRatio.parse(text)
            @Assert(SvgPreserveAspectRatio.parse(ratio.toString()) == ratio)
        }
    }

    /** meet 取较小缩放并垂直居中。 */
    @TestCase
    public func meetMatrix(): Unit {
        let viewBox = SvgViewBox(0.0, 0.0, 100.0, 50.0)
        let ratio = SvgPreserveAspectRatio.parse("xMidYMid meet")
        let matrix = ratio.toMatrix(viewBox, 200.0, 200.0)
        @Assert(matrixNear(matrix, SvgMatrix(2.0, 0.0, 0.0, 2.0, 0.0, 50.0)))
        @Assert(pointNear(matrix.apply(SvgPoint(0.0, 0.0)), SvgPoint(0.0, 50.0)))
        @Assert(pointNear(matrix.apply(SvgPoint(100.0, 50.0)), SvgPoint(200.0, 150.0)))
    }

    /** slice 取较大缩放并水平裁切。 */
    @TestCase
    public func sliceMatrix(): Unit {
        let viewBox = SvgViewBox(0.0, 0.0, 100.0, 50.0)
        let ratio = SvgPreserveAspectRatio.parse("xMidYMid slice")
        let matrix = ratio.toMatrix(viewBox, 200.0, 200.0)
        @Assert(matrixNear(matrix, SvgMatrix(4.0, 0.0, 0.0, 4.0, -100.0, 0.0)))
    }

    /** none 非等比拉伸。 */
    @TestCase
    public func noneMatrix(): Unit {
        let viewBox = SvgViewBox(0.0, 0.0, 100.0, 50.0)
        let matrix = SvgPreserveAspectRatio.parse("none").toMatrix(viewBox, 200.0, 200.0)
        @Assert(matrixNear(matrix, SvgMatrix(2.0, 0.0, 0.0, 4.0, 0.0, 0.0)))
    }

    /** 九种对齐的平移不同。 */
    @TestCase
    public func alignmentOffsets(): Unit {
        let viewBox = SvgViewBox(0.0, 0.0, 100.0, 50.0)
        @Assert(matrixNear(
            SvgPreserveAspectRatio.parse("xMinYMin meet").toMatrix(viewBox, 200.0, 200.0),
            SvgMatrix(2.0, 0.0, 0.0, 2.0, 0.0, 0.0)
        ))
        @Assert(matrixNear(
            SvgPreserveAspectRatio.parse("xMaxYMax meet").toMatrix(viewBox, 200.0, 200.0),
            SvgMatrix(2.0, 0.0, 0.0, 2.0, 0.0, 100.0)
        ))
        @Assert(matrixNear(
            SvgPreserveAspectRatio.parse("xMinYMax meet").toMatrix(viewBox, 200.0, 200.0),
            SvgMatrix(2.0, 0.0, 0.0, 2.0, 0.0, 100.0)
        ))
        // viewBox 原点不是 0 时平移包含 -minX / -minY。
        let shifted = SvgViewBox(10.0, 20.0, 100.0, 50.0)
        let matrix = SvgPreserveAspectRatio.parse("xMinYMin meet").toMatrix(shifted, 200.0, 200.0)
        @Assert(pointNear(matrix.apply(SvgPoint(10.0, 20.0)), SvgPoint(0.0, 0.0)))
    }

    /** 退化视口与非法值。 */
    @TestCase
    public func degenerateAndInvalid(): Unit {
        let viewBox = SvgViewBox(0.0, 0.0, 100.0, 50.0)
        let ratio = SvgPreserveAspectRatio.parse("xMidYMid meet")
        let zeroWidth = expectSvgException({=> ratio.toMatrix(viewBox, 0.0, 100.0)})
        @Assert(zeroWidth.kind == SvgErrorKind.InvalidValue)
        let zeroHeight = expectSvgException({=> ratio.toMatrix(viewBox, 100.0, 0.0)})
        @Assert(zeroHeight.kind == SvgErrorKind.InvalidValue)
        let badViewBox = SvgViewBox(0.0, 0.0, 0.0, 50.0)
        let degenerate = expectSvgException({=> ratio.toMatrix(badViewBox, 100.0, 100.0)})
        @Assert(degenerate.kind == SvgErrorKind.InvalidValue)

        let bad = ["", "xmidymid", "xMidYMid stretch", "xMidYMid meet slice", "middle"]
        for (text in bad) {
            let current = text
            let error = expectSvgException({=> SvgPreserveAspectRatio.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
        }
    }
}

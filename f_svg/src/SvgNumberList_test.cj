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
public class SvgPointList_test {
    /** 逗号与空白混用。 */
    @TestCase
    public func parseMixedSeparators(): Unit {
        let points = SvgPointList.parse("10,20 30,40")
        @Assert(points.points.size == 2)
        @Assert(points.points[0] == SvgPoint(10.0, 20.0))
        @Assert(points.points[1] == SvgPoint(30.0, 40.0))

        let spaced = SvgPointList.parse("10 20, 30 40 50 60")
        @Assert(spaced.points.size == 3)
        @Assert(spaced.points[2] == SvgPoint(50.0, 60.0))

        let negative = SvgPointList.parse("-1-2 3 4")
        @Assert(negative.points[0] == SvgPoint(-1.0, -2.0))
    }

    /** 空列表合法，奇数个数字非法。 */
    @TestCase
    public func oddCountRejected(): Unit {
        @Assert(SvgPointList.parse("").points.size == 0)
        @Assert(SvgPointList.parse("   ").points.size == 0)
        let error = expectSvgException({=> SvgPointList.parse("10,20 30")})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
        let single = expectSvgException({=> SvgPointList.parse("10")})
        @Assert(single.kind == SvgErrorKind.InvalidValue)
    }

    /** 序列化与往返。 */
    @TestCase
    public func serialization(): Unit {
        let points = SvgPointList.parse("10,20 30,40")
        @Assert(points.toString() == "10,20 30,40")
        @Assert(SvgPointList.parse(points.toString()) == points)
    }
}

@Test
public class SvgNumberList_test {
    /** 默认逗号或空白分隔。 */
    @TestCase
    public func parseDefaults(): Unit {
        let list = SvgNumberList.parse("1,2 3, 4")
        @Assert(list.values == [1.0, 2.0, 3.0, 4.0])
        @Assert(list.toString() == "1,2,3,4")
        @Assert(SvgNumberList.parse("").values.size == 0)
        @Assert(SvgNumberList.parse("5").values == [5.0])
    }

    /** 显式分隔符模式。 */
    @TestCase
    public func explicitSeparators(): Unit {
        let comma = SvgNumberList.parse("1, 2,3", separator: SvgListSeparator.Comma)
        @Assert(comma.values == [1.0, 2.0, 3.0])
        let commaError = expectSvgException({=> SvgNumberList.parse("1 2", separator: SvgListSeparator.Comma)})
        @Assert(commaError.kind == SvgErrorKind.InvalidValue)

        let space = SvgNumberList.parse("1 2  3", separator: SvgListSeparator.Space)
        @Assert(space.values == [1.0, 2.0, 3.0])
        let spaceError = expectSvgException({=> SvgNumberList.parse("1,2", separator: SvgListSeparator.Space)})
        @Assert(spaceError.kind == SvgErrorKind.InvalidValue)
    }

    /** 非法输入。 */
    @TestCase
    public func invalidInputs(): Unit {
        let bad = ["1,,2", "1,", "1 2 x", "1e", "--1"]
        for (text in bad) {
            let current = text
            let error = expectSvgException({=> SvgNumberList.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
        }
    }

    /** 往返。 */
    @TestCase
    public func roundTrip(): Unit {
        let list = SvgNumberList.parse("1.5 -2 3e2")
        @Assert(SvgNumberList.parse(list.toString()) == list)
    }

    /** stdDeviation 等场景：单值 / 双值 / 负值 / 非有限值。 */
    @TestCase
    public func m3DeviationShapes(): Unit {
        @Assert(SvgNumberList.parse("2").values == [2.0])
        @Assert(SvgNumberList.parse("2 3").values == [2.0, 3.0])
        @Assert(SvgNumberList.parse("2,3").values == [2.0, 3.0])
        @Assert(SvgNumberList.parse("-1").values == [-1.0])
        @Assert(SvgNumberList.parse("-1.5 -2.5").values == [-1.5, -2.5])

        let overflow = expectSvgException({=> SvgNumberList.parse("1e999")})
        @Assert(overflow.kind == SvgErrorKind.InvalidValue)
        let negativeOverflow = expectSvgException({=> SvgNumberList.parse("-1e999")})
        @Assert(negativeOverflow.kind == SvgErrorKind.InvalidValue)
    }
}

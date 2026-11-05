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
public class SvgTransform_test {
    /** 单个变换。 */
    @TestCase
    public func singleOperations(): Unit {
        let translate = SvgTransform.parse("translate(10,20)")
        @Assert(translate.operations.size == 1)
        @Assert(pointNear(translate.toMatrix().apply(SvgPoint(0.0, 0.0)), SvgPoint(10.0, 20.0)))

        let scale = SvgTransform.parse("scale(2,3)")
        @Assert(pointNear(scale.toMatrix().apply(SvgPoint(1.0, 1.0)), SvgPoint(2.0, 3.0)))

        let rotate = SvgTransform.parse("rotate(90)")
        @Assert(pointNear(rotate.toMatrix().apply(SvgPoint(1.0, 0.0)), SvgPoint(0.0, 1.0)))

        let skewX = SvgTransform.parse("skewX(45)")
        @Assert(pointNear(skewX.toMatrix().apply(SvgPoint(0.0, 1.0)), SvgPoint(1.0, 1.0)))

        let skewY = SvgTransform.parse("skewY(45)")
        @Assert(pointNear(skewY.toMatrix().apply(SvgPoint(1.0, 0.0)), SvgPoint(1.0, 1.0)))

        let matrix = SvgTransform.parse("matrix(1 0 0 1 4 5)")
        @Assert(pointNear(matrix.toMatrix().apply(SvgPoint(1.0, 1.0)), SvgPoint(5.0, 6.0)))
    }

    /** 多变换顺序：后写的先作用于坐标。 */
    @TestCase
    public func multipleOperations(): Unit {
        let transform = SvgTransform.parse("translate(10,20) scale(2)")
        @Assert(transform.operations.size == 2)
        @Assert(pointNear(transform.toMatrix().apply(SvgPoint(1.0, 1.0)), SvgPoint(12.0, 22.0)))
        let reversed = SvgTransform.parse("scale(2) translate(10,20)")
        @Assert(pointNear(reversed.toMatrix().apply(SvgPoint(1.0, 1.0)), SvgPoint(22.0, 42.0)))
    }

    /** 缺省参数：translate 的 ty、scale 的 sy、rotate 的圆心。 */
    @TestCase
    public func defaultArguments(): Unit {
        @Assert(pointNear(SvgTransform.parse("translate(10)").toMatrix().apply(SvgPoint(0.0, 0.0)), SvgPoint(10.0, 0.0)))
        @Assert(pointNear(SvgTransform.parse("scale(3)").toMatrix().apply(SvgPoint(2.0, 4.0)), SvgPoint(6.0, 12.0)))
        @Assert(pointNear(
            SvgTransform.parse("rotate(180)").toMatrix().apply(SvgPoint(1.0, 0.0)),
            SvgPoint(-1.0, 0.0)
        ))
        @Assert(pointNear(
            SvgTransform.parse("rotate(180, 1, 1)").toMatrix().apply(SvgPoint(1.0, 1.0)),
            SvgPoint(1.0, 1.0)
        ))
    }

    /** 负角度、逗号与空白混用。 */
    @TestCase
    public func anglesAndSeparators(): Unit {
        @Assert(pointNear(
            SvgTransform.parse("rotate(-90)").toMatrix().apply(SvgPoint(1.0, 0.0)),
            SvgPoint(0.0, -1.0)
        ))
        let spaced = SvgTransform.parse("  translate( 1  2 )   scale( 2 )  ")
        @Assert(spaced.operations.size == 2)
        @Assert(pointNear(spaced.toMatrix().apply(SvgPoint(1.0, 1.0)), SvgPoint(3.0, 4.0)))
        let commad = SvgTransform.parse("translate(1, 2),scale(2, 2)")
        @Assert(commad.operations.size == 2)
    }

    /** 空串与纯空白是 identity。 */
    @TestCase
    public func emptyIsIdentity(): Unit {
        @Assert(SvgTransform.parse("").operations.size == 0)
        @Assert(SvgTransform.parse("   ").operations.size == 0)
        @Assert(matrixNear(SvgTransform.parse("").toMatrix(), SvgMatrix.identity))
        @Assert(matrixNear(SvgTransform.identity.toMatrix(), SvgMatrix.identity))
    }

    /** 非法输入抛 InvalidValue。 */
    @TestCase
    public func invalidInputs(): Unit {
        let bad = [
            "translate(a)", "translate(1,2,3)", "scale()", "rotate(1,2)", "matrix(1 2 3)",
            "matrix(1 2 3 4 5 6 7)", "translate(1,,2)", "translate(1,)", "bounce(1)",
            "translate(1) garbage", "translate 1 2", "scale(1e)"
        ]
        for (text in bad) {
            let current = text
            let error = expectSvgException({=> SvgTransform.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
        }
    }

    /** 序列化规范形式与往返。 */
    @TestCase
    public func toStringRoundTrip(): Unit {
        @Assert(SvgTransform.parse("translate(10,20)").toString() == "translate(10 20)")
        @Assert(SvgTransform.parse("scale(2)").toString() == "scale(2)")
        @Assert(SvgTransform.parse("rotate(90, 5, 6)").toString() == "rotate(90 5 6)")
        @Assert(SvgTransform.parse("matrix(1 2 3 4 5 6)").toString() == "matrix(1 2 3 4 5 6)")
        let samples = [
            "translate(10 20)",
            "translate(10)",
            "scale(2)",
            "scale(2 3)",
            "rotate(45)",
            "rotate(45 1 2)",
            "skewX(15)",
            "skewY(-15)",
            "matrix(1 2 3 4 5 6)",
            "translate(10 20) scale(2) rotate(45 1 1)"
        ]
        for (text in samples) {
            let transform = SvgTransform.parse(text)
            @Assert(SvgTransform.parse(transform.toString()) == transform)
        }
    }
}

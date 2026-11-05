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
import std.math.*

internal func matrixNear(actual: SvgMatrix, expected: SvgMatrix): Bool {
    near(actual.a, expected.a) && near(actual.b, expected.b) && near(actual.c, expected.c) &&
    near(actual.d, expected.d) && near(actual.e, expected.e) && near(actual.f, expected.f)
}

internal func pointNear(actual: SvgPoint, expected: SvgPoint): Bool {
    near(actual.x, expected.x) && near(actual.y, expected.y)
}

@Test
public class SvgMatrix_test {
    /** 单位矩阵。 */
    @TestCase
    public func identity(): Unit {
        let identity = SvgMatrix.identity
        @Assert(identity.a == 1.0 && identity.b == 0.0 && identity.c == 0.0)
        @Assert(identity.d == 1.0 && identity.e == 0.0 && identity.f == 0.0)
        @Assert(pointNear(identity.apply(SvgPoint(3.0, 4.0)), SvgPoint(3.0, 4.0)))
    }

    /** 乘法与结合律。 */
    @TestCase
    public func multiplyAndAssociativity(): Unit {
        let a = SvgMatrix.translate(10.0, 20.0)
        let b = SvgMatrix.scale(2.0, 3.0)
        let c = SvgMatrix.rotate(30.0)
        @Assert(matrixNear(SvgMatrix.identity.multiply(a), a))
        @Assert(matrixNear(a.multiply(SvgMatrix.identity), a))
        let left = a.multiply(b).multiply(c)
        let right = a.multiply(b.multiply(c))
        @Assert(matrixNear(left, right))
    }

    /** 变换顺序：最后写的先作用。 */
    @TestCase
    public func compositionOrder(): Unit {
        let matrix = SvgMatrix.translate(10.0, 20.0).multiply(SvgMatrix.scale(2.0, 2.0))
        @Assert(pointNear(matrix.apply(SvgPoint(1.0, 1.0)), SvgPoint(12.0, 22.0)))
    }

    /** apply 的列向量右乘语义。 */
    @TestCase
    public func apply(): Unit {
        let matrix = SvgMatrix(2.0, 0.0, 0.0, 2.0, 5.0, 7.0)
        @Assert(pointNear(matrix.apply(SvgPoint(1.0, 2.0)), SvgPoint(7.0, 11.0)))
        @Assert(pointNear(SvgMatrix.translate(1.0, 2.0).apply(SvgPoint(3.0, 4.0)), SvgPoint(4.0, 6.0)))
        @Assert(pointNear(SvgMatrix.scale(2.0, 3.0).apply(SvgPoint(2.0, 2.0)), SvgPoint(4.0, 6.0)))
    }

    /** 行列式。 */
    @TestCase
    public func determinant(): Unit {
        @Assert(near(SvgMatrix.identity.determinant(), 1.0))
        @Assert(near(SvgMatrix.scale(2.0, 3.0).determinant(), 6.0))
        @Assert(near(SvgMatrix(1.0, 2.0, 3.0, 4.0, 5.0, 6.0).determinant(), -2.0))
    }

    /** 可逆矩阵往返；奇异矩阵返回 None。 */
    @TestCase
    public func invert(): Unit {
        let samples = [
            SvgMatrix.identity,
            SvgMatrix.translate(3.0, -4.0),
            SvgMatrix.scale(2.0, 0.5),
            SvgMatrix.rotate(37.0),
            SvgMatrix(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)
        ]
        for (matrix in samples) {
            match (matrix.invert()) {
                case Some(inverse) =>
                    @Assert(matrixNear(matrix.multiply(inverse), SvgMatrix.identity))
                    @Assert(matrixNear(inverse.multiply(matrix), SvgMatrix.identity))
                case None => @Fail("矩阵应当可逆")
            }
        }
        @Assert(SvgMatrix.scale(0.0, 1.0).invert().isNone())
        @Assert(SvgMatrix(1.0, 2.0, 2.0, 4.0, 0.0, 0.0).invert().isNone())
    }

    /** 六个工厂方法。 */
    @TestCase
    public func factories(): Unit {
        @Assert(matrixNear(SvgMatrix.translate(1.0, 2.0), SvgMatrix(1.0, 0.0, 0.0, 1.0, 1.0, 2.0)))
        @Assert(matrixNear(SvgMatrix.scale(2.0, 3.0), SvgMatrix(2.0, 0.0, 0.0, 3.0, 0.0, 0.0)))
        @Assert(pointNear(SvgMatrix.rotate(90.0).apply(SvgPoint(1.0, 0.0)), SvgPoint(0.0, 1.0)))
        @Assert(pointNear(SvgMatrix.rotate(180.0).apply(SvgPoint(1.0, 0.0)), SvgPoint(-1.0, 0.0)))
        @Assert(pointNear(SvgMatrix.rotateAround(90.0, 1.0, 1.0).apply(SvgPoint(1.0, 1.0)), SvgPoint(1.0, 1.0)))
        @Assert(pointNear(SvgMatrix.rotateAround(180.0, 0.0, 0.0).apply(SvgPoint(2.0, 3.0)), SvgPoint(-2.0, -3.0)))
        @Assert(pointNear(SvgMatrix.skewX(45.0).apply(SvgPoint(0.0, 1.0)), SvgPoint(1.0, 1.0)))
        @Assert(pointNear(SvgMatrix.skewY(45.0).apply(SvgPoint(1.0, 0.0)), SvgPoint(1.0, 1.0)))
    }

    /** 点与矩阵的 toString 稳定。 */
    @TestCase
    public func toStringStable(): Unit {
        @Assert(SvgPoint(1.5, -2.0).toString() == "1.5,-2")
        @Assert(SvgMatrix.identity.toString() == "1,0,0,1,0,0")
    }
}

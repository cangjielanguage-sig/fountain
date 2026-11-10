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

internal func boundsNear(actual: SvgBounds, expected: SvgBounds): Bool {
    near(actual.x, expected.x) && near(actual.y, expected.y) &&
    near(actual.width, expected.width) && near(actual.height, expected.height)
}

@Test
public class SvgBounds_test {
    /** empty 哨兵、union、intersect、inflate。 */
    @TestCase
    public func basicAlgebra(): Unit {
        let empty = SvgBounds.empty()
        @Assert(empty.isEmpty())
        @Assert(!SvgBounds(0.0, 0.0, 0.0, 0.0).isEmpty())
        let first = SvgBounds(0.0, 0.0, 10.0, 10.0)
        @Assert(boundsNear(first.union(empty), first))
        @Assert(boundsNear(empty.union(first), first))
        let second = SvgBounds(20.0, 20.0, 5.0, 5.0)
        @Assert(boundsNear(first.union(second), SvgBounds(0.0, 0.0, 25.0, 25.0)))
        @Assert(first.intersect(second).isEmpty())
        let overlap = SvgBounds(5.0, 5.0, 10.0, 10.0)
        @Assert(boundsNear(first.intersect(overlap), SvgBounds(5.0, 5.0, 5.0, 5.0)))
        @Assert(boundsNear(first.inflate(2.0), SvgBounds(-2.0, -2.0, 14.0, 14.0)))
        @Assert(boundsNear(first.inflate(-2.0), SvgBounds(2.0, 2.0, 6.0, 6.0)))
        let collapsed = first.inflate(-20.0)
        @Assert(!collapsed.isEmpty())
        @Assert(boundsNear(collapsed, SvgBounds(20.0, 20.0, 0.0, 0.0)))
        @Assert(SvgBounds.empty().inflate(2.0).isEmpty())
    }

    /** 零尺寸退化盒参与并集时保留。 */
    @TestCase
    public func degenerateBoundsSurviveUnion(): Unit {
        let point = SvgBounds(5.0, 6.0, 0.0, 0.0)
        let line = SvgBounds(5.0, 6.0, 10.0, 0.0)
        let union = point.union(line)
        @Assert(!union.isEmpty())
        @Assert(boundsNear(union, SvgBounds(5.0, 6.0, 10.0, 0.0)))
        @Assert(boundsNear(point.union(point), point))
    }

    /** 变换四角法：平移、非等比缩放、45° 旋转、奇异矩阵。 */
    @TestCase
    public func transforms(): Unit {
        let box = SvgBounds(0.0, 0.0, 10.0, 10.0)
        @Assert(boundsNear(box.transform(SvgMatrix.translate(3.0, -2.0)), SvgBounds(3.0, -2.0, 10.0, 10.0)))
        @Assert(boundsNear(box.transform(SvgMatrix.scale(2.0, 3.0)), SvgBounds(0.0, 0.0, 20.0, 30.0)))
        let rotated = box.transform(SvgMatrix.rotate(45.0))
        @Assert(near(rotated.x, -7.071067811865475))
        @Assert(near(rotated.y, 0.0))
        @Assert(near(rotated.width, 14.142135623730951))
        @Assert(near(rotated.height, 14.142135623730951))
        let singular = box.transform(SvgMatrix.scale(0.0, 0.0))
        @Assert(!singular.isEmpty())
        @Assert(near(singular.width, 0.0) && near(singular.height, 0.0))
        @Assert(SvgBounds.empty().transform(SvgMatrix.translate(1.0, 1.0)).isEmpty())
    }

    /** 字符串稳定。 */
    @TestCase
    public func toStringStable(): Unit {
        @Assert(SvgBounds(1.5, -2.0, 3.0, 4.0).toString() == "1.5,-2,3,4")
    }
}

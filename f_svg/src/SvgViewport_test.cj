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
public class SvgViewport_test {
    /** 无 viewBox、meet、slice、none 与九种对齐。 */
    @TestCase
    public func viewBoxMapping(): Unit {
        let plain = SvgRoot(width: SvgLength(200.0), height: SvgLength(100.0))
        @Assert(matrixNear(SvgViewport.from(plain, 300.0, 150.0).transform(plain), SvgMatrix.identity))

        let meetRoot = SvgRoot(width: SvgLength(200.0), height: SvgLength(100.0))
        meetRoot.setAttr("viewBox", "0 0 100 100")
        let meet = SvgViewport.from(meetRoot, 300.0, 150.0).transform(meetRoot)
        @Assert(pointNear(meet.apply(SvgPoint(0.0, 0.0)), SvgPoint(50.0, 0.0)))
        @Assert(pointNear(meet.apply(SvgPoint(100.0, 100.0)), SvgPoint(150.0, 100.0)))

        let sliceRoot = SvgRoot(width: SvgLength(200.0), height: SvgLength(100.0))
        sliceRoot.setAttr("viewBox", "0 0 100 100")
        sliceRoot.setAttr("preserveAspectRatio", "xMidYMid slice")
        let slice = SvgViewport.from(sliceRoot, 300.0, 150.0).transform(sliceRoot)
        @Assert(pointNear(slice.apply(SvgPoint(0.0, 0.0)), SvgPoint(0.0, -50.0)))
        @Assert(pointNear(slice.apply(SvgPoint(100.0, 100.0)), SvgPoint(200.0, 150.0)))

        let noneRoot = SvgRoot(width: SvgLength(200.0), height: SvgLength(100.0))
        noneRoot.setAttr("viewBox", "0 0 100 100")
        noneRoot.setAttr("preserveAspectRatio", "none")
        let none = SvgViewport.from(noneRoot, 300.0, 150.0).transform(noneRoot)
        @Assert(pointNear(none.apply(SvgPoint(100.0, 100.0)), SvgPoint(200.0, 100.0)))

        let alignRoot = SvgRoot(width: SvgLength(200.0), height: SvgLength(200.0))
        alignRoot.setAttr("viewBox", "0 0 100 50")
        alignRoot.setAttr("preserveAspectRatio", "xMinYMin meet")
        let minMin = SvgViewport.from(alignRoot, 300.0, 150.0).transform(alignRoot)
        @Assert(pointNear(minMin.apply(SvgPoint(0.0, 0.0)), SvgPoint(0.0, 0.0)))
        alignRoot.setAttr("preserveAspectRatio", "xMidYMid meet")
        let midMid = SvgViewport.from(alignRoot, 300.0, 150.0).transform(alignRoot)
        @Assert(pointNear(midMid.apply(SvgPoint(0.0, 0.0)), SvgPoint(0.0, 50.0)))
        alignRoot.setAttr("preserveAspectRatio", "xMaxYMax meet")
        let maxMax = SvgViewport.from(alignRoot, 300.0, 150.0).transform(alignRoot)
        @Assert(pointNear(maxMax.apply(SvgPoint(0.0, 0.0)), SvgPoint(0.0, 100.0)))
    }

    /** 尺寸解析：绝对值、百分比、缺省 300×150 与非法值。 */
    @TestCase
    public func sizeResolution(): Unit {
        let absolute = SvgRoot(width: SvgLength(120.0), height: SvgLength(80.0))
        let absoluteViewport = SvgViewport.from(absolute, 300.0, 150.0)
        @Assert(near(absoluteViewport.width, 120.0))
        @Assert(near(absoluteViewport.height, 80.0))

        let percent = SvgRoot(
            width: SvgLength(50.0, unit: SvgLengthUnit.Percent),
            height: SvgLength(50.0, unit: SvgLengthUnit.Percent)
        )
        let percentViewport = SvgViewport.from(percent, 200.0, 100.0)
        @Assert(near(percentViewport.width, 100.0))
        @Assert(near(percentViewport.height, 50.0))

        let missing = SvgRoot()
        let fallback = SvgViewport.from(missing, 300.0, 150.0)
        @Assert(near(fallback.width, 300.0))
        @Assert(near(fallback.height, 150.0))

        let invalid = SvgRoot(width: SvgLength(-10.0), height: SvgLength(0.0))
        let invalidViewport = SvgViewport.from(invalid, 300.0, 150.0)
        @Assert(near(invalidViewport.width, 300.0))
        @Assert(near(invalidViewport.height, 150.0))

        let inches = SvgRoot(width: SvgLength(1.0, unit: SvgLengthUnit.In), height: SvgLength(1.0, unit: SvgLengthUnit.In))
        let inchViewport = SvgViewport.from(inches, 300.0, 150.0)
        @Assert(near(inchViewport.width, 96.0))
        @Assert(near(inchViewport.height, 96.0))
    }

    /** 嵌套 svg：外层 × 内层矩阵、x/y 平移与裁剪尺寸。 */
    @TestCase
    public func nestedViewports(): Unit {
        let outer = SvgRoot(width: SvgLength(200.0), height: SvgLength(200.0))
        outer.setAttr("viewBox", "0 0 100 100")
        let outerMatrix = SvgViewport.from(outer, 300.0, 150.0).transform(outer)

        let inner = SvgRoot(width: SvgLength(50.0), height: SvgLength(50.0))
        inner.x = SvgLength(10.0)
        inner.y = SvgLength(20.0)
        inner.setAttr("viewBox", "0 0 25 25")
        let nested = SvgViewport.nestedTransform(outerMatrix, inner, 100.0, 100.0)
        @Assert(pointNear(nested.apply(SvgPoint(0.0, 0.0)), SvgPoint(20.0, 40.0)))
        @Assert(pointNear(nested.apply(SvgPoint(25.0, 25.0)), SvgPoint(120.0, 140.0)))

        let noViewBox = SvgRoot(width: SvgLength(30.0), height: SvgLength(30.0))
        noViewBox.x = SvgLength(5.0)
        noViewBox.y = SvgLength(6.0)
        let translated = SvgViewport.nestedTransform(SvgMatrix.identity, noViewBox, 100.0, 100.0)
        @Assert(pointNear(translated.apply(SvgPoint(0.0, 0.0)), SvgPoint(5.0, 6.0)))
        @Assert(pointNear(translated.apply(SvgPoint(10.0, 10.0)), SvgPoint(15.0, 16.0)))

        let viewport = SvgViewport.nestedViewport(inner, 100.0, 100.0)
        @Assert(near(viewport.width, 50.0))
        @Assert(near(viewport.height, 50.0))

        let percentChild = SvgRoot(
            width: SvgLength(50.0, unit: SvgLengthUnit.Percent),
            height: SvgLength(10.0, unit: SvgLengthUnit.Percent)
        )
        let percentViewport = SvgViewport.nestedViewport(percentChild, 200.0, 100.0)
        @Assert(near(percentViewport.width, 100.0))
        @Assert(near(percentViewport.height, 10.0))
    }
}

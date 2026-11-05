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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

internal func addStop(gradient: SvgElement, offset: Float64, color: ?SvgColor, opacity!: ?Float64 = None) {
    let stop = SvgStop()
    stop.setAttr("offset", formatSvgNumber(offset))
    match (color) {
        case Some(value) => stop.setAttr("stop-color", value.toString())
        case None => ()
    }
    match (opacity) {
        case Some(value) => stop.setAttr("stop-opacity", formatSvgNumber(value))
        case None => ()
    }
    gradient.appendElement(stop)
}

internal func linearGradientForTest(
    x1: Float64,
    x2: Float64,
    units!: String = "userSpaceOnUse"
): SvgLinearGradient {
    let gradient = SvgLinearGradient()
    gradient.setAttr("x1", formatSvgNumber(x1))
    gradient.setAttr("y1", "0")
    gradient.setAttr("x2", formatSvgNumber(x2))
    gradient.setAttr("y2", "0")
    gradient.setAttr("gradientUnits", units)
    gradient
}

@Test
public class SvgGradientSampler_test {
    /** 线性渐变端点、中点、t 公式与 p0 == p1。 */
    @TestCase
    public func linearEndpoints(): Unit {
        let gradient = linearGradientForTest(0.0, 10.0)
        addStop(gradient, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(gradient, 1.0, SvgColor.fromRgb(0, 0, 255))
        let sampler = SvgGradientSampler()
        let box = SvgBounds(0.0, 0.0, 10.0, 10.0)
        @Assert(colorNear(sampler.sample(gradient, SvgPoint(0.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
        @Assert(
            colorNear(
                sampler.sample(gradient, SvgPoint(5.0, 0.0), box, SvgColor.Black),
                SvgColor.fromRgb(128, 0, 128),
                tolerance: 2
            )
        )
        @Assert(colorNear(sampler.sample(gradient, SvgPoint(10.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))

        let degenerate = linearGradientForTest(5.0, 5.0)
        addStop(degenerate, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(degenerate, 1.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(colorNear(sampler.sample(degenerate, SvgPoint(3.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))

        let degenerateRepeat = linearGradientForTest(5.0, 5.0)
        degenerateRepeat.setAttr("spreadMethod", "repeat")
        addStop(degenerateRepeat, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(degenerateRepeat, 1.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(
            colorNear(
                sampler.sample(degenerateRepeat, SvgPoint(3.0, 0.0), box, SvgColor.Black),
                SvgColor.fromRgb(0, 0, 255)
            )
        )

        let objectBox = linearGradientForTest(0.0, 1.0, units: "objectBoundingBox")
        addStop(objectBox, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(objectBox, 1.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(colorNear(sampler.sample(objectBox, SvgPoint(10.0, 5.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))
        @Assert(colorNear(sampler.sample(objectBox, SvgPoint(0.0, 5.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
    }

    /** spreadMethod：pad / repeat / reflect。 */
    @TestCase
    public func spreadMethods(): Unit {
        let box = SvgBounds(0.0, 0.0, 10.0, 10.0)
        let sampler = SvgGradientSampler()
        for (method in ["pad", "repeat", "reflect"]) {
            let gradient = linearGradientForTest(0.0, 10.0)
            gradient.setAttr("spreadMethod", method)
            addStop(gradient, 0.0, SvgColor.fromRgb(255, 0, 0))
            addStop(gradient, 1.0, SvgColor.fromRgb(0, 0, 255))
            let before = sampler.sample(gradient, SvgPoint(-5.0, 0.0), box, SvgColor.Black)
            let after = sampler.sample(gradient, SvgPoint(15.0, 0.0), box, SvgColor.Black)
            let far = sampler.sample(gradient, SvgPoint(25.0, 0.0), box, SvgColor.Black)
            if (method == "pad") {
                @Assert(colorNear(before, SvgColor.fromRgb(255, 0, 0)))
                @Assert(colorNear(after, SvgColor.fromRgb(0, 0, 255)))
                @Assert(colorNear(far, SvgColor.fromRgb(0, 0, 255)))
            } else {
                @Assert(colorNear(before, SvgColor.fromRgb(128, 0, 128), tolerance: 2))
                @Assert(colorNear(after, SvgColor.fromRgb(128, 0, 128), tolerance: 2))
                @Assert(colorNear(far, SvgColor.fromRgb(128, 0, 128), tolerance: 2))
            }
        }
    }

    /** stops：乱序、钳制、stop-opacity、相同 offset、currentColor、缺省黑色。 */
    @TestCase
    public func stopsAndOpacity(): Unit {
        let sampler = SvgGradientSampler()
        let box = SvgBounds(0.0, 0.0, 10.0, 10.0)
        let unsorted = linearGradientForTest(0.0, 10.0)
        addStop(unsorted, 1.0, SvgColor.fromRgb(0, 0, 255))
        addStop(unsorted, 0.0, SvgColor.fromRgb(255, 0, 0))
        @Assert(colorNear(sampler.sample(unsorted, SvgPoint(0.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(sampler.sample(unsorted, SvgPoint(10.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))

        let opacity = linearGradientForTest(0.0, 10.0)
        addStop(opacity, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(opacity, 1.0, SvgColor.fromRgb(0, 0, 255), opacity: 0.5)
        let faded = sampler.sample(opacity, SvgPoint(10.0, 0.0), box, SvgColor.Black)
        @Assert(faded.blue == 255)
        @Assert(abs(faded.alpha - 0.5) < 0.01)

        let sameOffset = linearGradientForTest(0.0, 10.0)
        addStop(sameOffset, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(sameOffset, 0.5, SvgColor.fromRgb(255, 0, 0))
        addStop(sameOffset, 0.5, SvgColor.fromRgb(0, 0, 255))
        addStop(sameOffset, 1.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(colorNear(sampler.sample(sameOffset, SvgPoint(5.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))

        let current = linearGradientForTest(0.0, 10.0)
        let currentStop = SvgStop()
        currentStop.setAttr("offset", "1")
        currentStop.setAttr("stop-color", "currentColor")
        current.appendElement(currentStop)
        addStop(current, 0.0, SvgColor.fromRgb(255, 0, 0))
        @Assert(
            colorNear(
                sampler.sample(current, SvgPoint(10.0, 0.0), box, SvgColor.fromRgb(0, 255, 0)),
                SvgColor.fromRgb(0, 255, 0)
            )
        )

        let missing = linearGradientForTest(0.0, 10.0)
        let missingStart = SvgStop()
        missingStart.setAttr("offset", "0")
        let missingEnd = SvgStop()
        missingEnd.setAttr("offset", "1")
        missing.appendElement(missingStart)
        missing.appendElement(missingEnd)
        @Assert(colorNear(sampler.sample(missing, SvgPoint(5.0, 0.0), box, SvgColor.Black), SvgColor.Black))

        let clamped = linearGradientForTest(0.0, 10.0)
        let clampedStop = SvgStop()
        clampedStop.setAttr("offset", "150%")
        clampedStop.setAttr("stop-color", "red")
        clamped.appendElement(clampedStop)
        addStop(clamped, 0.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(colorNear(sampler.sample(clamped, SvgPoint(10.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
    }

    /** 径向渐变：圆心、边缘、焦点偏移、r=0 与 fr/FR 忽略。 */
    @TestCase
    public func radialGradients(): Unit {
        let box = SvgBounds(0.0, 0.0, 10.0, 10.0)
        let sampler = SvgGradientSampler()
        let radial = SvgRadialGradient()
        radial.setAttr("gradientUnits", "objectBoundingBox")
        radial.setAttr("cx", "50%")
        radial.setAttr("cy", "50%")
        radial.setAttr("r", "50%")
        addStop(radial, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(radial, 1.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(colorNear(sampler.sample(radial, SvgPoint(5.0, 5.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(sampler.sample(radial, SvgPoint(10.0, 5.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))

        radial.setAttr("fx", "25%")
        radial.setAttr("fy", "50%")
        @Assert(colorNear(sampler.sample(radial, SvgPoint(2.5, 5.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))

        let zero = SvgRadialGradient()
        zero.setAttr("gradientUnits", "objectBoundingBox")
        zero.setAttr("r", "0")
        addStop(zero, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(zero, 1.0, SvgColor.fromRgb(0, 0, 255))
        let zeroWarnings = SvgGradientSampler()
        let zeroColor = zeroWarnings.sample(zero, SvgPoint(5.0, 5.0), box, SvgColor.Black)
        @Assert(zeroWarnings.warnings.size >= 1)
        @Assert(zeroColor.alpha == 0.0)

        let withFr = SvgRadialGradient()
        withFr.setAttr("r", "50%")
        withFr.setAttr("fr", "10%")
        addStop(withFr, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(withFr, 1.0, SvgColor.fromRgb(0, 0, 255))
        let frWarnings = SvgGradientSampler()
        frWarnings.sample(withFr, SvgPoint(5.0, 5.0), box, SvgColor.Black)
        @Assert(frWarnings.warnings.size >= 1)
    }

    /** 坐标系、gradientTransform 逆矩阵与不可逆矩阵。 */
    @TestCase
    public func coordinateSystems(): Unit {
        let sampler = SvgGradientSampler()
        let gradient = linearGradientForTest(0.0, 10.0)
        addStop(gradient, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(gradient, 1.0, SvgColor.fromRgb(0, 0, 255))
        let shiftedBox = SvgBounds(100.0, 100.0, 5.0, 5.0)
        @Assert(
            colorNear(
                sampler.sample(gradient, SvgPoint(5.0, 100.0), shiftedBox, SvgColor.Black),
                SvgColor.fromRgb(128, 0, 128),
                tolerance: 2
            )
        )
        @Assert(colorNear(sampler.sample(gradient, SvgPoint(0.0, 0.0), shiftedBox, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))

        let transformed = linearGradientForTest(0.0, 10.0)
        transformed.setAttr("gradientTransform", "translate(5 0)")
        addStop(transformed, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(transformed, 1.0, SvgColor.fromRgb(0, 0, 255))
        @Assert(colorNear(sampler.sample(transformed, SvgPoint(5.0, 0.0), SvgBounds(0.0, 0.0, 10.0, 10.0), SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(sampler.sample(transformed, SvgPoint(10.0, 0.0), SvgBounds(0.0, 0.0, 10.0, 10.0), SvgColor.Black), SvgColor.fromRgb(128, 0, 128), tolerance: 2))

        let singular = linearGradientForTest(0.0, 10.0)
        singular.setAttr("gradientTransform", "scale(0 0)")
        addStop(singular, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(singular, 1.0, SvgColor.fromRgb(0, 0, 255))
        let singularSampler = SvgGradientSampler()
        singularSampler.sample(singular, SvgPoint(5.0, 0.0), SvgBounds(0.0, 0.0, 10.0, 10.0), SvgColor.Black)
        @Assert(singularSampler.warnings.size >= 1)
    }

    /** href 继承 stops、属性覆盖与循环 / 深度上限。 */
    @TestCase
    public func hrefInheritance(): Unit {
        let root = SvgRoot()
        let base = linearGradientForTest(0.0, 10.0)
        base.setAttr("id", "base")
        addStop(base, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(base, 1.0, SvgColor.fromRgb(0, 0, 255))
        root.appendElement(base)

        let child = SvgLinearGradient()
        child.setAttr("id", "child")
        child.href = "#base"
        child.setAttr("x2", "5")
        root.appendElement(child)

        let sampler = SvgGradientSampler(root: Some(root))
        let box = SvgBounds(0.0, 0.0, 10.0, 10.0)
        @Assert(colorNear(sampler.sample(child, SvgPoint(0.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(sampler.sample(child, SvgPoint(5.0, 0.0), box, SvgColor.Black), SvgColor.fromRgb(0, 0, 255)))

        let cycleRoot = SvgRoot()
        let first = linearGradientForTest(0.0, 10.0)
        first.setAttr("id", "a")
        first.href = "#b"
        addStop(first, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(first, 1.0, SvgColor.fromRgb(0, 0, 255))
        let second = linearGradientForTest(0.0, 10.0)
        second.setAttr("id", "b")
        second.href = "#a"
        cycleRoot.appendElement(first)
        cycleRoot.appendElement(second)
        let cycleSampler = SvgGradientSampler(root: Some(cycleRoot))
        cycleSampler.sample(first, SvgPoint(5.0, 0.0), box, SvgColor.Black)
        @Assert(cycleSampler.warnings.size >= 1)

        let deepRoot = SvgRoot()
        var previousId = ""
        var lastGradient: ?SvgGradient = None
        for (index in 0..70) {
            let gradient = linearGradientForTest(0.0, 10.0)
            let id = "g" + index.toString()
            gradient.setAttr("id", id)
            if (index == 0) {
                addStop(gradient, 0.0, SvgColor.fromRgb(255, 0, 0))
                addStop(gradient, 1.0, SvgColor.fromRgb(0, 0, 255))
            } else {
                gradient.href = "#" + previousId
            }
            deepRoot.appendElement(gradient)
            previousId = id
            lastGradient = Some(gradient)
        }
        let deepSampler = SvgGradientSampler(root: Some(deepRoot))
        match (lastGradient) {
            case Some(gradient) =>
                let deepError = expectSvgException({=>
                    deepSampler.sample(gradient, SvgPoint(5.0, 0.0), box, SvgColor.Black)
                })
                @Assert(deepError.kind == SvgErrorKind.Limit)
            case None => @Fail("缺少渐变")
        }
    }
}

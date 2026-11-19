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

internal func clipElementWithRect(x: Float64, y: Float64, width: Float64, height: Float64): SvgContainer {
    let clip = SvgContainer(SvgContainerKind.ClipPath)
    let rect = SvgRect(x: SvgLength(x), y: SvgLength(y), width: SvgLength(width), height: SvgLength(height))
    clip.appendElement(rect)
    clip
}

internal func maskElementWithRect(width: Float64, height: Float64, color: SvgColor, opacity: Float64): SvgContainer {
    let mask = SvgContainer(SvgContainerKind.Mask)
    let rect = SvgRect(width: SvgLength(width), height: SvgLength(height))
    rect.fill = SvgPaint.of(color)
    rect.fillOpacity = opacity
    mask.appendElement(rect)
    mask
}

@Test
public class SvgClipMask_test {
    /** 矩形裁剪、圆形抗锯齿、evenodd 与 clipPathUnits 两种。 */
    @TestCase
    public func clipPaths(): Unit {
        let rectClip = clipElementWithRect(2.0, 2.0, 4.0, 4.0)
        let mask = SvgClipPathMasker.render(
            rectClip,
            10,
            10,
            samplesPerPixel: 4,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0)
        )
        @Assert(mask.coverageAt(2, 2) == 255)
        @Assert(mask.coverageAt(5, 5) == 255)
        @Assert(mask.coverageAt(1, 1) == 0)
        @Assert(mask.coverageAt(6, 6) == 0)

        let circleClip = SvgContainer(SvgContainerKind.ClipPath)
        circleClip.appendElement(SvgCircle(cx: SvgLength(5.0), cy: SvgLength(5.0), r: SvgLength(3.4)))
        let circleMask = SvgClipPathMasker.render(
            circleClip,
            10,
            10,
            samplesPerPixel: 4,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0)
        )
        @Assert(circleMask.coverageAt(5, 5) == 255)
        let edge = circleMask.coverageAt(8, 5)
        @Assert(edge > 0)
        @Assert(edge < 255)

        let evenOddClip = SvgContainer(SvgContainerKind.ClipPath)
        evenOddClip.setAttr("clip-rule", "evenodd")
        evenOddClip.appendElement(
            SvgPath(
                d: SvgPathData.parse("M1 1 L9 1 L9 9 L1 9 Z M3 3 L7 3 L7 7 L3 7 Z")
            )
        )
        let evenOddMask = SvgClipPathMasker.render(
            evenOddClip,
            10,
            10,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0)
        )
        @Assert(evenOddMask.coverageAt(5, 5) == 0)
        @Assert(evenOddMask.coverageAt(1, 5) == 255)

        let objectClip = SvgContainer(SvgContainerKind.ClipPath)
        objectClip.appendElement(
            SvgRect(x: SvgLength(0.0), y: SvgLength(0.0), width: SvgLength(0.5), height: SvgLength(0.5))
        )
        let objectMask = SvgClipPathMasker.render(
            objectClip,
            40,
            40,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.ObjectBoundingBox,
            targetBox: SvgBounds(10.0, 10.0, 20.0, 20.0)
        )
        @Assert(objectMask.coverageAt(15, 15) == 255)
        @Assert(objectMask.coverageAt(5, 5) == 0)
        @Assert(objectMask.coverageAt(20, 20) == 0)
        @Assert(objectMask.coverageAt(35, 35) == 0)
    }

    /** 8 位裁剪蒙版的乘法合成。 */
    @TestCase
    public func coverageMultiplication(): Unit {
        let first = SvgClipPathMasker.render(
            clipElementWithRect(0.0, 0.0, 10.0, 10.0),
            4,
            4,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 4.0, 4.0)
        )
        let second = SvgCoverageMask(4, 4, Array<Byte>(16, repeat: 128))
        let product = first.multiply(second)
        @Assert(product.coverageAt(0, 0) == 128)
        @Assert(product.coverageAt(3, 3) == 128)

        let bitmap = SvgBitmap(4, 4)
        bitmap.fill(SvgColor.Black)
        product.applyTo(bitmap)
        let pixel = bitmap.pixel(0, 0)
        @Assert(abs(pixel.alpha - 128.0 / 255.0) < 0.01)
    }

    /** mask：半透明、luminance、alpha 与 maskUnits / maskContentUnits。 */
    @TestCase
    public func masks(): Unit {
        let gray = maskElementWithRect(10.0, 10.0, SvgColor.fromRgb(128, 128, 128), 1.0)
        let luminance = SvgMasker.render(
            gray,
            10,
            10,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            maskUnits: SvgCoordinateUnits.UserSpaceOnUse,
            maskContentUnits: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0)
        )
        @Assert(abs(Int64(luminance.coverageAt(5, 5)) - 128) <= 3)

        let alphaMask = maskElementWithRect(10.0, 10.0, SvgColor.fromRgb(128, 128, 128), 1.0)
        alphaMask.setAttr("mask-type", "alpha")
        let alpha = SvgMasker.render(
            alphaMask,
            10,
            10,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            maskUnits: SvgCoordinateUnits.UserSpaceOnUse,
            maskContentUnits: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0)
        )
        @Assert(alpha.coverageAt(5, 5) == 255)

        let half = maskElementWithRect(10.0, 10.0, SvgColor.White, 0.5)
        let halfMask = SvgMasker.render(
            half,
            10,
            10,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            maskUnits: SvgCoordinateUnits.UserSpaceOnUse,
            maskContentUnits: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0)
        )
        @Assert(abs(Int64(halfMask.coverageAt(5, 5)) - 128) <= 3)

        let boxMaskElement = SvgContainer(SvgContainerKind.Mask)
        let unitRect = SvgRect(x: SvgLength(0.0), y: SvgLength(0.0), width: SvgLength(1.0), height: SvgLength(1.0))
        unitRect.fill = SvgPaint.of(SvgColor.White)
        boxMaskElement.appendElement(unitRect)
        let boxMask = SvgMasker.render(
            boxMaskElement,
            40,
            40,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            maskUnits: SvgCoordinateUnits.ObjectBoundingBox,
            maskContentUnits: SvgCoordinateUnits.ObjectBoundingBox,
            targetBox: SvgBounds(10.0, 10.0, 20.0, 20.0)
        )
        @Assert(boxMask.coverageAt(20, 20) == 255)
        @Assert(boxMask.coverageAt(5, 5) == 0)
    }

    /** 嵌套 clipPath / mask 引用与循环、深度上限。 */
    @TestCase
    public func nestedReferences(): Unit {
        let root = SvgRoot()
        let inner = clipElementWithRect(5.0, 5.0, 5.0, 5.0)
        inner.setAttr("id", "inner")
        root.appendElement(inner)
        let outer = SvgContainer(SvgContainerKind.ClipPath)
        outer.setAttr("id", "outer")
        let rect = SvgRect(x: SvgLength(0.0), y: SvgLength(0.0), width: SvgLength(10.0), height: SvgLength(10.0))
        rect.setAttr("clip-path", "url(#inner)")
        outer.appendElement(rect)
        root.appendElement(outer)
        let nested = SvgClipPathMasker.render(
            outer,
            10,
            10,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 10.0, 10.0),
            root: Some(root)
        )
        @Assert(nested.coverageAt(2, 2) == 0)
        @Assert(nested.coverageAt(7, 7) == 255)

        let cycleRoot = SvgRoot()
        let cycleClip = SvgContainer(SvgContainerKind.ClipPath)
        cycleClip.setAttr("id", "cycle")
        let cycleGroup = SvgContainer(SvgContainerKind.Group)
        cycleGroup.setAttr("clip-path", "url(#cycle)")
        cycleClip.appendElement(cycleGroup)
        cycleRoot.appendElement(cycleClip)
        let clipWarnings = ArrayList<String>()
        SvgClipPathMasker.render(
            cycleClip,
            4,
            4,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            units: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 4.0, 4.0),
            root: Some(cycleRoot),
            warnings: Some(clipWarnings)
        )
        @Assert(clipWarnings.size >= 1)

        let maskRoot = SvgRoot()
        let cycleMask = SvgContainer(SvgContainerKind.Mask)
        cycleMask.setAttr("id", "cycleMask")
        let maskGroup = SvgContainer(SvgContainerKind.Group)
        maskGroup.setAttr("mask", "url(#cycleMask)")
        cycleMask.appendElement(maskGroup)
        maskRoot.appendElement(cycleMask)
        let maskWarnings = ArrayList<String>()
        SvgMasker.render(
            cycleMask,
            4,
            4,
            samplesPerPixel: 1,
            contentMatrix: SvgMatrix.identity,
            maskUnits: SvgCoordinateUnits.UserSpaceOnUse,
            maskContentUnits: SvgCoordinateUnits.UserSpaceOnUse,
            targetBox: SvgBounds(0.0, 0.0, 4.0, 4.0),
            root: Some(maskRoot),
            warnings: Some(maskWarnings)
        )
        @Assert(maskWarnings.size >= 1)

        let deepRoot = SvgRoot()
        var index = 0
        while (index <= 65) {
            let clip = SvgContainer(SvgContainerKind.ClipPath)
            clip.setAttr("id", "deep${index}")
            if (index == 65) {
                clip.appendElement(
                    SvgRect(width: SvgLength(4.0), height: SvgLength(4.0))
                )
            } else {
                let group = SvgContainer(SvgContainerKind.Group)
                group.setAttr("clip-path", "url(#deep${index + 1})")
                clip.appendElement(group)
            }
            deepRoot.appendElement(clip)
            index++
        }
        let first = deepRoot.childrenOf("clipPath")[0]
        let deepError = expectSvgException({=>
            SvgClipPathMasker.render(
                first,
                4,
                4,
                samplesPerPixel: 1,
                contentMatrix: SvgMatrix.identity,
                units: SvgCoordinateUnits.UserSpaceOnUse,
                targetBox: SvgBounds(0.0, 0.0, 4.0, 4.0),
                root: Some(deepRoot)
            )
        })
        @Assert(deepError.kind == SvgErrorKind.Limit)
    }

    /** 组透明度：整组合成一次、嵌套与非法值。 */
    @TestCase
    public func groupOpacity(): Unit {
        let destination = SvgBitmap(2, 2)
        let layer = SvgBitmap(2, 2)
        layer.fill(SvgColor.fromRgb(255, 0, 0))
        SvgGroupCompositor.composite(destination, layer, 0.5)
        @Assert(abs(destination.pixel(0, 0).alpha - 0.5) < 0.01)
        @Assert(destination.pixel(0, 0).red == 255)

        let nested = SvgBitmap(1, 1)
        let inner = SvgBitmap(1, 1)
        inner.fill(SvgColor.fromRgb(0, 0, 255))
        let middle = SvgBitmap(1, 1)
        SvgGroupCompositor.composite(middle, inner, 0.5)
        SvgGroupCompositor.composite(nested, middle, 0.5)
        @Assert(abs(nested.pixel(0, 0).alpha - 0.25) < 0.01)

        let invalid = SvgBitmap(1, 1)
        let opaque = SvgBitmap(1, 1)
        opaque.fill(SvgColor.Black)
        SvgGroupCompositor.composite(invalid, opaque, 1.5)
        @Assert(invalid.pixel(0, 0).alpha == 1.0)

        let limited = SvgRenderOptions(maxPixels: 100)
        let error = expectSvgException({=> SvgGroupCompositor.createLayer(1000, 1000, limited)})
        @Assert(error.kind == SvgErrorKind.Limit)
        @Assert(SvgGroupCompositor.createLayer(10, 10, SvgRenderOptions()).width == 10)
    }

    /** 渐变填充接入光栅器。 */
    @TestCase
    public func gradientPaintIntegration(): Unit {
        let gradient = linearGradientForTest(0.0, 10.0)
        addStop(gradient, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(gradient, 1.0, SvgColor.fromRgb(0, 0, 255))
        let bitmap = SvgBitmap(10, 1)
        let raster = SvgRasterizer(bitmap, samplesPerPixel: 1)
        raster.fillGradient(
            SvgPathData.parse("M0 0 L10 0 L10 1 L0 1 Z"),
            gradient,
            SvgBounds(0.0, 0.0, 10.0, 1.0),
            SvgColor.Black
        )
        let left = bitmap.pixel(0, 0)
        let right = bitmap.pixel(9, 0)
        let middle = bitmap.pixel(5, 0)
        @Assert(left.red > 240 && left.blue < 20)
        @Assert(right.blue > 240 && right.red < 20)
        @Assert(middle.red > 100 && middle.red < 160)
        @Assert(middle.blue > 100 && middle.blue < 160)

        let strokeBitmap = SvgBitmap(10, 10)
        let strokeRaster = SvgRasterizer(strokeBitmap, samplesPerPixel: 1)
        strokeRaster.strokeGradient(
            SvgPathData.parse("M0 5 L10 5"),
            gradient,
            SvgBounds(0.0, 0.0, 10.0, 10.0),
            SvgColor.Black,
            strokeWidth: 4.0
        )
        let strokeLeft = strokeBitmap.pixel(0, 5)
        let strokeRight = strokeBitmap.pixel(9, 5)
        @Assert(strokeLeft.red > 240 && strokeLeft.blue < 20)
        @Assert(strokeRight.blue > 240 && strokeRight.red < 20)
    }
}

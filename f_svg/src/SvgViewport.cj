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

/**
 * 视口尺寸与 `viewBox` 到设备坐标的映射。
 *
 * 无 `viewBox` 时为单位矩阵；有 `viewBox` 时复用 M1 的
 * `SvgPreserveAspectRatio.toMatrix`，不实现第二套 meet / slice。
 */
public struct SvgViewport {
    public let width: Float64
    public let height: Float64

    public init(width: Float64, height: Float64) {
        this.width = width
        this.height = height
    }

    /** 解析根尺寸：绝对长度直接换算，百分比与缺省用 fallback。 */
    public static func from(root: SvgRoot, fallbackWidth: Float64, fallbackHeight: Float64): SvgViewport {
        if (fallbackWidth <= 0.0 && fallbackHeight <= 0.0) {
            throw invalidValue("视口 fallback 宽高不能同时为非正数")
        }
        SvgViewport(
            resolveViewportLength(root.width, SvgLengthAxis.Horizontal, fallbackWidth),
            resolveViewportLength(root.height, SvgLengthAxis.Vertical, fallbackHeight)
        )
    }

    public func transform(root: SvgRoot): SvgMatrix {
        match (root.viewBox) {
            case Some(viewBox) =>
                let aspect = root.preserveAspectRatio ?? SvgPreserveAspectRatio.Default
                aspect.toMatrix(viewBox, this.width, this.height)
            case None => SvgMatrix.identity
        }
    }

    /** 嵌套 svg 的裁剪尺寸：百分比相对父视口。 */
    public static func nestedViewport(child: SvgRoot, parentWidth: Float64, parentHeight: Float64): SvgViewport {
        SvgViewport(
            resolveViewportLength(child.width, SvgLengthAxis.Horizontal, parentWidth),
            resolveViewportLength(child.height, SvgLengthAxis.Vertical, parentHeight)
        )
    }

    /** 嵌套 svg 矩阵：`M_parent × translate(x,y) × toMatrix(viewBox, width, height)`。 */
    public static func nestedTransform(
        parent: SvgMatrix,
        child: SvgRoot,
        parentWidth: Float64,
        parentHeight: Float64
    ): SvgMatrix {
        let viewport = nestedViewport(child, parentWidth, parentHeight)
        let x = resolveViewportOffset(child.x, SvgLengthAxis.Horizontal, parentWidth)
        let y = resolveViewportOffset(child.y, SvgLengthAxis.Vertical, parentHeight)
        let local = match (child.viewBox) {
            case Some(viewBox) =>
                let aspect = child.preserveAspectRatio ?? SvgPreserveAspectRatio.Default
                aspect.toMatrix(viewBox, viewport.width, viewport.height)
            case None => SvgMatrix.identity
        }
        parent.multiply(SvgMatrix.translate(x, y)).multiply(local)
    }
}

private func resolveViewportLength(length: ?SvgLength, axis: SvgLengthAxis, fallback: Float64): Float64 {
    let safeFallback = if (isFiniteSvgNumber(fallback) && fallback > 0.0) {
        fallback
    } else if (axis == SvgLengthAxis.Horizontal) {
        300.0
    } else {
        150.0
    }
    match (length) {
        case Some(value) =>
            if (value.value <= 0.0 || !isFiniteSvgNumber(value.value)) {
                return safeFallback
            }
            if (value.unit == SvgLengthUnit.Percent) {
                let resolved = value.value / 100.0 * safeFallback
                if (resolved > 0.0) {
                    return resolved
                }
                return safeFallback
            }
            let context = SvgLengthContext(safeFallback, safeFallback)
            let resolved = toUserUnits(value, axis, context)
            if (resolved > 0.0 && isFiniteSvgNumber(resolved)) {
                resolved
            } else {
                safeFallback
            }
        case None => safeFallback
    }
}

private func resolveViewportOffset(length: ?SvgLength, axis: SvgLengthAxis, reference: Float64): Float64 {
    match (length) {
        case Some(value) =>
            let context = SvgLengthContext(reference, reference)
            let resolved = toUserUnits(value, axis, context)
            if (isFiniteSvgNumber(resolved)) {
                resolved
            } else {
                0.0
            }
        case None => 0.0
    }
}

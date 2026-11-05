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

/** 图案 tile 上限。 */
internal let SVG_MAX_PATTERN_TILE_PIXELS: Int64 = 4 * 1024 * 1024
/** pattern 引用深度上限。 */
internal let SVG_MAX_PATTERN_DEPTH: Int64 = 64

/** 已渲染的 tile 与其在用户空间的映射。 */
internal class SvgPatternTile {
    let bitmap: SvgBitmap
    let tileWidth: Float64
    let tileHeight: Float64
    let originX: Float64
    let originY: Float64
    let inverseTransform: SvgMatrix

    init(
        bitmap: SvgBitmap,
        tileWidth: Float64,
        tileHeight: Float64,
        originX: Float64,
        originY: Float64,
        inverseTransform: SvgMatrix
    ) {
        this.bitmap = bitmap
        this.tileWidth = tileWidth
        this.tileHeight = tileHeight
        this.originX = originX
        this.originY = originY
        this.inverseTransform = inverseTransform
    }

    /** 用户空间点 → tile 像素（最近邻，sRGB 直接取样）。 */
    func colorAt(user: SvgPoint): SvgColor {
        let local = this.inverseTransform.apply(user)
        var u = local.x - this.originX
        var v = local.y - this.originY
        u = u - floor(u / this.tileWidth) * this.tileWidth
        v = v - floor(v / this.tileHeight) * this.tileHeight
        var column = Int64(floor(u / this.tileWidth * Float64(this.bitmap.width)))
        var row = Int64(floor(v / this.tileHeight * Float64(this.bitmap.height)))
        column = clampPatternIndex(column, this.bitmap.width)
        row = clampPatternIndex(row, this.bitmap.height)
        let base = (row * this.bitmap.width + column) * 4
        SvgColor(
            this.bitmap.pixels[base],
            this.bitmap.pixels[base + 1],
            this.bitmap.pixels[base + 2],
            alpha: Float64(this.bitmap.pixels[base + 3]) / 255.0
        )
    }
}

private func clampPatternIndex(value: Int64, size: Int64): Int64 {
    if (value < 0) {
        return 0
    }
    if (value >= size) {
        return size - 1
    }
    value
}

/**
 * 图案取样器：解析 href 继承链、换算 tile 尺寸、渲染 tile 位图。
 *
 * 实例生命周期为一次 render；同一 pattern + 包围盒在实例内只渲染一次。
 */
public class SvgPatternSampler {
    public let warnings = ArrayList<String>()
    private let registry: ?SvgFontRegistry
    private let root: ?SvgElement
    private let cache = HashMap<String, SvgPatternTile>()

    public init(registry!: ?SvgFontRegistry = None, root!: ?SvgElement = None) {
        this.registry = registry
        this.root = root
    }

    /** 返回可平铺 tile 位图；不合法时返回 `None`。 */
    public func sample(
        pattern: SvgPattern,
        objectBounds: SvgBounds,
        transform: SvgMatrix,
        options: SvgRenderOptions
    ): ?SvgBitmap {
        if (transform.invert().isNone()) {
            this.warnings.add("pattern 取样变换不可逆，跳过绘制")
            return None
        }
        match (this.sampleTile(pattern, objectBounds, options)) {
            case Some(tile) => Some(tile.bitmap)
            case None => None
        }
    }

    internal func sampleTile(
        pattern: SvgPattern,
        objectBounds: SvgBounds,
        options: SvgRenderOptions
    ): ?SvgPatternTile {
        let key = "${pattern.identity}:${objectBounds.x},${objectBounds.y},${objectBounds.width},${objectBounds.height}"
        match (this.cache.get(key)) {
            case Some(tile) => return Some(tile)
            case None => ()
        }
        let chain = this.resolveChain(pattern)
        if (chain.size == 0) {
            return None
        }
        let boxWidth = max(0.0, objectBounds.width)
        let boxHeight = max(0.0, objectBounds.height)
        let unitsText = this.effectiveAttr(chain, "patternUnits") ?? "objectBoundingBox"
        let objectUnits = (SvgCoordinateUnits.fromName(unitsText.trimAscii()) ?? 
            SvgCoordinateUnits.ObjectBoundingBox) == SvgCoordinateUnits.ObjectBoundingBox
        let tileWidth = this.resolveAxis(chain, "width", boxWidth, objectUnits)
        let tileHeight = this.resolveAxis(chain, "height", boxHeight, objectUnits)
        if (tileWidth <= 0.0 || tileHeight <= 0.0) {
            this.warnings.add(
                "pattern「${pattern.attr("id") ?? ""}」的 tile 尺寸为空（${tileWidth}×${tileHeight}），不绘制"
            )
            return None
        }
        if (!isFiniteSvgNumber(tileWidth) || !isFiniteSvgNumber(tileHeight) ||
            tileWidth > Float64(SVG_MAX_PATTERN_TILE_PIXELS) ||
            tileHeight > Float64(SVG_MAX_PATTERN_TILE_PIXELS)) {
            throw SvgException(
                "pattern tile 像素数超过上限 ${SVG_MAX_PATTERN_TILE_PIXELS}",
                kind: SvgErrorKind.Limit
            )
        }
        let pixelWidth = maxInt64Pattern(1, Int64(ceil(tileWidth)))
        let pixelHeight = maxInt64Pattern(1, Int64(ceil(tileHeight)))
        if (pixelWidth > SVG_MAX_PATTERN_TILE_PIXELS / pixelHeight) {
            throw SvgException(
                "pattern tile 像素数超过上限 ${SVG_MAX_PATTERN_TILE_PIXELS}",
                kind: SvgErrorKind.Limit
            )
        }
        let originX = this.resolveOrigin(chain, "x", objectBounds.x, boxWidth, objectUnits)
        let originY = this.resolveOrigin(chain, "y", objectBounds.y, boxHeight, objectUnits)

        var contentSource: ?SvgElement = None
        for (element in chain) {
            if (element.children.size > 0) {
                contentSource = Some(element)
                break
            }
        }
        let bitmap = match (contentSource) {
            case Some(source) =>
                let contentUnitsText = this.effectiveAttr(chain, "patternContentUnits") ??
                    "userSpaceOnUse"
                let contentObject = (SvgCoordinateUnits.fromName(contentUnitsText.trimAscii()) ??
                    SvgCoordinateUnits.UserSpaceOnUse) == SvgCoordinateUnits.ObjectBoundingBox
                let contentMatrix = if (contentObject) {
                    SvgMatrix.scale(boxWidth, boxHeight)
                } else {
                    SvgMatrix.identity
                }
                let builder = SvgRenderTreeBuilder()
                let list = builder.buildContent(
                    source,
                    pixelWidth,
                    pixelHeight,
                    contentMatrix,
                    options.fonts,
                    root: this.root
                )
                if (builder.warnings.size > 0) {
                    for (warning in builder.warnings) {
                        this.warnings.add("pattern 子内容：${warning}")
                    }
                    return None
                }
                let tileRenderer = SvgRenderer(options: options)
                let rendered = tileRenderer.renderDisplayList(list)
                if (tileRenderer.warnings.size > 0) {
                    for (warning in tileRenderer.warnings) {
                        this.warnings.add("pattern 子内容：${warning}")
                    }
                    return None
                }
                rendered
            case None => SvgBitmap(pixelWidth, pixelHeight)
        }
        let transform = match (this.effectiveTransform(chain)) {
            case Some(value) => value.toMatrix()
            case None => SvgMatrix.identity
        }
        let inverse = match (transform.invert()) {
            case Some(value) => value
            case None => SvgMatrix.identity
        }
        let tile = SvgPatternTile(
            bitmap,
            tileWidth,
            tileHeight,
            originX,
            originY,
            inverse
        )
        this.cache[key] = tile
        Some(tile)
    }

    private func resolveChain(pattern: SvgPattern): ArrayList<SvgElement> {
        let chain = ArrayList<SvgElement>()
        let visited = ArrayList<Int64>()
        var current: SvgElement = pattern
        var stop = false
        while (!stop) {
            let element = current
            var repeated = false
            for (identity in visited) {
                if (identity == element.identity) {
                    repeated = true
                }
            }
            if (repeated) {
                this.warnings.add("pattern「${pattern.attr("id") ?? ""}」的 href 存在循环引用，继承停止")
                stop = true
                continue
            }
            visited.add(element.identity)
            chain.add(element)
            if (Int64(chain.size) > SVG_MAX_PATTERN_DEPTH) {
                throw SvgException(
                    "pattern 引用深度超过上限 ${SVG_MAX_PATTERN_DEPTH}",
                    kind: SvgErrorKind.Limit
                )
            }
            match (readSvgHref(element)) {
                case Some(href) =>
                    let id = stripSvgHash(href)
                    match (findSvgElementById(this.root, id)) {
                        case Some(next) =>
                            if (next is SvgPattern) {
                                current = next
                            } else {
                                stop = true
                            }
                        case None =>
                            this.warnings.add("pattern 引用的「${id}」不存在")
                            stop = true
                    }
                case None => stop = true
            }
        }
        chain
    }

    private func effectiveAttr(chain: ArrayList<SvgElement>, name: String): ?String {
        for (element in chain) {
            match (element.attr(name)) {
                case Some(value) => return Some(value)
                case None => ()
            }
        }
        None
    }

    private func resolveAxis(
        chain: ArrayList<SvgElement>,
        name: String,
        base: Float64,
        objectUnits: Bool
    ): Float64 {
        let length = this.resolveLength(chain, name) ?? SvgLength(0.0)
        let raw = if (length.unit == SvgLengthUnit.Percent) {
            length.value / 100.0
        } else {
            length.value
        }
        if (objectUnits) {
            raw * base
        } else {
            length.value
        }
    }

    private func resolveOrigin(
        chain: ArrayList<SvgElement>,
        name: String,
        base: Float64,
        extent: Float64,
        objectUnits: Bool
    ): Float64 {
        let length = this.resolveLength(chain, name) ?? SvgLength(0.0)
        let raw = if (length.unit == SvgLengthUnit.Percent) {
            length.value / 100.0
        } else {
            length.value
        }
        if (objectUnits) {
            base + raw * extent
        } else {
            length.value
        }
    }

    private func resolveLength(chain: ArrayList<SvgElement>, name: String): ?SvgLength {
        for (element in chain) {
            match (element.attr(name)) {
                case Some(text) =>
                    match (SvgLength.tryParse(text)) {
                        case Some(value) => return Some(value)
                        case None => ()
                    }
                case None => ()
            }
        }
        None
    }

    private func effectiveTransform(chain: ArrayList<SvgElement>): ?SvgTransform {
        for (element in chain) {
            match (element.attr("patternTransform")) {
                case Some(text) =>
                    match (tryParseSvgTransform(text)) {
                        case Some(value) => return Some(value)
                        case None => ()
                    }
                case None => ()
            }
        }
        None
    }
}

private func maxInt64Pattern(left: Int64, right: Int64): Int64 {
    if (left > right) {
        left
    } else {
        right
    }
}

internal func findPatternById(element: ?SvgElement, id: String): ?SvgPattern {
    match (element) {
        case Some(node) =>
            match (node) {
                case pattern: SvgPattern => if (pattern.attr("id") == Some(id)) {
                    return Some(pattern)
                }
                case _ => ()
            }
            for (child in node.children) {
                match (child) {
                    case ElementNode(next) =>
                        match (findPatternById(Some(next), id)) {
                            case Some(found) => return Some(found)
                            case None => ()
                        }
                    case _ => ()
                }
            }
            None
        case None => None
    }
}

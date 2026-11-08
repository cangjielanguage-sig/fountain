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

/**
 * 作者侧链式 SVG 构建器。
 *
 * 与解析期 `SvgBuilder.cj` 的 `buildSvgDocument` 无关：本类只负责生成，
 * 内部持有根元素、插入容器与游标，最终交给既有 `SvgWriter` 序列化。
 *
 * `container` 决定新元素挂到哪；`cursor` 是样式与动画的作用对象。
 * `group()` 把当前容器压栈并把两者移入新组，`end()` 弹栈回退。
 */
public class SvgBuilder {
    private let root: SvgRoot
    private var container: SvgElement
    private var cursor: SvgElement
    private let stack = ArrayList<SvgElement>()

    public init(width: Float64, height: Float64, viewBox!: ?SvgViewBox = None) {
        this.root = SvgRoot(
            width: Some(SvgLength(width, unit: SvgLengthUnit.Px)),
            height: Some(SvgLength(height, unit: SvgLengthUnit.Px))
        )
        this.container = this.root
        this.cursor = this.root
        match (viewBox) {
            case Some(box) => this.root.viewBox = Some(box)
            case None => ()
        }
    }

    /** 当前构建结果。 */
    public func document(): SvgDocument {
        SvgDocument(this.root)
    }

    /** 追加 `g` 元素并把游标移入该组。 */
    public func group(id!: ?String = None): SvgBuilder {
        let group = SvgContainer(SvgContainerKind.Group)
        match (id) {
            case Some(value) => group.setAttr("id", value)
            case None => ()
        }
        this.container.appendElement(group)
        this.stack.add(this.container)
        this.container = group
        this.cursor = group
        this
    }

    /** 游标退回父元素；栈底为根，额外调用无副作用。 */
    public func end(): SvgBuilder {
        if (this.stack.size > 0) {
            let parent = this.stack.remove(at: this.stack.size - 1)
            this.container = parent
            this.cursor = parent
        }
        this
    }

    /** `rect`；几何值写 `px`。 */
    public func rect(
        x!: Float64 = 0.0,
        y!: Float64 = 0.0,
        width!: Float64,
        height!: Float64,
        rx!: ?Float64 = None,
        ry!: ?Float64 = None
    ): SvgBuilder {
        let element = SvgRect(
            x: Some(svgPx(x)),
            y: Some(svgPx(y)),
            width: Some(svgPx(width)),
            height: Some(svgPx(height)),
            rx: svgOptionalPx(rx),
            ry: svgOptionalPx(ry)
        )
        this.adopt(element)
    }

    public func circle(cx!: Float64 = 0.0, cy!: Float64 = 0.0, r!: Float64): SvgBuilder {
        this.adopt(SvgCircle(cx: Some(svgPx(cx)), cy: Some(svgPx(cy)), r: Some(svgPx(r))))
    }

    public func ellipse(
        cx!: Float64 = 0.0,
        cy!: Float64 = 0.0,
        rx!: Float64,
        ry!: Float64
    ): SvgBuilder {
        this.adopt(
            SvgEllipse(
                cx: Some(svgPx(cx)),
                cy: Some(svgPx(cy)),
                rx: Some(svgPx(rx)),
                ry: Some(svgPx(ry))
            )
        )
    }

    public func line(x1!: Float64, y1!: Float64, x2!: Float64, y2!: Float64): SvgBuilder {
        this.adopt(
            SvgLine(
                x1: Some(svgPx(x1)),
                y1: Some(svgPx(y1)),
                x2: Some(svgPx(x2)),
                y2: Some(svgPx(y2))
            )
        )
    }

    /** `points` 为调用方传入的原始字符串。 */
    public func polyline(points!: String): SvgBuilder {
        let element = SvgPolyline()
        element.setAttr("points", points)
        this.adopt(element)
    }

    /** `points` 为调用方传入的原始字符串。 */
    public func polygon(points!: String): SvgBuilder {
        let element = SvgPolygon()
        element.setAttr("points", points)
        this.adopt(element)
    }

    /** `d` 为调用方传入的原始字符串。 */
    public func path(d!: String): SvgBuilder {
        let element = SvgPath()
        element.setAttr("d", d)
        this.adopt(element)
    }

    /** 追加文本节点；转义由 `SvgWriter` 负责。 */
    public func text(content!: String, x!: Float64 = 0.0, y!: Float64 = 0.0): SvgBuilder {
        let element = SvgText()
        element.x = Some([svgPx(x)])
        element.y = Some([svgPx(y)])
        element.appendText(content)
        this.adopt(element)
    }

    public func use(href!: String, x!: Float64 = 0.0, y!: Float64 = 0.0): SvgBuilder {
        this.adopt(SvgUse(href: Some(href), x: Some(svgPx(x)), y: Some(svgPx(y))))
    }

    public func image(
        href!: String,
        x!: Float64,
        y!: Float64,
        width!: Float64,
        height!: Float64
    ): SvgBuilder {
        this.adopt(
            SvgImage(
                href: Some(href),
                x: Some(svgPx(x)),
                y: Some(svgPx(y)),
                width: Some(svgPx(width)),
                height: Some(svgPx(height))
            )
        )
    }

    /** 填充色；作为呈现属性写在当前游标元素上。 */
    public func fill(paint: String): SvgBuilder {
        this.cursor.setAttr("fill", paint)
        this
    }

    private func adopt(element: SvgElement): SvgBuilder {
        this.container.appendElement(element)
        this.cursor = element
        this
    }
}

/** 构建器内部的数值几何统一写 `px`。 */
private func svgPx(value: Float64): SvgLength {
    SvgLength(value, unit: SvgLengthUnit.Px)
}

private func svgOptionalPx(value: ?Float64): ?SvgLength {
    match (value) {
        case Some(number) => Some(svgPx(number))
        case None => None
    }
}

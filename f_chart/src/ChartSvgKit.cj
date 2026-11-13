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
package fountain::f_chart

import fountain::f_svg.{SvgBuilder, formatSvgNumber}

/** 在 `SvgBuilder` 上画图元的薄封装：统一 class、颜色、字号与文本锚点。 */
internal class ChartSvgKit {
    let builder: SvgBuilder
    let theme: ChartTheme

    init(builder: SvgBuilder, theme: ChartTheme) {
        this.builder = builder
        this.theme = theme
    }

    func background(width: Float64, height: Float64): Unit {
        if (this.theme.background != "none") {
            this.rect(0.0, 0.0, width, height, fill: this.theme.background, className: "background")
        }
    }

    func rect(
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        fill!: ?String = None,
        stroke!: ?String = None,
        strokeWidth!: Float64 = 0.0,
        className!: String = "",
        radius!: ?Float64 = None,
        fillOpacity!: Float64 = 1.0
    ): Unit {
        this.builder.group()
        this.builder.rect(x: x, y: y, width: width, height: height, rx: radius, ry: radius)
        if (!className.isEmpty()) {
            this.builder.className(className)
        }
        match (fill) {
            case Some(color) =>
                this.builder.fill(color)
                if (fillOpacity < 1.0) {
                    this.builder.fillOpacity(fillOpacity)
                }
            case None => ()
        }
        match (stroke) {
            case Some(color) =>
                this.builder.stroke(color)
                if (strokeWidth > 0.0) {
                    this.builder.strokeWidth(strokeWidth)
                }
            case None => ()
        }
        this.builder.end()
    }

    func line(
        x1: Float64,
        y1: Float64,
        x2: Float64,
        y2: Float64,
        stroke!: String,
        strokeWidth!: Float64 = 1.0,
        className!: String = "",
        dash!: String = ""
    ): Unit {
        this.builder.group()
        this.builder.line(x1: x1, y1: y1, x2: x2, y2: y2)
        if (!className.isEmpty()) {
            this.builder.className(className)
        }
        this.builder.stroke(stroke)
        this.builder.strokeWidth(strokeWidth)
        if (!dash.isEmpty()) {
            this.builder.attr("stroke-dasharray", dash)
        }
        this.builder.end()
    }

    func text(
        x: Float64,
        y: Float64,
        content: String,
        size!: Float64,
        color!: String,
        anchor!: String = "start",
        className!: String = "",
        rotate!: Float64 = 0.0
    ): Unit {
        this.builder.group()
        this.builder.text(content: content, x: x, y: y)
        if (!className.isEmpty()) {
            this.builder.className(className)
        }
        this.builder.attr("text-anchor", anchor)
        this.builder.attr("dominant-baseline", "middle")
        this.builder.attr("font-size", formatSvgNumber(size))
        this.builder.fill(color)
        if (rotate != 0.0) {
            this.builder.attr(
                "transform",
                "rotate(${formatSvgNumber(rotate)} ${formatSvgNumber(x)} ${formatSvgNumber(y)})"
            )
        }
        this.builder.end()
    }

    func circle(
        cx: Float64,
        cy: Float64,
        radius: Float64,
        fill!: String,
        className!: String = ""
    ): Unit {
        this.builder.group()
        this.builder.circle(cx: cx, cy: cy, r: radius)
        if (!className.isEmpty()) {
            this.builder.className(className)
        }
        this.builder.fill(fill)
        this.builder.end()
    }

    func ellipse(
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        fill!: ?String = None,
        stroke!: ?String = None,
        className!: String = ""
    ): Unit {
        this.builder.group()
        this.builder.ellipse(cx: cx, cy: cy, rx: rx, ry: ry)
        if (!className.isEmpty()) {
            this.builder.className(className)
        }
        match (fill) {
            case Some(color) => this.builder.fill(color)
            case None => ()
        }
        match (stroke) {
            case Some(color) =>
                this.builder.stroke(color)
                this.builder.strokeWidth(1.0)
            case None => ()
        }
        this.builder.end()
    }

    func square(
        cx: Float64,
        cy: Float64,
        size: Float64,
        fill!: String,
        className!: String = ""
    ): Unit {
        this.rect(
            cx - size / 2.0, cy - size / 2.0, size, size,
            fill: fill, className: className
        )
    }

    func diamond(
        cx: Float64,
        cy: Float64,
        size: Float64,
        fill!: String,
        className!: String = ""
    ): Unit {
        let half = size / 2.0
        let d = "M ${formatSvgNumber(cx)} ${formatSvgNumber(cy - half)} " +
            "L ${formatSvgNumber(cx + half)} ${formatSvgNumber(cy)} " +
            "L ${formatSvgNumber(cx)} ${formatSvgNumber(cy + half)} " +
            "L ${formatSvgNumber(cx - half)} ${formatSvgNumber(cy)} Z"
        this.path(d, fill: fill, className: className)
    }

    func path(
        d: String,
        fill!: ?String = None,
        stroke!: ?String = None,
        strokeWidth!: Float64 = 1.0,
        className!: String = "",
        fillOpacity!: Float64 = 1.0
    ): Unit {
        this.builder.group()
        this.builder.path(d: d)
        if (!className.isEmpty()) {
            this.builder.className(className)
        }
        match (fill) {
            case Some(color) =>
                this.builder.fill(color)
                if (fillOpacity < 1.0) {
                    this.builder.fillOpacity(fillOpacity)
                }
            case None => ()
        }
        match (stroke) {
            case Some(color) =>
                this.builder.stroke(color)
                this.builder.strokeWidth(strokeWidth)
            case None => ()
        }
        this.builder.end()
    }
}

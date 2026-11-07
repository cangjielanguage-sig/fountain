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

/** 自动尺寸结果。 */
public struct SvgAutoSizeSize {
    public let width: Float64
    public let height: Float64

    public init(width: Float64, height: Float64) {
        this.width = width
        this.height = height
    }
}

/** `width` / `height: auto`：只认显式 auto，缺失属性保持 M5 推导。 */
public class SvgAutoSize {
    public static func rootSize(
        root: SvgRoot,
        styles: SvgComputedStyleTree,
        fallbackWidth: Float64,
        fallbackHeight: Float64,
        warnings!: ?ArrayList<String> = None
    ): SvgAutoSizeSize {
        let widthAuto = root.attr("width")?.trimAscii().toAsciiLower() == "auto"
        let heightAuto = root.attr("height")?.trimAscii().toAsciiLower() == "auto"
        let viewport = SvgViewport.from(root, fallbackWidth, fallbackHeight)
        if (!widthAuto && !heightAuto) {
            return SvgAutoSizeSize(viewport.width, viewport.height)
        }
        let box = svgBBoxOf(root, SvgBBoxRequest(
            SvgBBoxOptions(),
            Some(styles),
            viewportWidth: fallbackWidth,
            viewportHeight: fallbackHeight
        ))
        let contentWidth = match (box) {
            case Some(value) => if (value.width > 0.0) { value.width } else { 0.0 }
            case None => 0.0
        }
        let contentHeight = match (box) {
            case Some(value) => if (value.height > 0.0) { value.height } else { 0.0 }
            case None => 0.0
        }
        let viewBox = root.viewBox
        if (widthAuto && heightAuto) {
            var width = contentWidth
            var height = contentHeight
            if (width > 0.0 && height > 0.0) {
                return SvgAutoSizeSize(width, height)
            }
            match (viewBox) {
                case Some(value) =>
                    if (value.width > 0.0 && value.height > 0.0) {
                        if (width <= 0.0) {
                            width = if (height > 0.0) {
                                height * value.width / value.height
                            } else {
                                value.width
                            }
                        }
                        if (height <= 0.0) {
                            height = width * value.height / value.width
                        }
                        return SvgAutoSizeSize(width, height)
                    }
                case None => ()
            }
            return fallbackAutoSize(fallbackWidth, fallbackHeight, warnings)
        }
        if (widthAuto) {
            let height = viewport.height
            match (viewBox) {
                case Some(value) =>
                    if (value.width > 0.0 && value.height > 0.0 && height > 0.0) {
                        return SvgAutoSizeSize(height * value.width / value.height, height)
                    }
                case None => ()
            }
            if (contentWidth > 0.0) {
                return SvgAutoSizeSize(contentWidth, height)
            }
            return fallbackAutoSize(fallbackWidth, fallbackHeight, warnings)
        }
        let width = viewport.width
        match (viewBox) {
            case Some(value) =>
                if (value.width > 0.0 && value.height > 0.0 && width > 0.0) {
                    return SvgAutoSizeSize(width, width * value.height / value.width)
                }
            case None => ()
        }
        if (contentHeight > 0.0) {
            return SvgAutoSizeSize(width, contentHeight)
        }
        fallbackAutoSize(fallbackWidth, fallbackHeight, warnings)
    }
}

/** 无法确定尺寸时回退缺省值并 warning。 */
private func fallbackAutoSize(
    fallbackWidth: Float64,
    fallbackHeight: Float64,
    warnings: ?ArrayList<String>
): SvgAutoSizeSize {
    let width = if (fallbackWidth > 0.0) { fallbackWidth } else { 300.0 }
    let height = if (fallbackHeight > 0.0) { fallbackHeight } else { 150.0 }
    match (warnings) {
        case Some(list) =>
            list.add("根 svg 的 auto 尺寸无法确定（无 viewBox 且无可渲染内容），已回退 ${width}×${height}")
        case None => ()
    }
    SvgAutoSizeSize(width, height)
}

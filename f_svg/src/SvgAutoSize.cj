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
        fallbackHeight: Float64
    ): SvgAutoSizeSize {
        let widthAuto = root.attr("width")?.trimAscii().toAsciiLower() == "auto"
        let heightAuto = root.attr("height")?.trimAscii().toAsciiLower() == "auto"
        if (!widthAuto && !heightAuto) {
            let viewport = SvgViewport.from(root, fallbackWidth, fallbackHeight)
            return SvgAutoSizeSize(viewport.width, viewport.height)
        }
        let box = match (svgBBoxOf(root, SvgBBoxRequest(
            SvgBBoxOptions(),
            Some(styles),
            viewportWidth: fallbackWidth,
            viewportHeight: fallbackHeight
        ))) {
            case Some(value) => value
            case None => SvgBounds(0.0, 0.0, fallbackWidth, fallbackHeight)
        }
        var width = if (widthAuto) { box.width } else {
            SvgViewport.from(root, fallbackWidth, fallbackHeight).width
        }
        var height = if (heightAuto) { box.height } else {
            SvgViewport.from(root, fallbackWidth, fallbackHeight).height
        }
        if (widthAuto && heightAuto) {
            match (root.viewBox) {
                case Some(viewBox) =>
                    if (viewBox.width > 0.0 && viewBox.height > 0.0) {
                        let ratio = viewBox.width / viewBox.height
                        if (width <= 0.0) {
                            width = height * ratio
                        }
                        if (height <= 0.0) {
                            height = width / ratio
                        }
                    }
                case None => ()
            }
        }
        if (width <= 0.0 || height <= 0.0) {
            return SvgAutoSizeSize(fallbackWidth, fallbackHeight)
        }
        SvgAutoSizeSize(width, height)
    }
}

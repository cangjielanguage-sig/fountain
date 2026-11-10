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


/** 渐变色标。`offset` 归一为 0..1，越界钳制。 */
public class SvgStop <: SvgElement {
    private let offsetCache = SvgValueCache<Float64>()
    private let stopColorCache = SvgValueCache<SvgColor>()
    private let stopOpacityCache = SvgValueCache<Float64>()

    public init(
        offset!: ?Float64 = None,
        stopColor!: ?SvgColor = None,
        stopOpacity!: ?Float64 = None
    ) {
        super("stop")
        this.offset = offset
        this.stopColor = stopColor
        this.stopOpacity = stopOpacity
    }

    public mut prop offset: ?Float64 {
        get() {
            this.offsetCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("offset")) {
                        case Some(text) => tryParseSvgOffset(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(number) => this.setAttr("offset", formatSvgNumber(clampSvgUnit(number)))
                case None => this.removeAttr("offset")
            }
        }
    }

    /** `currentColor` 保留原始字符串，类型化字段为 `None`。 */
    public mut prop stopColor: ?SvgColor {
        get() {
            this.stopColorCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("stop-color")) {
                        case Some(text) =>
                            if (text.trimAscii().toAsciiLower() == "currentcolor") {
                                None
                            } else {
                                SvgColor.tryParse(text)
                            }
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(color) => this.setAttr("stop-color", color.toString())
                case None => this.removeAttr("stop-color")
            }
        }
    }

    public mut prop stopOpacity: ?Float64 {
        get() {
            this.stopOpacityCache.get(this.attributesVersion, {=> readFloat(this, "stop-opacity")})
        }
        set(value) {
            writeFloat(this, "stop-opacity", value)
        }
    }
}

internal func clampSvgUnit(value: Float64): Float64 {
    if (value < 0.0) {
        0.0
    } else if (value > 1.0) {
        1.0
    } else {
        value
    }
}

internal func tryParseSvgOffset(text: String): ?Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        return None
    }
    var body = trimmed
    var percent = false
    if (trimmed[trimmed.size - 1] == b'%') {
        percent = true
        body = trimmed[0..trimmed.size - 1]
    }
    match (tryParseSvgFloat(body)) {
        case Some(value) =>
            let normalized = if (percent) {
                value / 100.0
            } else {
                value
            }
            Some(clampSvgUnit(normalized))
        case None => None
    }
}

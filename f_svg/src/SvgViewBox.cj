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


/** `viewBox`：用户坐标系的窗口。宽高必须为正。 */
public struct SvgViewBox <: Equatable<SvgViewBox> & ToString {
    public let minX: Float64
    public let minY: Float64
    public let width: Float64
    public let height: Float64

    public init(minX: Float64, minY: Float64, width: Float64, height: Float64) {
        this.minX = minX
        this.minY = minY
        this.width = width
        this.height = height
    }

    public static func parse(text: String): SvgViewBox {
        let values = parseSvgNumberSequence(text, SvgListSeparator.CommaOrSpace)
        if (values.size != 4) {
            throw invalidValue("viewBox 需要 4 个数值，实际 ${values.size} 个")
        }
        if (values[2] <= 0.0 || values[3] <= 0.0) {
            throw invalidValue("viewBox 的宽高必须为正数")
        }
        SvgViewBox(values[0], values[1], values[2], values[3])
    }

    public func toString(): String {
        formatSvgNumber(this.minX) + " " + formatSvgNumber(this.minY) + " " +
        formatSvgNumber(this.width) + " " + formatSvgNumber(this.height)
    }

    public operator func ==(that: SvgViewBox): Bool {
        this.minX == that.minX && this.minY == that.minY &&
        this.width == that.width && this.height == that.height
    }
}

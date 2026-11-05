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
 * 滤镜离屏缓冲：RGBA8 非预乘，行优先。
 *
 * 每个原语产生新缓冲，避免原地读写歧义；区域外由 `fromBitmap` 补透明。
 */
public class SvgFilterBuffer {
    public let width: Int64
    public let height: Int64
    public let pixels: Array<Byte>

    public init(width: Int64, height: Int64) {
        if (width <= 0 || height <= 0) {
            throw invalidValue("滤镜缓冲尺寸必须为正，实际 ${width}×${height}")
        }
        this.width = width
        this.height = height
        this.pixels = Array<Byte>(width * height * 4, repeat: 0)
    }

    internal static func fromBitmap(
        bitmap: SvgBitmap,
        x: Int64,
        y: Int64,
        width: Int64,
        height: Int64
    ): SvgFilterBuffer {
        let buffer = SvgFilterBuffer(width, height)
        var row = 0
        while (row < height) {
            var column = 0
            while (column < width) {
                let sourceX = x + column
                let sourceY = y + row
                if (sourceX >= 0 && sourceY >= 0 &&
                    sourceX < bitmap.width && sourceY < bitmap.height) {
                    let sourceBase = (sourceY * bitmap.width + sourceX) * 4
                    let targetBase = (row * width + column) * 4
                    buffer.pixels[targetBase] = bitmap.pixels[sourceBase]
                    buffer.pixels[targetBase + 1] = bitmap.pixels[sourceBase + 1]
                    buffer.pixels[targetBase + 2] = bitmap.pixels[sourceBase + 2]
                    buffer.pixels[targetBase + 3] = bitmap.pixels[sourceBase + 3]
                }
                column++
            }
            row++
        }
        buffer
    }

    internal func copy(): SvgFilterBuffer {
        let clone = SvgFilterBuffer(this.width, this.height)
        for (index in 0..this.pixels.size) {
            clone.pixels[index] = this.pixels[index]
        }
        clone
    }

    internal func writeTo(bitmap: SvgBitmap, x: Int64, y: Int64): Unit {
        var row = 0
        while (row < this.height) {
            var column = 0
            while (column < this.width) {
                let targetX = x + column
                let targetY = y + row
                if (targetX >= 0 && targetY >= 0 &&
                    targetX < bitmap.width && targetY < bitmap.height) {
                    let sourceBase = (row * this.width + column) * 4
                    let targetBase = (targetY * bitmap.width + targetX) * 4
                    bitmap.pixels[targetBase] = this.pixels[sourceBase]
                    bitmap.pixels[targetBase + 1] = this.pixels[sourceBase + 1]
                    bitmap.pixels[targetBase + 2] = this.pixels[sourceBase + 2]
                    bitmap.pixels[targetBase + 3] = this.pixels[sourceBase + 3]
                }
                column++
            }
            row++
        }
    }
}

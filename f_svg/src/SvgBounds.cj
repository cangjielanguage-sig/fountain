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
 * 轴对齐包围盒。
 *
 * `empty()` 用负尺寸哨兵表示空；零宽或零高的退化盒是合法几何，参与并集时保留。
 */
public struct SvgBounds <: Equatable<SvgBounds> & ToString {
    public let x: Float64
    public let y: Float64
    public let width: Float64
    public let height: Float64

    public init(x: Float64, y: Float64, width: Float64, height: Float64) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
    }

    public static func empty(): SvgBounds {
        SvgBounds(0.0, 0.0, -1.0, -1.0)
    }

    public func isEmpty(): Bool {
        this.width < 0.0 || this.height < 0.0
    }

    public func union(that: SvgBounds): SvgBounds {
        if (this.isEmpty()) {
            return that
        }
        if (that.isEmpty()) {
            return this
        }
        let left = if (this.x < that.x) { this.x } else { that.x }
        let top = if (this.y < that.y) { this.y } else { that.y }
        let thisRight = this.x + this.width
        let thatRight = that.x + that.width
        let thisBottom = this.y + this.height
        let thatBottom = that.y + that.height
        let right = if (thisRight > thatRight) { thisRight } else { thatRight }
        let bottom = if (thisBottom > thatBottom) { thisBottom } else { thatBottom }
        SvgBounds(left, top, right - left, bottom - top)
    }

    public func intersect(that: SvgBounds): SvgBounds {
        if (this.isEmpty() || that.isEmpty()) {
            return SvgBounds.empty()
        }
        let thisRight = this.x + this.width
        let thatRight = that.x + that.width
        let thisBottom = this.y + this.height
        let thatBottom = that.y + that.height
        let left = if (this.x > that.x) { this.x } else { that.x }
        let top = if (this.y > that.y) { this.y } else { that.y }
        let right = if (thisRight < thatRight) { thisRight } else { thatRight }
        let bottom = if (thisBottom < thatBottom) { thisBottom } else { thatBottom }
        if (right < left || bottom < top) {
            return SvgBounds.empty()
        }
        SvgBounds(left, top, right - left, bottom - top)
    }

    /** 四角变换后取轴对齐包围盒（保守但不会漏点）。 */
    public func transform(matrix: SvgMatrix): SvgBounds {
        if (this.isEmpty()) {
            return SvgBounds.empty()
        }
        let p0 = matrix.apply(SvgPoint(this.x, this.y))
        let p1 = matrix.apply(SvgPoint(this.x + this.width, this.y))
        let p2 = matrix.apply(SvgPoint(this.x + this.width, this.y + this.height))
        let p3 = matrix.apply(SvgPoint(this.x, this.y + this.height))
        var minX = p0.x
        var maxX = p0.x
        var minY = p0.y
        var maxY = p0.y
        for (point in [p1, p2, p3]) {
            if (point.x < minX) {
                minX = point.x
            }
            if (point.x > maxX) {
                maxX = point.x
            }
            if (point.y < minY) {
                minY = point.y
            }
            if (point.y > maxY) {
                maxY = point.y
            }
        }
        SvgBounds(minX, minY, maxX - minX, maxY - minY)
    }

    public func inflate(amount: Float64): SvgBounds {
        if (this.isEmpty()) {
            return SvgBounds.empty()
        }
        SvgBounds(this.x - amount, this.y - amount, this.width + 2.0 * amount, this.height + 2.0 * amount)
    }

    public func toString(): String {
        formatSvgNumber(this.x) + "," + formatSvgNumber(this.y) + "," +
        formatSvgNumber(this.width) + "," + formatSvgNumber(this.height)
    }

    public operator func ==(that: SvgBounds): Bool {
        this.x == that.x && this.y == that.y && this.width == that.width && this.height == that.height
    }
}

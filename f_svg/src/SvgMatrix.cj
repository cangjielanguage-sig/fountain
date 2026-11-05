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

import std.math.*

private const SVG_PI = 3.141592653589793
private const SVG_INVERT_EPSILON = 1e-12

/** 二维点。 */
public struct SvgPoint <: Equatable<SvgPoint> & ToString {
    public let x: Float64
    public let y: Float64

    public init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }

    public func toString(): String {
        formatSvgNumber(this.x) + "," + formatSvgNumber(this.y)
    }

    public operator func ==(that: SvgPoint): Bool {
        this.x == that.x && this.y == that.y
    }
}

/**
 * SVG 2D 仿射矩阵 `[a c e; b d f; 0 0 1]`。
 *
 * 点按列向量右乘：`x' = a*x + c*y + e`，`y' = b*x + d*y + f`。
 */
public struct SvgMatrix <: Equatable<SvgMatrix> & ToString {
    public let a: Float64
    public let b: Float64
    public let c: Float64
    public let d: Float64
    public let e: Float64
    public let f: Float64

    public init(a: Float64, b: Float64, c: Float64, d: Float64, e: Float64, f: Float64) {
        this.a = a
        this.b = b
        this.c = c
        this.d = d
        this.e = e
        this.f = f
    }

    public static let identity = SvgMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

    /** `this × that`：先应用 `that`，再应用 `this`。 */
    public func multiply(that: SvgMatrix): SvgMatrix {
        SvgMatrix(
            this.a * that.a + this.c * that.b,
            this.b * that.a + this.d * that.b,
            this.a * that.c + this.c * that.d,
            this.b * that.c + this.d * that.d,
            this.a * that.e + this.c * that.f + this.e,
            this.b * that.e + this.d * that.f + this.f
        )
    }

    public func apply(point: SvgPoint): SvgPoint {
        SvgPoint(
            this.a * point.x + this.c * point.y + this.e,
            this.b * point.x + this.d * point.y + this.f
        )
    }

    public func determinant(): Float64 {
        this.a * this.d - this.b * this.c
    }

    /** 不可逆（行列式接近 0）时返回 `None`。 */
    public func invert(): ?SvgMatrix {
        let det = this.determinant()
        if (abs(det) < SVG_INVERT_EPSILON) {
            return None
        }
        SvgMatrix(
            this.d / det,
            -this.b / det,
            -this.c / det,
            this.a / det,
            (this.c * this.f - this.d * this.e) / det,
            (this.b * this.e - this.a * this.f) / det
        )
    }

    public static func translate(tx: Float64, ty: Float64): SvgMatrix {
        SvgMatrix(1.0, 0.0, 0.0, 1.0, tx, ty)
    }

    public static func scale(sx: Float64, sy: Float64): SvgMatrix {
        SvgMatrix(sx, 0.0, 0.0, sy, 0.0, 0.0)
    }

    public static func rotate(degrees: Float64): SvgMatrix {
        let radians = degrees * SVG_PI / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        SvgMatrix(cosine, sine, -sine, cosine, 0.0, 0.0)
    }

    public static func rotateAround(degrees: Float64, cx: Float64, cy: Float64): SvgMatrix {
        translate(cx, cy).multiply(rotate(degrees)).multiply(translate(-cx, -cy))
    }

    public static func skewX(degrees: Float64): SvgMatrix {
        SvgMatrix(1.0, 0.0, tan(degrees * SVG_PI / 180.0), 1.0, 0.0, 0.0)
    }

    public static func skewY(degrees: Float64): SvgMatrix {
        SvgMatrix(1.0, tan(degrees * SVG_PI / 180.0), 0.0, 1.0, 0.0, 0.0)
    }

    public func toString(): String {
        formatSvgNumber(this.a) + "," + formatSvgNumber(this.b) + "," + formatSvgNumber(this.c) + "," +
        formatSvgNumber(this.d) + "," + formatSvgNumber(this.e) + "," + formatSvgNumber(this.f)
    }

    public operator func ==(that: SvgMatrix): Bool {
        this.a == that.a && this.b == that.b && this.c == that.c &&
        this.d == that.d && this.e == that.e && this.f == that.f
    }
}

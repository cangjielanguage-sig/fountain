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

/** 新增 `vector-effect` 的矩阵修正。 */
public class SvgVectorEffect2 {
    /**
     * 按 `non-scaling-size → non-rotation → fixed-position` 顺序修正矩阵。
     *
     * `local` 只用于 `fixed-position`：丢弃祖先累积，仅保留元素自身矩阵。
     */
    public static func apply(
        matrix: SvgMatrix,
        effects: Array<SvgVectorEffect>,
        local!: SvgMatrix = SvgMatrix.identity
    ): SvgMatrix {
        var result = matrix
        var nonScalingSize = false
        var nonRotation = false
        var fixedPosition = false
        for (effect in effects) {
            match (effect.toString()) {
                case "non-scaling-size" => nonScalingSize = true
                case "non-rotation" => nonRotation = true
                case "fixed-position" => fixedPosition = true
                case _ => ()
            }
        }
        if (nonScalingSize) {
            let (rotation, tx, ty) = decompose(result)
            result = SvgMatrix.translate(tx, ty).multiply(SvgMatrix.rotate(rotation))
        }
        if (nonRotation) {
            let (_, tx, ty, sx, sy) = decomposeScale(result)
            result = SvgMatrix.translate(tx, ty).multiply(SvgMatrix.scale(sx, sy))
        }
        if (fixedPosition) {
            result = local
        }
        result
    }

    private static func decompose(matrix: SvgMatrix): (Float64, Float64, Float64) {
        let rotation = atan2(matrix.b, matrix.a) * 180.0 / 3.141592653589793
        (rotation, matrix.e, matrix.f)
    }

    private static func decomposeScale(
        matrix: SvgMatrix
    ): (Float64, Float64, Float64, Float64, Float64) {
        let rotation = atan2(matrix.b, matrix.a) * 180.0 / 3.141592653589793
        let sx = sqrt(matrix.a * matrix.a + matrix.b * matrix.b)
        let sy = sqrt(matrix.c * matrix.c + matrix.d * matrix.d)
        (rotation, matrix.e, matrix.f, sx, sy)
    }
}

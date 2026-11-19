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

/** 点列表，用于 `polyline` / `polygon` 的 `points`。 */
public struct SvgPointList <: Equatable<SvgPointList> & ToString {
    public let points: Array<SvgPoint>

    public init(points: Array<SvgPoint>) {
        this.points = points
    }

    public static func parse(text: String): SvgPointList {
        let values = parseSvgNumberSequence(text, SvgListSeparator.CommaOrSpace)
        if (values.size % 2 != 0) {
            throw invalidValue("点列表的数字个数必须为偶数，实际 ${values.size} 个")
        }
        let points = ArrayList<SvgPoint>()
        var index = 0
        while (index < values.size) {
            points.add(SvgPoint(values[index], values[index + 1]))
            index += 2
        }
        SvgPointList(points.toArray())
    }

    public func toString(): String {
        let out = StringBuilder()
        for (index in 0..this.points.size) {
            if (index > 0) {
                out.append(" ")
            }
            out.append(this.points[index].toString())
        }
        out.toString()
    }

    public operator func ==(that: SvgPointList): Bool {
        this.points == that.points
    }
}

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
import fountain::f_base.*

/** `pathLength` 校准：返回 `实际弧长 / 声明长度`，消费者乘该比例。 */
public class SvgPathLength {
    public static func ratio(element: SvgElement, actualLength: Float64): Float64 {
        ratio(element, actualLength, ArrayList<String>())
    }

    public static func ratio(
        element: SvgElement,
        actualLength: Float64,
        warnings: ArrayList<String>
    ): Float64 {
        let text = match (element.attr("pathLength")) {
            case Some(value) => value.trimAscii()
            case None => return 1.0
        }
        let declared = match (tryParseSvgFloat(text)) {
            case Some(value) => value
            case None =>
                warnings.add("pathLength 的值「${text}」不是有限数字，已忽略")
                return 1.0
        }
        if (!isFiniteSvgNumber(declared) || declared <= 0.0) {
            warnings.add("pathLength 必须为正的有限数，实际「${text}」，已忽略")
            return 1.0
        }
        if (!isFiniteSvgNumber(actualLength) || actualLength <= 0.0) {
            return 1.0
        }
        actualLength / declared
    }
}

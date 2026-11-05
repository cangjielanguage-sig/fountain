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

/** 数字列表的分隔符要求。 */
public enum SvgListSeparator <: Equatable<SvgListSeparator> & ToString {
    /** 逗号或空白均可（默认）。 */
    | CommaOrSpace
    | Comma
    | Space

    public operator func ==(that: SvgListSeparator): Bool {
        match ((this, that)) {
            case (CommaOrSpace, CommaOrSpace) => true
            case (Comma, Comma) => true
            case (Space, Space) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case CommaOrSpace => "CommaOrSpace"
            case Comma => "Comma"
            case Space => "Space"
        }
    }
}

/** 数字列表。 */
public struct SvgNumberList <: Equatable<SvgNumberList> & ToString {
    public let values: Array<Float64>

    public init(values: Array<Float64>) {
        this.values = values
    }

    public static func parse(
        text: String,
        separator!: SvgListSeparator = SvgListSeparator.CommaOrSpace
    ): SvgNumberList {
        SvgNumberList(parseSvgNumberSequence(text, separator))
    }

    public func toString(): String {
        let out = StringBuilder()
        for (index in 0..this.values.size) {
            if (index > 0) {
                out.append(",")
            }
            out.append(formatSvgNumber(this.values[index]))
        }
        out.toString()
    }

    public operator func ==(that: SvgNumberList): Bool {
        this.values == that.values
    }
}

/**
 * 解析逗号 / 空白分隔的数字序列。
 *
 * 逗号最多一个；`Comma` 模式要求必须有逗号，`Space` 模式禁止逗号，
 * `CommaOrSpace` 两者均可并允许 `-1-2` 这类符号紧邻写法。
 */
internal func parseSvgNumberSequence(text: String, separator: SvgListSeparator): Array<Float64> {
    let bytes = text.unsafeBytes()
    let values = ArrayList<Float64>()
    var i = skipSvgSpaces(bytes, 0)
    if (i >= bytes.size) {
        return Array<Float64>()
    }
    while (true) {
        match (scanSvgNumber(text, i)) {
            case Some(token) =>
                values.add(requireFinite(token.value, "列表数值"))
                i = token.end
            case None => throw invalidValue("列表中出现非法数字")
        }
        i = skipSvgSpaces(bytes, i)
        if (i >= bytes.size) {
            break
        }
        var hadComma = false
        if (bytes[i] == b',') {
            hadComma = true
            i = skipSvgSpaces(bytes, i + 1)
            if (i >= bytes.size || bytes[i] == b',') {
                throw invalidValue("列表出现多余的逗号")
            }
        }
        match (separator) {
            case Comma => if (!hadComma) {
                throw invalidValue("列表要求使用逗号分隔")
            }
            case Space => if (hadComma) {
                throw invalidValue("列表不允许逗号分隔")
            }
            case CommaOrSpace => ()
        }
        if (!isNumberStart(bytes[i])) {
            throw invalidValue("列表中出现非法字符")
        }
    }
    values.toArray()
}

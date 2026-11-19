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

/**
 * `begin` / `end` 表达式的不可变项列表。
 *
 * 每个静态工厂返回新实例；`join` 复制两侧项后返回新实例，不修改入参，
 * 因此同一个表达式可安全复用于多个动画。时间项只保存调用方输入，
 * 生成侧不解析、不校验、不改写。
 */
public class SvgBegin <: ToString {
    private let items: ArrayList<String>

    private init(items: ArrayList<String>) {
        this.items = items
    }

    /** 绝对偏移：秒数加 `s`。 */
    public static func offset(seconds: Float64): SvgBegin {
        SvgBegin(ArrayList<String>([formatSvgNumber(seconds) + "s"]))
    }

    /** 时钟字符串原样保存，如 `2s`、`500ms`。 */
    public static func clock(value: String): SvgBegin {
        SvgBegin(ArrayList<String>([value]))
    }

    /** `id.begin` 或 `id.end`。 */
    public static func at(id: String, begin!: Bool = true): SvgBegin {
        SvgBegin(ArrayList<String>([id + if (begin) {
            ".begin"
        } else {
            ".end"
        }]))
    }

    /** `id.end` 加带符号秒数；零偏移省略符号。 */
    public static func after(id: String): SvgBegin {
        after(id, 0.0)
    }

    /** `id.end` 加带符号秒数；零偏移省略符号。 */
    public static func after(id: String, offset: Float64): SvgBegin {
        let text = formatSvgNumber(offset)
        let suffix = if (text == "0") {
            ""
        } else if (text.startsWith("-")) {
            text + "s"
        } else {
            "+" + text + "s"
        }
        SvgBegin(ArrayList<String>([id + ".end" + suffix]))
    }

    /** `id.repeat(n)`。 */
    public static func repeatOf(id: String, iteration: Int64): SvgBegin {
        SvgBegin(ArrayList<String>([id + ".repeat(" + iteration.toString() + ")"]))
    }

    /** 事件名原样保存，如 `click`、`mouseover`。 */
    public static func event(name: String): SvgBegin {
        SvgBegin(ArrayList<String>([name]))
    }

    /** `indefinite`。 */
    public static func indefinite(): SvgBegin {
        SvgBegin(ArrayList<String>(["indefinite"]))
    }

    /** 调用方给出的原始时间项，原样保存。 */
    public static func literal(value: String): SvgBegin {
        SvgBegin(ArrayList<String>([value]))
    }

    /** 追加另一表达式，返回新实例；两侧入参均不被修改。 */
    public func join(other: SvgBegin): SvgBegin {
        let merged = ArrayList<String>()
        for (item in this.items) {
            merged.add(item)
        }
        for (item in other.items) {
            merged.add(item)
        }
        SvgBegin(merged)
    }

    /** 分号列表，参与项按调用顺序排列。 */
    public func toString(): String {
        joinCssStrings(this.items, "; ")
    }
}

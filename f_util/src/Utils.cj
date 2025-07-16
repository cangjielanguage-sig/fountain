/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_util

import std.regex.Regex
import std.convert.Parsable
import f_regex.RegexFromString

/**
 * compute parameter such as 123KB 24M etc。 to a UInt64,
 */
public func computeBytes(size: String): Option<Int64> {
    let sizeRegex = #"^(\d+)([kmgtpezyKMGTPEZY]?)[bB]?$"#.regex(solid: true)
    let matched = sizeRegex.find(size, group: true).getOrThrow()
    let num = Int64.parse(matched.matchString(1))
    if (matched.groupCount() >= 2) {
        let unit = matched.matchString(2)
        return computeBytes(num, unit)
    }
    return num
}

public func computeBytes(n: Int64, unit: String): Option<Int64> {
    let uniteq = unit.toAsciiLower()
    if (uniteq == "b") {
        n
    } else if (uniteq == "k" || uniteq == "kb") {
        n * 1024
    } else if (uniteq == "m" || uniteq == "mb") {
        n * 1024 * 1024
    } else if (uniteq == "g" || uniteq == "gb") {
        n * 1024 * 1024 * 1024
    } else if (uniteq == "t" || uniteq == "tb") {
        n * 1024 * 1024 * 1024 * 1024
    } else if (uniteq == "p" || uniteq == "pb") {
        n * 1024 * 1024 * 1024 * 1024 * 1024
    } else if (uniteq == "e" || uniteq == "eb") {
        n * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
    } else if (uniteq == "z" || uniteq == "zb") {
        n * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
    } else if (uniteq == "y" || uniteq == "yb") {
        n * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
    }
    throw IllegalArgumentException("not supported byte unit: ${unit}")
}

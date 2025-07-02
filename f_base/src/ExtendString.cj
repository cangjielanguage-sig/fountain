/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public func stringJoin<T>(parts: Array<T>, delimiter!: String = '', leftPadding!: String = '',
    rightPadding!: String = ''): String where T <: ToString {
    stringJoin<T, Array<T>>(parts, delimiter: delimiter, leftPadding: leftPadding, rightPadding: rightPadding)
}

public func stringJoin<T, C>(parts: C, delimiter!: String = '', leftPadding!: String = '', rightPadding!: String = ''): String where T <: ToString,
    C <: Iterable<T> {
    let builder = StringGenerator()
    builder.append(leftPadding)
    var i = 0
    for (p in parts) {
        if (i > 0) {
            builder.append(delimiter)
        }
        builder.append(p)
        i++
    }
    builder.append(rightPadding)
    builder.toString()
}

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

import std.convert.Parsable
import std.regex.*

public interface ExtendRange<T> where T <: Countable<T> & ToString {
    func toString(): String
}

extend<T> Range<T> <: ExtendRange<T> where T <: Countable<T> & ToString {
    public func toString(): String {
        "${start} .. ${if (isClosed) { "=" } else { String.empty }}${end} : ${step}"
    }
}

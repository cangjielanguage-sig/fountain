/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */
macro package f_mvc.macros

import std.ast.*
import f_macros.*
import f_mvc.exception.MVCException

public macro WSEndPoint(attr: Tokens, input: Tokens): Tokens {
    if (attr.size != 1) {
        diagReport(WARNING, attr, 'size of attr in @WSEndPoint should be one.', '')
    }
    if (let STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL <- attr[0].kind) {
    } else {
        diagReport(ERROR, attr, 'attr in @WSEndPoint should be string literal or single quoted string literal.', '')
        throw MVCException()
    }
    let decl = match (parseDecl(input)) {
        case d: ClassDecl => d
        case d: MacroExpandDecl => return replaceMacroInputDecl(quote(@WSEndPoint[$attr]), d).toTokens()
        case _ =>
            diagReport(ERROR, input, 'illegal decl', '')
            throw MVCException()
    }
    let identifier = decl.identifier
    let path = attr[0]

    quote(
        $input
        private let _ = {=>
            let path = $path

        }()
    )
}

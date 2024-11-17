/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_macros

public import std.ast.*
import f_macros.exception.MacroFragmentException

public func extractFirstTokenToStringLiteral(tokens: Tokens, default!: Token = `empty_string`[0]): Token {
    if (tokens.size == 0) {
        return default
    }
    match (tokens[0].kind) {
        case IDENTIFIER => Token(STRING_LITERAL, tokens[0].value)
        case STRING_LITERAL => tokens[0]
        case _ => throw MacroFragmentException("first attr must be an IDENTIFIER or a STRING_LITERAL")
    }
}
public func extractFirstTokenToIdentifier(tokens: Tokens): Token {
    match (tokens[0].kind) {
        case IDENTIFIER => tokens[0]
        case STRING_LITERAL => Token(IDENTIFIER, tokens[0].value)
        case _ => throw MacroFragmentException("first attr must be an IDENTIFIER or a STRING_LITERAL")
    }
}

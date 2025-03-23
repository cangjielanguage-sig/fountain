/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
*/
macro package f_bean.macros

import std.convert.*
import f_exception.UnreachableException
import f_macros.*

/**
 * 本宏只修饰成员变量，从fountain/app.App.config获取配置为它修饰的成员变量赋值
 */
public macro ValueInject(attr: Tokens, input: Tokens): Tokens {
    let decl = (parseDecl(input) as VarDecl).getOrThrow()
    let typeTokens = decl.declType.toTokens()
    let default = decl.expr.toTokens()
    decl.toTokens() + `assign` + generateValueTokens(attr,
        typeTokens, default)
}
func generateValueTokens(attr: Tokens, typeToken: Tokens, default: Tokens) {
    let item = extractFirstTokenToStringLiteral(attr)
    var arrayType = `empty_tokens`
    var isString = false
    var isAny = false
    var typeName = match (typeToken[0].kind) {
        case INT8 | UINT8 | INT16 | UINT16 | INT32 | UINT32 | INT64 | UINT64 | BOOLEAN | RUNE | FLOAT16 | FLOAT32 | FLOAT64 => typeToken
        case IDENTIFIER where typeToken[0].value == "String" =>
            isString = true
            typeToken
        case IDENTIFIER where typeToken[0].value == "Any" =>
            isAny = true
            typeToken
        case IDENTIFIER =>
            var typeIdentifiers = `empty_tokens`
            if (typeToken.size > 1) {
                for (i in 0..typeToken.size where typeToken[i].value != "<") {
                    typeIdentifiers += typeToken[i]
                }
            }
            if (typeIdentifiers.size < typeToken.size) {
                for (i in typeToken.size - typeIdentifiers.size..typeToken.size - 1) {
                    arrayType += typeToken[i]
                }
            }
            match (arrayType[0].kind) {
                case INT8 | UINT8 | INT16 | UINT16 | INT32 | UINT32 | INT64 | UINT64 | BOOLEAN | RUNE | FLOAT16 | FLOAT32 | FLOAT64 => isString = false
                case IDENTIFIER where arrayType[0].value == "String" => isString = true
                case IDENTIFIER where arrayType[0].value == "Any" => isAny = true
                case _ => throw UnreachableException()
            }
            typeIdentifiers
        case _ => throw UnreachableException()
    }
    if (default.size == 0) {
        quote(
            App.config
        ) + if (arrayType.size == 0 && !isString && !isAny) {
            quote(
              .getConf<$typeName>($item, $typeName.parse)
            )
        } else if (arrayType.size == 0 && isString) {
            quote(
              .getConf($item) ?? ""
            )
        } else if (arrayType.size == 0 && isAny) {
            quote(
              .getConf($item)
            )
        } else if (arrayType.size > 0 && !isString && !isAny) {
            quote(
              .getArrayConf<$arrayType>($item, $typeName.parse)
            )
        } else if (arrayType.size > 0 && (isString || isAny)) {
            quote(
              .getStringArrayConf($item)
            )
        } else {
            throw UnreachableException()
        }
    } else {
        if (arrayType.size == 0 && !isString && !isAny) {
            quote(
                App.config.getConf<$typeName>($item, $typeName.parse) ?? $default
            )
        } else if (arrayType.size == 0 && (isString || isAny)) {
            quote(
                App.config.getConf($item) ?? $default
            )
        } else if (arrayType.size > 0 && !isString && !isAny) {
            quote(
                App.config.getArrayConf<$arrayType>($item, $typeName.parse) ?? $default
            )
        } else if (arrayType.size > 0 && (isString || isAny)) {
            quote(
                App.config.getStringArrayConf($item) ?? default
            )
        } else {
            throw UnreachableException()
        }
    }
}

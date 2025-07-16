/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */
macro package f_data.validation.macros

import std.ast.*
import f_macros.*

/**
 * 预定义规则有Integer Decimal Email ChineseCellPhone IntegerRange Regex DateTime
 * Integers Pascals Camels LowerUnderScores UpperUnderScores LowerHyphens UpperHyphens，这几个都是都号分割的
 * Duration 按照Duration.toString()的格式
 * ChineseCellPhone 用法：
 *     1. 单独只指定ChineseCellPhone，
 *     2. 后面跟NationalCode [hyphen | paren | "-"]
 *        - hyphen 跟"-"等价
 *        - paren 表示用()包含国际区号
 *        - 还可以字符串字面值型指定其它分割符
 * IntegerRange 以数学区间符号定义
 * Regex 以原始字符串字面值定义
 * DateTime 以原始字符串或单行字符串形式定义
 * 所有的Validation只能作为Validations的内层宏使用，并且只能注解public var和public mut prop
 */
public macro IntegerValidation(input: Tokens): Tokens {
    dataValidation("Integer", input)
}

public macro DecimalValidation(input: Tokens): Tokens {
    dataValidation("Decimal", input)
}

public macro EmailValidation(input: Tokens): Tokens {
    dataValidation("Email", input)
}

public macro ChineseCellPhoneValidation(attr: Tokens, input: Tokens): Tokens {
    dataValidation("Integer", input)
    for (i in 0..attr.size) {
        let token = attr[i]
        match ((token.kind, token.value)) {
            case (IDENTIFIER, "NationalCode") => setItem("NationalCode", true)
            case (IDENTIFIER, "hyphen") | (STRING_LITERAL, "-") => setItem("separator", "-")
            case (IDENTIFIER, "paren") => setItem("separator", ")")
            case (STRING_LITERAL, x) => setItem("separator", x)
            case _ => throw IllegalArgumentException(
                "illegal attr for @ChineseCellPhoneValidation[], (${token.kind}, ${token.value})")
        }
    }
    input
}

public macro IntegerRangeValidation(attr: Tokens, input: Tokens): Tokens {
    dataValidation("IntegerRange", input)
    setItem("range", attr[0].value)
    input
}

public macro RegexValidation(attr: Tokens, input: Tokens): Tokens {
    dataValidation("Regex", input)
    setItem("regex", attr[0].value)
    input
}

public macro DurationValidation(input: Tokens): Tokens {
    dataValidation("Duration", input)
}

public macro DateTimeValidation(attr: Tokens, input: Tokens): Tokens {
    dataValidation("DateTime", input)
    setItem("format", attr[0].value)
    input
}

public macro IntegersValidation(input: Tokens): Tokens {
    dataValidation("Integers", input)
}

public macro PascalsValidation(input: Tokens): Tokens {
    dataValidation("Pascals", input)
}

public macro CalmesValidation(input: Tokens): Tokens {
    dataValidation("Camels", input)
}

public macro LowerUnderScoresValidation(input: Tokens): Tokens {
    dataValidation("LowerUnderScores", input)
}

public macro UpperUnderScoresValidation(input: Tokens): Tokens {
    dataValidation("UpperUnderScores", input)
}

public macro LowerHyphensScoresValidation(input: Tokens): Tokens {
    dataValidation("LowerHyphens", input)
}

public macro UpperHyphensScoresValidation(input: Tokens): Tokens {
    dataValidation("UpperHyphens", input)
}

public macro CustomisedValidation(attr: Tokens, input: Tokens): Tokens {
    dataValidation(attr[0].value, input)
    setItem("customised", true)
    input
}

func dataValidation(ruleName: String, input: Tokens): Tokens {
    assertParentContext("Validations")
    let decl = parseDecl(input)
    if (decl is VarDecl) {
        let varDecl = (decl as VarDecl).getOrThrow()
        if (!varDecl.isStatic() && varDecl.keyword.kind == VAR && varDecl.isPublic()) {
            let name = varDecl.identifier
            let varType = varDecl.declType
            setItem("name", name.value)
            setItem("type", varType.toTokens().toString())
            setItem("rule", ruleName)
            input
        } else {
            throw IllegalArgumentException(
                "annotated target must be public var or public mut prop, it is ${decl.toTokens()}")
        }
    } else if (decl is PropDecl) {
        let propDecl = (decl as PropDecl).getOrThrow()
        if (!propDecl.isStatic() && propDecl.isMut() && propDecl.isPublic()) {
            let name = propDecl.identifier
            let propType = propDecl.declType
            setItem("name", name.value)
            setItem("type", propType.toTokens().toString())
            setItem("rule", ruleName)
            input
        } else {
            throw IllegalArgumentException(
                "annotated target must be public var or public mut prop, it is ${decl.toTokens()}")
        }
    } else {
        throw IllegalArgumentException(
            "annotated target must be public var or public mut prop, it is ${decl.toTokens()}")
    }
}

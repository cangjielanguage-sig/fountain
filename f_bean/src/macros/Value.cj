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

/**
 * 修饰需要注入来自f_config.Config配置项的实例成员变量、构造函数形叁、工厂函数形参，也可以修饰顶级变量。
 * 修饰参数时必须在Constructor下面。
 * 把找到的第一个标识符作为配置项名称。
 */
public macro Value(input: Tokens): Tokens {
    for (i in 0..input.size where input[i].kind == IDENTIFIER) {
        return injectValue(input[i].value, input)
    }
    report(input, 'input of current macro @Value must be a instance member variable or a func param.')
}
/**
 * 修饰需要注入来自f_config.Config配置项的实例成员变量、构造函数形叁、工厂函数形参，也可以修饰顶级变量。
 * 修饰参数时必须在Constructor下面。
 * attr的第一个Token的value作为配置项名称，如果attr是空的相当于使用了无属性的@Value。
 */
public macro Value(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) {
        quote(
            @Value
            $input
        )
    } else {
        injectValue(attr[0].value, input)
    }
}

private func injectValue(confKey: String, input: Tokens): Tokens {
    if (insideParentContext('Constructor')) { //参数
        let (identifier, value) = if (input[0].kind == IDENTIFIER) { //普通形参
            let param = FuncParam(input)
            genParamMessage(input, confKey, param)
        } else { //成员变量形参
            let param = primaryCtorParam(input)
            genParamMessage(input, confKey, param)
        }
        setIdentifierValue(identifier, value)
        input
    } else { //成员变量
        let decl = VarDecl(input)
        let (identifier, value) = genParamMessage(input, confKey, decl.identifier.value, decl.declType,
            if (decl.assign.kind == ASSIGN) {
                decl.expr
            } else {
                None
            })
        decl.assign = Token(ASSIGN)
        decl.expr = parseExpr(value)
        decl.toTokens()
    }
}

internal func genParamMessage(input: Tokens, confKey: String, param: FuncParam): (String, Tokens) {
    genParamMessage(input, confKey, param.identifier.value, param.paramType,
        if (param.assign.kind == ASSIGN) {
            param.expr
        } else {
            None
        })
}

private func genParamMessage(input: Tokens, confKey: String, identifier: String, typeNode: TypeNode, expr: ?Expr): (String, 
    Tokens) {
    let tokens = match (typeNode) {
        case x: RefType =>
            let typeTokens = x.toTokens()
            if (typeTokens[0].kind == IDENTIFIER && typeTokens[0].value == 'Array') {
                let elementType = typeTokens[2]
                match (elementType.value) {
                    case 'String' =>
                        if (expr.isSome()) {
                            quote(getStringArrayConfig($confKey, $(identifier), $(expr.getOrThrow())))
                        } else {
                            quote(getStringArrayConfig($confKey, $(identifier)))
                        }
                    case _ =>
                        if (expr.isSome()) {
                            quote(getArrayConfig<$elementType>($confKey, $(identifier), $(expr.getOrThrow())))
                        } else {
                            quote(getArrayConfig<$elementType>($confKey, $(identifier)))
                        }
                }
            } else if (typeTokens[0].kind == IDENTIFIER && typeTokens[0].value == 'String') {
                if (expr.isSome()) {
                    quote(getStringConfig($confKey, $(identifier), $(expr.getOrThrow())))
                } else {
                    quote(getStringConfig($confKey, $(identifier)))
                }
            } else if (typeTokens[0].kind == IDENTIFIER && typeTokens[0].value == 'Duration') {
                if (expr.isSome()) {
                    quote(getConfig<$typeTokens>($confKey, $(identifier), $(expr.getOrThrow())))
                } else {
                    quote(getConfig<$typeTokens>($confKey, $(identifier)))
                }
            } else if (typeTokens[0].kind == IDENTIFIER && typeTokens[0].value == 'Option') {
                let optType = typeTokens[2]
                match (optType.value) {
                    case 'String' =>
                        if (expr.isSome()) {
                            quote(getStringConfig($confKey, $(identifier), $(expr.getOrThrow())))
                        } else {
                            quote(getStringConfig($confKey, $(identifier)))
                        }
                    case _ =>
                        if (expr.isSome()) {
                            quote(getConfig<$optType>($confKey, $(identifier), $(expr.getOrThrow())))
                        } else {
                            quote(getConfig<$optType>($confKey, $(identifier)))
                        }
                }
            } else {
                report(
                    input,
                    'macro @Value can inject value for func param and instance member variable which type is f_data.DataParsable or array with f_data.DataParsable element or String or Array<String>.'
                )
            }
        case x: PrimitiveType =>
            if (expr.isSome()) {
                quote(getConfig<$x>($confKey, $(identifier), $(expr.getOrThrow())))
            } else {
                quote(getConfig<$x>($confKey, $(identifier)))
            }
        case x: PrefixType =>
            if (expr.isSome()) {
                quote(getConfig<$(x.baseType)>($confKey, $(identifier), $(expr.getOrThrow())))
            } else {
                quote(getConfig<$(x.baseType)>($confKey, $(identifier)))
            }
        case _ => report(
            input,
            'macro @Value can inject value for func param and instance member variable which type is f_data.DataParsable or array with f_data.DataParsable element or String or Array<String>.'
        )
    }
    (identifier, tokens)
}

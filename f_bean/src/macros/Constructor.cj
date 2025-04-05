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

import std.ast.*

/**
 * 修饰构造函数或工厂函数。必须在Bean或Configuration。
 * 在Bean下面时，只有第一个Constructor生效，且不能修饰静态函数。
 * 在Configuration下面时，@Configuration里面被@Constructor修饰的所有函数都生效，且可以修饰实例函数。
 */
public macro Constructor(input: Tokens): Tokens {
    if (!(insideParentContext('Bean') || insideParentContext('Configuration'))) {
        report(input, 'macro @Constructor must be inside @Bean or @Configuration')
    }
    let decl = parseDecl(input)
    if (insideParentContext('Bean') && !(decl is PrimaryCtorDecl || decl.identifier.value == 'init' || isStatic(decl))) {
        report(input, 'if macro @Constructor is inside @Bean, it must modify a static func decl or a constructor decl')
    }
    let (constructor, params) = match (decl) {
        case x: PrimaryCtorDecl where isPublic(x) => (quote(init), x.funcParams)
        case x: FuncDecl where (isStatic(x) || x.identifier == 'init') && isPublic(x) => (quote($(x.identifier)), x
                .funcParams)
        case _ => report(input, 'macro @Constructor accept constructor decl or static func decl')
    }
    setItem('static', isStatic(decl))
    setItem('constructor', constructor)
    setItem('params', populateParams(params))
    input
}

internal func populateParams(params: ArrayList<FuncParam>) {
    let map = HashMap<String, Tokens>()
    populateParamMessages(map, 'Autowired')
    populateParamMessages(map, 'Value')
    var tokens = `empty_tokens`
    for (param in params) {
        if (tokens.size > 0) {
            tokens += `comma`
        }
        tokens += genParamMessage(param, map)
    }
    tokens
}

private func populateParamMessages(map: HashMap<String, Tokens>, childMacro: String) {
    for (msg in getChildMessages(childMacro)) {
        map[msg.getString('identifier')] = msg.getTokens('value')
    }
}

private func genParamMessage(param: FuncParam, map: HashMap<String, Tokens>): Tokens {
    let (identifier, value) = if (let Some(v) <- map.get(param.identifier.value)) {
        (param.identifier.value, v)
    } else {
        let tokens = param.toTokens()
        let typeNode = param.paramType
        let typeTokens = typeNode.toTokens()
        let typeIdentifier = typeTokens[0].value
        func genOptType() {
            let optType = typeTokens[2]
            match ((optType.kind, optType.value)) {
                case (IDENTIFIER, 'String') | (IDENTIFIER, 'Duration') => genParamMessage(tokens, param
                    .identifier
                    .value, param)
                case _ where FuncParam(quote(a: $optType)).paramType is PrimitiveType => genParamMessage(tokens,
                    param.identifier.value, param)
                case _ => genParamMessage(param.identifier.value, tokens)
            }
        }
        match (typeNode) {
            case _: RefType => match (typeIdentifier) {
                case 'Array' | 'String' | 'Duration' => genParamMessage(tokens, param.identifier.value, param)
                case 'ArrayList' | 'List' => genParamMessage(param.identifier.value, tokens)
                case 'HashMap' | 'Map' => genParamMessage(param.identifier.value, tokens)
                case 'Option' => genOptType()
                case _ => genParamMessage(param.identifier.value, tokens)
            }
            case _: PrefixType => genOptType()
            case _: PrimitiveType => genParamMessage(tokens, param.identifier.value, param)
            case _ => report(param.toTokens(), 'does not support current param type.')
        }
    }
    if (param.not.kind == NOT) {
        let name = Token(IDENTIFIER, identifier)
        quote($name:$value)
    } else {
        value
    }
}

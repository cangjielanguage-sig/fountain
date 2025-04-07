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
 * 修饰需要注入bean的实例成员变量或构造函数形参、工厂函数形参，也可以注入顶级变量。
 * 修饰参数时必须在Constructor下面。
 * 把input内的第一个标识符作为beanName，精准匹配。
 */
public macro Autowired(input: Tokens): Tokens {
    for (i in 0..input.size where input[i].kind == IDENTIFIER) {
        return autowired(input[i].value, input)
    }
    report(input, 'input of current macro @Autowired must be a instance member variable or a func param.')
}
/**
 * attr接收StringCond枚举的各种构造器，如果attr是空的相当于调用了无属性的@Autowired，也可以注入顶级变量。
 * 修饰参数时必须在Constructor下面。
 * 修饰需要注入bean的实例成员变量或构造函数形参、工厂函数形参。
 */
public macro Autowired(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) {
        quote(
         @Autowired
         $input
      )
    } else {
        autowired(attr, input)
    }
}

private func beanNameTokens(beanName: String) {
    quote(StringCond.Exactly($(beanName)))
}

internal func genParamMessage(beanName: String, input: Tokens): (String, Tokens) {
    genParamMessage(beanNameTokens(beanName), input)
}

private func genParamMessage(beanName: Tokens, input: Tokens): (String, Tokens) {
    let param = if (input[0].kind == IDENTIFIER) { //普通形参
        FuncParam(input)
    } else { //成员变量形参
        primaryCtorParam(input)
    }
    genAutowiredMessage(input, beanName, param)
}

private func autowired(beanName: String, input: Tokens): Tokens {
    autowired(beanNameTokens(beanName), input)
}

private func autowired(beanName: Tokens, input: Tokens): Tokens {
    if (insideParentContext('Constructor')) { //参数
        let (identifier, value) = genParamMessage(beanName, input)
        setIdentifierValue(identifier, value)
        input
    } else { //成员变量
        let decl = VarDecl(input)
        let (identifier, value) = genAutowiredMessage(input, beanName, decl.identifier.value, decl.declType,
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

private func genAutowiredMessage(input: Tokens, beanName: Tokens, param: FuncParam): (String, Tokens) {
    genAutowiredMessage(input, beanName, param.identifier.value, param.paramType,
        if (param.assign.kind == ASSIGN) {
            param.expr
        } else {
            None
        })
}

private func genAutowiredMessage(input: Tokens, beanName: Tokens, identifier: String, typeNode: TypeNode, expr: ?Expr): (String, 
    Tokens) {
    let typeTokens = typeNode.toTokens()
    let typeIdentifier = typeTokens[0].value
    let tokens = match (typeIdentifier) {
        case 'List' | 'ArrayList' where typeTokens[1].kind == TokenKind.LT =>
            if (expr.isSome()) {
                quote(
                    getBeanList<$(typeTokens[2 .. typeTokens.size - 1])>($beanName, $(identifier), $(expr.getOrThrow())))
            } else {
                quote(getBeanList<$(typeTokens[2 .. typeTokens.size - 1])>($beanName, $(identifier)))
            }
            match (expr) {
                case Some(e) => quote(
                    getBeanList<$(typeTokens[2 .. typeTokens.size - 1])>($beanName, $(identifier), $(e)))
                case _ => quote(getBeanList<$(typeTokens[2 .. typeTokens.size - 1])>($beanName, $(identifier)))
            }
        case 'Map' | 'HashMap' where typeTokens[1].kind == TokenKind.LT => match (expr) {
            case Some(e) => quote(getBeanMap<$(typeTokens[4 .. typeTokens.size - 1])>($beanName, $(identifier), $(e)))
            case _ => quote(getBeanMap<$(typeTokens[4 .. typeTokens.size - 1])>($beanName, $(identifier)))
        }
        case '?' => match (expr) {
            case Some(e) => quote(getBean<$(typeTokens[1 ..])>($beanName, $identifier, $e))
            case _ => quote(getBean<$(typeTokens[1 ..])>($beanName, $identifier))
        }
        case 'Option' => match (expr) {
            case Some(e) => quote(getBean<$(typeTokens[2 .. typeTokens.size -1])>($beanName, $identifier, $e))
            case _ => quote(getBean<$(typeTokens[2 .. typeTokens.size -1])>($beanName, $identifier))
        }
        case _ => match (expr) {
            case Some(e) => quote(getBean<$typeTokens>($beanName, $identifier, $e))
            case _ => quote(getBean<$typeTokens>($beanName, $identifier).getOrThrow{BeanException('bean name ' + $(beanName.toString()) + 'is not found')})
        }
    }
    (identifier, tokens)
}

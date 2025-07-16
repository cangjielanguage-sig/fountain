/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */
macro package f_aspect.macros

import std.ast.*
import f_aspect.exception.AspectException
import f_macros.*

public macro Pointcut(attr: Tokens, input: Tokens): Tokens {
    if (insideParentContext('Pointcut')) {
        return input
    }
    var decl = parseDecl(input)
    while (let m: MacroExpandDecl <- decl) {
        decl = m.macroInputDecl
    }
    match (decl) {
        case x: FuncDecl =>
            var funcDecl = `empty_tokens`
            for (t in input) {
                if (t.kind == TokenKind.LCURL) {
                    break
                }
                funcDecl += t
            }
            let params = x.funcParams
            var argVars = quote()
            var args = `lsquare`
            for (i in 0..params.size) {
                let param = params[i]
                let paramName = param.identifier
                argVars += quote(
                    let $paramName = (args[$(i)] as $(param.paramType)).getOrThrow()
                ) +
                    `nl`
                if (i > 0) {
                    args += `comma`
                }
                args += paramName
            }
            args += `rsquare`
            let qualifiedName = attr[0].value
            let funcName = x.identifier.value
            let funcType = try {
                x.declType.toTokens()
            } catch (_) {
                `empty_tokens`
            }
            let proceed = if (funcType.size == 0) {
                quote(Aspects.proceed(info, callee))
            } else {
                quote(Aspects.proceed<$funcType>(info, callee))
            }
            quote(
                $funcDecl {
                    func callee(args: Array<Any>){
                        $argVars
                        $(x.block.nodes)
                    }
                    let info = InvocationFuncInfo($qualifiedName, $funcName, $args)
                    $proceed
                }
            )
        case _ =>
            diagReport(ERROR, input, '${decl.identifier.value} must be a func decl', '')
            throw AspectException()
    }
}

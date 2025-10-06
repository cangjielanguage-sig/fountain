/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
macro package f_aspect.macros

import std.ast.*
import f_aspect.exception.AspectException
import f_macros.*

public macro Pointcut(input: Tokens): Tokens {
    if (insideParentContext('Pointcut')) {
        return input
    }
    match(parseDecl(input)){
        case x: FuncDecl => pointcut(x)
        case x: ClassDecl => 
            expandClassDecl(x)
        case x: MacroExpandDecl => 
            let d = extract(x)
            let tokens = pointcut(d)
            x.macroInputDecl = parseDecl(tokens)
            x.macroInputs = tokens
            x.toTokens()
        case x => 
            diagReport(ERROR, input, '${x.identifier.value} must be a func decl', '')
            throw AspectException()
    }
}
private func pointcut(decl: Decl): Tokens {
    let tokens = decl.toTokens()
    match (decl) {
        case x: FuncDecl =>
            let funcDecl = quote()
            for (t in tokens) {
                if (t.kind == TokenKind.LCURL) {
                    break
                }
                funcDecl.append(t)
            }
            let params = x.funcParams
            let argVars = quote()
            let args = quote($(`lsquare`))
            for (i in 0..params.size) {
                let param = params[i]
                let paramName = param.identifier
                argVars.append(quote(
                    let $paramName = (args[$(i)] as $(param.paramType)).getOrThrow()
                )).append(`nl`)
                if (i > 0) {
                    args.append( `comma`)
                }
                args.append(paramName)
            }
            args.append(`rsquare`)
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
                    let _tYpEInfO__ = TypeInfo.of(this).qualifiedName
                    let info = InvocationFuncInfo(_tYpEInfO__, $funcName, $args)
                    $proceed
                }
            )
        case x: ClassDecl => expandClassDecl(x)
        case _ =>
            diagReport(ERROR, tokens, '${decl.identifier.value} must be a func decl', '')
            throw AspectException()
    }
}
private func expandClassDecl(decl: ClassDecl): Tokens {
    let decls = decl.body.decls
    for(i in 0 .. decls.size) {
        let d = decls[i]
        if (d is FuncDecl && !isStatic(d) && isPublic(d)) {
            decls[i] = parseDecl(quote(
                @Pointcut
                $d
            ))
        } else if (let md: MacroExpandDecl <- d && let ed: FuncDecl <- extract(md) && !isStatic(ed) && isPublic(ed)) {
            let tokens = quote(
                @Pointcut
                $ed
            )
            let fd = parseDecl(tokens)
            md.macroInputDecl = fd
            md.macroInputs = tokens
        }
    }
    decl.toTokens()
}
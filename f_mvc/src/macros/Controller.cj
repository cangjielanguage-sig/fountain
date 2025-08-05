/*
   Copyright (c) 2022 WuJingrun（吴京润）
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
public import f_bean.macros.*

public macro Controller(input: Tokens): Tokens {
    let tokens = generate(input)
    quote(
        @Bean
        $input
        $tokens
    )
}

func generate(input: Tokens): Tokens {
    var tokens = `empty_tokens`
    let decl = match(parseDecl(input)){
        case x: ClassDecl => x
        case x: MacroExpandDecl => 
            var y = x
            while(let m: MacroExpandDecl <- y.macroInputDecl) {
                y = m
            }
            if(let d: ClassDecl <- y.macroInputDecl) {
                d
            }else{
                diagReport(ERROR, y.macroInputs, 'illegal decl', '')
                throw MVCException()
            }
        case _ => 
            diagReport(ERROR, input, 'illegal decl', '')
            throw MVCException()
    }
    let klass = decl.identifier
    for (d in decl.body.decls) {
        var md: Decl = d
        while(let m: MacroExpandDecl <- md && let _: MacroExpandDecl <- m.macroInputDecl){
            md = m
        }
        if (let m: MacroExpandDecl <- md && let f: FuncDecl <- extract(m) && !isStatic(f) && isPublic(f)) {
            let (argTypes, argExprs, args) = generateArgs(f)
            tokens += quote(
                private let _ = {=>
                    let fname = $(f.identifier.value)
                    let metas = MVCStarter.generateAndRegister<$klass>($(f.identifier.value), $argTypes)
                    for(meta in metas){
                        meta.setHandle{controller, ctx, patterns => 
                            $argExprs
                            controller.$(f.identifier)($args)
                        }
                    }
                }()
            ) +
                `nl`
        }
    }
    tokens
}

func generateArgs(decl: FuncDecl): (Tokens, Tokens, Tokens) {
    var argTypes = `lsquare`
    var exprs = `empty_tokens`
    var args = `lsquare`
    for (p in decl.funcParams) {
        let pname = p.identifier.value
        let ptype = p.paramType
        let defaultValue = try {
            p.expr.toTokens()
        } catch (_) {
            `empty_tokens`
        }
        let default = if (defaultValue.size > 0) {
            quote(, $defaultValue)
        } else {
            `empty_tokens`
        }
        exprs += quote(
            let $(p.identifier) = 
            if (meta.isMultipart($pname)) {
                meta.multipart<$ptype>(ctx, $pname)
            } else {
                match(None<$ptype>){
                    case _: ?HttpContext => ctx
                    case _: ?HttpHeaders => ctx.request.headers
                    case _: ?HttpRequest => ctx.request
                    case _: ?HttpResponseBuilder => ctx.responseBuilder
                    case _ => meta.extract<$ptype>(ctx, $pname $default)
                } as $ptype
            }.getOrThrow()
        ) +
            `nl`
        let named = try {
            p.not.kind == TokenKind.NOT
        } catch (_) {
            false
        }
        if (args.size > 0) {
            args += `comma`
        }
        args += if (named) {
            quote($(p.identifier): $(p.identifier))
        } else {
            quote($(p.identifier))
        }
        if (argTypes.size > 1) {
            argTypes += `comma`
        }
        argTypes += quote(
            TypeInfos.get<$(p.paramType)>()
        )
    }
    argTypes += `rsquare`
    args += `rsquare`
    (argTypes, exprs, args)
}

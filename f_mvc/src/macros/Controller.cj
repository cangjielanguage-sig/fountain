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
macro package f_mvc.macros

/**
 * http mvc控制器的宏。请确保作为控制器的类型一定是class，且只有作为请求处理的函数是公共的。
 * 请求处理函数只接收实现了接口fountain.data.DataFields<T>的类型或HttpContext HttpHeaders HttpRequest HttpResponseBuilderw做参数
 * 如果有其它公共函数，或者试图使用其它类型作为请求处理函数的参数将会在本宏展开时发生编译错误。
 * 所有基本类型 Duration DateTime String 都实现了DataFields<T>接口，可以直接用。
 * 使用fountain.data.macros.DataAssist，@DataAssist[fields]注解的类也实现了DataFields<T>。
 */
public macro Controller(input: Tokens): Tokens {
    let tokens = generate(input)
    quote(
        @Bean
        $input
        $tokens
    )
}

private func generate(input: Tokens): Tokens {
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
                return input
            }
        case _ => 
            diagReport(ERROR, input, 'illegal decl', '')
            return input
    }
    let klass = decl.identifier
    for (d in decl.body.decls) {
        if (let m: MacroExpandDecl <- d && let f: FuncDecl <- extract(m) && !isStatic(f) && isPublic(f)) {
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

private func generateArgs(decl: FuncDecl): (Tokens, Tokens, Tokens) {
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
            quote(None<T>)
        }
        exprs += quote(
            let $(p.identifier) = if(isMultipart(name)){
                multipart<$ptype>(ctx, name)
            }else{
                match(None<$ptype>){
                    case x: ?HttpContext => ctx
                    case x: ?HttpRequest => ctx.request
                    case x: ?HttpHeaders => ctx.request.headers
                    case _: ?HttpResponseBuilder => ctx.responseBuilder
                    case _ => meta.extract<$ptype>(ctx, $pname $default)
                }
            }
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

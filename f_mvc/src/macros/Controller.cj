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
 * @Controller宏的属性用于@Bean[$attr]，具体用法见@Bean宏的解释。
 */
public macro Controller(input: Tokens): Tokens {
    generateController(`empty_tokens`, input)
}
public macro Controller(attr: Tokens, input: Tokens): Tokens {
    generateController(attr, input)
}

private func generateController(attr: Tokens, input: Tokens): Tokens {
    for(t in input where t.kind == COALESCING){
        diagReport(ERROR, input, '?? cannot be used in Controller class at Cangjie version 1.0.3 due to a compiler bug, or the project cannot be compiled.', '')
        throw Exception()
    }
    let beanAttr = if(attr.size > 0){
        quote([$attr])
    }else{
        `empty_tokens`
    }
    quote(
        @Bean$beanAttr
        $input
        $(generate(input))
    )
}
private func generate(input: Tokens): Tokens {
    let decl = match(parseDecl(input)){
        case x: ClassDecl => x
        case x: MacroExpandDecl => 
            let d = extract(x)
            return generate(d.toTokens())
        case _ => 
            diagReport(ERROR, input, 'illegal decl', '')
            return input
    }
    var tokens = quote()
    let klass = decl.identifier
    for (d in decl.body.decls) {
        if (let m: MacroExpandDecl <- d && let f: FuncDecl <- extract(m) && !isStatic(f) && isPublic(f)) {
            let (argTypes, argExprs, args, anyargs) = generateArgs(f)
            tokens += topMacroAnonymousClosure(quote(
                let fname = $(f.identifier.value)
                    let metas = MVCStarter.generateAndRegister<$klass>($(f.identifier.value), $argTypes)
                    for(meta in metas){
                        meta.setHandle{controller: $klass, ctx: HttpContext, patterns: HttpRequestPathPatterns => 
                            let start = MonoTime.now()
                            $argExprs
                            $anyargs
                            var any: ?Any = None<Any>
                            var ex = None<Exception>
                            try {
                                if (meta.checkAuth(ctx, anyArgs)) {
                                    let returned: Any = controller.$(f.identifier)($args)
                                    any = returned
                                    return returned
                                }
                            } catch(e: Exception) {
                                ex = e
                            } finally {
                                meta.accessLog<$klass>(start, ctx, anyArgs, any, ex)
                            }
                        }
                    }
            )) + `nl`
        }
    }
    tokens
}

private func generateArgs(decl: FuncDecl): (Tokens, Tokens, Tokens, Tokens) {
    var argTypes = quote([)
    var exprs = quote()
    var args = quote()
    var anyArgs = quote(let anyArgs = ArrayList<Any>())
    for (fp in decl.funcParams) {
        let p: FuncParam = match(fp){
            case x: MacroExpandParam => extract(x)
            case x => x
        }
        let pname = p.identifier.value
        let ptype = p.paramType
        let defaultValue = try {
            p.expr.toTokens()
        } catch (_) {
            `empty_tokens`
        }
        let default = if (defaultValue.size > 0) {
            quote($defaultValue)
        } else {
            quote(None<$ptype>)
        }
        exprs += quote(
            let $(p.identifier) = meta.extract<$ptype>(ctx, $pname, $default)$(`nl`)
        )
        let named = try {
            p.not.kind == TokenKind.NOT
        } catch (_) {
            false
        }
        if (args.size > 0) {
            args += `comma`
        }
        let arg = if (named) {
            quote($(p.identifier): $(p.identifier))
        } else {
            quote($(p.identifier))
        }
        args += arg
        anyArgs += `nl` + quote(anyArgs.add($(p.identifier)))
        if (argTypes.size > 1) {
            argTypes += `comma`
        }
        argTypes += quote(
            TypeInfos.get<$(ptype)>()
        )
    }
    argTypes += `rsquare`
    (argTypes, exprs, args, anyArgs)
}

/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
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
    let decl = ClassDecl(input)
    let klass = decl.identifier
    for(d in decl.body.decls){
        match(d){
            case f: FuncDecl where !isStatic(f) && isPublic(f) =>
                let argTypes = generateArgTypes(f)
                let (argExprs, args) = generateArgValues(f)
                tokens += quote(
                    private let _ = {=>
                        let fname = $(f.identifier.value)
                        let metas = MVCLauncher.generateAndRegister<$klass>($(f.identifier.value), $argTypes)
                        for(meta in metas){
                            meta.setHandle{controller, ctx, patterns => 
                                $argExprs
                                controller.$(f.identifier)($args)
                            }
                        }
                    }()
                ) + `nl`
            case _ => continue
        }
    }
    tokens
}
func generateArgTypes(decl: FuncDecl): Tokens {
    var tokens = `lsquare`
    for(p in decl.funcParams){
        if(tokens.size > 1){
            tokens += `comma`
        }
        tokens += quote(
            TypeInfos.get<$(p.paramType)>()
        )
    }
    tokens + `rsquare`
}
func generateArgValues(decl: FuncDecl): (Tokens, Tokens) {
    var exprs = `empty_tokens`
    var tokens = `empty_tokens`
    for(p in decl.funcParams){
        let pname = p.identifier.value
        let ptype = p.paramType
        let defaultValue = try{
            p.expr.toTokens()
        }catch(_){
            `empty_tokens`
        }
        let default = if(defaultValue.size > 0){
            quote(, $defaultValue)
        }else{
            `empty_tokens`
        }
        exprs += quote(
            let $(p.identifier) = 
            if(meta.isMultipart($pname)){
                meta.multipart<$ptype>(ctx, $pname)
            }else{
                meta.extract<$ptype>(ctx, $pname $default)
            }
        ) + `nl`
        let named = try{
            if(let NOT <- p.not.kind){
                true
            }else{
                false
            }
        }catch(_){
            false
        }
        if(tokens.size > 0){
            tokens += `comma`
        }
        tokens += if(named){
            quote($(p.identifier): $(p.identifier))
        }else{
            quote($(p.identifier))
        }
    }
    (exprs, tokens)
}
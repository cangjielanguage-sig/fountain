/*
Copyright (c) 2026 WuJingrun（吴京润）

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
macro package fountain::f_rpc.macros

public import fountain::f_bean.macros.*
import std.ast.*
import fountain::f_macros.*

public macro RPCServer(input: Tokens): Tokens {
    return RPCServer(empty_tokens, input)
}
/**
 * attr 作为fountain::f_bean.macros.Bean宏的属性，可以没有
 */
public macro RPCServer(attr: Tokens, input: Tokens): Tokens {
    expand(attr, parseDecl(input))
}
private func expand(attr: Tokens, input: Decl): Tokens {
    match(input){
        case x: ClassDecl => 
            quote(
                @Bean[$attr]
                $input
                private let _ = {=>
                    $(extractFuncs(x))
                }()
            )
        case x: MacroExpandDecl => expand(attr, extract(x))
        case x => 
            diagReport(ERROR, input, '${x.identifier.value} must be a class decl', '')
            return `empty_tokens`
    }
}

private func extractFuncs(decl: ClassDecl): Tokens {
    let klass = decl.identifier + if(decl.isGenericDecl){
        decl.genericParam
    }else{
        `empty_tokens`
    }
    var funcs = `empty_tokens`
    for(d in decl.body.decls){
        if(let f: FuncDecl <- d && isPublic(f) && !isStatic(f)){
            if(funcs.size > 0){
                funcs += `nl`
            }
            let fname = f.identifier
            let (argTypes, argValues, argNames) = extractParams(f.funcParams)
            funcs += quote(ServiceHub.register<$klass>($(fname.value), $argTypes){beanName: String, args: Array<Data> => 
                $argValues
                if(beanName.isEmpty()){
                    lookup<$klass>()
                }else{
                    lookup<$klass>(beanName)
                }.$(fname)($argNames)
            })
        }
    }
    funcs
}
private func extractParams(params: ArrayList<FuncParam>): (Tokens, Tokens, Tokens) {
    var argTypes = `lspare`
    var argValues = `empty_tokens`
    var argNames = `empty_tokens`
    for(i in 0 .. params.size){
        let p = params[i]
        if(argTypes.size > 1){
            argTypes += `, `
            argValues += `nl`
            argNames += `, `
        }
        argTypes += quote(TypeInfo.of<$(p.paramType)>())
        argValues += quote(let $(p.identifier) = f_data.convert<$(p.paramType)>(args[$i]).getOrThrow())
        argNames += quote(p.identifier)
    }
    argTypes += `rsquare`
    (argTypes, argValues, argNames)
}
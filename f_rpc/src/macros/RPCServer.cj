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
 * attr 可以没有，第一个元素如果是true或false，表示注册RPC服务的版本是否与项目cjpm.toml version一致；剩余属性都是fountain::f_bean.macrs.Bean宏的属性。
 * 如果第一个元素不是true或false，表示注册RPC服务的版本只采用项目cjpm.toml version的前两位；attr都是fountain::f_bean.macrs.Bean宏的属性
 */
public macro RPCServer(attr: Tokens, input: Tokens): Tokens {
    let attrs = if(attr.size == 0){
        `false`
    }else{
        attr
    }
    match(parseDecl(input)){
        case x: ClassDecl => 
            let (beanAttrs, exactly)if(attr.size > 1 && attr[0].kind == BOOL_LITERAL){
                (quote([$(attr[1..])]), quote($(attr[0])))
            }else if(attr.size == 1 && attr[0].kind == BOOL_LITERAL){
                (`empty_tokens`, quote($(attr[0])))
            }else if(attr.size > 0 && attr[0].kind != BOOL_LITERAL){
                (attr, `false`)
            }else{//attr.size == 0
                (`empty_tokens`, `false`)
            }
            quote(
                @Bean$beanAttrs
                $input
                private _ = {=>
                    $(extractFuncs($exactly, x))
                }()
            )
        case x => 
            diagReport(ERROR, input, '${x.identifier.value} must be a class decl', '')
            return `empty_tokens`
    }   
}

private func extractFuncs(exactlyVersion: Token, decl: ClassDecl): Tokens {
    let klass = decl.identifier
    var funcs = `empty_tokens`
    for(d in decl.body.decls){
        if(funcs.size > 0){
            funcs += `nl`
        }
        if(let f: FuncDecl <: d && isPublic(f) && !isStatic(f)){
            let fname = f.identifier
            let (argTypes, argValues, argNames) = extractParams(f.funcParams)
            let closure = quote(
                {beanName: String, args: Array<Data> => 
                    $argValues
                    if(beanName.isEmpty()){
                        lookup<$klass>()
                    }else{
                        lookup<$klass>(beanName)
                    }.$(fname)($argNames)
                }
            )
            funcs += quote(ServiceHub.register<$klass>($exactlyVersion, $fname, $argTypes, $closure))
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
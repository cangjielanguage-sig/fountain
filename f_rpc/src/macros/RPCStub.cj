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

import std.ast.*

public macro RPCStub(input: Tokens): Tokens {
    RPCStub(`empty_tokens`, input)
}
public macro RPCStub(attr: Tokens, input: Tokens): Tokens {
    var version = ''
    var name = ''
    var exactlyVersion = false
    var i = 0
    while (i < attr.size){
        let t = attr[i]
        match(t.value){
            case 'name' => 
                i += 2
                name = attr[i].value
            case 'version' =>
                i += 2
                version = attr[i].value
            case 'exactlyVersion' =>
                i += 2
                exactlyVersion = attr[i].value == 'true'
            case _ => ()
        }
        i++
    }
    genStub(exactlyVersion, version, name, parseDecl(input))
}
private func genStub(exactlyVersion: Bool, version: String, name: String, decl: Decl): Tokens {
    var tokens = `empty_tokens`
    match(decl){
        case x: InterfaceDecl => 
            let typeName = x.qualifiedName
            for(d in x.body.decls){
                if(let f: FuncDecl <- d){
                    tokens = genStub(exactlyVersion, version, name, typeName, f)
                }else{
                    diagReport(ERROR, d.toTokens(), 'decl ${d.identifier.value} in ${x.identifier.value} must be a func decl for fountain::f_rpc stub', '')
                    throw RPCException()
                }
            }
        case _ => 
            diagReport(ERROR, decl.toTokens(), '${x.identifier.value} must be a interface decl', '')
            throw RPCException()
    }
    let className = Token(IDENTIFIER, '${decl.identifier.value}_STUB__')
    quote(
        $decl
        @Bean
        public class $(className) <: $(decl.identifier){
            $tokens
        }
    )
}
private func genStub(exactlyVersion: Bool, version: String, name: String, typeName: String, decl: FuncDecl): Tokens {
    var argTypes = `lsquare`
    var argValues = `lsquare`
    for(arg in decl.funcParams){
        if(argTypes.size > 1){
            argTypes += `comma`
            argValues += `comma`
        }
        argTypes += quote(TypeInfo.of<$(arg.paramType)>().qualifiedName)
        argValues += quote($(arg.identifier).toData())
    }
    argTypes = `rsquare`
    argValues = `rsquare`
    quote(
        public func $(decl.identifier)($(decl.funcParams)): $(decl.declType) {
            let version = $(version)
            let name = $(name)
            let typeName = $(typeName)
            let methodName = $(decl.identifier.value)
            let argTypeNames = $(argTypes)
            let meta = ServiceMeta(version, name, typeName, methodName, argTypeNames, exactlyVersion: $exactlyVersion)
            let args = $(argValues)
            let message = RPCMessage(meta, args)
            RPCClient.call<$(decl.declType)>(message)
        }
    )
}
/*
    private var version: String = ''
    private var name: String = ''
    private var typeName: String = ''
    private var methodName: String = ''
    private var argTypeNames: Array<String> = []
*/
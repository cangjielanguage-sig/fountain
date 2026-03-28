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
macro package fountain::f_llm.macros

public import fountain::f_bean.macros.Bean

import std.ast.*
import fountain::f_macros.*
import fountain::f_llm.exception.*

public macro Tool(input: Tokens): Tokens {
    match(parseDecl(input)){
        case x: ClassDecl => expand(x)
        case x: MacroExpandDecl =>
            var d = x
            while(let inner: MacroExpandDecl <- d.macroInputDecl){
                d = inner
            }
            expand((d as ClassDecl) ?? throw FunctionCallingException('declaration modified by @Tool must be a class'))
        case _ => throw FunctionCallingException('@Tool can only be applied to class')
    }
}
public macro WeavedTool(input: Tokens): Tokens {
    quote(
        @Tool
        @Pointcut
        $input
    )
}
private func expand(decl: ClassDecl): Tokens {
    var tokens = quote()
    for(d in decl.body.decls){
        if(let f: FuncDecl <- d && f.isPublic() && !f.isStatic()){
            let params = f.funcParams
            if(params.size != 1){
                throw FunctionCallingException('public func decl in @Tool class must have only one parameter and be modified with @FunctionDefinition')
            }
            let paramType = params[0].paramType
            let name = f.identifier.value
            tokens += quote(
                let _ = FunctionDefinition.register<$(decl.identifier), $paramType>($name){p: $paramType => 
                    lookup<$(decl.identifier)>().$(f.identifier)(p)
                }
            ) + `nl`
        }
    }
    quote(
        @Bean
        $decl
        private let _ = {=> 
            $tokens
        }()
    )
}
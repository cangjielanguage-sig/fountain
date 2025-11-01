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
macro package f_orm.macros

import std.ast.*
import f_macros.*
import f_orm.exception.*
public import f_aspect.macros.*

public macro TransationalService(input: Tokens): Tokens {
    quote(
        @Bean
        $(transational(input))
    )
}
private func transational(input: Tokens): Tokens{
    match(parseDecl(input)){
        case x: ClassDecl => 
            let decls = x.body.decls
            for(i in 0 .. decls.size){
                func pointcut(f: FuncDecl){
                    parseDecl(quote(
                        @Pointcut
                        $x
                    ))
                }
                match(decls[i]){
                    case x: FuncDecl where x.isPublic() && !x.isStatic() => 
                        decls[i] = pointcut(x)
                    case x: MacroExpandDecl => 
                        var md = x
                        while(let x: MacroExpandDecl <- md.macroInputDecl){
                            md = x
                        }
                        if (let x: FuncDecl <- md.macroInputDecl && x.isPublic() && !x.isStatic()) {
                            let d = pointcut(x)
                            md.macroInputs = d.toTokens()
                            md.macroInputDecl = parseDecl(d.toTokens())
                        }
                    case _ => continue
                }
            }
            x.toTokens()
        case x: MacroExpandDecl => 
            var md = x
            while(let x: MacroExpandDecl <- md.macroInputDecl){
                md = x
            }
            let tokens = transational(md.macroInputs)
            md.macroInputs = tokens
            md.macroInputDecl = parseDecl(tokens)
            x.toTokens()
        case _ => 
            diagReport(ERROR, input, 'input must be a class decl', '')
            throw ORMException()
    }
}
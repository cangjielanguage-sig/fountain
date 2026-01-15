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
macro package f_bean.macros

public macro BeanParam(attr: Tokens, input: Tokens): Tokens {
    func setItem(attr: Tokens, param: FuncParam): Unit {
        setItem('name', param.identifier.value)
        setItem('cond', if(attr[0].kind == STRING_LITERAL){
            attr
        }else{
            quote(StringCond.$attr)
        })
    }
    assertParentContext('Constructor')
    match(parseDecl(attr)){
        case x: FuncParam => 
            setItem(attr, x)
        case x: MacroExpandParam => 
            var d: Decl = x
            while(let mp: MacroExpandParam <- d){
                d = mp.macroInputDecl
            }
            if(let p: FuncParam <- d){
                setItem(attr, p)
            }else{
                diagReport(ERROR, input, '${input} must be a FuncParam or a MacroExpandParam', '')
            }
        case _ => 
            diagReport(ERROR, input, '${input} must be a FuncParam or a MacroExpandParam', '')
    }
    input
}
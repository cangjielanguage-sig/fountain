/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */
macro package f_bean.macros

/**
 * 将@Configuration修饰的类里被@Constructor修饰的函数作为bean初始化函数。被@Configuration修饰的类不会注册到BeanFactory.
 */
public macro Configuration(input: Tokens): Tokens {
    let klass = ClassDecl(input)
    let identifier = klass.identifier
    var ctorTokens = quote(
        let ctors = HashMap<String, ()-> $identifier>()
    ) + `nl`
    for(d in klass.body.decls){
        match(d){
            case med: MacroExpandDecl => 
                var md: Decl = med
                while(let d: MacroExpandDecl <- md){
                    md = d.macroInputDecl
                    match(md){
                        case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() => 
                            let fname = f.identifier.value
                            ctorTokens += quote(
                                ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                            ) + `nl`
                        case f: FuncDecl where !isStatic(f) && isPublic(f) && f.funcParams.isEmpty() => 
                            let fname = f.identifier.value
                            ctorTokens += quote(
                                ctors[$fname] = {=> configuration.$(f.identifier)()}
                            )
                        case f: MacroExpandDecl => continue
                        case _ => break
                    }
                    break
                }
            case _ => ()
        }
    }
    quote(
        $input
        private let _ = {=>
            let configuration = $(identifier)()
            $ctorTokens
            for ((n, f) in ctors where TypeInfos.withAnnotation<$identifier, Constructor>(n, [])) {
                BeanFactory.instance.register<$identifier>(f)
            }
        }()
    )
}
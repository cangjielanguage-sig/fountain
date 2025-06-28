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

//Autowired Constructor Value只能是宏否则会用到大量反射
/**
 * 只能修饰类。将@Bean修饰的类注册到BeanFactory
 */
public macro Bean(input: Tokens): Tokens {
    let klass = ClassDecl(input)
    let identifier = klass.identifier
    var ctorTokens = quote(
        let ctors = HashMap<String, ()-> $identifier>()
    ) + `nl`
    var funcTokens = `lsquare`
    for(d in klass.body.decls){
        match(d){
            case f: FuncDecl where f.identifier.value == 'init' =>
                ctorTokens += quote(
                    ctors['init'] = {=> $(identifier)()}
                ) + `nl`
            case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() => 
                let fname = f.identifier.value
                ctorTokens += quote(
                    ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                ) + `nl`
            case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() =>
                ctorTokens += quote(
                    ctors['init'] = {=> $(identifier)()}
                ) + `nl`
            case med: MacroExpandDecl => 
                var md: Decl = med
                while(let d: MacroExpandDecl <- md){
                    md = d.macroInputDecl
                    match(md){
                        case f: FuncDecl where f.identifier.value == 'init' =>
                            ctorTokens += quote(
                                ctors['init'] = {=> $(identifier)()}
                            ) + `nl`
                        case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() => 
                            let fname = f.identifier.value
                            ctorTokens += quote(
                                ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                            ) + `nl`
                        case f: FuncDecl where !isStatic(f) && isPublic(f) && f.funcParams.isEmpty() => 
                            if(funcTokens.size > 1) {
                                funcTokens += `comma`
                            }
                            let fn = f.identifier
                            funcTokens += quote(($(fn.value), {o: Object => let _ = (o as $identifier)?.$fn()}))
                        case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() =>
                            ctorTokens += quote(
                                ctors['init'] = {=> $(identifier)()}
                            ) + `nl`
                        case f: MacroExpandDecl => continue
                        case _ => break
                    }
                    break
                }
            case _ => continue
        }
    }
    funcTokens += `rsquare`
    quote(
        $input
        private let _ = {=>
            $ctorTokens
            var constructor = if(ctors.size == 1){
                (ctors.values().iterator().next().getOrThrow(), true)
            }else{
                ({=>}, false)
            }
            if (!constructor[1]) {
                for ((n, f) in ctors where TypeInfos.withAnnotation<$identifier, Constructor>(n, [])) {
                    constructor = (f, true)
                    break
                }
            }
            if (!constructor[1] && let Some(f) <- ctors.get("init")) {
                constructor = (f, true)
            }
            if(!constructor[1]){
                throw BeanException('class $(identifier.value) must be with a public parameterless constructor or a public static parameterless function.')
            }
            var postConstruct = BeanManager.dummyFunc
            var destroy = BeanManager.dummyFunc
            var i = 0i8
            for((n, f) in $funcTokens){
                if(TypeInfos.withAnnotation<$identifier, PostConstruct>(n, [])) {
                    postConstruct = f
                    i++
                }else if (TypeInfos.withAnnotation<$identifier, Destroy>(n, [])) {
                    destroy = f
                    i++
                }
                if(i == 2) {
                    break
                }
            }
            BeanFactory.instance.register<$identifier>(constructor[0], postConstruct, destroy)
        }()
    )
}


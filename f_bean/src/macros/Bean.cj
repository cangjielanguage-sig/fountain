/*
   Copyright (c) 2022 WuJingrun（吴京润）
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
    let klass = match(parseDecl(input)){
        case x: ClassDecl => x
        case x: MacroExpandDecl => 
            return replaceMacroInputDecl(quote(@Bean), x).toTokens()
        case _ => 
            diagReport(ERROR, input, 'illegal decl', '')
            throw BeanException()
    }
    let identifier = klass.identifier
    var ctorTokens = quote(
        let ctors = HashMap<String, ()-> $identifier>()
    ) + `nl`
    for (d in klass.body.decls) {
        match (d) {
            case f: FuncDecl where f.identifier.value == 'init' => ctorTokens += quote(
                    ctors['init'] = {=> $(identifier)()}
                ) +
                `nl`
            case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() =>
                let fname = f.identifier.value
                ctorTokens += quote(
                    ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                ) +
                    `nl`
            case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() => ctorTokens += quote(
                    ctors['init'] = {=> $(identifier)()}
                ) +
                `nl`
            case med: MacroExpandDecl =>
                var md: Decl = med
                while (let d: MacroExpandDecl <- md) {
                    md = d.macroInputDecl
                    match (md) {
                        case f: FuncDecl where f.identifier.value == 'init' => ctorTokens += quote(
                                ctors['init'] = {=> $(identifier)()}
                            ) +
                            `nl`
                        case f: FuncDecl where isStatic(f) && isPublic(f) && f.funcParams.isEmpty() =>
                            let fname = f.identifier.value
                            ctorTokens += quote(
                                ctors[$fname] = {=> $(identifier).$(f.identifier)()}
                            ) +
                                `nl`
                        case f: PrimaryCtorDecl where isPublic(f) && f.funcParams.isEmpty() => ctorTokens += quote(
                                ctors['init'] = {=> $(identifier)()}
                            ) +
                            `nl`
                        case f: MacroExpandDecl => continue
                        case _ => break
                    }
                    break
                }
            case _ => continue
        }
    }
    quote(
        $input
        private let _ = {=>
            $ctorTokens
            var constructor = None<() -> $identifier>
            for ((n, f) in ctors where TypeInfos.withAnnotation<$identifier, Constructor>(n, [])) {
                constructor = n
                break
            }
            if (constructor.isNone() && let Some(f) <- ctors.get("init")) {
                constructor = f
            }
            BeanFactory.instance.register<$identifier>(constructor.getOrThrow{
                BeanException('class $(identifier.value) must be with a public parameterless constructor or a public static parameterless function.')
            })
        }()
    )
}